-- | 建立專案:選素材、過授權閘門、單筆解壓、寫 manifest 與 Assets.hs。
module AssetDB.Project.Create
  ( CreateOptions (..)
  , CreateResult (..)
  , createProject

    -- * 授權閘門
    --
    -- $licenseGate
  , nonCommercialPacks
  ) where

import AssetDB.Archive
import AssetDB.Id (newULID, unULID)
import AssetDB.Manifest
import AssetDB.Project.Assets
import AssetDB.Project.Internal
import AssetDB.Project.Template
import AssetDB.Store
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

data CreateOptions = CreateOptions
  { coName :: Text
  , coPath :: FilePath
  , coLibraryRoot :: FilePath
  , coPacks :: [Text]
  , coQuery :: Maybe Text
  , coAllowNonCommercial :: Bool
  , coOnEvent :: Text -> IO ()
  }

data CreateResult = CreateResult
  { crCopied :: Int
  , crSkipped :: [Text]
  , crBlocked :: [Text]
  -- ^ 被授權閘門擋下的素材包。
  }
  deriving stock (Eq, Show)

createProject :: Store -> ArchiveTools -> CreateOptions -> IO CreateResult
createProject st tools CreateOptions {..} = do
  exists <- doesDirectoryExist coPath
  nonEmpty <- if exists then not . null <$> listDirectory coPath else pure False
  if nonEmpty
    then do
      coOnEvent ("✗ 目標目錄已存在且非空:" <> T.pack coPath)
      pure (CreateResult 0 [] [])
    else do
      picks <- selectAssets (storeConn st) coPacks coQuery

      -- **授權閘門。** 這是 pack.toml 的 commercial 欄位唯一有實際效果的地方。
      blocked <-
        if coAllowNonCommercial
          then pure []
          else nonCommercialPacks (storeConn st) (nub (map pkPack picks))

      let usable = [p | p <- picks, pkPack p `notElem` blocked]

      mapM_ (\b -> coOnEvent ("⚠ 授權閘門擋下素材包「" <> b <> "」(不可商用)")) blocked

      packInfo <- packCredits (storeConn st) (nub (map pkPack usable))
      let credits = creditsSection packInfo

      mapM_ (createDirectoryIfMissing True . (coPath </>)) templateDirs
      mapM_
        (\TemplateFile {..} -> writeUtf8 (coPath </> tfPath) tfContent)
        (templateFiles coName credits)

      (copied, skipped) <- copyAssets tools coLibraryRoot coPath usable

      now <- getCurrentTime
      -- manifest.json 與 Assets.hs 從**同一個集合**產生:任一筆驗證失敗就兩邊
      -- 一起排除,而且經 coOnEvent 出聲(B007)。
      listed <- excludeUnusable coOnEvent pickLabel (toManifest coPath) copied
      -- 素材包與授權中繼資料涵蓋實際複製進去的全部素材:被排除的那一筆檔案仍在
      -- 專案裡,致謝與授權義務跟著檔案走。
      packsMeta <- manifestPacks (storeConn st) (nub (map pkPack copied))
      licMeta <- manifestLicenses (storeConn st) (nub (map pkPack copied))

      writeUtf8Bytes
        (coPath </> "assets" </> "manifest.json")
        (BL.toStrict (encodePretty (Manifest currentSchemaVersion coName now (map snd listed) packsMeta licMeta)))

      writeUtf8
        (coPath </> "assets" </> "Assets.hs")
        (renderAssetsModule coName [AssetRef (pkName p) (destRelOf p) (Just (pkPack p)) | (p, _) <- listed])

      writeUtf8 (coPath </> T.unpack coName <> ".cabal") (cabalFile coName)

      -- 專案要登記進資料庫,否則 links 無從指向它,而且沒有人回答得了
      -- 「這個素材被哪些專案用了」—— 那個反向查詢與正向一樣重要。
      registerProject st coName coPath copied

      pure (CreateResult (length copied) skipped blocked)

--------------------------------------------------------------------------------

