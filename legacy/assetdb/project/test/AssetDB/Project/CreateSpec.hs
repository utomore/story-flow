-- | 授權閘門。
--
-- 這是 @pack.toml@ 的 @commercial@ 欄位唯一有實際效果的地方,也是整個系統裡
-- 少數「寫錯會有法律後果」的判斷。它先前完全沒有測試(delivery/E004 T3)。
--
-- 測試的重點只有一個:**未查證的授權(NULL)必須與明確禁止(0)同樣被擋下**。
-- 這是三值邏輯最容易被寫錯的地方 —— @l.commercial = 0@ 對 NULL 求值是 NULL
-- 而不是 true,少寫一個 @IS NULL@ 分支就會讓授權不明的素材靜靜地進到商業專案。
module AssetDB.Project.CreateSpec (spec) where

import AssetDB.Archive (ArchiveTools (..))
import AssetDB.Manifest
import AssetDB.Naming (logicalNameText)
import AssetDB.Project.Create
import AssetDB.Store
import Codec.Archive.Zip qualified as Z
import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  gateSpec
  generatedSetSpec

gateSpec :: Spec
gateSpec = describe "nonCommercialPacks" $ do
  it "擋下 license_id 為 NULL 的素材包" $ withPacks $ \conn ->
    nonCommercialPacks conn ["unlicensed"] `shouldReturn` ["unlicensed"]

  it "擋下明確標記不可商用的素材包" $ withPacks $ \conn ->
    nonCommercialPacks conn ["noncomm"] `shouldReturn` ["noncomm"]

  it "放行可商用的素材包" $ withPacks $ \conn ->
    nonCommercialPacks conn ["comm"] `shouldReturn` []

  it "混合輸入時只回傳擋下的那些" $ withPacks $ \conn -> do
    blocked <- nonCommercialPacks conn ["comm", "noncomm", "unlicensed"]
    sort blocked `shouldBe` ["noncomm", "unlicensed"]

  -- 授權未查證與明確禁止在資料庫層是兩件事(NULL vs 0,見 SchemaSpec),
  -- 但在閘門這一側必須是同一件事:兩者都不放行。
  it "NULL 與 0 在閘門這一側等價" $ withPacks $ \conn -> do
    a <- nonCommercialPacks conn ["unlicensed"]
    b <- nonCommercialPacks conn ["noncomm"]
    length a `shouldBe` length b

  it "空清單直接回空,不查資料庫" $ withPacks $ \conn ->
    nonCommercialPacks conn [] `shouldReturn` []

  it "重複的 slug 不會讓同一包被擋兩次以上而改變語意" $ withPacks $ \conn -> do
    -- 呼叫端已經先 nub 過,但這裡不依賴那件事:重複輸入時結果仍然是
    -- 「這一包被擋下」,而不是某種數量相關的行為。
    blocked <- nonCommercialPacks conn ["noncomm", "noncomm"]
    blocked `shouldSatisfy` all (== "noncomm")
    blocked `shouldSatisfy` (not . null)

--------------------------------------------------------------------------------

