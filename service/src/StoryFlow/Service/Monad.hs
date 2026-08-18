-- | 'ServiceM' —— 業務操作跑在哪裡,以及 'Env' 從哪裡來。
--
-- 用 @ReaderT@ + @ExceptT@ 而不是「每個函式吃 'Env' 回 @IO (Either ...)@」的
-- 理由:業務操作是__組合__的。「建一個 Entity 並同時掛一條 partOf 關聯」是三次
-- 落地呼叫串起來,每一次都可能失敗;手工串 @Either@ 會讓每個函式的主體被
-- @case@ 淹沒,而錯誤處理正是最不該被淹沒的部分。
--
-- 'ServiceM' 以 @GeneralizedNewtypeDeriving@ 拿 'MonadError' \/ 'MonadReader',
-- 呼叫端因此不必知道它是 @ReaderT@ 疊 @ExceptT@ ——這一層的內部結構未來要換
-- (例如加 @StateT@ 放快取)不會波及 @server@ 與 @cli@。
--
-- __沒有把時鐘放進 'Env'__:@store@ 的寫入函式已經自己
-- 'Data.Time.getCurrentTime'。把時鐘注入 service 卻不注入 store,等於只有一半
-- 可控,不如統一。
module StoryFlow.Service.Monad
  ( -- * 環境
    Env (..)

    -- * Monad
  , ServiceM
  , runService
  , liftStore

    -- * 生命週期
  , openEnv
  , closeEnv
  , withEnv

    -- * 全域 Vault 註冊表
  , vaultsFile
  , vaultsEnvVar
  ) where

import Control.Exception (finally)
import Control.Monad.Except (ExceptT, MonadError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection)
import StoryFlow.Core.Registry (TypeRegistry)
import StoryFlow.Service.Error (ServiceError (..))
import StoryFlow.Store
  ( IndexIssue
  , StoreError
  , Vault
  , closeIndex
  , openVaultIndex
  , registryPath
  , resolveVaultWith
  )
import StoryFlow.Types.Loader (defaultRegistryDir, loadRegistry, registryEnvVar)
import System.Environment (lookupEnv)

-- | 一次業務呼叫需要的全部外部狀態。三樣都在 'openEnv' 一次張羅好,
-- 業務函式因此不必逐個參數傳 @Connection@ \/ @Vault@ \/ 註冊表。
data Env = Env
  { envVault :: Vault
  , envConn :: Connection
  , envTypes :: TypeRegistry
  }

newtype ServiceM a = ServiceM (ReaderT Env (ExceptT ServiceError IO) a)
  deriving newtype
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    , MonadReader Env
    , MonadError ServiceError
    )

runService :: Env -> ServiceM a -> IO (Either ServiceError a)
runService env (ServiceM m) = runExceptT (runReaderT m env)

-- | 把 @store@ 的 @IO (Either StoreError a)@ 接進 'ServiceM'。
--
-- 落地層的失敗原樣包成 'StoreFailed' ——訊息與錯誤碼都由
-- "StoryFlow.Service.Error" 委派回去,這一層不重寫。
liftStore :: IO (Either StoreError a) -> ServiceM a
liftStore act = liftIO act >>= either (throwError . StoreFailed) pure

-- 全域 Vault 註冊表 -------------------------------------------------------------

-- | 覆寫全域 Vault 註冊表位置的環境變數名。
vaultsEnvVar :: String
vaultsEnvVar = "STORYFLOW_VAULTS"

-- | @~\/.config\/story-flow\/vaults.toml@,或 'vaultsEnvVar' 指定的檔案。
--
-- 需要一個覆寫點的理由有兩個,而且都不是可選的:測試不能碰使用者真正的註冊表
-- (寫進去就是污染真實環境),而同一台機器上跑不同工作集的人需要能切換。
vaultsFile :: IO FilePath
vaultsFile =
  lookupEnv vaultsEnvVar >>= \case
    Just p | not (null p) -> pure p
    _ -> registryPath

-- 生命週期 ---------------------------------------------------------------------

-- | 定位 Vault、載入型別註冊表、開索引。
--
-- 順序不是隨便排的:__索引最後開__,前兩步失敗時才不會漏掉一個沒關的連線。
-- 'openVaultIndex' 回的 @[IndexIssue]@ 一併帶出——作者用編輯器改過的檔案在這
-- 一步就補進索引了,而解析失敗的檔案要讓呼叫端有機會提醒。
openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))
openEnv mName cwd = do
  regFile <- vaultsFile
  resolveVaultWith regFile mName cwd >>= \case
    Left e -> pure (Left (StoreFailed e))
    Right v ->
      loadTypeRegistry >>= \case
        Left e -> pure (Left e)
        Right reg ->
          openVaultIndex v >>= \case
            Left e -> pure (Left (StoreFailed e))
            Right (conn, issues) -> pure (Right (Env v conn reg, issues))

-- | 載入型別註冊表。
--
-- 失敗__直接讓 'openEnv' 失敗,不退回空註冊表__:空註冊表會讓
-- 'StoryFlow.Core.Registry.checkEntity' 對每個 Entity 都回
-- @UnknownEntityType@,把一個設定錯誤偽裝成滿螢幕的資料錯誤。
loadTypeRegistry :: IO (Either ServiceError TypeRegistry)
loadTypeRegistry =
  defaultRegistryDir >>= \case
    Nothing -> Left . RegistryUnavailable <$> registryHint
    Just d -> either (Left . RegistryLoadFailed) Right <$> loadRegistry d

-- | 註冊表找不到時,訊息要說出__去哪裡找過__。
registryHint :: IO Text
registryHint =
  lookupEnv registryEnvVar >>= \case
    Just p
      | not (null p) ->
          pure $
            "環境變數 "
              <> T.pack registryEnvVar
              <> " 指向 "
              <> T.pack p
              <> ",但那個目錄不存在"
    _ ->
      pure $
        "隨執行檔安裝的 registry/ 目錄不在,而環境變數 "
          <> T.pack registryEnvVar
          <> " 也沒有設定;請把它指向原始碼樹的 types/registry/"

closeEnv :: Env -> IO ()
closeEnv = closeIndex . envConn

-- | 開 → 用 → 關。動作拋例外時連線一樣會被關掉。
withEnv :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)
withEnv mName cwd act =
  openEnv mName cwd >>= \case
    Left e -> pure (Left e)
    Right (env, _) -> Right <$> (act env `finally` closeEnv env)
