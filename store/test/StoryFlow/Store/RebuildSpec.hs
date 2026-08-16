-- | T6 全量重建 / T7 重建等價性。
--
-- 等價性那一條是 ADR-0002「檔案才是真相」唯一可執行的證明:刪掉 @index.db@ 再
-- 重建,逐表逐筆必須一模一樣。它一旦紅燈,就代表索引裡存在檔案生不出來的資訊。
module StoryFlow.Store.RebuildSpec (spec) where

import Control.Monad (forM)
import Data.List (sort, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import StoryFlow.Md (MdError (..), MdErrorKind (..), MdWarning)
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Index
import StoryFlow.Store.Schema
import StoryFlow.Store.Vault (Vault, indexDbPath)
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec = do
  describe "T6 rebuildIndex" $ do
    it "3 份 Entity 檔 + 2 份 Level 檔重建後各表筆數正確" $
      withSampleIndex $ \_ conn -> do
        countRows conn "files" `shouldReturn` 5
        -- 琳達 1+2、織紋刀 1+1、埃提亞崩塌 1+2
        countRows conn "entities" `shouldReturn` 8
        countRows conn "levels" `shouldReturn` 2
        countRows conn "nodes" `shouldReturn` 6
        countRows conn "fts_map" `shouldReturn` 8
        countRows conn "entities_fts" `shouldReturn` 8

    it "一份檔案壞掉時其餘檔案照常索引,壞的那份回報 IndexIssue" $
      withSampleVault $ \v -> do
        writeVaultFile v "lore/壞掉.md" brokenMd
        withOpenIndex v $ \conn -> do
          issues <- orDie =<< rebuildIndex conn v
          let errs = filter issueHasError issues
          map issuePath errs `shouldBe` ["lore/壞掉.md"]
          concatMap issueErrors errs `shouldSatisfy` any isYamlError
          -- 其餘五份仍然全部進索引
          countRows conn "files" `shouldReturn` 5
          countRows conn "entities" `shouldReturn` 8

    it "警告也被收集起來(md 是純函式庫,只有索引走得過全部檔案)" $
      withSampleVault $ \v -> do
        writeVaultFile v "lore/沒寫總結.md" noSummaryMd
        withOpenIndex v $ \conn -> do
          issues <- orDie =<< rebuildIndex conn v
          let ws = concatMap issueWarnings (filter (not . issueHasError) issues)
          ws `shouldSatisfy` not . null

    it ".storyflow/ 與隱藏目錄下的 .md 不被掃描" $
      withSampleVault $ \v -> do
        writeVaultFile v ".storyflow/內部.md" lindaMd
        writeVaultFile v ".hidden/隱藏.md" lindaMd
        files <- vaultMarkdownFiles v
        files `shouldBe` sort (map fst sampleFiles)
        withOpenIndex v $ \conn -> do
          _ <- orDie =<< rebuildIndex conn v
          countRows conn "files" `shouldReturn` 5

  describe "T7 重建等價性" $
    it "刪掉 index.db 重建後,每一張表逐筆相同" $
      withSampleVault $ \v -> do
        dumpBefore <- withOpenIndex v $ \conn -> do
          _ <- orDie =<< rebuildIndex conn v
          dumpAll conn

        removeFile (indexDbPath v)

        dumpAfter <- withOpenIndex v $ \conn -> do
          _ <- orDie =<< rebuildIndex conn v
          dumpAll conn

        length dumpBefore `shouldBe` length indexTables
        mapM_
          (\(t, b, a) -> (t, a) `shouldBe` (t, b))
          (zip3 indexTables (map snd dumpBefore) (map snd dumpAfter))

-- | 逐表 dump。列內順序不保證,所以排序後比對——要證明的是「內容相同」,
-- 不是「插入順序相同」。
dumpAll :: Connection -> IO [(Text, [[SQLData]])]
dumpAll conn = forM indexTables $ \t -> do
  rows <- query_ conn (Query ("SELECT rowid, * FROM " <> t)) :: IO [[SQLData]]
  pure (t, sortOn show rows)

withOpenIndex :: Vault -> (Connection -> IO a) -> IO a
withOpenIndex v act = do
  conn <- orDie =<< openIndex v
  r <- act conn
  closeIndex conn
  pure r

issuePath :: IndexIssue -> FilePath
issuePath (IndexIssue p _ _) = p

issueErrors :: IndexIssue -> [MdError]
issueErrors (IndexIssue _ es _) = es

issueWarnings :: IndexIssue -> [MdWarning]
issueWarnings (IndexIssue _ _ ws) = ws

-- | 壞掉的那份是 frontmatter 的 YAML 解析失敗。
isYamlError :: MdError -> Bool
isYamlError e = case errKind e of
  FrontmatterYaml _ -> True
  _ -> False

noSummaryMd :: Text
noSummaryMd =
  T.unlines
    [ "---"
    , "id: ent-2001"
    , "vault: liftgame"
    , "type: lore"
    , "title: 沒寫總結"
    , "summary: 這一份的片段刻意不寫 summary"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 沒寫總結"
    , ""
    , "主體。"
    , ""
    , "## 缺總結的片段 {#ent-2002}"
    , ""
    , "```meta"
    , "type: lore-fragment"
    , "```"
    , ""
    , "正文。"
    ]
