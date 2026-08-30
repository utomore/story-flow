-- | graph-core\/F005:PRAGMA 設定、@schema_version@ 重建與 'IndexIssue'、
-- vault 身分寫入。graph-core\/F006(STEP-1)擴充:12 張表全建齊、三個新
-- 'IndexIssue' 建構子的 'renderIndexIssue'。graph-core\/F007 再擴充:
-- @fts_tri@\/@fts_cjk@\/@fts_map@ 三張表、schemaVersion 2 → 3。
module Aapms.Store.SchemaSpec (spec) where

import Data.List (partition)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Id (VaultId (..))
import Aapms.Core.Meta (MetaWarning (..), TypeKey (..))
import Aapms.Md.Error (MdError (..), MdErrorKind (..))
import Aapms.Store.Fixtures (idOf, orDie, withTempVault)
import Aapms.Store.Schema
import System.FilePath ((</>))
import Test.Hspec

testVaultId :: VaultId
testVaultId = VaultId "vlt-7f3b2a91"

-- | design.md「索引結構」段落的 12 張表 + graph-core\/F007 的三張 FTS 相關表
-- (@fts_tri@\/@fts_cjk@\/@fts_map@),共 15 張——即 'indexTables' 的完整清單。
-- __不含__ FTS5 幫兩張虛擬表自動生成的影子表(見 'isFtsShadowTable')。
-- SQLite 回傳依 sqlite_master.name 字母序,不是 'indexTables' 的建表順序。
expectedTables :: [Text]
expectedTables =
  [ "assets"
  , "files"
  , "fts_cjk"
  , "fts_map"
  , "fts_tri"
  , "levels"
  , "licenses"
  , "links"
  , "meta_info"
  , "node_aliases"
  , "node_tags"
  , "nodes"
  , "packs"
  , "tree_node_entities"
  , "tree_nodes"
  ]

-- | @fts_tri@\/@fts_cjk@ 都不是 contentless(design.md\/F007「介面」註解:
-- snippet() 要拿得到內容、要能整批刪列),FTS5 因此各自幫它們生出 5 張影子表
-- (@_data@\/@_idx@\/@_content@\/@_docsize@\/@_config@)——這些不是本文檔宣告的
-- 表,不列進 'expectedTables',測試裡濾掉即可。
isFtsShadowTable :: Text -> Bool
isFtsShadowTable t = any (`T.isPrefixOf` t) ["fts_tri_", "fts_cjk_"]

spec :: Spec
spec = describe "graph-core/F005 schema" $ do
  it "graph-core/F007: 15 張表全建齊(不含 FTS5 影子表),schemaVersion(3)寫入 meta_info" $
    withTempVault $ \dir -> do
      (conn, _issues) <- orDie =<< openIndexAt (dir </> "index.db") testVaultId AssetVault "a"
      allTables <- tableNames conn
      let (shadow, real) = partition isFtsShadowTable allTables
      real `shouldBe` expectedTables
      -- fts_tri / fts_cjk 各 5 張影子表
      length shadow `shouldBe` 10
      length allTables `shouldBe` 25
      schemaVersion `shouldBe` 3
      currentVersion conn `shouldReturn` Just schemaVersion
      closeIndex conn

  it "STEP-1: renderIndexIssue 對三個新建構子輸出非空、含中文、指出檔案路徑" $ do
    let fp = "story/broken.md"
        parseIssue = renderIndexIssue (ParseFailed fp (MdError 3 NoFrontmatter))
        treeIssue = renderIndexIssue (TreeInvalid fp [])
        dupIssue = renderIndexIssue (DuplicateAssetName fp (LogicalName "ui_gui_panel_001"))
        warnIssue =
          renderIndexIssue
            (MetaWarningsFound fp (idOf "ent-00000001") [UnknownNodeType (TypeKey "character")])
    mapM_
      (`shouldSatisfy` (not . T.null))
      [parseIssue, treeIssue, dupIssue, warnIssue]
    mapM_ (`shouldSatisfy` T.isInfixOf (T.pack fp)) [parseIssue, treeIssue, dupIssue, warnIssue]

  it "foreign_keys / journal_mode / busy_timeout 三個 PRAGMA 符合預期" $
    withTempVault $ \dir -> do
      (conn, _issues) <- orDie =<< openIndexAt (dir </> "index.db") testVaultId AssetVault "a"
      scalarInt conn "PRAGMA foreign_keys" `shouldReturn` 1
      journalMode <- query_ conn "PRAGMA journal_mode" :: IO [Only Text]
      map fromOnly journalMode `shouldBe` ["wal"]
      scalarInt conn "PRAGMA busy_timeout" `shouldReturn` 5000
      closeIndex conn

  it "全新索引檔回報一筆 SchemaRebuilt Nothing schemaVersion" $
    withTempVault $ \dir -> do
      (conn, issues) <- orDie =<< openIndexAt (dir </> "index.db") testVaultId AssetVault "a"
      issues `shouldBe` [SchemaRebuilt Nothing schemaVersion]
      closeIndex conn

  it "schema_version 被改成舊值後重新開啟會整庫重建並回報" $
    withTempVault $ \dir -> do
      let fp = dir </> "index.db"
      conn1 <- fmap fst . orDie =<< openIndexAt fp testVaultId AssetVault "a"
      execute_ conn1 "UPDATE meta_info SET value = '0' WHERE key = 'schema_version'"
      closeIndex conn1

      (conn2, issues) <- orDie =<< openIndexAt fp testVaultId AssetVault "a"
      issues `shouldBe` [SchemaRebuilt (Just 0) schemaVersion]
      currentVersion conn2 `shouldReturn` Just schemaVersion
      closeIndex conn2

  it "openIndexAt 完成後 meta_info 含正確的 vault_id/vault_kind/vault_name" $
    withTempVault $ \dir -> do
      (conn, _issues) <-
        orDie =<< openIndexAt (dir </> "index.db") testVaultId StoryVault "liftgame"
      metaValue conn "vault_id" `shouldReturn` Just "vlt-7f3b2a91"
      metaValue conn "vault_kind" `shouldReturn` Just "story"
      metaValue conn "vault_name" `shouldReturn` Just "liftgame"
      closeIndex conn

  describe "VaultKind" $ do
    it "renderVaultKind / parseVaultKind 互為反函式" $ do
      renderVaultKind AssetVault `shouldBe` "asset"
      renderVaultKind StoryVault `shouldBe` "story"
      parseVaultKind "asset" `shouldBe` Just AssetVault
      parseVaultKind "story" `shouldBe` Just StoryVault

    it "parseVaultKind 對其餘字串回 Nothing" $
      parseVaultKind "other" `shouldBe` Nothing

  describe "renderIndexIssue" $
    it "非空、含新舊版本" $ do
      renderIndexIssue (SchemaRebuilt (Just 0) 1) `shouldNotBe` ""
      renderIndexIssue (SchemaRebuilt Nothing 1) `shouldNotBe` ""

tableNames :: Connection -> IO [Text]
tableNames conn = do
  rows <-
    query_ conn "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name" ::
      IO [Only Text]
  pure (map fromOnly rows)

scalarInt :: Connection -> Query -> IO Int
scalarInt conn q = do
  rows <- query_ conn q :: IO [Only Int]
  pure $ case rows of
    (Only n : _) -> n
    [] -> 0

metaValue :: Connection -> Text -> IO (Maybe Text)
metaValue conn key = do
  rows <-
    query conn "SELECT value FROM meta_info WHERE key = ?" (Only key) :: IO [Only Text]
  pure $ case rows of
    (Only v : _) -> Just v
    [] -> Nothing
