-- | Vault 的定位、設定檔與初始化(ADR-0008)。
--
-- 定位是三段規則:@--vault \<名稱\>@ 查全域註冊表 → 否則從工作目錄向上搜尋
-- @.storyflow\/@ → 都沒有就報錯並提示下一步。與 git 同一個心智模型。
--
-- 向上搜尋__找到 @.storyflow\/@ 但設定檔壞掉時不繼續往上找__:繼續找會默默寫進
-- 上一層的另一個 Vault,正是 ADR-0008 列出的誤操作風險。
module StoryFlow.Store.Vault
  ( -- * 型別
    Vault (..)
  , VaultConfig (..)
  , LlmConfig (..)

    -- * 定位
  , resolveVault
  , resolveVaultWith
  , loadVaultAt

    -- * 全域註冊表
  , registryPath
  , loadVaultRegistry
  , loadVaultRegistryFrom

    -- * 初始化
  , initVault
  , vaultSubdirs

    -- * 路徑
  , storyflowDir
  , configPath
  , indexDbPath
  , vaultRelPath
  , vaultAbsPath
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Store.Atomic (atomicWriteText)
import StoryFlow.Store.Error (StoreError (..))
import System.Directory
  ( XdgDirectory (XdgConfig)
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getXdgDirectory
  )
import System.FilePath (makeRelative, normalise, takeDirectory, (</>))
import qualified TOML

-- | 一個 Vault = 一個世界 = 一個 git repo。
data Vault = Vault
  { vaultName :: Text
  , vaultRoot :: FilePath
  -- ^ 含 @.storyflow\/@ 的那一層
  , vaultCfg :: VaultConfig
  }
  deriving stock (Show, Eq)

data VaultConfig = VaultConfig
  { cfgName :: Text
  , cfgReferences :: [Text]
  -- ^ 引用的其他 Vault 名稱。對本 Vault 而言唯讀(ADR-0008)
  , cfgLlm :: Maybe LlmConfig
  }
  deriving stock (Show, Eq)

-- | @[llm]@ 是 P5 的東西。P1 __原樣讀存不解讀__,所以直接保留 TOML 表本身——
-- 現在替它定義欄位,等於在 P1 就凍結 P5 還沒想清楚的設定形狀。
newtype LlmConfig = LlmConfig {llmTable :: TOML.Table}
  deriving stock (Show, Eq)

-- 路徑 ------------------------------------------------------------------------

storyflowDir :: FilePath -> FilePath
storyflowDir root = root </> ".storyflow"

configPath :: FilePath -> FilePath
configPath root = storyflowDir root </> "config.toml"

indexDbPath :: Vault -> FilePath
indexDbPath v = storyflowDir (vaultRoot v) </> "index.db"

-- | 絕對路徑 → 索引中儲存的相對路徑。
--
-- __一律以 @\/@ 分隔__:索引可能被跨平台重建(ADR-0002 保證刪掉重建等價),
-- 而 @characters\\琳達.md@ 與 @characters\/琳達.md@ 是兩個不同的字串主鍵。
-- 傳入已經是相對路徑的值時原樣正規化後回傳。
vaultRelPath :: Vault -> FilePath -> FilePath
vaultRelPath v fp = toSlash (makeRelative (normalise (vaultRoot v)) (normalise fp))

-- | 索引中的相對路徑 → 可開檔的絕對路徑。
vaultAbsPath :: Vault -> FilePath -> FilePath
vaultAbsPath v rel = vaultRoot v </> rel

toSlash :: FilePath -> FilePath
toSlash = map (\c -> if c == '\\' then '/' else c)

-- 定位 ------------------------------------------------------------------------

-- | ADR-0008 的三段規則。@Just name@ 查全域註冊表,@Nothing@ 從 @cwd@ 向上搜尋。
resolveVault :: Maybe Text -> FilePath -> IO (Either StoreError Vault)
resolveVault mName cwd = do
  reg <- registryPath
  resolveVaultWith reg mName cwd

-- | 指定註冊表檔案位置的版本。測試用臨時註冊表,不去碰使用者真正的
-- @~\/.config\/story-flow\/vaults.toml@。
resolveVaultWith :: FilePath -> Maybe Text -> FilePath -> IO (Either StoreError Vault)
resolveVaultWith regFile mName cwd = case mName of
  Just name ->
    loadVaultRegistryFrom regFile >>= \case
      Left e -> pure (Left e)
      Right reg -> case M.lookup name reg of
        Nothing -> pure (Left (VaultNotFound name))
        Just root -> do
          ok <- doesDirectoryExist (storyflowDir root)
          if ok then loadVaultAt root else pure (Left (VaultNotFound name))
  Nothing -> searchUp (normalise cwd)

-- | 向上搜尋,抵達檔案系統根目錄(@takeDirectory@ 不再改變路徑)時停止。
searchUp :: FilePath -> IO (Either StoreError Vault)
searchUp dir = do
  here <- doesDirectoryExist (storyflowDir dir)
  if here
    then loadVaultAt dir
    else
      let up = takeDirectory dir
       in if up == dir then pure (Left (VaultNotFound "")) else searchUp up

-- | 由已知的根目錄讀出 Vault。設定檔缺漏或壞掉一律 'VaultConfigInvalid'。
loadVaultAt :: FilePath -> IO (Either StoreError Vault)
loadVaultAt root = do
  let fp = configPath root
  ok <- doesFileExist fp
  if not ok
    then pure (Left (VaultConfigInvalid fp "設定檔不存在"))
    else
      readUtf8 fp >>= \case
        Left msg -> pure (Left (VaultConfigInvalid fp msg))
        Right txt -> pure $ case parseConfig fp txt of
          Left e -> Left e
          Right cfg -> Right (Vault (cfgName cfg) root cfg)

readUtf8 :: FilePath -> IO (Either Text Text)
readUtf8 fp = do
  raw <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
  pure $ case raw of
    Left e -> Left (T.pack (show e))
    Right bytes -> case TE.decodeUtf8' bytes of
      Left e -> Left ("檔案不是合法的 UTF-8:" <> T.pack (show e))
      Right t -> Right t

parseConfig :: FilePath -> Text -> Either StoreError VaultConfig
parseConfig fp txt = case TOML.decode txt of
  Left e -> Left (VaultConfigInvalid fp (TOML.renderTOMLError e))
  Right (TOML.Table tbl) -> do
    name <- case M.lookup "name" tbl of
      Just (TOML.String s) -> Right s
      Just _ -> Left (VaultConfigInvalid fp "鍵 `name` 必須是字串")
      Nothing -> Left (VaultConfigInvalid fp "缺少必填鍵 `name`")
    refs <- case M.lookup "references" tbl of
      Nothing -> Right []
      Just (TOML.Array xs) -> traverse str xs
      Just _ -> Left (VaultConfigInvalid fp "鍵 `references` 必須是字串陣列")
    let llm = case M.lookup "llm" tbl of
          Just (TOML.Table t) -> Just (LlmConfig t)
          _ -> Nothing
    Right (VaultConfig name refs llm)
  Right _ -> Left (VaultConfigInvalid fp "檔案的最上層不是 TOML 表")
  where
    str (TOML.String s) = Right s
    str _ = Left (VaultConfigInvalid fp "鍵 `references` 必須是字串陣列")

-- 全域註冊表 --------------------------------------------------------------------

-- | @~\/.config\/story-flow\/vaults.toml@(Windows 為 @%APPDATA%@ 下的對應位置)。
registryPath :: IO FilePath
registryPath = do
  dir <- getXdgDirectory XdgConfig "story-flow"
  pure (dir </> "vaults.toml")

loadVaultRegistry :: IO (Either StoreError (Map Text FilePath))
loadVaultRegistry = registryPath >>= loadVaultRegistryFrom

-- | 檔案不存在時回傳__空註冊表__而不是錯誤:還沒註冊過任何 Vault 是正常狀態,
-- 「查不到這個名稱」的錯誤由呼叫端以 'VaultNotFound' 表達,訊息才講得清楚。
--
-- 格式兩種都收(ADR-0008 要求可手寫):最上層的 @名稱 = \"路徑\"@,
-- 以及 @[vaults]@ 表底下的同樣寫法。
loadVaultRegistryFrom :: FilePath -> IO (Either StoreError (Map Text FilePath))
loadVaultRegistryFrom fp = do
  ok <- doesFileExist fp
  if not ok
    then pure (Right M.empty)
    else
      readUtf8 fp >>= \case
        Left msg -> pure (Left (VaultConfigInvalid fp msg))
        Right txt -> pure $ case TOML.decode txt of
          Left e -> Left (VaultConfigInvalid fp (TOML.renderTOMLError e))
          Right (TOML.Table tbl) -> Right (flat tbl <> nested tbl)
          Right _ -> Left (VaultConfigInvalid fp "檔案的最上層不是 TOML 表")
  where
    flat tbl = M.fromList [(k, T.unpack s) | (k, TOML.String s) <- M.toList tbl]
    nested tbl = case M.lookup "vaults" tbl of
      Just (TOML.Table t) -> flat t
      _ -> M.empty

-- 初始化 ----------------------------------------------------------------------

-- | Entity 檔依型別分目錄,Level 檔集中在 @levels\/@(architecture.md 的目錄結構)。
vaultSubdirs :: [FilePath]
vaultSubdirs = ["characters", "lore", "items", "dialogues", "levels"]

-- | 建立 Vault 骨架。已經有 Vault 時回 'VaultAlreadyExists' 且__不覆寫任何東西__。
initVault :: FilePath -> Text -> IO (Either StoreError Vault)
initVault root name = do
  exists <- doesFileExist (configPath root)
  if exists
    then pure (Left (VaultAlreadyExists root))
    else do
      createDirectoryIfMissing True (storyflowDir root)
      mapM_ (createDirectoryIfMissing True . (root </>)) vaultSubdirs
      atomicWriteText (configPath root) (renderConfig name) >>= \case
        Left e -> pure (Left e)
        Right () ->
          -- .storyflow/.gitignore 讓 index.db 就算 Vault 根目錄沒有 .gitignore
          -- 也不會被 commit;根目錄那份是給人看的
          atomicWriteText (storyflowDir root </> ".gitignore") "index.db\n" >>= \case
            Left e -> pure (Left e)
            Right () ->
              appendMissingLines (root </> ".gitignore") [".storyflow/index.db"] >>= \case
                Left e -> pure (Left e)
                Right () -> loadVaultAt root

renderConfig :: Text -> Text
renderConfig name =
  T.unlines
    [ "name = " <> quote name
    , "references = []"
    ]

quote :: Text -> Text
quote t = "\"" <> T.concatMap esc t <> "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc c = T.singleton c

-- | 只__追加缺少的行__,不覆寫作者既有內容——.gitignore 常常已經有一堆規則,
-- 蓋掉別人的檔案是最不能接受的初始化行為。
appendMissingLines :: FilePath -> [Text] -> IO (Either StoreError ())
appendMissingLines fp wanted = do
  ok <- doesFileExist fp
  if not ok
    then atomicWriteText fp (T.unlines wanted)
    else
      readUtf8 fp >>= \case
        Left msg -> pure (Left (FileReadFailed fp msg))
        Right old ->
          let have = map T.strip (T.lines old)
              missing = [l | l <- wanted, l `notElem` have]
              sep = if T.null old || "\n" `T.isSuffixOf` old then "" else "\n"
           in if null missing
                then pure (Right ())
                else atomicWriteText fp (old <> sep <> T.unlines missing)
