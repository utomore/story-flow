module AssetDB.Cli.OptionsSpec (spec) where

import AssetDB.Cli.Options
import Data.List (isInfixOf)
import System.Directory (createDirectoryIfMissing, withCurrentDirectory)
import System.FilePath (isAbsolute, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "findDbUpwards" $ do
    it "從子目錄能找到上層的 .assetdb" $
      withDbTree $ \root deep -> do
        found <- findDbUpwards deep
        found `shouldSatisfy` maybe False (dbDirName `isInfixOf`)
        found `shouldBe` Just (root </> dbDirName </> dbFileName)

    it "資料庫就在當層時也找得到" $
      withDbTree $ \root _ ->
        findDbUpwards root `shouldReturn` Just (root </> dbDirName </> dbFileName)

    it "到檔案系統根都找不到時回 Nothing,不拋例外" $
      withSystemTempDirectory "assetdb-cli-test" $ \dir -> do
        let deep = dir </> "a" </> "b"
        createDirectoryIfMissing True deep
        findDbUpwards deep `shouldReturn` Nothing

    it "目錄裡有 .assetdb 但沒有資料庫檔時不算命中" $
      withSystemTempDirectory "assetdb-cli-test" $ \dir -> do
        createDirectoryIfMissing True (dir </> dbDirName)
        findDbUpwards dir `shouldReturn` Nothing

  describe "resolveDbPathForInit" $ do
    it "找不到既有資料庫時,回傳 cwd 底下的新路徑" $
      withSystemTempDirectory "assetdb-cli-test" $ \dir ->
        withCurrentDirectory dir $ do
          p <- resolveDbPathForInit (GlobalArgs Nothing)
          p `shouldSatisfy` isAbsolute
          p `shouldSatisfy` (dbFileName `isInfixOf`)
          -- 只是「決定路徑」,不該順手把檔案建出來
          findDbUpwards dir `shouldReturn` Nothing

    it "從子目錄執行時沿用上層既有的資料庫,不開第二個" $
      withDbTree $ \root deep ->
        withCurrentDirectory deep $
          resolveDbPathForInit (GlobalArgs Nothing)
            `shouldReturn` (root </> dbDirName </> dbFileName)

    it "--db 指定時直接採用,並轉成絕對路徑" $
      withSystemTempDirectory "assetdb-cli-test" $ \dir ->
        withCurrentDirectory dir $ do
          p <- resolveDbPathForInit (GlobalArgs (Just "custom.sqlite"))
          p `shouldSatisfy` isAbsolute
          p `shouldSatisfy` ("custom.sqlite" `isInfixOf`)

  describe "resolveDbPathForQuery" $ do
    it "找得到既有資料庫時回傳它的絕對路徑" $
      withDbTree $ \root deep ->
        withCurrentDirectory deep $
          resolveDbPathForQuery (GlobalArgs Nothing)
            `shouldReturn` (root </> dbDirName </> dbFileName)

  describe "錯誤訊息" $ do
    it "找不到資料庫時提示 --db 與 scan" $ do
      let msg = dbNotFoundMessage "C:/somewhere/else"
      msg `shouldSatisfy` ("--db" `isInfixOf`)
      msg `shouldSatisfy` ("scan" `isInfixOf`)
      msg `shouldSatisfy` ("C:/somewhere/else" `isInfixOf`)

    it "--db 指到不存在的檔案時把路徑印出來" $
      dbMissingAtMessage "nope.sqlite" `shouldSatisfy` ("nope.sqlite" `isInfixOf`)

--------------------------------------------------------------------------------

-- | 建一棵 @<root>\/.assetdb\/assetdb.sqlite@ 加上兩層子目錄的暫存目錄樹,
-- callback 收到 (根目錄, 最深的子目錄)。
withDbTree :: (FilePath -> FilePath -> IO a) -> IO a
withDbTree f =
  withSystemTempDirectory "assetdb-cli-test" $ \dir -> do
    createDirectoryIfMissing True (dir </> dbDirName)
    writeFile (dir </> dbDirName </> dbFileName) ""
    let deep = dir </> "packs" </> "vendor"
    createDirectoryIfMissing True deep
    f dir deep
