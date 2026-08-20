-- | @project@ 套件的內部共用輔助。**不是公開介面** ——
-- 不在 @exposed-modules@ 裡,套件外(含測試套件)引用不到。
--
-- 這裡放的是 'AssetDB.Project.Create' 與 'AssetDB.Project.Sync' **必須逐字相同**
-- 的四件事:選素材的 SQL 語意、單筆解壓、manifest 的組法、以及 UTF-8 寫檔。
-- 兩條指令對「哪些素材可用」給出不同答案是這個子系統最嚴重的漂移,
-- 而共用同一份實作是唯一擋得住它的方式(F006 T1)。
module AssetDB.Project.Internal
  ( Pick (..)
  , selectAssets
  , destRelOf
  , copyAssets
  , excludeUnusable
  , pickLabel
  , labelOf
  , toManifest
  , manifestPacks
  , manifestLicenses
  , extOf
  , writeUtf8
  , writeUtf8Bytes
  ) where

import AssetDB.Archive
import AssetDB.Id (parseULID)
import AssetDB.Manifest
import AssetDB.Naming (validateLogicalName)
import AssetDB.PathText (extensionOf)
import AssetDB.Types (AssetKind (..), kindDefaultDir, parseTextEnum)
import Data.Aeson (Value (Null), decodeStrict)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))

-- | 一筆待複製的素材。
data Pick = Pick
  { pkUlid :: Text
  , pkName :: Text
  , pkKind :: AssetKind
  , pkSha :: Text
  , pkMeta :: Maybe Text
  , pkArchive :: Text
  , pkEntry :: Text
  , pkPack :: Text
  , pkLicense :: Maybe Text
  }

instance FromRow Pick where
  fromRow =
    Pick <$> field <*> field <*> (toKind <$> field) <*> field <*> field
      <*> field <*> field <*> field <*> field
    where
      toKind t = either (const KSource) id (parseTextEnum t)

selectAssets :: Connection -> [Text] -> Maybe Text -> IO [Pick]
selectAssets conn packs q = do
  let packFilter =
        if null packs
          then ""
          else " AND p.slug IN (" <> T.intercalate "," (map (const "?") packs) <> ")"
      textFilter =
        case q of
          Nothing -> ""
          Just _ -> " AND a.logical_name LIKE ?"
      sql =
        "SELECT a.ulid, a.logical_name, a.kind, a.sha256, a.meta_json, \
        \       ar.rel_path, a.entry_path, p.slug, l.name \
        \FROM assets a \
        \JOIN archives ar ON ar.id = a.archive_id \
        \JOIN packs p ON p.id = a.pack_id \
        \LEFT JOIN licenses l ON l.id = p.license_id \
        \WHERE a.logical_name IS NOT NULL AND a.status = 'active' \
        \  AND a.sha256 IS NOT NULL"
          <> packFilter
          <> textFilter
          <> " ORDER BY a.logical_name"
  query conn (Query sql) (map SQLText packs <> maybe [] (\t -> [SQLText ("%" <> t <> "%")]) q)

-- | 一筆素材在專案裡的落點,專案根目錄的相對路徑,永遠以 @/@ 分隔。
--
-- 與 'copyAssets' 實際寫入的位置、以及 'toManifest' 的 'maPath' 必須一致。
destRelOf :: Pick -> Text
destRelOf p = "assets/" <> kindDefaultDir (pkKind p) <> "/" <> pkName p <> extOf (pkEntry p)

--------------------------------------------------------------------------------

manifestPacks :: Connection -> [Text] -> IO [ManifestPack]
manifestPacks _ [] = pure []
manifestPacks conn slugs = do
  rows <-
    query
      conn
      ( Query
          ( "SELECT p.name, p.vendor, p.source_url, p.version, l.name \
            \FROM packs p LEFT JOIN licenses l ON l.id = p.license_id WHERE p.slug IN ("
              <> T.intercalate "," (map (const "?") slugs)
              <> ") ORDER BY p.name"
          )
      )
      (map SQLText slugs)
  pure [ManifestPack n v u ver l | (n, v, u, ver, l) <- rows]

manifestLicenses :: Connection -> [Text] -> IO [ManifestLicense]
manifestLicenses _ [] = pure []
manifestLicenses conn slugs = do
  rows <-
    query
      conn
      ( Query
          ( "SELECT DISTINCT l.name, l.commercial, l.attribution_required, l.credit_text \
            \FROM packs p JOIN licenses l ON l.id = p.license_id WHERE p.slug IN ("
              <> T.intercalate "," (map (const "?") slugs)
              <> ") ORDER BY l.name"
          )
      )
      (map SQLText slugs) ::
      IO [(Text, Int, Int, Maybe Text)]
  pure [ManifestLicense n (c /= 0) (a /= 0) note | (n, c, a, note) <- rows]

