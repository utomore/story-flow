-- | @story-flow doctor@:五項__讀不連__的本機診斷(G-E002)。
--
-- 回答的是「這個 CLI 在這裡跑得起來嗎」。它刻意__不開 Vault 的索引__、__不打任何
-- 網路__:診斷指令不該有副作用,而它要在連 Vault 都還沒有的目錄也跑得起來
-- ——使用者可能正要 @vault init@。
--
-- 五項依序:版本、型別註冊表、Vault、全域註冊表(@vaults.toml@)、@[llm]@ 段。
-- 每項各自有 @ok@,彼此獨立;__只有型別註冊表那一項決定退出碼__——沒有註冊表
-- 什麼都不能做,其餘四項是資訊。
--
-- 這裡__不是__「首次執行引導」。第一個跑這個 CLI 的是 Claude Code,stdin 不是
-- TTY,@--json@ 的 stdout 是協定通道;診斷一律是「使用者主動問、機器回答」,
-- 不會擋住任何 agent。
module StoryFlow.Cli.Doctor
  ( -- * 報告
    DoctorReport (..)
  , RegistryCheck (..)
  , VaultCheck (..)
  , VaultRegistryCheck (..)
  , LlmCheck (..)
  , LlmState (..)

    -- * 執行
  , runDoctor
  , doctorPasses

    -- * 渲染
  , renderDoctor
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Registry (listTypes)
import StoryFlow.Llm (LlmConfig (..), parseLlmConfig, renderLlmError)
import StoryFlow.Service

-- 報告 -------------------------------------------------------------------------

data DoctorReport = DoctorReport
  { drVersion :: Text
  , drRegistry :: RegistryCheck
  , drVault :: VaultCheck
  , drVaultRegistry :: VaultRegistryCheck
  , drLlm :: LlmCheck
  }
  deriving stock (Show, Eq)

-- | 型別註冊表:從哪一層載入、載到幾個型別。
data RegistryCheck = RegistryCheck
  { dgOk :: Bool
  , dgSource :: Maybe Text
  -- ^ @env@ \/ @beside_executable@ \/ @data_files@
  , dgPath :: Maybe FilePath
  , dgTypes :: Int
  , dgErrors :: [Text]
  , dgMessage :: Text
  }
  deriving stock (Show, Eq)

-- | 目前 Vault:找得到就給名稱與根目錄。找不到__不是失敗__。
data VaultCheck = VaultCheck
  { dvOk :: Bool
  , dvName :: Maybe Text
  , dvRoot :: Maybe FilePath
  , dvMessage :: Text
  }
  deriving stock (Show, Eq)

-- | 全域 @vaults.toml@ 解不解得開。2026-08-22 發現中文 Vault 名會把它寫壞,
-- 這一項就是要把那種狀況指出來。
data VaultRegistryCheck = VaultRegistryCheck
  { dxOk :: Bool
  , dxPath :: FilePath
  , dxCount :: Int
  , dxMessage :: Text
  }
  deriving stock (Show, Eq)

data LlmState
  = -- | 第 3 項沒找到 Vault,查不了
    LlmUnchecked
  | -- | Vault 在,但 @config.toml@ 沒有 @[llm]@ 段
    LlmAbsent
  | -- | 有,而且解得開
    LlmConfigured
  | -- | 有,但解不開
    LlmInvalid
  deriving stock (Show, Eq)

data LlmCheck = LlmCheck
  { dlState :: LlmState
  , dlBaseUrl :: Maybe Text
  , dlModel :: Maybe Text
  , dlMessage :: Text
  }
  deriving stock (Show, Eq)

-- | 退出碼的唯一依據。
doctorPasses :: DoctorReport -> Bool
doctorPasses = dgOk . drRegistry

-- 執行 -------------------------------------------------------------------------

-- | 五項依序跑完。@cwd@ 與 @--vault@ 由呼叫端給,與 'openEnv' 同一種簽名。
runDoctor :: Text -> Maybe Text -> FilePath -> IO DoctorReport
runDoctor ver mVault cwd = do
  reg <- checkRegistry
  vault <- locateVault mVault cwd
  DoctorReport ver reg (vaultCheck vault)
    <$> checkVaultRegistry
    <*> pure (llmCheck vault)

checkRegistry :: IO RegistryCheck
checkRegistry =
  locateRegistry >>= \case
    Nothing -> do
      beside <- registryBesideExecutable
      pure
        RegistryCheck
          { dgOk = False
          , dgSource = Nothing
          , dgPath = Nothing
          , dgTypes = 0
          , dgErrors = []
          , dgMessage =
              "找過三個地方都沒有:環境變數 "
                <> T.pack registryEnvVar
                <> "、執行檔旁的 "
                <> T.pack beside
                <> "、cabal 安裝時的 data-files。請把 registry/ 放到執行檔旁邊,或設 "
                <> T.pack registryEnvVar
          }
    Just (src, dir) ->
      loadRegistry dir >>= \case
        Left es ->
          pure
            RegistryCheck
              { dgOk = False
              , dgSource = Just (sourceName src)
              , dgPath = Just dir
              , dgTypes = 0
              , dgErrors = map renderLoadError es
              , dgMessage = "在 " <> T.pack dir <> " 找到了,但有 " <> count (length es) "份宣告" <> "載入失敗"
              }
        Right tr ->
          let n = length (listTypes tr)
           in pure
                RegistryCheck
                  { dgOk = True
                  , dgSource = Just (sourceName src)
                  , dgPath = Just dir
                  , dgTypes = n
                  , dgErrors = []
                  , dgMessage = count n "個型別" <> ",來自" <> sourceLabel src <> " " <> T.pack dir
                  }

sourceName :: RegistrySource -> Text
sourceName = \case
  FromEnv -> "env"
  BesideExecutable -> "beside_executable"
  FromDataDir -> "data_files"

sourceLabel :: RegistrySource -> Text
sourceLabel = \case
  FromEnv -> "環境變數 " <> T.pack registryEnvVar
  BesideExecutable -> "執行檔旁"
  FromDataDir -> "cabal 安裝目錄"

vaultCheck :: Either ServiceError (VaultView, VaultConfig) -> VaultCheck
vaultCheck = \case
  Left e ->
    VaultCheck
      { dvOk = False
      , dvName = Nothing
      , dvRoot = Nothing
      , dvMessage = renderServiceError e
      }
  Right (v, _) ->
    VaultCheck
      { dvOk = True
      , dvName = Just (vvName v)
      , dvRoot = Just (vvRoot v)
      , dvMessage = vvName v <> "(" <> T.pack (vvRoot v) <> ")"
      }

checkVaultRegistry :: IO VaultRegistryCheck
checkVaultRegistry = do
  path <- vaultsFile
  listVaults >>= \case
    Left e ->
      pure
        VaultRegistryCheck
          { dxOk = False
          , dxPath = path
          , dxCount = 0
          , dxMessage = renderServiceError e
          }
    Right vs ->
      pure
        VaultRegistryCheck
          { dxOk = True
          , dxPath = path
          , dxCount = length vs
          , dxMessage = T.pack path <> ",登記了 " <> count (length vs) "個 Vault"
          }

llmCheck :: Either ServiceError (VaultView, VaultConfig) -> LlmCheck
llmCheck = \case
  Left _ -> LlmCheck LlmUnchecked Nothing Nothing "無法檢查(沒有 Vault)"
  Right (_, cfg) -> case cfgLlm cfg of
    Nothing -> LlmCheck LlmAbsent Nothing Nothing "沒有 [llm] 段;conflict check 會退化成兩層,workshop 跑不起來"
    section -> case parseLlmConfig section of
      Left e -> LlmCheck LlmInvalid Nothing Nothing (renderLlmError e)
      Right c ->
        LlmCheck
          LlmConfigured
          (Just (lcBaseUrl c))
          (Just (lcModel c))
          (lcModel c <> " @ " <> lcBaseUrl c)

count :: Int -> Text -> Text
count n unit = T.pack (show n) <> " " <> unit

-- 渲染 -------------------------------------------------------------------------

-- | 給人看的五行。前綴用 ASCII:人類模式的輸出走主控台的 codec,符號會先壞。
--
-- * @[ok]@ 這一項沒問題
-- * @[!!]@ 這一項有問題
-- * @[--]@ 這一項查不了(前置項失敗)
renderDoctor :: DoctorReport -> Text
renderDoctor r =
  T.intercalate
    "\n"
    [ row True "版本" (drVersion r)
    , row (dgOk reg) "型別註冊表" (dgMessage reg <> errs (dgErrors reg))
    , row (dvOk vlt) "Vault" (dvMessage vlt)
    , row (dxOk vr) "全域註冊表" (dxMessage vr)
    , llmRow (drLlm r)
    ]
  where
    reg = drRegistry r
    vlt = drVault r
    vr = drVaultRegistry r
    row ok label msg = (if ok then "[ok] " else "[!!] ") <> label <> ":" <> msg
    errs [] = ""
    errs es = "\n" <> T.intercalate "\n" (map ("       " <>) es)
    llmRow l = case dlState l of
      LlmUnchecked -> "[--] [llm]:" <> dlMessage l
      LlmAbsent -> "[!!] [llm]:" <> dlMessage l
      LlmInvalid -> "[!!] [llm]:" <> dlMessage l
      LlmConfigured -> "[ok] [llm]:" <> dlMessage l

-- JSON:五個鍵,snake_case。
instance ToJSON DoctorReport where
  toJSON r =
    object
      [ "version" .= drVersion r
      , "registry" .= drRegistry r
      , "vault" .= drVault r
      , "vault_registry" .= drVaultRegistry r
      , "llm" .= drLlm r
      ]

instance ToJSON RegistryCheck where
  toJSON c =
    object
      [ "ok" .= dgOk c
      , "source" .= dgSource c
      , "path" .= dgPath c
      , "types" .= dgTypes c
      , "errors" .= dgErrors c
      , "message" .= dgMessage c
      ]

instance ToJSON VaultCheck where
  toJSON c =
    object
      [ "ok" .= dvOk c
      , "name" .= dvName c
      , "root" .= dvRoot c
      , "message" .= dvMessage c
      ]

instance ToJSON VaultRegistryCheck where
  toJSON c =
    object
      [ "ok" .= dxOk c
      , "path" .= dxPath c
      , "count" .= dxCount c
      , "message" .= dxMessage c
      ]

instance ToJSON LlmCheck where
  toJSON c =
    object
      [ "ok" .= (dlState c == LlmConfigured)
      , "state" .= stateName (dlState c)
      , "base_url" .= dlBaseUrl c
      , "model" .= dlModel c
      , "message" .= dlMessage c
      ]
    where
      stateName :: LlmState -> Text
      stateName = \case
        LlmUnchecked -> "unchecked"
        LlmAbsent -> "absent"
        LlmConfigured -> "configured"
        LlmInvalid -> "invalid"
