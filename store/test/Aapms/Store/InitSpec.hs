-- | T2:@initVault@ 的骨架建立與 @.gitignore@ 追加而不覆寫。
module Aapms.Store.InitSpec (spec) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Store.Error (StoreError (..), renderStoreError)
import Aapms.Store.Fixtures (withTempVault)
import Aapms.Store.Vault
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "T2 initVault" $ do
  it "建立 .storyflow/config.toml 與五個子目錄" $
    withTempVault $ \dir -> do
      v <- either (fail . T.unpack . renderStoreError) pure =<< initVault dir "liftgame"
      vaultName v `shouldBe` "liftgame"
      doesFileExist (configPath dir) `shouldReturn` True
      mapM_ (\d -> doesDirectoryExist (dir </> d) `shouldReturn` True) vaultSubdirs

  it ".storyflow/.gitignore 含 index.db 與 workshops/,根目錄 .gitignore 含 .storyflow/index.db" $
    withTempVault $ \dir -> do
      _ <- initVault dir "liftgame"
      inner <- readText (storyflowDir dir </> ".gitignore")
      T.lines inner `shouldContain` ["index.db"]
      T.lines inner `shouldContain` ["workshops/"]
      outer <- readText (dir </> ".gitignore")
      T.lines outer `shouldContain` [".storyflow/index.db"]

  it "已有 .gitignore 時原有內容完整保留,只追加缺少的行" $
    withTempVault $ \dir -> do
      let gi = dir </> ".gitignore"
          old = "# 作者自己的規則\ndist-newstyle/\n*.bak\n"
      writeText gi old
      _ <- initVault dir "liftgame"
      new <- readText gi
      old `shouldSatisfy` (`T.isPrefixOf` new)
      T.lines new `shouldContain` [".storyflow/index.db"]

  it "已經含有該行時不重複追加" $
    withTempVault $ \dir -> do
      let gi = dir </> ".gitignore"
      writeText gi ".storyflow/index.db\n"
      _ <- initVault dir "liftgame"
      readText gi `shouldReturn` ".storyflow/index.db\n"

  it "重複 init 回 VaultAlreadyExists 且不覆寫既有 config" $
    withTempVault $ \dir -> do
      _ <- initVault dir "liftgame"
      original <- readText (configPath dir)
      r <- initVault dir "另一個名字"
      r `shouldBe` Left (VaultAlreadyExists dir)
      readText (configPath dir) `shouldReturn` original

readText :: FilePath -> IO Text
readText fp = TE.decodeUtf8 <$> BS.readFile fp

writeText :: FilePath -> Text -> IO ()
writeText fp = BS.writeFile fp . TE.encodeUtf8
