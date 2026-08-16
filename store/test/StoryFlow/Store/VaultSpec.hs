-- | T1:Vault 的三條定位路徑與 @config.toml@ 解析。
module StoryFlow.Store.VaultSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Store.Error (StoreError (..), renderStoreError)
import StoryFlow.Store.Fixtures (withTempVault)
import StoryFlow.Store.Vault
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Hspec
import qualified TOML

spec :: Spec
spec = describe "T1 Vault 定位" $ do
  it "從三層深的子目錄向上搜尋找得到 root" $
    withTempVault $ \dir -> do
      _ <- initVault dir "liftgame"
      let deep = dir </> "characters" </> "支線" </> "配角"
      createDirectoryIfMissing True deep
      resolveVaultWith (noRegistry dir) Nothing deep >>= \case
        Right v -> do
          vaultRoot v `shouldBe` dir
          vaultName v `shouldBe` "liftgame"
        Left e -> expectationFailure (T.unpack (renderStoreError e))

  it "沒有 .storyflow/ 時回 VaultNotFound,訊息提示 vault init" $
    withTempVault $ \dir -> do
      r <- resolveVaultWith (noRegistry dir) Nothing dir
      case r of
        Left e@(VaultNotFound "") ->
          renderStoreError e `shouldSatisfy` T.isInfixOf "vault init"
        other -> expectationFailure ("預期 VaultNotFound,得到 " <> show other)

  it "--vault <名稱> 經全域註冊表解析" $
    withTempVault $ \dir -> do
      let root = dir </> "vaults" </> "liftgame"
          reg = dir </> "vaults.toml"
      createDirectoryIfMissing True root
      _ <- initVault root "liftgame"
      -- TOML 的基本字串會把 Windows 路徑的反斜線當跳脫,所以寫成單引號的字面字串
      writeText reg ("liftgame = '" <> T.pack root <> "'\n")
      resolveVaultWith reg (Just "liftgame") dir >>= \case
        Right v -> vaultRoot v `shouldBe` root
        Left e -> expectationFailure (T.unpack (renderStoreError e))

  it "註冊表沒有這個名稱時回 VaultNotFound 且帶名稱" $
    withTempVault $ \dir -> do
      r <- resolveVaultWith (noRegistry dir) (Just "不存在的庫") dir
      r `shouldBe` Left (VaultNotFound "不存在的庫")

  it "註冊表檔案不存在時是空註冊表,不是錯誤" $
    withTempVault $ \dir ->
      loadVaultRegistryFrom (noRegistry dir) `shouldReturn` Right M.empty

  it "找到 .storyflow/ 但 config.toml 壞掉時回 VaultConfigInvalid,不繼續往上找" $
    withTempVault $ \dir -> do
      -- 外層是一個完全正常的 Vault:繼續往上找就會誤中它
      _ <- initVault dir "outer"
      let inner = dir </> "a" </> "b"
          deep = inner </> "c"
      createDirectoryIfMissing True deep
      createDirectoryIfMissing True (storyflowDir inner)
      writeText (configPath inner) "name = \"inner\"\nreferences = [\n"
      r <- resolveVaultWith (noRegistry dir) Nothing deep
      case r of
        Left (VaultConfigInvalid fp _) -> fp `shouldBe` configPath inner
        other -> expectationFailure ("預期 VaultConfigInvalid,得到 " <> show other)

  it "缺少 name 鍵時回 VaultConfigInvalid" $
    withTempVault $ \dir -> do
      createDirectoryIfMissing True (storyflowDir dir)
      writeText (configPath dir) "references = []\n"
      r <- resolveVaultWith (noRegistry dir) Nothing dir
      case r of
        Left (VaultConfigInvalid _ msg) -> msg `shouldSatisfy` T.isInfixOf "name"
        other -> expectationFailure ("預期 VaultConfigInvalid,得到 " <> show other)

  it "references 與 [llm] 區塊被原樣讀進來" $
    withTempVault $ \dir -> do
      createDirectoryIfMissing True (storyflowDir dir)
      writeText (configPath dir) $
        T.unlines
          [ "name = \"liftgame\""
          , "references = [\"shared-lore\"]"
          , ""
          , "[llm]"
          , "endpoint = \"http://127.0.0.1:8080/v1\""
          , "model = \"qwen2.5-14b-instruct\""
          ]
      loadVaultAt dir >>= \case
        Left e -> expectationFailure (T.unpack (renderStoreError e))
        Right v -> do
          let cfg = vaultCfg v
          cfgReferences cfg `shouldBe` ["shared-lore"]
          fmap (M.lookup "model" . llmTable) (cfgLlm cfg)
            `shouldBe` Just (Just (TOML.String "qwen2.5-14b-instruct"))

  it "vaultRelPath 一律回傳以 / 分隔的相對路徑" $
    withTempVault $ \dir -> do
      v <- either (fail . T.unpack . renderStoreError) pure =<< initVault dir "liftgame"
      vaultRelPath v (dir </> "characters" </> "琳達.md") `shouldBe` "characters/琳達.md"
      vaultAbsPath v "characters/琳達.md" `shouldBe` dir </> "characters/琳達.md"

-- | 指向一個確定不存在的註冊表檔,避免測試讀到開發者本機真正的 vaults.toml。
noRegistry :: FilePath -> FilePath
noRegistry dir = dir </> "no-such-registry.toml"

-- | 一律以 UTF-8 位元組寫入:@writeFile@ 走的是本機 locale 編碼,
-- Windows 上會把中文寫成 cp950。
writeText :: FilePath -> Text -> IO ()
writeText fp = BS.writeFile fp . TE.encodeUtf8