-- | @new-project@ 的兩個產物必須用同一個集合(B007)。
--
-- 這裡走**真正的 'createProject'**,而不是只測輔助函式:fixture 的壓縮檔是
-- 即時建立的 ZIP,而 ZIP 是原生路徑(不需要 7-Zip 側車),所以整條
-- 「選素材 → 單筆解壓 → 寫產物 → 登記」在任何機器上都跑得動。
--
-- 這個缺陷是從 F005 繼承的:manifest 用過濾後的子集、@Assets.hs@ 用全集,
-- 差集就是「有 @AssetKey@ 常數但 manifest 查不到」的那些。
generatedSetSpec :: Spec
generatedSetSpec = describe "createProject 的產物集合" $ do
  it "manifest.json 與 Assets.hs 涵蓋同一組 key,驗證失敗的列兩邊一起排除" $
    withProjectFixture $ \st tools libRoot proj _ -> do
      _ <- createProject st tools (opts libRoot proj (\_ -> pure ()))
      mKeys <- manifestKeys proj
      aKeys <- assetsModuleKeys proj
      aKeys `shouldBe` mKeys
      mKeys `shouldBe` ["ui_gui_alpha_01"]

  it "被排除的列經 coOnEvent 出聲,附邏輯名稱與落點" $
    withProjectFixture $ \st tools libRoot proj _ -> do
      ref <- newIORef []
      _ <- createProject st tools (opts libRoot proj (\t -> modifyIORef' ref (<> [t])))
      events <- readIORef ref
      events `shouldSatisfy` any (T.isInfixOf badName)
      events `shouldSatisfy` any (T.isInfixOf "assets/sprites/UI Gui Bad 01.png")

  -- T5:落點是「檔案寫到哪、manifest 說在哪、登記說在哪」的唯一真相。
  -- 收斂到 destRelOf 之後,三處必須逐字相同。
  it "manifest 的 path 與 project_assets 的 dest_rel_path 逐字相同" $
    withProjectFixture $ \st tools libRoot proj _ -> do
      _ <- createProject st tools (opts libRoot proj (\_ -> pure ()))
      raw <- BS.readFile (proj </> "assets" </> "manifest.json")
      paths <- case eitherDecodeStrict raw :: Either String Manifest of
        Left e -> fail ("manifest.json 解不開:" <> e)
        Right m -> pure (sort (map maPath (mAssets m)))
      regs <-
        query_ (storeConn st) "SELECT dest_rel_path FROM project_assets ORDER BY dest_rel_path" ::
          IO [Only Text]
      -- 登記涵蓋全部複製進去的素材(含被排除的那筆),manifest 只涵蓋可用的那些,
      -- 所以比對的是「manifest 的每個 path 都能在登記裡逐字找到」。
      let registered = map fromOnly regs
      paths `shouldSatisfy` all (`elem` registered)
      paths `shouldBe` ["assets/sprites/ui_gui_alpha_01.png"]
      registered `shouldSatisfy` elem "assets/sprites/UI Gui Bad 01.png"

  -- 被排除的那一筆檔案仍在專案裡,致謝與授權義務跟著檔案走。
  it "被排除的素材仍然被複製、仍然登記,不是靜默丟掉整筆" $
    withProjectFixture $ \st tools libRoot proj _ -> do
      r <- createProject st tools (opts libRoot proj (\_ -> pure ()))
      crCopied r `shouldBe` 2
      BS.readFile (proj </> "assets" </> "sprites" </> "UI Gui Bad 01.png")
        `shouldReturn` pngLike "bad"

--------------------------------------------------------------------------------

badName :: Text
badName = "UI Gui Bad 01"

opts :: FilePath -> FilePath -> (Text -> IO ()) -> CreateOptions
opts libRoot proj onEvent =
  CreateOptions
    { coName = "game"
    , coPath = proj
    , coLibraryRoot = libRoot
    , coPacks = []
    , coQuery = Nothing
    , coAllowNonCommercial = False
    , coOnEvent = onEvent
    }

manifestKeys :: FilePath -> IO [Text]
manifestKeys proj = do
  raw <- BS.readFile (proj </> "assets" </> "manifest.json")
  case eitherDecodeStrict raw :: Either String Manifest of
    Left e -> fail ("manifest.json 解不開:" <> e)
    Right m -> pure (sort (map (logicalNameText . maKey) (mAssets m)))

-- | @Assets.hs@ 裡每個常數的查表 key,取自 @= AssetKey "…"@ 那一行。
assetsModuleKeys :: FilePath -> IO [Text]
assetsModuleKeys proj = do
  src <- decodeUtf8 <$> BS.readFile (proj </> "assets" </> "Assets.hs")
  pure (sort [k | l <- T.lines src, Just k <- [keyOf l]])
  where
    marker = "= AssetKey \""
    keyOf l = case T.breakOn marker l of
      (_, rest)
        | T.null rest -> Nothing
        | otherwise -> Just (T.takeWhile (/= '"') (T.drop (T.length marker) rest))

pngLike :: ByteString -> ByteString
pngLike tag = BC.pack "\137PNG\r\n\26\n" <> tag

-- | 兩筆素材,同一個可商用素材包:一筆合法,一筆邏輯名稱不合命名文法
-- (含大寫與空白),'toManifest' 必然 'Left'。
fixtureEntries :: [(Text, Text)]
fixtureEntries = [("a.png", "alpha"), ("bad.png", "bad")]

withProjectFixture :: (Store -> ArchiveTools -> FilePath -> FilePath -> FilePath -> IO a) -> IO a
withProjectFixture f = withSystemTempDirectory "assetdb-create" $ \dir -> do
  let libRoot = dir </> "library"
      zipRel = "comm" </> "pack.zip"
      proj = dir </> "game"
  createDirectoryIfMissing True (libRoot </> "comm")
  Z.createArchive (libRoot </> zipRel) $
    forM_ fixtureEntries $ \(entry, tag) -> do
      sel <- Z.mkEntrySelector (T.unpack entry)
      Z.addEntry Z.Deflate (pngLike (BC.pack (T.unpack tag))) sel
  st <- openStoreInMemory
  _ <- initSchema st
  seedLibrary (storeConn st)
  -- ZIP 是原生路徑,不需要 7-Zip 側車:測試因此與這台機器的環境無關。
  r <- f st (ArchiveTools Nothing) libRoot proj (libRoot </> zipRel)
  close (storeConn st)
  pure r

seedLibrary :: Connection -> IO ()
seedLibrary c = do
  execute_ c "INSERT INTO roots (id, path, label, kind) VALUES (1, '/tmp/lib', 'lib', 'packs')"
  execute_
    c
    "INSERT INTO licenses (id, name, commercial, attribution_required) VALUES \
    \  (901, 'Commercial OK', 1, 0)"
  execute_
    c
    "INSERT INTO packs (id, ulid, slug, name, root_id, rel_dir, license_id, created_at, updated_at) \
    \VALUES (1, '01pcomm', 'comm', 'comm', 1, 'v/comm', 901, 't', 't')"
  execute_
    c
    "INSERT INTO archives (id, ulid, pack_id, rel_path, format, sha256, bytes) VALUES \
    \  (1, '01ar1', 1, 'comm/pack.zip', 'zip', 'aa', 1)"
  mapM_
    (insertAsset c)
    [ ("01ARZ3NDEKTSV4RRFFQ69G5FA1", "ui_gui_alpha_01", "a.png")
    , ("01ARZ3NDEKTSV4RRFFQ69G5FB1", badName, "bad.png")
    ]

insertAsset :: Connection -> (Text, Text, Text) -> IO ()
insertAsset c (ulid, name, entry) = do
  execute
    c
    "INSERT OR IGNORE INTO blobs (sha256, bytes, kind, first_seen) VALUES (?, 1, 'image', 't')"
    (Only ("sha-" <> ulid))
  execute
    c
    "INSERT INTO assets \
    \  (ulid, logical_name, kind, archive_id, entry_path, original_name, ext, sha256, \
    \   pack_id, status, meta_json, created_at, updated_at) \
    \VALUES (?, ?, 'image', 1, ?, ?, '.png', ?, 1, 'active', NULL, 't', 't')"
    (ulid, name, entry, entry, "sha-" <> ulid)

--------------------------------------------------------------------------------

-- | 三個素材包,涵蓋授權的三種狀態:可商用、明確不可商用、未指定授權。
withPacks :: (Connection -> IO a) -> IO a
withPacks f = do
  st <- openStoreInMemory
  _ <- initSchema st
  let conn = storeConn st
  execute_ conn "INSERT INTO roots (id, path, label, kind) VALUES (1, '/tmp/lib', 'lib', 'packs')"
  -- 900 起跳:migration 001 已經種了八筆查證過的授權(id 1..8),
  -- 固定資料要避開它們。
  execute_
    conn
    "INSERT INTO licenses (id, name, commercial, attribution_required) VALUES \
    \  (901, 'Commercial OK', 1, 0), \
    \  (902, 'Non-Commercial', 0, 0)"
  mapM_ (insertPack conn) packFixtures
  r <- f conn
  close conn
  pure r

-- | (slug, license_id)。@Nothing@ 代表授權欄位留空 —— 匯入了但還沒查證。
packFixtures :: [(Text, Maybe Int)]
packFixtures =
  [ ("comm", Just 901)
  , ("noncomm", Just 902)
  , ("unlicensed", Nothing)
  ]

insertPack :: Connection -> (Text, Maybe Int) -> IO ()
insertPack conn (slug, licenseId) =
  execute
    conn
    "INSERT INTO packs (ulid, slug, name, root_id, rel_dir, license_id, created_at, updated_at) \
    \VALUES (?, ?, ?, 1, ?, ?, 't', 't')"
    ("01" <> slug, slug, slug, "vendor/" <> slug, licenseId)