--------------------------------------------------------------------------------

-- | **單筆解壓。** 永遠不會整包解開 —— 專案只拿它真正用到的東西。
copyAssets :: ArchiveTools -> FilePath -> FilePath -> [Pick] -> IO ([Pick], [Text])
copyAssets tools libRoot projectRoot picks = go picks [] []
  where
    go [] ok bad = pure (reverse ok, reverse bad)
    go (p : ps) ok bad = do
      r <- readEntry tools (libRoot </> T.unpack (pkArchive p)) (pkEntry p)
      case r of
        Left err -> go ps ok (renderArchiveError err : bad)
        Right content -> do
          let dest = projectRoot </> "assets" </> T.unpack (kindDefaultDir (pkKind p)) </> T.unpack (pkName p <> extOf (pkEntry p))
          createDirectoryIfMissing True (takeDirectory dest)
          BS.writeFile dest content
          go ps (p : ok) bad

--------------------------------------------------------------------------------

-- | 產物集合的共用過濾(B007)。
--
-- @manifest.json@ 與 @Assets.hs@ 必須從**同一個集合**產生:任一筆驗證失敗
-- (ULID 解析失敗、邏輯名稱缺漏或不合文法)就兩邊一起排除。兩邊集合不同會產生
-- 「@Assets.hs@ 有這個 @AssetKey@ 常數,但 manifest 查不到」的組合 —— 編譯得過、
-- 執行期查表落空,正是產生 @Assets.hs@ 的全部理由要消滅的失敗模式。
--
-- 排除一律**出聲**。靜默丟資料是最不該的處理:素材在專案裡卻沒有常數,
-- 使用者查不出原因,也不知道要去修哪一筆的邏輯名稱。
excludeUnusable
  :: (Text -> IO ())
  -- ^ 事件回呼(@coOnEvent@ / @soOnEvent@)。
  -> (a -> Text)
  -- ^ 定位資訊:讓使用者找得到是哪一筆。
  -> (a -> Either Text b)
  -- ^ 驗證。'Left' 是被排除的原因。
  -> [a]
  -> IO [(a, b)]
excludeUnusable onEvent locate validate = fmap concat . mapM step
  where
    step x = case validate x of
      Left why ->
        [] <$ onEvent ("⚠ 排除 " <> locate x <> ":" <> why <> "。manifest.json 與 Assets.hs 都不會列入這一筆")
      Right b -> pure [(x, b)]

-- | 「名稱 [ulid …,落點 …]」。
--
-- 邏輯名稱可能為空,而那正是被排除的原因之一 —— 所以 ULID 與落點永遠都在,
-- 使用者總有辦法定位到是哪一筆。
labelOf :: Text -> Text -> Text -> Text
labelOf name ulid dest =
  (if T.null name then "(無邏輯名稱)" else "「" <> name <> "」")
    <> " [ulid "
    <> ulid
    <> ",落點 "
    <> dest
    <> "]"

-- | 'Pick' 的定位資訊。
pickLabel :: Pick -> Text
pickLabel p = labelOf (pkName p) (pkUlid p) (destRelOf p)

--------------------------------------------------------------------------------

toManifest :: FilePath -> Pick -> Either Text ManifestAsset
toManifest _ p = do
  u <- parseULID (pkUlid p)
  k <- either (Left . T.pack . show) Right (validateLogicalName (pkName p))
  pure
    ManifestAsset
      { maId = u
      , maKey = k
      , -- 落點只有 'destRelOf' 一份實作(B007 T5)。
        maPath = destRelOf p
      , maKind = pkKind p
      , maSha256 = pkSha p
      , maPack = Just (pkPack p)
      , maLicense = pkLicense p
      , maMeta = maybe Null id (pkMeta p >>= decodeStrict . encodeUtf8)
      }

-- | 副檔名抽取的唯一實作在 core 的 AssetDB.PathText(G-E002)。
extOf :: Text -> Text
extOf = extensionOf

writeUtf8 :: FilePath -> Text -> IO ()
writeUtf8 p = writeUtf8Bytes p . encodeUtf8

-- 一律以 UTF-8 位元組寫檔。Data.Text.IO 用 locale 編碼,
-- Windows 上寫不出中文與符號。
writeUtf8Bytes :: FilePath -> BS.ByteString -> IO ()
writeUtf8Bytes p bs = createDirectoryIfMissing True (takeDirectory p) >> BS.writeFile p bs
