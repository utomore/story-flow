-- | llm-workshop-mcp/F001 T4:@vaultConfig@ 這個內嵌出口。
--
-- __本檔刻意只 import @Aapms.Service@__:被測的是 service 的__匯出面__ ——
-- @VaultConfig (..)@ 與 @LlmSection (..)@ 有沒有真的 re-export 出來。若這裡改成
-- 從 @Aapms.Store@ 拿型別,測試會照樣通過,而 @aapms-llm@(它的
-- @build-depends@ 逐字擋著 @aapms-store@)卻會編不起來。
module Aapms.Service.VaultConfigSpec (spec) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Service
import Aapms.Service.Fixtures (orDieS, runS, withVaultDir)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  it "新建的 Vault 讀得出 name / references,且沒有 [llm] 段" $
    withVault [] $ \env -> do
      cfg <- runS env vaultConfig
      cfgName cfg `shouldBe` "liftgame"
      cfgReferences cfg `shouldBe` []
      -- createVault 寫出來的 config.toml 沒有 [llm];「沒設定」與「設定錯了」
      -- 是兩件事,這裡確認前者長什麼樣
      cfgLlm cfg `shouldBe` Nothing

  it "先寫 [llm] 段再 openEnv,拿得到原樣捧著的那張表" $
    withVault
      [ "base_url = \"http://127.0.0.1:8080/v1\""
      , "model = \"qwen2.5-14b-instruct\""
      ]
      $ \env -> do
        cfg <- runS env vaultConfig
        -- 表原樣交出來,service 這一層不解讀它的鍵
        fmap (M.keys . llmSectionTable) (cfgLlm cfg)
          `shouldBe` Just ["base_url", "model"]

  it "設定在 openEnv 那一步才被讀進 Vault" $
    -- 這條是上面那條的前提:先 openEnv 再寫檔的話,拿到的會是舊的設定。
    -- 寫測試的人踩過一次就會知道為什麼 withVault 的順序不能調換。
    withVault ["model = \"m\""] $ \env -> do
      cfg <- runS env vaultConfig
      cfgLlm cfg `shouldNotBe` Nothing

-- | 建臨時 Vault,可選地附一段 @[llm]@。
--
-- __順序是硬的__:設定在 'openEnv' 那一步才被讀進 @Vault@,所以 @[llm]@ 段必須
-- 先寫進檔案再 'openEnv'。
withVault :: [T.Text] -> (Env -> IO a) -> IO a
withVault llmLines act = withVaultDir $ \dir -> do
  _ <- orDieS =<< createVault dir "liftgame"
  appendLlm dir llmLines
  bracket (fst <$> (orDieS =<< openEnv Nothing dir)) closeEnv act

-- | 一律以 UTF-8 位元組讀寫:@readFile@ \/ @writeFile@ 走的是本機 locale 編碼。
appendLlm :: FilePath -> [T.Text] -> IO ()
appendLlm _ [] = pure ()
appendLlm root ls = do
  let fp = root </> ".storyflow" </> "config.toml"
  old <- TE.decodeUtf8 <$> BS.readFile fp
  BS.writeFile fp (TE.encodeUtf8 (old <> T.unlines ("" : "[llm]" : ls)))
