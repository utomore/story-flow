-- | Vault 的定位、設定檔與初始化(ADR-008)。
--
-- 定位是三段規則:@--vault \<名稱\>@ 查全域註冊表 → 否則從工作目錄向上搜尋
-- @.storyflow\/@ → 都沒有就報錯並提示下一步。與 git 同一個心智模型。
--
-- 向上搜尋__找到 @.storyflow\/@ 但設定檔壞掉時不繼續往上找__:繼續找會默默寫進
-- 上一層的另一個 Vault,正是 ADR-008 列出的誤操作風險。
module Aapms.Store.Vault
  ( -- * 型別
    Vault (..)
  , VaultConfig (..)
  , LlmSection (..)

    -- * 定位
  , resolveVault
  , resolveVaultWith
  , loadVaultAt

    -- * 全域註冊表
  , registryPath
  , loadVaultRegistry
  , loadVaultRegistryFrom
  , registerVaultIn

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
import Aapms.Store.Atomic (atomicWriteText)
import Aapms.Store.Error (StoreError (..))
import System.Directory
  ( XdgDirectory (XdgConfig)
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , makeAbsolute
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
  -- ^ 引用的其他 Vault 名稱。對本 Vault 而言唯讀(ADR-008)
  , cfgLlm :: Maybe LlmSection
  }
  deriving stock (Show, Eq)

-- | @[llm]@ 那張表,__原樣捧著不解讀__。
--
-- 這一層的職責是「把表捧著」,不是「表達設定」——設定的形狀(@base_url@ /
-- @model@ / @api_key@ / @timeout_ms@ / @retries@)由 @aapms-llm@ 的
-- @Aapms.Llm.Config@ 在 P5 定義並解析。P1 就替它定義欄位,等於在 P1 凍結
-- P5 還沒想清楚的設定形狀。
newtype LlmSection = LlmSection {llmSectionTable :: TOML.Table}
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
-- __一律以 @\/@ 分隔__:索引可能被跨平台重建(ADR-002 保證刪掉重建等價),
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

-- | ADR-008 的三段規則。@Just name@ 查全域註冊表,@Nothing@ 從 @cwd@ 向上搜尋。
resolveVault :: Maybe Text -> FilePath -> IO (Either StoreError Vault)
resolveVault mName cwd = do
  reg <- registryPath
  resolveVaultWith reg mName cwd

-- | 指定註冊表檔案位置的版本。測試用臨時註冊表,不去碰使用者真正的
-- @~\/.config\/aapms\/vaults.toml@。
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
          Just (TOML.Table t) -> Just (LlmSection t)
          _ -> Nothing
    Right (VaultConfig name refs llm)
  Right _ -> Left (VaultConfigInvalid fp "檔案的最上層不是 TOML 表")
  where
    str (TOML.String s) = Right s
    str _ = Left (VaultConfigInvalid fp "鍵 `references` 必須是字串陣列")

-- 全域註冊表 --------------------------------------------------------------------

-- | @~\/.config\/aapms\/vaults.toml@(Windows 為 @%APPDATA%@ 下的對應位置)。
registryPath :: IO FilePath
registryPath = do
  dir <- getXdgDirectory XdgConfig "story-flow"
  pure (dir </> "vaults.toml")

loadVaultRegistry :: IO (Either StoreError (Map Text FilePath))
loadVaultRegistry = registryPath >>= loadVaultRegistryFrom

-- | 檔案不存在時回傳__空註冊表__而不是錯誤:還沒註冊過任何 Vault 是正常狀態,
-- 「查不到這個名稱」的錯誤由呼叫端以 'VaultNotFound' 表達,訊息才講得清楚。
--
-- 格式兩種都收(ADR-008 要求可手寫):最上層的 @名稱 = \"路徑\"@,
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

-- | 把一個 Vault 記進全域註冊表。__只追加一行__,不重寫整份檔案。
--
-- ADR-008 要求 @vaults.toml@ 可手寫、格式簡單,所以作者的註解與排列順序不能
-- 被工具洗掉;重寫整份檔案就會。名稱已經登記過同一個路徑時是 no-op(重複
-- 執行 @vault init@ 不該報錯);登記到__另一個__路徑時回
-- 'VaultConfigInvalid' ——同一個名稱指向兩個世界是誤操作的溫床,而
-- TOML 也不接受重複的鍵。
--
-- 註冊表檔案位置由呼叫端給,與 'loadVaultRegistryFrom' 同一個理由:測試不能
-- 碰使用者真正的 @~\/.config\/aapms\/vaults.toml@。
registerVaultIn :: FilePath -> Text -> FilePath -> IO (Either StoreError ())
registerVaultIn regFile name root =
  loadVaultRegistryFrom regFile >>= \case
    Left e -> pure (Left e)
    Right reg -> case M.lookup name reg of
      Just old
        | normalise old == normalise root -> pure (Right ())
        | otherwise ->
            pure . Left . VaultConfigInvalid regFile $
              "名稱「"
                <> name
                <> "」已經指向 "
                <> T.pack old
                <> ";請換一個 Vault 名稱,或先手動修掉這一行"
      Nothing -> do
        createDirectoryIfMissing True (takeDirectory regFile)
        -- key 也要引號(entity-graph-core/B001):TOML 的裸 key 只准 [A-Za-z0-9_-],
        -- 中文名寫成裸 key 會讓整份全域註冊表下一次就解析失敗。quote 做的逃逸
        -- 對 key 與 value 是同一套
        appendMissingLines regFile [quote name <> " = " <> quote (T.pack (toSlash root))]

-- 初始化 ----------------------------------------------------------------------

-- | Entity 檔依型別分目錄,Level 檔集中在 @levels\/@(system.md 的目錄結構)。
vaultSubdirs :: [FilePath]
vaultSubdirs = ["characters", "lore", "items", "dialogues", "levels"]

-- | 建立 Vault 骨架。已經有 Vault 時回 'VaultAlreadyExists' 且__不覆寫任何東西__。
initVault :: FilePath -> Text -> IO (Either StoreError Vault)
initVault givenRoot name = do
  -- 先轉絕對路徑(entity-graph-core/B002):呼叫端常給「.」,而這個 root 會被寫進
  -- 全域註冊表、被 --vault <名稱> 從任何目錄拿來定址——相對路徑在那裡毫無意義
  root <- makeAbsolute givenRoot
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
          -- 也不會被 commit;根目錄那份是給人看的。workshops/ 是工作坊的 session
          -- 快照(llm-workshop-mcp/F002):未定案的對話是本機互動狀態,不是故事
          -- 設定,同一個理由不進 git
          atomicWriteText (storyflowDir root </> ".gitignore") "index.db\nworkshops/\n" >>= \case
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
