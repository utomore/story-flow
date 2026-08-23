-- | 專案增量同步:把符合條件的素材加進**已登記**的專案。
--
-- == 為什麼對帳要先於寫入
--
-- 「該不該覆蓋一個使用者可能已經手改過的檔案」是這個功能最容易寫錯的地方。
-- 把對帳(純查詢)與寫入(需要壓縮檔)分成兩個入口之後,四類判定可以對著
-- 真實的登記資料與真實的暫存目錄直接測到,不必為了看它而準備一整組壓縮檔。
--
-- == 只增不刪
--
-- 只有「新增」類會被寫進磁碟。「來源已更新」與「本地已修改」只回報 ——
-- 那兩件事各自需要自己的旗標與自己的確認語意,不在本契約內。
-- @project_assets@ 的既有列一律不動:'AssetDB.Project.Create' 的登記是
-- @DELETE FROM project_assets@ 之後重灌,**這裡絕對不能走那條路徑**,
-- 否則一次同步就把整個專案的登記洗掉。
module AssetDB.Project.Sync
  ( SyncOptions (..)
  , SyncClass (..)
  , SyncEntry (..)
  , SyncPlan (..)
  , SyncResult (..)
  , SyncError (..)
  , planSync
  , syncProject
  ) where

import AssetDB.Archive (ArchiveTools)
import AssetDB.Guard (guardedTry)
import AssetDB.Id (parseULID)
import AssetDB.Ingest.Hash (sha256File, unSha256)
import AssetDB.Manifest
import AssetDB.Naming (validateLogicalName)
import AssetDB.Project.Assets (AssetRef (..), renderAssetsModule)
import AssetDB.Project.Create (nonCommercialPacks)
import AssetDB.Project.Internal
import AssetDB.Store
import AssetDB.Types (AssetKind (..), parseTextEnum)
import Data.Aeson (Value (Null), decodeStrict)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple
import System.Directory (doesDirectoryExist, doesFileExist, getFileSize)
import System.FilePath ((</>))

data SyncOptions = SyncOptions
  { soName :: Text
  -- ^ 專案名稱,即 @projects.name@。
  , soLibraryRoot :: FilePath
  -- ^ 素材庫根目錄,壓縮檔相對路徑的基準。
  , soPacks :: [Text]
  -- ^ @--pack@,可重複;空清單代表不限素材包。
  , soQuery :: Maybe Text
  -- ^ @--match@,邏輯名稱的子字串。
  , soAllowNonCommercial :: Bool
  -- ^ 關掉授權閘門。
  , soConfirm :: Bool
  -- ^ 'False' 時不寫磁碟、不寫資料庫。
  , soOnEvent :: Text -> IO ()
  -- ^ 進度與警告。
  }

-- | 對帳的四類。順序即回報的呈現順序。
data SyncClass = SyncNew | SyncUnchanged | SyncSourceUpdated | SyncLocallyModified
  deriving stock (Eq, Show)

data SyncEntry = SyncEntry
  { seUlid :: Text
  , seName :: Text
  -- ^ 邏輯名稱。
  , seRelPath :: Text
  -- ^ 專案根目錄的相對路徑,永遠以 @/@ 分隔。
  , seClass :: SyncClass
  }
  deriving stock (Eq, Show)

data SyncPlan = SyncPlan
  { spProjectPath :: FilePath
  , spEntries :: [SyncEntry]
  -- ^ 只含本次候選素材,依邏輯名稱排序。
  , spBlocked :: [Text]
  -- ^ 被授權閘門擋下的素材包(只影響新增)。
  , spWarnedPacks :: [Text]
  -- ^ 既有素材仍留著、但授權為不可商用或未查證的素材包。
  --
  -- 與 'spBlocked' **語意不同不可合併**:'spBlocked' 是「被擋下、不會加入」,
  -- 這裡是「已經在專案裡、不會被移除,但發行前要處理」。
  }
  deriving stock (Eq, Show)

data SyncResult = SyncResult
  { syPlan :: SyncPlan
  , syCopied :: Int
  , sySkipped :: [Text]
  -- ^ 讀取失敗的訊息。
  }
  deriving stock (Eq, Show)

data SyncError = ProjectNotRegistered Text | ProjectDirMissing FilePath
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------

-- | 只對帳,不寫磁碟也不寫資料庫。可重複執行,結果相同。
planSync :: Store -> SyncOptions -> IO (Either SyncError SyncPlan)
planSync st opts = fmap prPlan <$> prepare st opts

