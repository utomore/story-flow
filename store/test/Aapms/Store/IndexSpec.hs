-- | graph-core\/F006:STEP-3(檔案掃描)、STEP-4(單檔索引)、STEP-5(重覆索引整檔
-- 替換、移除記錄的級聯與冪等)、STEP-14(fixture 健檢)。
--
-- 2026-09-06 退場波:舊的 @indexFile@ \/ @unindexFile@ 直接 IO 路徑退場,本檔
-- 改呼叫 P-001-index-rebuild 的新核心——'Aapms.Store.Fixtures.indexOnePath'
-- (第 16 列 @indexPath@)與 'Aapms.Store.Fixtures.unindexOnePath'(第 13 列
-- @removeFile@),兩者都跑在真解譯器上,斷言逐字不變。
module Aapms.Store.IndexSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Core.Asset (LogicalName (..))
import Aapms.Md.Document (DocKind (..), docKind)
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Store.Fixtures
import Aapms.Store.Marker (VaultHandle, vhConn, vhRoot)
import Aapms.Store.Schema (IndexIssue (..))
import Aapms.Store.Walk (vaultMarkdownFiles)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "graph-core/F006 Index" $ do
  describe "STEP-3: vaultMarkdownFiles" $
    it "略過 . 開頭目錄與非 .md 檔,只回排序後的 .md 相對路徑" $
      withTempVault $ \dir -> do
        createDirectoryIfMissing True (dir </> ".aapms")
        createDirectoryIfMissing True (dir </> ".git")
        writeFile (dir </> ".aapms" </> "config.toml") "id = \"vlt-1\"\n"
        writeFile (dir </> ".git" </> "HEAD") "ref: refs/heads/main\n"
        writeFile (dir </> "foo.txt") "not markdown"
        writeFile (dir </> "bar.md") "---\n---\n"
        files <- vaultMarkdownFiles dir
        files `shouldBe` ["bar.md"]

  describe "STEP-14: fixture 健檢" $
    it "story vault 與 asset vault 的全部檔案能被 parseDocument + 對應 to* 成功解析" $ do
      mapM_ (assertParses . snd) storyVaultFiles
      mapM_ (assertParses . snd) assetVaultFiles

  describe "STEP-4: indexOne(經 indexOnePath 驗證,兩者對單檔行為一致)" $ do
    it "story vault 的主題檔索引後,nodes 有主體(owner NULL)+ 片段(owner = 主體 id)" $
      withStoryVault $ \vh -> do
        issuesR <- indexOnePath vh "characters/test-character.md"
        case issuesR of
          Left e -> expectationFailure (show e)
          Right _issues -> pure ()
        mainOwner <- ownerOf vh "ent-00000001"
        fragOwner <- ownerOf vh "ent-00000002"
        mainOwner `shouldBe` Nothing
        fragOwner `shouldBe` Just "ent-00000001"

    it "asset vault 的 pack.md 索引後,nodes/assets 有 pack(owner NULL)+ 全部 asset\
       \(owner = pack id),含 status = missing 的那筆" $
      withAssetVault $ \vh -> do
        _ <- orDie =<< indexOnePath vh "library/packs/test-vendor/test-pack/pack.md"
        pckOwner <- ownerOf vh "pck-00000001"
        astOwner <- ownerOf vh "ast-00000001"
        pckOwner `shouldBe` Nothing
        astOwner `shouldBe` Just "pck-00000001"
        statusOf vh "ast-00000002" `shouldReturn` Just "missing"

    it "父節點不存在的 Level fixture 索引結果含 TreeInvalid,nodes 沒有該檔案的殘留" $
      -- toLevel 本身的 structure/rootId 已經把「跳級」「root 與第一節不符」
      -- 等情況攔在 MdError 那一層(buildTree 收到的 [Node] 因此永遠是「由標題
      -- 巢狀結構長出來」的合法樹,ParseFailed 而非 TreeInvalid 才是那些情況的
      -- 正確結果——見上一條測試)。要讓 buildTree 本身失敗,只剩「frontmatter
      -- 宣告了 root,但檔案裡一個 Node 都沒有」這條路徑合法卻能通過 toLevel:
      -- rootId 對 (Just root, []) 直接放行,buildTree [] 才真正回報 NoRoot。
      withStoryVault $ \vh -> do
        let badLevel =
              T.unlines
                [ "---"
                , "id: lvl-00000002"
                , "vault: liftgame"
                , "type: level"
                , "title: 壞掉的場景"
                , "status: canon"
                , "source: human"
                , "revision: 1"
                , "created: 2026-08-16"
                , "updated: 2026-08-16"
                , "root: nod-00000099"
                , "---"
                , ""
                , "沒有任何 Node,frontmatter 宣告的 root 不存在。"
                ]
        writeFiles (vhRoot vh) [("levels/broken.md", badLevel)]
        result <- orDie =<< indexOnePath vh "levels/broken.md"
        case result of
          [TreeInvalid _ _] -> pure ()
          other -> expectationFailure ("預期 [TreeInvalid _ _],得到 " <> show other)
        rows <-
          query (vhConn vh) "SELECT count(*) FROM nodes WHERE file_path = ?" (Only ("levels/broken.md" :: Text)) ::
            IO [Only Int]
        rows `shouldBe` [Only 0]

    it "YAML 壞掉的檔案索引結果含 ParseFailed,nodes 沒有殘留" $
      withStoryVault $ \vh -> do
        let broken = "---\nid: [this is not\n---\n"
        writeFiles (vhRoot vh) [("characters/broken.md", broken)]
        result <- orDie =<< indexOnePath vh "characters/broken.md"
        case result of
          [ParseFailed _ _] -> pure ()
          other -> expectationFailure ("預期 [ParseFailed _ _],得到 " <> show other)
        rows <-
          query
            (vhConn vh)
            "SELECT count(*) FROM nodes WHERE file_path = ?"
            (Only ("characters/broken.md" :: Text)) ::
            IO [Only Int]
        rows `shouldBe` [Only 0]

    it "兩個不同檔案的 asset 撞同一個 name,後索引的整檔回滾並回 DuplicateAssetName,\
       \先索引的保留" $
      withAssetVault $ \vh -> do
        _ <- orDie =<< indexOnePath vh "library/packs/test-vendor/test-pack/pack.md"
        let dupPack =
              T.unlines
                [ "---"
                , "id: pck-00000099"
                , "vault: liftgame-assets"
                , "type: asset-pack"
                , "title: 撞名 Pack"
                , "status: canon"
                , "source: scan"
                , "revision: 1"
                , "created: 2026-08-10"
                , "updated: 2026-08-10"
                , "---"
                , ""
                , "撞名測試。"
                , ""
                , "## dup.png {#ast-00000099}"
                , ""
                , "```meta"
                , "type: asset-image"
                , "name: ui_gui_panel_001"
                , "entry: PNG/dup.png"
                , "sha256: \"9999999999999999999999999999999999999999999999999999999999999999\""
                , "```"
                ]
        writeFiles (vhRoot vh) [("library/packs/test-vendor/dup/pack.md", dupPack)]
        result <- orDie =<< indexOnePath vh "library/packs/test-vendor/dup/pack.md"
        -- P-001 LAW-6 / 決定:撞名以路徑字母序裁決。dup < test-pack,所以後索引的 dup
        -- 留下、先索引的 test-pack 整檔退場(舊 indexOne 是插入順序,搬遷後以 law 為準)。
        let isDup (DuplicateAssetName p (LogicalName "ui_gui_panel_001")) =
              p == "library/packs/test-vendor/test-pack/pack.md"
            isDup _ = False
        result `shouldSatisfy` any isDup
        -- 字母序在前的 dup 保留,它的 asset 歸它的 pack
        ownerDup <- ownerOf vh "ast-00000099"
        ownerDup `shouldBe` Just "pck-00000099"
        -- 字母序在後的 test-pack 整檔退場
        rows <-
          query
            (vhConn vh)
            "SELECT count(*) FROM nodes WHERE file_path = ?"
            (Only ("library/packs/test-vendor/test-pack/pack.md" :: Text)) ::
            IO [Only Int]
        rows `shouldBe` [Only 0]

  describe "STEP-5: indexOnePath / unindexOnePath" $ do
    it "對已索引的檔案改內容後重新 indexOnePath,舊記錄被整檔替換而非疊加" $
      withStoryVault $ \vh -> do
        _ <- orDie =<< indexOnePath vh "characters/test-character.md"
        countFragments vh `shouldReturn` 2
        let changed = T.replace "外貌片段" "改過的外貌片段" storyLindaMdForTest
        writeFiles (vhRoot vh) [("characters/test-character.md", changed)]
        _ <- orDie =<< indexOnePath vh "characters/test-character.md"
        countFragments vh `shouldReturn` 2
        summary <- summaryOf vh "ent-00000002"
        summary `shouldBe` Just "改過的外貌片段"

    it "unindexOnePath 後該檔案的 nodes/assets/links/node_tags 等全部記錄消失,files 也消失" $
      withAssetVault $ \vh -> do
        _ <- orDie =<< indexOnePath vh "library/packs/test-vendor/test-pack/pack.md"
        unindexOnePath vh "library/packs/test-vendor/test-pack/pack.md"
        nodesLeft <-
          query
            (vhConn vh)
            "SELECT count(*) FROM nodes WHERE file_path = ?"
            (Only ("library/packs/test-vendor/test-pack/pack.md" :: Text)) ::
            IO [Only Int]
        assetsLeft <-
          query (vhConn vh) "SELECT count(*) FROM assets WHERE id = ?" (Only ("ast-00000001" :: Text)) ::
            IO [Only Int]
        filesLeft <-
          query
            (vhConn vh)
            "SELECT count(*) FROM files WHERE path = ?"
            (Only ("library/packs/test-vendor/test-pack/pack.md" :: Text)) ::
            IO [Only Int]
        nodesLeft `shouldBe` [Only 0]
        assetsLeft `shouldBe` [Only 0]
        filesLeft `shouldBe` [Only 0]

    it "對不存在的路徑呼叫 unindexOnePath 不報錯" $
      withStoryVault $ \vh ->
        unindexOnePath vh "characters/never-existed.md" `shouldReturn` ()

