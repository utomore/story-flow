-- | T4:schema 建立、PRAGMA 設定、版本不符自動重建。
module StoryFlow.Store.SchemaSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Index (issueHasError, openVaultIndex)
import StoryFlow.Store.Schema
import StoryFlow.Store.Vault (Vault (..))
import Test.Hspec

spec :: Spec
spec = describe "T4 SQLite schema" $ do
  it "建立後全部的表都存在" $
    withVaultIndex $ \_ conn ->
      forM_ indexTables $ \t -> do
        n <- tableCount conn t
        (t, n) `shouldBe` (t, 1)

  it "entities_fts 用 trigram tokenizer" $
    withVaultIndex $ \_ conn -> do
      sql <- tableSql conn "entities_fts"
      sql `shouldSatisfy` T.isInfixOf "trigram"
      sql `shouldSatisfy` T.isInfixOf "fts5"

  it "foreign_keys 為 ON" $
    withVaultIndex $ \_ conn ->
      scalarInt conn "PRAGMA foreign_keys" () `shouldReturn` 1

  it "journal_mode 為 WAL" $
    withVaultIndex $ \_ conn -> do
      rows <- query_ conn "PRAGMA journal_mode" :: IO [Only Text]
      map fromOnly rows `shouldBe` ["wal"]

  it "meta_info 記著 schema_version" $
    withVaultIndex $ \_ conn ->
      currentVersion conn `shouldReturn` Just schemaVersion

  it "schema_version 被竄改為舊值後 openIndex 重建而不是報錯" $
    withEmptyVault $ \v -> do
      conn <- orDie =<< openIndex v
      execute_ conn "INSERT INTO files(path, mtime, size) VALUES ('殘留.md', 1, 1)"
      execute_ conn "UPDATE meta_info SET value = '0' WHERE key = 'schema_version'"
      closeIndex conn

      conn2 <- orDie =<< openIndex v
      currentVersion conn2 `shouldReturn` Just schemaVersion
      -- 舊資料跟著 schema 一起被砍掉,而不是留在版本不符的表裡
      countRows conn2 "files" `shouldReturn` 0
      closeIndex conn2

  it "版本不符後 openVaultIndex 會把整個 Vault 重新索引回來" $
    withSampleVault $ \v -> do
      conn <- orDie =<< openIndex v
      execute_ conn "UPDATE meta_info SET value = '0' WHERE key = 'schema_version'"
      closeIndex conn

      (conn2, issues) <- orDie =<< openVaultIndex v
      filter issueHasError issues `shouldBe` []
      countRows conn2 "files" `shouldReturn` length sampleFiles
      countRows conn2 "entities" `shouldReturn` 8
      closeIndex conn2

  it "連線知道自己屬於哪個 Vault" $
    withVaultIndex $ \v conn ->
      vaultRootOf conn `shouldReturn` Just (vaultRoot v)

tableCount :: Connection -> Text -> IO Int
tableCount conn name =
  scalarInt
    conn
    "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
    (Only name)

tableSql :: Connection -> Text -> IO Text
tableSql conn name = do
  rows <-
    query conn "SELECT sql FROM sqlite_master WHERE name = ?" (Only name) ::
      IO [Only Text]
  pure $ case rows of
    (Only s : _) -> s
    [] -> ""