-- | @soConfirm = False@ 時等同 'planSync'(包成 @SyncResult plan 0 []@)。
syncProject :: Store -> ArchiveTools -> SyncOptions -> IO (Either SyncError SyncResult)
syncProject st tools opts@SyncOptions {..} = do
  prepared <- prepare st opts
  case prepared of
    Left e -> pure (Left e)
    Right pr
      | not soConfirm -> pure (Right (SyncResult (prPlan pr) 0 []))
      | otherwise -> do
          let projPath = spProjectPath (prPlan pr)
          (copied, skipped) <- copyAssets tools soLibraryRoot projPath (prNewPicks pr)
          -- 登記與 updated_at 在同一個交易內,避免出現「檔案寫了但沒登記」
          -- 與「登記了但時間戳沒動」的中間狀態。
          registerAdditions st (prProjectId pr) copied
          -- 重讀登記全集再重寫,而不是在記憶體裡合併「既有 + 新增」——
          -- 合併邏輯會與登記邏輯漂移,重讀天然保證「manifest 描述的就是登記的」。
          rewriteGenerated st soName projPath (prProjectId pr) soOnEvent
          pure (Right (SyncResult (prPlan pr) (length copied) skipped))

--------------------------------------------------------------------------------

-- | 一筆既有登記。
data Registration = Registration
  { rgDestRel :: Text
  , rgCopiedSha :: Maybe Text
  }

-- | 對帳與寫入共用的準備結果。'planSync' 只取 'prPlan';
-- 'syncProject' 另外需要「新增」類對應的 'Pick' 才有辦法解壓。
data Prepared = Prepared
  { prProjectId :: Int
  , prPlan :: SyncPlan
  , prNewPicks :: [Pick]
  }

prepare :: Store -> SyncOptions -> IO (Either SyncError Prepared)
prepare st SyncOptions {..} = do
  let conn = storeConn st
  rows <- query conn "SELECT id, path FROM projects WHERE name = ?" (Only soName) :: IO [(Int, Text)]
  case rows of
    [] -> pure (Left (ProjectNotRegistered soName))
    ((pid, pathT) : _) -> do
      let projPath = T.unpack pathT
      present <- doesDirectoryExist projPath
      if not present
        then pure (Left (ProjectDirMissing projPath))
        else do
          picks <- selectAssets conn soPacks soQuery
          reg <- loadRegistrations conn pid
          classified <- mapM (classify conn projPath reg) picks

          -- **授權閘門只擋新增,不回溯既有。** 既有登記素材的素材包後來授權
          -- 降級時,素材仍留在磁碟、仍列入重寫的 manifest 與 Assets.hs
          -- —— 否則遊戲端已經 import 的 AssetKey 常數會靜默消失。
          --
          -- 警告的涵蓋範圍是**登記的全集**,不是本次候選(B006)。重寫的 manifest
          -- 涵蓋全集,警告就必須跟著全集;只查本次 @--pack@ / @--match@ 命中的
          -- 那些,等於讓不在篩選條件內的授權問題靜靜通過。
          registeredPacks <- registeredPackSlugs conn pid
          let newPacks = nub [pkPack p | (p, e) <- classified, seClass e == SyncNew]
          (blocked, warned) <-
            if soAllowNonCommercial
              then pure ([], [])
              else do
                bad <- nonCommercialPacks conn (nub (newPacks <> registeredPacks))
                pure (filter (`elem` bad) newPacks, filter (`elem` bad) registeredPacks)

          mapM_
            (\b -> soOnEvent ("⚠ 授權閘門擋下素材包「" <> b <> "」(不可商用),該包的新增素材不會加入"))
            blocked
          mapM_
            ( \w ->
                soOnEvent
                  ( "⚠ 既有登記素材所屬的素材包「"
                      <> w
                      <> "」授權為不可商用或未查證。素材保留在專案內、仍列入 manifest,請自行確認發行風險"
                  )
            )
            warned

          let kept = [(p, e) | (p, e) <- classified, not (seClass e == SyncNew && pkPack p `elem` blocked)]
          pure
            ( Right
                Prepared
                  { prProjectId = pid
                  , prPlan =
                      SyncPlan
                        { spProjectPath = projPath
                        , spEntries = map snd kept
                        , spBlocked = blocked
                        , spWarnedPacks = warned
                        }
                  , prNewPicks = [p | (p, e) <- kept, seClass e == SyncNew]
                  }
            )

