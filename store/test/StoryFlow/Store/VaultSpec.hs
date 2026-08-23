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
import System.Directory (createDirectoryIfMissing, doesFileExist, withCurrentDirectory)
import System.FilePath (isAbsolute, normalise, (</>))
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

  -- entity-graph-core/B001:中文 Vault 名寫進全域註冊表後要讀得回來。
  -- 2026-08-22 實測:registerVaultIn 寫出「測試世界 = "."」——TOML 的裸 key 只准
  -- [A-Za-z0-9_-],下一次 load 直接解析失敗,而且壞的是全域檔,所有 Vault 一起讀不到。
  it "中文 Vault 名登記後,註冊表讀得回來(B001 重現)" $
    withTempVault $ \dir -> do
      let reg = dir </> "vaults.toml"
      registerVaultIn reg "測試世界" dir `shouldReturn` Right ()
      r <- loadVaultRegistryFrom reg
      fmap M.keys r `shouldBe` Right ["測試世界"]

  -- entity-graph-core/B002:initVault 收到相對路徑時,Vault 的 root 與寫進全域註冊表的
  -- 路徑都要是絕對的。「.」在別的目錄下毫無意義,--vault <名稱> 定址會指到錯的地方。
  it "initVault 給相對路徑 → vaultRoot 是絕對路徑(B002 重現)" $
    withTempVault $ \dir -> do
      r <- withCurrentDirectory dir (initVault "." "relworld")
      case r of
        Left e -> expectationFailure (T.unpack (renderStoreError e))
        Right v -> do
          isAbsolute (vaultRoot v) `shouldBe` True
          normalise (vaultRoot v) `shouldBe` normalise dir

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
          fmap (M.lookup "model" . llmSectionTable) (cfgLlm cfg)
            `shouldBe` Just (Just (TOML.String "qwen2.5-14b-instruct"))

  -- llm-workshop-mcp/F001 T3:佔位型別 @LlmConfig@ 改名為 @LlmSection@ ——
  -- 名字讓給 @storyflow-llm@ 的五欄設定型別,這一層捧的是「那張表」不是「設定」。
  --
  -- __行為測試看不出改名__:上面那條就算舊名字還留著(deprecated alias、或只加
  -- 不減)一樣會過。所以直接讀原始碼斷言舊名字__不再出現__,否則兩個同名同義
  -- 不同型的 @LlmConfig@ 會同時存在於 store 與 llm 兩個套件裡。
  it "改名徹底:原始碼裡不再出現 LlmConfig 這個名字" $ do
    src <- readUtf8Source "StoryFlow/Store/Vault.hs"
    ("LlmConfig" `T.isInfixOf` src) `shouldBe` False
    ("LlmSection" `T.isInfixOf` src) `shouldBe` True

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

-- | 讀本套件 @src\/@ 底下的原始碼檔。
--
-- 兩個候選路徑是因為 test 的工作目錄在 @cabal test@(套件目錄)與從專案根
-- 執行時不同;以 UTF-8 位元組解碼,不走系統預設編碼——原始碼裡有繁中註解,
-- Windows 的預設 code page 讀到第一個中文字就會丟 InvalidArgument。
readUtf8Source :: FilePath -> IO Text
readUtf8Source rel = go ["src" </> rel, "store" </> "src" </> rel]
  where
    go [] = fail ("找不到原始碼檔:" <> rel)
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then TE.decodeUtf8 <$> BS.readFile c else go rest
