-- | 伺服器狀態與 'run1' ——每個 handler 的固定形狀。
--
-- __'MVar' 把所有請求序列化__。@sqlite-simple@ 的 @Connection@ 不保證多執行緒
-- 安全,而 warp 是多執行緒的。三種可能的解法:
--
-- 1. 每請求開一條連線——每次都要重跑 schema 檢查與過時偵測
-- 2. 連線池——要處理 SQLite 的寫入鎖,而且多條連線同時寫仍然要協調
-- 3. 單一連線加互斥鎖
--
-- 單人本機工具選第三個。它順帶讓「先寫檔、再更新索引」這條紀律在__請求之間__
-- 也是原子的:兩個並發的 PATCH 不可能交錯成「A 寫檔 → B 寫檔 → A 更新索引」。
-- 代價是吞吐量,而單人工作室的吞吐量不是瓶頸。
--
-- __這不是疏忽,是取捨__ ——後人要改成連線池之前,請先確認上面那條原子性還有人守。
--
-- 'Env' 是__延遲取得__的:@GET \/vaults@ 與 @POST \/vaults@ 對應 service 不需要
-- @Env@ 的那兩個函式,所以在沒有目前 Vault 的目錄裡啟動仍然要能服務它們。開索引
-- 因此發生在第一個真的需要它的請求上,而不是啟動時。
module StoryFlow.Server.State
  ( AppState (..)
  , newAppState
  , closeAppState
  , run1
  , runIO
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Servant (Handler)
import StoryFlow.Server.Error (toServerError)
import StoryFlow.Service (Env, ServiceError, ServiceM, closeEnv, openEnv, runService)

data AppState = AppState
  { asVault :: Maybe Text
  -- ^ @--vault@ 的名稱,原樣傳給 'openEnv'
  , asCwd :: FilePath
  -- ^ 向上搜尋 @.storyflow\/@ 的起點
  , asEnv :: MVar (Maybe Env)
  -- ^ @Nothing@ = 還沒開。這個 'MVar' 同時是「延遲取得」的記憶體與請求的互斥鎖
  }

newAppState :: Maybe Text -> FilePath -> IO AppState
newAppState vault cwd = AppState vault cwd <$> newMVar Nothing

closeAppState :: AppState -> IO ()
closeAppState st = readMVar (asEnv st) >>= maybe (pure ()) closeEnv

-- | 每個需要 'Env' 的 handler 的固定形狀:轉換請求 → 'runService' → 對應狀態碼。
--
-- @handler = run1 st (someServiceFunction args)@ 就是全部。任何一個 handler 若比
-- 這長,那多出來的部分十之八九是業務判斷,而業務判斷屬於 @service@。
run1 :: AppState -> ServiceM a -> Handler a
run1 st op = do
  r <- liftIO (withEnvLocked st (\env -> runService env op))
  either (throwError . toServerError) pure r

-- | 不需要 'Env' 的兩個操作('StoryFlow.Service.listVaults' \/
-- 'StoryFlow.Service.createVault')走這條。
runIO :: IO (Either ServiceError a) -> Handler a
runIO act = liftIO act >>= either (throwError . toServerError) pure

-- | 取鎖 → 必要時開 'Env' → 跑動作。
--
-- 開 'Env' 失敗時__不把失敗記住__:下一個請求會再試一次。作者可能剛好在兩個請求
-- 之間才 @vault init@ 完,把第一次的失敗快取起來會逼他重啟伺服器。
withEnvLocked :: AppState -> (Env -> IO (Either ServiceError a)) -> IO (Either ServiceError a)
withEnvLocked st act = modifyMVar (asEnv st) $ \case
  Just env -> (,) (Just env) <$> act env
  Nothing ->
    openEnv (asVault st) (asCwd st) >>= \case
      Left e -> pure (Nothing, Left e)
      Right (env, _issues) -> (,) (Just env) <$> act env
