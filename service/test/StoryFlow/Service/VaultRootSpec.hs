-- | llm-workshop-mcp/F002 T2:新增的內嵌出口 @vaultRoot :: ServiceM FilePath@。
--
-- __本檔刻意只 import @StoryFlow.Service@__:與 'StoryFlow.Service.VaultConfigSpec'
-- 同一個理由——被測的是 service 的匯出面,不是底層 @Vault@ 的欄位存取子。
module StoryFlow.Service.VaultRootSpec (spec) where

import Control.Exception (bracket)
import StoryFlow.Service
import StoryFlow.Service.Fixtures (orDieS, runS, withVaultDir)
import System.Directory (doesDirectoryExist)
import System.FilePath (normalise, (</>))
import Test.Hspec

spec :: Spec
spec =
  it "vaultRoot 回傳的路徑正規化後等於 createVault 給的臨時目錄,且底下有 .storyflow" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      bracket (fst <$> (orDieS =<< openEnv Nothing dir)) closeEnv $ \env -> do
        root <- runS env vaultRoot
        normalise root `shouldBe` normalise dir
        doesDirectoryExist (root </> ".storyflow") `shouldReturn` True
