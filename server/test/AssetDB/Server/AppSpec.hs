module AssetDB.Server.AppSpec (spec) where

import AssetDB.Server.App
import AssetDB.Store
import Data.List (isInfixOf)
import Database.SQLite.Simple (execute, execute_, lastInsertRowId)
import System.Directory (doesFileExist)
import System.FilePath (isAbsolute, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "resolveServerDb" $ do
    it "對不存在的路徑且未帶 --init 時失敗,而且不建檔" $
      withSystemTempDirectory "assetdb-server-test" $ \dir -> do
        let path = dir </> "missing.sqlite"
        r <- resolveServerDb (cfg path False)
        case r of
          Right p -> expectationFailure ("應該要失敗,卻回傳 " <> p)
          Left err -> do
            err `shouldSatisfy` ("找不到資料庫" `isInfixOf`)
            err `shouldSatisfy` ("--init" `isInfixOf`)
        -- 靜默建檔正是 bug-0002 的病灶,檢查是否真的沒動到磁碟
        doesFileExist path `shouldReturn` False

    it "帶 --init 時接受不存在的路徑,交由 withStore 建立新庫" $
      withSystemTempDirectory "assetdb-server-test" $ \dir -> do
        let path = dir </> "fresh.sqlite"
        r <- resolveServerDb (cfg path True)
        case r of
          Left err -> expectationFailure ("不該失敗:" <> err)
          Right p -> p `shouldSatisfy` isAbsolute
        withStore path $ \st -> initSchema st >>= \ms -> ms `shouldNotBe` []
        doesFileExist path `shouldReturn` True

    it "資料庫存在時回傳絕對路徑" $
      withSystemTempDirectory "assetdb-server-test" $ \dir -> do
        let path = dir </> "existing.sqlite"
        withStore path $ \st -> initSchema st >> pure ()
        r <- resolveServerDb (cfg path False)
        case r of
          Left err -> expectationFailure ("不該失敗:" <> err)
          Right p -> do
            p `shouldSatisfy` isAbsolute
            p `shouldSatisfy` ("existing.sqlite" `isInfixOf`)

  describe "countAssets" $
    it "回報 assets 表的實際筆數" $
      withSystemTempDirectory "assetdb-server-test" $ \dir ->
        withStore (dir </> "counted.sqlite") $ \st -> do
          _ <- initSchema st
          countAssets st `shouldReturn` 0
          insertAssets st 3
          countAssets st `shouldReturn` 3

  describe "startupBanner" $
    it "包含 db 絕對路徑與 assets 筆數" $ do
      let banner = startupBanner 8787 "C:/lib/.assetdb/assetdb.sqlite" 5721
      banner `shouldSatisfy` ("C:/lib/.assetdb/assetdb.sqlite" `isInfixOf`)
      banner `shouldSatisfy` ("5721" `isInfixOf`)
      banner `shouldSatisfy` ("8787" `isInfixOf`)

cfg :: FilePath -> Bool -> ServerConfig
cfg path doInit =
  ServerConfig
    { scDbPath = path
    , scCacheRoot = "cache"
    , scWebRoot = "web"
    , scPort = 8787
    , scInit = doInit
    }

-- | 直接塞最小可用的 asset 列。這裡只在乎 COUNT,不走完整的 ingest 路徑。
insertAssets :: Store -> Int -> IO ()
insertAssets st n = do
  execute_ (storeConn st) "INSERT INTO roots (path, label, kind) VALUES ('/tmp/r', 'r', 'packs')"
  rootId <- lastInsertRowId (storeConn st)
  mapM_
    ( \i ->
        execute
          (storeConn st)
          "INSERT INTO assets \
          \  (ulid, kind, root_id, rel_path, original_name, created_at, updated_at) \
          \VALUES (?, 'image', ?, ?, ?, '2026-08-16T00:00:00Z', '2026-08-16T00:00:00Z')"
          ( "01TEST" <> show i :: String
          , rootId
          , "a" <> show i <> ".png" :: String
          , "a" <> show i <> ".png" :: String
          )
    )
    [1 .. n]
