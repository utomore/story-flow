-- | 測試底稿:一個真的跑在本機的 OpenAI 相容 stub 端點,以及一個保證__拒絕
-- 連線__的埠。
--
-- __為什麼要打真的 HTTP__:「連不上服務」是地端優先場景最常發生的那一個錯誤。
-- 把 'Aapms.Llm.Client.chat' 簡化成只測純函式,等於把唯一真正會發生的失敗
-- 路徑排除在測試之外。
--
-- __為什麼不用固定埠號__:任何寫死的埠都可能被別的東西佔著,那正是最典型的
-- 偶發失敗。'withStub' 與 'withDeadPort' 都讓 warp 自己配。
module Aapms.Llm.Fixtures
  ( -- * stub 端點
    Stub (..)
  , okStub
  , chatCompletion
  , StubHandle (..)
  , RecordedRequest (..)
  , withStub
  , stubConfig

    -- * 連線被拒
  , withDeadPort

    -- * 臨時 Vault
  , withLlmVault
  , runS

    -- * @[llm]@ 段
  , sectionOf
  , rawSection
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (mkStatus, status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Aapms.Llm (LlmConfig (..))
import Aapms.Service
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import qualified TOML

-- stub 端點 ---------------------------------------------------------------------

-- | stub 要怎麼回應。三個旋鈕分別對應三種失敗:狀態碼(非 2xx)、內文
-- (形狀不對)、延遲(逾時)。
data Stub = Stub
  { stubStatus :: Int
  , stubBody :: LBS.ByteString
  , stubDelayMs :: Int
  -- ^ 回應前先睡多久。逾時測試靠它,__不是靠固定長 sleep 碰運氣__
  }

-- | 200 + 一份合法的 chat completion,不延遲。
okStub :: Stub
okStub = Stub 200 (chatCompletion "琳達站在白塔的階梯上。") 0

-- | 一份 OpenAI 相容的回應。
--
-- __刻意帶上 @id@ \/ @object@ \/ @usage@ 這些額外欄位__:端點之間差異最大的正是
-- 它們,而客戶端必須忽略得掉——認得它們只會讓相容性變窄。
chatCompletion :: Text -> LBS.ByteString
chatCompletion content =
  encode $
    object
      [ "id" .= ("chatcmpl-stub" :: Text)
      , "object" .= ("chat.completion" :: Text)
      , "created" .= (1755648000 :: Int)
      , "model" .= ("qwen2.5-14b-instruct" :: Text)
      , "usage" .= object ["total_tokens" .= (42 :: Int)]
      , "choices"
          .= [ object
                 [ "index" .= (0 :: Int)
                 , "finish_reason" .= ("stop" :: Text)
                 , "message"
                     .= object
                       [ "role" .= ("assistant" :: Text)
                       , "content" .= content
                       ]
                 ]
             ]
      ]

-- | 跑起來的 stub。'stubRequests' 是__到目前為止收到幾個請求__,重試測試看的
-- 就是它。
data StubHandle = StubHandle
  { stubPort :: Int
  , stubRequests :: IO Int
  , stubLast :: IO (Maybe RecordedRequest)
  }

-- | stub 收到的請求。路徑、內文與 header 都留下來,讓測試驗得到「送出去的
-- 到底長什麼樣」。
data RecordedRequest = RecordedRequest
  { rrPath :: Text
  , rrBody :: LBS.ByteString
  , rrHeaders :: [Header]
  }

withStub :: Stub -> (StubHandle -> IO a) -> IO a
withStub st act = do
  countRef <- newIORef 0
  lastRef <- newIORef Nothing
  Warp.testWithApplication (pure (stubApp st countRef lastRef)) $ \port ->
    act (StubHandle port (readIORef countRef) (readIORef lastRef))

-- | __計數發生在延遲__之前__:逾時測試的客戶端會在 stub 還在睡的時候就斷線,
-- 計數若放在回應之後就永遠數不到那一次,而重試測試正是靠這個數字。
--
-- stub 那條執行緒還在睡不影響斷言;'Warp.testWithApplication' 離開區塊時會把它
-- 收掉,而客戶端提前斷線對 warp 而言是正常事件,不會變成應用層例外。
stubApp :: Stub -> IORef Int -> IORef (Maybe RecordedRequest) -> Wai.Application
stubApp Stub {..} countRef lastRef req respond = do
  body <- Wai.strictRequestBody req
  atomicModifyIORef' countRef (\n -> (n + 1, ()))
  writeIORef lastRef . Just $
    RecordedRequest
      { rrPath = "/" <> T.intercalate "/" (Wai.pathInfo req)
      , rrBody = body
      , rrHeaders = Wai.requestHeaders req
      }
  unless (stubDelayMs <= 0) (threadDelay (stubDelayMs * 1000))
  respond $
    Wai.responseLBS
      (mkStatus stubStatus "stub")
      [("Content-Type", "application/json")]
      stubBody

-- | 指向 stub 的設定。逾時 2 秒是給__成功路徑__用的寬裕值;逾時測試自己會把
-- 'lcTimeout' 壓到 150 ms。
stubConfig :: Int -> LlmConfig
stubConfig port =
  LlmConfig
    { lcBaseUrl = "http://127.0.0.1:" <> T.pack (show port) <> "/v1"
    , lcModel = "qwen2.5-14b-instruct"
    , lcApiKey = Nothing
    , lcTimeout = 2000
    , lcRetries = 0
    }

-- 連線被拒 ---------------------------------------------------------------------

-- | 一個保證__沒有人在聽__的埠。
--
-- 作法:先用 'Warp.testWithApplication' 起一個 stub 拿到 warp 配給的埠號,
-- __離開區塊讓它關掉__,再把那個埠號交給 act。聽取用的 socket 關閉後沒有
-- @TIME_WAIT@(那是連線的狀態,不是監聽 socket 的),連過去就是
-- @ConnectionFailure@,而且__立刻__失敗——不必等逾時。
--
-- 這個前提本身由 @Aapms.Llm.StubSpec@ 以一條斷言釘住,不讓它變成
-- 「大概沒人在那個埠上」這種隱性假設。
withDeadPort :: (Int -> IO a) -> IO a
withDeadPort act = do
  port <- Warp.testWithApplication (pure deadApp) pure
  act port
  where
    deadApp _ respond = respond (Wai.responseLBS status200 [] "")

-- 臨時 Vault --------------------------------------------------------------------

-- | 建一個臨時 Vault,可選地在 @.storyflow\/config.toml@ 裡放一段 @[llm]@。
--
-- 傳空清單代表__不寫 @[llm]@ 段__(用來驗 'Aapms.Llm.LlmConfigMissing')。
--
-- __順序是硬的__:設定在 'openEnv' 那一步才被讀進 @Vault@,所以 @[llm]@ 段
-- 必須先寫進檔案再 'openEnv'。
--
-- 建 Vault __只靠 @aapms-service@ 的門面__:@createVault@ \/ @openEnv@ \/
-- @runService@ 都在上面,@aapms-store@ 一次都不必露臉——這正是子系統界線
-- 「設定經 @ServiceM@ 取得」在測試端的證明。
withLlmVault :: [Text] -> (Env -> IO a) -> IO a
withLlmVault llmLines act =
  withSystemTempDirectory "aapms-llm" $ \dir -> do
    reg <- registryDir
    withEnvVars
      [ ("STORYFLOW_VAULTS", dir </> "vaults.toml")
      , ("STORYFLOW_REGISTRY", reg)
      ]
      $ do
        _ <- orDie =<< createVault dir "liftgame"
        unless (null llmLines) $
          appendConfig dir ("" : "[llm]" : llmLines)
        bracket (fst <$> (orDie =<< openEnv Nothing dir)) closeEnv act

-- | 把幾行附到 @.storyflow\/config.toml@ 後面。
--
-- 路徑用字面字串組(而不是 @store@ 的 @configPath@):@aapms-store@ 不在
-- 本套件的相依裡,而且__本來就不該在__。
--
-- 一律以 UTF-8 位元組讀寫:@readFile@ \/ @writeFile@ 走的是本機 locale 編碼,
-- Windows 上會把中文寫成 cp950。
appendConfig :: FilePath -> [Text] -> IO ()
appendConfig root extra = do
  let fp = root </> ".storyflow" </> "config.toml"
  old <- TE.decodeUtf8 <$> BS.readFile fp
  BS.writeFile fp (TE.encodeUtf8 (old <> T.unlines extra))

-- | 整合測試需要真正的型別註冊表。候選路徑涵蓋「從套件目錄跑」與「從專案根跑」。
registryDir :: IO FilePath
registryDir = go ["../types/registry", "types/registry", "../../types/registry"]
  where
    go [] = fail "找不到 types/registry/;整合測試需要真正的型別註冊表"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

-- | 兩個環境變數與 @service@ \/ @conflict@ 的測試底稿同一套:@STORYFLOW_VAULTS@
-- 指向臨時目錄(不動使用者真正的註冊表),@STORYFLOW_REGISTRY@ 指向原始碼樹的
-- 註冊表。離開時原樣還原。
withEnvVars :: [(String, String)] -> IO a -> IO a
withEnvVars vars act = bracket save restore (const act)
  where
    save = mapM apply vars
    apply (k, v) = do
      old <- lookupEnv k
      setEnv k v
      pure (k, old)
    restore = mapM_ (\(k, mv) -> maybe (unsetEnv k) (setEnv k) mv)

runS :: Env -> ServiceM a -> IO a
runS env m = orDie =<< runService env m

-- | 全是字串值的 @[llm]@ 段。
--
-- 這個底稿的存在讓 @Aapms.LlmSpec@ 得以__只 import 門面一個模組__就走完
-- 整輪:'Aapms.Llm.Config.parseLlmConfig' 吃的 @LlmSection@ 來自
-- @aapms-service@,而那個 import 正是門面測試要避開的。
sectionOf :: [(Text, Text)] -> Maybe LlmSection
sectionOf kvs = rawSection [(k, TOML.String v) | (k, v) <- kvs]

-- | 任意 TOML 值的 @[llm]@ 段。給「型別不對」那幾條測試用。
rawSection :: [(Text, TOML.Value)] -> Maybe LlmSection
rawSection = Just . LlmSection . M.fromList

orDie :: Either ServiceError a -> IO a
orDie = either (fail . T.unpack . renderServiceError) pure