-- | 把專案與它使用的素材寫進資料庫。
--
-- @copied_sha256@ 記錄複製當下的內容雜湊,讓之後能分辨兩種不同的狀況:
-- 「專案裡的素材被改過」與「來源壓縮檔更新了」。
registerProject :: Store -> Text -> FilePath -> [Pick] -> IO ()
registerProject st name path picks = do
  let conn = storeConn st
  now <- T.pack . iso8601Show <$> getCurrentTime
  u <- unULID <$> newULID
  withTransaction conn $ do
    -- 目前是單模板系統:鷹架產生(templateFiles / cabalFile)與這裡的
    -- template 值都是同一套 haskell-raylib-2d。projects.template 欄位是
    -- 為未來多模板預留的 —— 在第二套鷹架存在之前刻意不開 CLI 參數,
    -- 免得出現「可以指定但沒有效果」的假選項(delivery/E003)。
    execute
      conn
      "INSERT INTO projects (ulid,name,path,template,created_at,updated_at) VALUES (?,?,?,?,?,?) \
      \ON CONFLICT (name) DO UPDATE SET path = excluded.path, updated_at = excluded.updated_at"
      (u, name, T.pack path, "haskell-raylib-2d" :: Text, now, now)
    rows <- query conn "SELECT id FROM projects WHERE name = ?" (Only name) :: IO [Only Int]
    case rows of
      (Only pid : _) -> do
        execute conn "DELETE FROM project_assets WHERE project_id = ?" (Only pid)
        mapM_
          ( \p ->
              execute
                conn
                "INSERT OR IGNORE INTO project_assets \
                \  (project_id, asset_id, dest_rel_path, copy_mode, copied_sha256, added_at) \
                \SELECT ?, a.id, ?, 'copy', ?, ? FROM assets a WHERE a.ulid = ?"
                ( pid
                , -- 落點只有 'destRelOf' 一份實作(B007 T5):檔案寫到哪、manifest
                  -- 說在哪、登記說在哪,必須是同一個答案。
                  destRelOf p
                , pkSha p
                , now
                , pkUlid p
                )
          )
          picks
      [] -> pure ()

-- $licenseGate
--
-- 'nonCommercialPacks' 匯出是為了讓它**被直接測到**。它是專案裡少數帶法律
-- 後果的判斷,而從 'createProject' 走到它需要一整組真實的壓縮檔與
-- @ArchiveTools@ —— 那樣的測試貴到不會有人寫,於是這條防線就一直沒有測試。

-- | 不可商用的素材包。**NULL 也算不可用** —— 授權未查證時不該放行。
nonCommercialPacks :: Connection -> [Text] -> IO [Text]
nonCommercialPacks _ [] = pure []
nonCommercialPacks conn slugs = do
  rows <-
    query
      conn
      ( Query
          ( "SELECT p.slug FROM packs p LEFT JOIN licenses l ON l.id = p.license_id \
            \WHERE p.slug IN ("
              <> T.intercalate "," (map (const "?") slugs)
              <> ") AND (l.commercial IS NULL OR l.commercial = 0)"
          )
      )
      (map SQLText slugs)
  pure (map fromOnly rows)

packCredits :: Connection -> [Text] -> IO [(Text, Maybe Text, Bool)]
packCredits _ [] = pure []
packCredits conn slugs = do
  rows <-
    query
      conn
      ( Query
          ( "SELECT p.name, l.name, COALESCE(l.attribution_required,0) \
            \FROM packs p LEFT JOIN licenses l ON l.id = p.license_id \
            \WHERE p.slug IN ("
              <> T.intercalate "," (map (const "?") slugs)
              <> ") ORDER BY p.name"
          )
      )
      (map SQLText slugs) ::
      IO [(Text, Maybe Text, Int)]
  pure [(n, l, r /= 0) | (n, l, r) <- rows]

cabalFile :: Text -> Text
cabalFile name =
  T.unlines
    [ "cabal-version:      3.4"
    , "name:               " <> name
    , "version:            0.1.0.0"
    , "build-type:         Simple"
    , ""
    , "executable " <> name
    , "    main-is:          Main.hs"
    , "    hs-source-dirs:   app, src, assets"
    , "    other-modules:    Assets"
    , "    build-depends:"
    , "        , assetdb-core"
    , "        , base >=4.17 && <5"
    , "        , aeson"
    , "        , containers"
    , "        , text"
    , "        -- , h-raylib"
    , "        -- , apecs"
    , "    default-language: GHC2021"
    ]