-- | 登記全集所屬的素材包 slug,**與 'rewriteGenerated' 的涵蓋範圍相同**。
--
-- @packs@ 走 INNER JOIN 而不是 LEFT JOIN:@assets.pack_id@ 為 NULL 的列沒有素材包,
-- 也就沒有授權可查 —— 它不是「未查證的授權」,而是根本不屬於任何包。
registeredPackSlugs :: Connection -> Int -> IO [Text]
registeredPackSlugs conn pid =
  map fromOnly
    <$> ( query
            conn
            "SELECT DISTINCT p.slug FROM project_assets pa \
            \JOIN assets a ON a.id = pa.asset_id \
            \JOIN packs p ON p.id = a.pack_id \
            \WHERE pa.project_id = ? ORDER BY p.slug"
            (Only pid) ::
            IO [Only Text]
        )

loadRegistrations :: Connection -> Int -> IO (Map Text Registration)
loadRegistrations conn pid = do
  rows <-
    query
      conn
      "SELECT a.ulid, pa.dest_rel_path, pa.copied_sha256 \
      \FROM project_assets pa JOIN assets a ON a.id = pa.asset_id \
      \WHERE pa.project_id = ?"
      (Only pid) ::
      IO [(Text, Text, Maybe Text)]
  pure (Map.fromList [(u, Registration d c) | (u, d, c) <- rows])

classify :: Connection -> FilePath -> Map Text Registration -> Pick -> IO (Pick, SyncEntry)
classify conn projPath reg p =
  case Map.lookup (pkUlid p) reg of
    -- 路徑取登記的 dest_rel_path,不重算 —— 重算會在命名規則變動之後
    -- 把既有素材指到一個不存在的新路徑上。
    Just r -> do
      cls <- reconcile conn projPath r (pkSha p)
      pure (p, entry (rgDestRel r) cls)
    Nothing -> pure (p, entry (destRelOf p) SyncNew)
  where
    entry rel c = SyncEntry {seUlid = pkUlid p, seName = pkName p, seRelPath = rel, seClass = c}

-- | 既有登記 × 磁碟現況 → 四類之一。
reconcile :: Connection -> FilePath -> Registration -> Text -> IO SyncClass
reconcile conn projPath r srcSha = do
  let dest = projPath </> T.unpack (rgDestRel r)
  present <- either (const False) id <$> guardedTry (doesFileExist dest)
  if not present
    then pure SyncLocallyModified
    else do
      -- 大小優先(F006 D3):大小不同必然內容不同,不必讀檔。
      -- blobs 查不到對應列時退回讀檔,不因為缺一筆中繼資料就誤判。
      mismatch <- sizeMismatch conn dest (rgCopiedSha r)
      if mismatch
        then pure SyncLocallyModified
        else do
          -- TOCTOU:'doesFileExist' 與這一行之間,檔案可能已經被刪掉、
          -- 改名或被其他程式鎖住。契約 §6 已經把「檔案已不在」歸進
          -- 'SyncLocallyModified'(不覆蓋、請人來看),讀不到雜湊落在
          -- 同一類 —— 沒有比對基準時保守處理,而不是讓一個 IOException
          -- 穿出子系統邊界把整次 sync 炸掉(G-E003)。
          hashed <- guardedTry (unSha256 <$> sha256File dest)
          pure $ case hashed of
            Left _ -> SyncLocallyModified
            Right disk -> case rgCopiedSha r of
              Just c
                | disk /= c -> SyncLocallyModified
                | c == srcSha -> SyncUnchanged
                | otherwise -> SyncSourceUpdated
              -- copied_sha256 為 NULL 時沒有比對基準,退回與來源比(F006 A4):
              -- 保守地永遠不覆蓋。
              Nothing
                | disk == srcSha -> SyncUnchanged
                | otherwise -> SyncLocallyModified

sizeMismatch :: Connection -> FilePath -> Maybe Text -> IO Bool
sizeMismatch _ _ Nothing = pure False
sizeMismatch conn dest (Just sha) = do
  rows <- query conn "SELECT bytes FROM blobs WHERE sha256 = ?" (Only sha) :: IO [Only Integer]
  case rows of
    (Only expected : _) -> do
      -- 讀不到大小(檔案剛被刪掉、權限不足)就當成不一致 —— 接下來的
      -- 分類是 'SyncLocallyModified',也就是不覆蓋。
      actual <- guardedTry (getFileSize dest)
      pure (either (const True) (/= expected) actual)
    [] -> pure False

--------------------------------------------------------------------------------

