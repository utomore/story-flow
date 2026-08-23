-- | G-E002 T2 / T3:註冊表找不到時的三層訊息,與不開索引的 'locateVault'。
--
-- __本檔刻意只 import @StoryFlow.Service@__:與 'StoryFlow.Service.VaultRootSpec'
-- 同一個理由——被測的是 service 的匯出面,不是底層 @Vault@ 的欄位存取子。
module StoryFlow.Service.LocateSpec (spec) where

import Control.Exception (bracket)
import Data.List (isInfixOf)
import qualified Data.Text as T
import StoryFlow.Service
import StoryFlow.Service.Fixtures (orDieS, shouldFailWith, withEnvVars, withVaultDir)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath (normalise, (</>))
import Test.Hspec

spec :: Spec
spec = do
  -- T2:三層都沒有時,訊息要列出三個地方,而且不再叫人去找原始碼樹。
  describe "registryHint(G-E002 T2)" $
    it "環境變數沒設、執行檔旁沒有、data-files 也沒有 → 訊息列三個地方,不提原始碼樹" $
      withVaultDir $ \dir -> do
        _ <- orDieS =<< createVault dir "liftgame"
        r <-
          withoutEnv "STORYFLOW_REGISTRY" $
            -- Paths_storyflow_types 自己的覆寫鉤子:把 data-files 指到不存在的地方,
            -- 這樣第三層一定找不到,測試才不受「cabal test 有沒有替相依套件設 datadir」影響
            withEnvVars [("storyflow_types_datadir", dir </> "no-datadir")] $
              openEnv Nothing dir
        fmap (const ()) r `shouldFailWith` "registry_unavailable"
        case r of
          Left e -> do
            let msg = T.unpack (renderServiceError e)
            msg `shouldSatisfy` isInfixOf "STORYFLOW_REGISTRY"
            msg `shouldSatisfy` isInfixOf "執行檔旁"
            msg `shouldSatisfy` isInfixOf "data-files"
            msg `shouldNotSatisfy` isInfixOf "原始碼樹"
          Right _ -> expectationFailure "預期失敗"

  -- T3:找 Vault 不開索引。
  describe "locateVault(G-E002 T3)" $ do
    it "在臨時 Vault 回 Right,vvEntityCount 是 Nothing,而且不建 index.db" $
      withVaultDir $ \dir -> do
        _ <- orDieS =<< createVault dir "liftgame"
        (view, cfg) <- orDieS =<< locateVault Nothing dir
        vvName view `shouldBe` "liftgame"
        normalise (vvRoot view) `shouldBe` normalise dir
        vvEntityCount view `shouldBe` Nothing
        cfgName cfg `shouldBe` "liftgame"
        doesFileExist (dir </> ".storyflow" </> "index.db") `shouldReturn` False

    it "在非 Vault 目錄回 vault_not_found" $
      withVaultDir $ \dir -> do
        let outside = dir </> "no-vault-here"
        createDirectoryIfMissing True outside
        r <- locateVault Nothing outside
        fmap (const ()) r `shouldFailWith` "vault_not_found"

-- | 清掉一個環境變數跑一段,結束後還原。'withEnvVars' 只會設,不會清。
withoutEnv :: String -> IO a -> IO a
withoutEnv name act = bracket save restore (const act)
  where
    save = lookupEnv name <* unsetEnv name
    restore = maybe (pure ()) (setEnv name)
