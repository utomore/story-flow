-- | graph-core\/F006:T3(檔案掃描)、T4(單檔索引 indexOne,經 'indexFile' 測試
-- ——兩者對單檔的行為完全一致,見 "Aapms.Store.Index" 的說明)、T5('indexFile'
-- 覆寫、'unindexFile' 級聯與冪等)、T14(fixture 健檢)。
module Aapms.Store.IndexSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Core.Asset (LogicalName (..))
import Aapms.Md.Document (DocKind (..), docKind)
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Store.Fixtures
import Aapms.Store.Index
import Aapms.Store.Marker (VaultHandle, vhConn, vhRoot)
import Aapms.Store.Schema (IndexIssue (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "graph-core/F006 Index" $ do
  describe "T3: vaultMarkdownFiles" $
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

  describe "T14: fixture 健檢" $
    it "story vault 與 asset vault 的全部檔案能被 parseDocument + 對應 to* 成功解析" $ do
      mapM_ (assertParses . snd) storyVaultFiles
      mapM_ (assertParses . snd) assetVaultFiles

  describe "T4: indexOne(經 indexFile 驗證,兩者對單檔行為一致)" $ do
    it "story vault 的主題檔索引後,nodes 有主體(owner NULL)+ 片段(owner = 主體 id)" $
      withStoryVault $ \vh -> do
        issuesR <- indexFile vh "characters/test-character.md"
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
        _ <- orDie =<< indexFile vh "packs/test-vendor/pack.md"
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
        result <- orDie =<< indexFile vh "levels/broken.md"
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
        result <- orDie =<< indexFile vh "characters/broken.md"
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
        _ <- orDie =<< indexFile vh "packs/test-vendor/pack.md"
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
        writeFiles (vhRoot vh) [("packs/dup/pack.md", dupPack)]
        result <- orDie =<< indexFile vh "packs/dup/pack.md"
        case result of
          [DuplicateAssetName _ (LogicalName "ui_gui_panel_001")] -> pure ()
          other -> expectationFailure ("預期 DuplicateAssetName,得到 " <> show other)
        -- 先索引的那個(ast-00000001)保留
        owner <- ownerOf vh "ast-00000001"
        owner `shouldBe` Just "pck-00000001"
        -- 後索引的檔案整檔沒進去
        rows <-
          query
            (vhConn vh)
            "SELECT count(*) FROM nodes WHERE file_path = ?"
            (Only ("packs/dup/pack.md" :: Text)) ::
            IO [Only Int]
        rows `shouldBe` [Only 0]

  describe "T5: indexFile / unindexFile" $ do
    it "對已索引的檔案改內容後重新 indexFile,舊記錄被整檔替換而非疊加" $
      withStoryVault $ \vh -> do
        _ <- orDie =<< indexFile vh "characters/test-character.md"
        countFragments vh `shouldReturn` 2
        let changed = T.replace "外貌片段" "改過的外貌片段" storyLindaMdForTest
        writeFiles (vhRoot vh) [("characters/test-character.md", changed)]
        _ <- orDie =<< indexFile vh "characters/test-character.md"
        countFragments vh `shouldReturn` 2
        summary <- summaryOf vh "ent-00000002"
        summary `shouldBe` Just "改過的外貌片段"

    it "unindexFile 後該檔案的 nodes/assets/links/node_tags 等全部記錄消失,files 也消失" $
      withAssetVault $ \vh -> do
        _ <- orDie =<< indexFile vh "packs/test-vendor/pack.md"
        _ <- orDie =<< unindexFile vh "packs/test-vendor/pack.md"
        nodesLeft <-
          query
            (vhConn vh)
            "SELECT count(*) FROM nodes WHERE file_path = ?"
            (Only ("packs/test-vendor/pack.md" :: Text)) ::
            IO [Only Int]
        assetsLeft <-
          query (vhConn vh) "SELECT count(*) FROM assets WHERE id = ?" (Only ("ast-00000001" :: Text)) ::
            IO [Only Int]
        filesLeft <-
          query
            (vhConn vh)
            "SELECT count(*) FROM files WHERE path = ?"
            (Only ("packs/test-vendor/pack.md" :: Text)) ::
            IO [Only Int]
        nodesLeft `shouldBe` [Only 0]
        assetsLeft `shouldBe` [Only 0]
        filesLeft `shouldBe` [Only 0]

    it "對不存在的路徑呼叫 unindexFile 不報錯" $
      withStoryVault $ \vh -> do
        result <- unindexFile vh "characters/never-existed.md"
        case result of
          Right () -> pure ()
          Left e -> expectationFailure (show e)

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