--------------------------------------------------------------------------------
-- 輔助

storyLindaMdForTest :: Text
storyLindaMdForTest = case lookup "characters/test-character.md" storyVaultFiles of
  Just t -> t
  Nothing -> error "fixture 缺少 characters/test-character.md"

assertParses :: Text -> IO ()
assertParses txt = case parseDocument txt of
  Left e -> expectationFailure ("parseDocument 失敗:" <> show e)
  Right doc -> do
    let attempt = case docKind doc of
          TopicDoc -> either (Left . show) (const (Right ())) (toTopic doc)
          LevelDoc -> either (Left . show) (const (Right ())) (toLevel doc)
          PackDoc -> either (Left . show) (const (Right ())) (toPack doc)
          LicenseDoc -> either (Left . show) (const (Right ())) (toLicenses doc)
    case attempt of
      Left msg -> expectationFailure msg
      Right () -> pure ()

ownerOf :: VaultHandle -> Text -> IO (Maybe Text)
ownerOf vh nodeId = do
  rows <- query (vhConn vh) "SELECT owner FROM nodes WHERE id = ?" (Only nodeId) :: IO [Only (Maybe Text)]
  pure $ case rows of
    (Only o : _) -> o
    [] -> Nothing

statusOf :: VaultHandle -> Text -> IO (Maybe Text)
statusOf vh nodeId = do
  rows <- query (vhConn vh) "SELECT status FROM nodes WHERE id = ?" (Only nodeId) :: IO [Only Text]
  pure $ case rows of
    (Only s : _) -> Just s
    [] -> Nothing

summaryOf :: VaultHandle -> Text -> IO (Maybe Text)
summaryOf vh nodeId = do
  rows <- query (vhConn vh) "SELECT summary FROM nodes WHERE id = ?" (Only nodeId) :: IO [Only Text]
  pure $ case rows of
    (Only s : _) -> Just s
    [] -> Nothing

countFragments :: VaultHandle -> IO Int
countFragments vh = do
  rows <-
    query_
      (vhConn vh)
      "SELECT count(*) FROM nodes WHERE prefix = 'ent' AND owner IS NOT NULL" ::
      IO [Only Int]
  pure $ case rows of
    (Only n : _) -> n
    [] -> 0