-- | 只 INSERT,**不 DELETE、不覆蓋**。@INSERT OR IGNORE@ 讓
-- @PRIMARY KEY (project_id, asset_id)@ 與 @UNIQUE (project_id, dest_rel_path)@
-- 自然吸收重複。
registerAdditions :: Store -> Int -> [Pick] -> IO ()
registerAdditions st pid picks = do
  let conn = storeConn st
  now <- T.pack . iso8601Show <$> getCurrentTime
  withTransaction conn $ do
    mapM_
      ( \p ->
          execute
            conn
            "INSERT OR IGNORE INTO project_assets \
            \  (project_id, asset_id, dest_rel_path, copy_mode, copied_sha256, added_at) \
            \SELECT ?, a.id, ?, 'copy', ?, ? FROM assets a WHERE a.ulid = ?"
            (pid, destRelOf p, pkSha p, now, pkUlid p)
      )
      picks
    execute conn "UPDATE projects SET updated_at = ? WHERE id = ?" (now, pid)

-- | 登記全集的一列。@packs@ 走 LEFT JOIN(@assets.pack_id@ 可為 NULL)——
-- 少一筆就少一個 @AssetKey@ 常數,而那會讓遊戲端編不過。
data FullRow = FullRow
  { frUlid :: Text
  , frName :: Text
  , frKind :: AssetKind
  , frMeta :: Maybe Text
  , frPack :: Maybe Text
  , frLicense :: Maybe Text
  , frPath :: Text
  , frSha :: Text
  }

instance FromRow FullRow where
  fromRow =
    FullRow <$> field <*> field <*> (toKind <$> field) <*> field
      <*> field <*> field <*> field <*> field
    where
      toKind t = either (const KSource) id (parseTextEnum t)

-- | 以重讀的登記全集重寫 @assets/manifest.json@ 與 @assets/Assets.hs@。
--
-- 樣板檔案(@SKILL.md@、@README.md@、@docs\/@、@\<NAME\>.cabal@ …)一個都不重寫,
-- 連內容相同也不寫 —— 使用者手改過樣板是預期中的事。
-- @manifest.json@ 與 @Assets.hs@ 從**同一個集合**產生:任一筆驗證失敗就兩邊
-- 一起排除,而且經 @soOnEvent@ 出聲(B007)。
rewriteGenerated :: Store -> Text -> FilePath -> Int -> (Text -> IO ()) -> IO ()
rewriteGenerated st name projPath pid onEvent = do
  let conn = storeConn st
  rows <-
    query
      conn
      "SELECT a.ulid, COALESCE(a.logical_name,''), a.kind, a.meta_json, p.slug, l.name, \
      \       pa.dest_rel_path, COALESCE(pa.copied_sha256, a.sha256, '') \
      \FROM project_assets pa \
      \JOIN assets a ON a.id = pa.asset_id \
      \LEFT JOIN packs p ON p.id = a.pack_id \
      \LEFT JOIN licenses l ON l.id = p.license_id \
      \WHERE pa.project_id = ? \
      \ORDER BY a.logical_name"
      (Only pid)
  now <- getCurrentTime
  usable <- excludeUnusable onEvent rowLabel toFullManifest rows
  -- 素材包與授權中繼資料涵蓋**登記的全集**,不隨產物排除而縮減:被排除的那一筆
  -- 檔案仍然在專案目錄裡,致謝與授權義務跟著檔案走,不跟著 AssetKey 常數走。
  let slugs = nub (mapMaybe frPack rows)
  packsMeta <- manifestPacks conn slugs
  licMeta <- manifestLicenses conn slugs

  writeUtf8Bytes
    (projPath </> "assets" </> "manifest.json")
    (BL.toStrict (encodePretty (Manifest currentSchemaVersion name now (map snd usable) packsMeta licMeta)))

  writeUtf8
    (projPath </> "assets" </> "Assets.hs")
    (renderAssetsModule name [AssetRef (frName r) (frPath r) (frPack r) | (r, _) <- usable])

-- | 登記全集一列的定位資訊。@frPath@ 是 @dest_rel_path@ —— 專案裡的落點,
-- 使用者拿它就能直接找到檔案。
rowLabel :: FullRow -> Text
rowLabel r = labelOf (frName r) (frUlid r) (frPath r)

-- | maSha256 取 @copied_sha256@ 而不是來源的最新 @sha256@:manifest 描述的是
-- 專案目錄裡的那一份檔案。取來源 sha 會讓「來源已更新」的項目在 manifest 裡
-- 宣稱一個磁碟上並不存在的雜湊(F006 A2)。
toFullManifest :: FullRow -> Either Text ManifestAsset
toFullManifest r = do
  u <- parseULID (frUlid r)
  k <- either (Left . T.pack . show) Right (validateLogicalName (frName r))
  pure
    ManifestAsset
      { maId = u
      , maKey = k
      , maPath = frPath r
      , maKind = frKind r
      , maSha256 = frSha r
      , maPack = frPack r
      , maLicense = frLicense r
      , maMeta = maybe Null id (frMeta r >>= decodeStrict . encodeUtf8)
      }
