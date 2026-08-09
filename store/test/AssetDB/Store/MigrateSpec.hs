module AssetDB.Store.MigrateSpec (spec) where

import AssetDB.Store
import AssetDB.Store.Schema (schemaVersion)
import Control.Exception (try)
import Database.SQLite.Simple
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "runMigrations" $ do
    it "全新資料庫的版本是 0" $ inMemory $ \st ->
      storeVersion st `shouldReturn` 0

    it "套用後版本等於最新的 migration" $ inMemory $ \st -> do
      _ <- initSchema st
      storeVersion st `shouldReturn` schemaVersion

    it "是冪等的:第二次呼叫什麼都不做" $ inMemory $ \st -> do
      first <- initSchema st
      second <- initSchema st
      length first `shouldBe` schemaVersion
      second `shouldBe` []

    it "記錄每個 migration 的套用時間" $ inMemory $ \st -> do
      _ <- initSchema st
      applied <- appliedVersions (storeConn st)
      map (\(v, _, _) -> v) applied `shouldBe` [1 .. schemaVersion]

    it "版本號非遞增時直接爆炸,不半套" $ inMemory $ \st -> do
      let bad =
            [ Migration 2 "second" ["CREATE TABLE b (x)"]
            , Migration 1 "first" ["CREATE TABLE a (x)"]
            ]
      r <- try (runMigrations (storeConn st) bad)
      case r of
        Left (MigrationsOutOfOrder vs) -> vs `shouldBe` [2, 1]
        Left other -> expectationFailure ("預期 MigrationsOutOfOrder,收到 " <> show other)
        Right _ -> expectationFailure "應該要失敗"
      -- 沒有任何 migration 被套用
      storeVersion st `shouldReturn` 0

    it "資料庫比程式新時拒絕動作" $ inMemory $ \st -> do
      -- 模擬「有人用更新版的工具開過這個檔案」
      _ <- initSchema st
      execute_
        (storeConn st)
        "INSERT INTO schema_migrations (version, name, applied_at) VALUES (999,'future','2099-01-01T00:00:00Z')"
      r <- try (initSchema st)
      case r of
        Left (DatabaseNewerThanCode dbv codev) -> do
          dbv `shouldBe` 999
          codev `shouldBe` schemaVersion
        Left other -> expectationFailure ("預期 DatabaseNewerThanCode,收到 " <> show other)
        Right _ -> expectationFailure "應該要失敗"

    it "單一 migration 失敗時整個交易回滾" $ inMemory $ \st -> do
      let broken =
            [ Migration
                1
                "half-broken"
                [ "CREATE TABLE ok_table (x)"
                , "CREATE TABLE ok_table (x)" -- 重複建表,必定失敗
                ]
            ]
      r <- try (runMigrations (storeConn st) broken) :: IO (Either SQLError [Migration])
      r `shouldSatisfy` isLeftE
      -- 第一句的效果也必須消失
      tables <- query_ (storeConn st) "SELECT name FROM sqlite_master WHERE name='ok_table'" :: IO [Only String]
      tables `shouldBe` []
      storeVersion st `shouldReturn` 0

  describe "檔案資料庫" $ do
    it "在磁碟上建立檔案並啟用 WAL" $
      withSystemTempDirectory "assetdb-test" $ \dir -> do
        let path = dir </> "nested" </> "assetdb.sqlite"
        withStore path $ \st -> do
          _ <- initSchema st
          mode <- query_ (storeConn st) "PRAGMA journal_mode" :: IO [Only String]
          map fromOnly mode `shouldBe` ["wal"]

    it "重新開啟時保留已套用的 migration" $
      withSystemTempDirectory "assetdb-test" $ \dir -> do
        let path = dir </> "assetdb.sqlite"
        withStore path $ \st -> initSchema st >>= \ms -> length ms `shouldBe` schemaVersion
        withStore path $ \st -> do
          storeVersion st `shouldReturn` schemaVersion
          initSchema st `shouldReturn` []

  describe "PRAGMA" $ do
    it "foreign_keys 有開" $ inMemory $ \st -> do
      r <- query_ (storeConn st) "PRAGMA foreign_keys" :: IO [Only Int]
      map fromOnly r `shouldBe` [1]

--------------------------------------------------------------------------------

inMemory :: (Store -> IO a) -> IO a
inMemory f = do
  st <- openStoreInMemory
  r <- f st
  close (storeConn st)
  pure r

isLeftE :: Either a b -> Bool
isLeftE = either (const True) (const False)
