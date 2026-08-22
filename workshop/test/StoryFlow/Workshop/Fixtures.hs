-- | 測試底稿:一個真的跑在本機的 OpenAI 相容 stub 端點、一個保證拒絕連線的埠,
-- 以及臨時 Vault 的建立(真實型別註冊表,或自訂型別註冊表)。
--
-- __為什麼要打真的 HTTP__:「連不上服務」是地端優先場景最常發生的那一個錯誤,
-- 與 @llm\/test\/StoryFlow\/Llm\/Fixtures.hs@ 同一個理由。
--
-- __臨時 Vault 只靠 @storyflow-service@ 的門面__:@createVault@ \/ @openEnv@ \/
-- @runService@ 都在門面上,@storyflow-store@ 一次都不必露臉。
module StoryFlow.Workshop.Fixtures
  ( -- * stub 端點
    Stub (..)
  , okStub
  , chatCompletion
  , StubHandle (..)
  , RecordedRequest (..)
  , withStub
  , stubClient

    -- * 連線被拒
  , withDeadPort
  , deadClient

    -- * 臨時 Vault(真實型別註冊表)
  , withWorkshopVaultDir
  , withRealRegistryEnv
  , withWorkshopVault

    -- * 臨時 Vault(自訂型別註冊表)
  , withCustomRegistryDir
  , withCustomRegistryEnv
  , withCustomVault

    -- * 共用小工具
  , runS
  , orDie
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (mkStatus, status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import StoryFlow.Llm (LlmClient, LlmConfig (..), newLlmClient)
import StoryFlow.Service
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- stub 端點 ---------------------------------------------------------------------

-- | stub 要怎麼回應。三個旋鈕分別對應三種失敗:狀態碼(非 2xx)、內文
-- (形狀不對)、延遲(逾時)。
data Stub = Stub
  { stubStatus :: Int
  , stubBody :: LBS.ByteString
  , stubDelayMs :: Int
  }

-- | 200 + 一份合法的 chat completion,不延遲。
okStub :: Stub
okStub = Stub 200 (chatCompletion "以下是這個階段的草稿。") 0

-- | 一份 OpenAI 相容的回應。刻意帶上額外欄位:端點之間差異最大的正是它們,
-- 客戶端必須忽略得掉。
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

-- | 跑起來的 stub。
data StubHandle = StubHandle
  { stubPort :: Int
  , stubRequests :: IO Int
  , stubLast :: IO (Maybe RecordedRequest)
  }

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

-- | 指向 stub 端口的 'LlmClient'。逾時 2 秒是給成功路徑用的寬裕值。
stubClient :: Int -> IO LlmClient
stubClient port = newLlmClient (llmConfigFor port)

llmConfigFor :: Int -> LlmConfig
llmConfigFor port =
  LlmConfig
    { lcBaseUrl = "http://127.0.0.1:" <> T.pack (show port) <> "/v1"
    , lcModel = "qwen2.5-14b-instruct"
    , lcApiKey = Nothing
    , lcTimeout = 2000
    , lcRetries = 0
    }

-- 連線被拒 ---------------------------------------------------------------------

-- | 一個保證沒有人在聽的埠,與 @llm\/test\/StoryFlow\/Llm\/Fixtures.hs@ 同一個
-- 作法:起一個 stub 拿到 warp 配給的埠號、離開區塊讓它關掉,再把埠號交給 act。
withDeadPort :: (Int -> IO a) -> IO a
withDeadPort act = do
  port <- Warp.testWithApplication (pure deadApp) pure
  act port
  where
    deadApp _ respond = respond (Wai.responseLBS status200 [] "")

-- | 指向死埠的 'LlmClient'。
deadClient :: Int -> IO LlmClient
deadClient port = newLlmClient (llmConfigFor port)

-- 臨時 Vault(真實型別註冊表)-----------------------------------------------------

-- | 建一個臨時 Vault 目錄並登記進(同樣臨時的)全域註冊表,__不開 @Env@__——
-- 讓呼叫端可以在同一個 vault 目錄上,先後用不同的型別註冊表開出不同的 @Env@
-- (T10 的「型別在呼叫前被移除」場景需要這個)。
withWorkshopVaultDir :: (FilePath -> IO a) -> IO a
withWorkshopVaultDir act =
  withSystemTempDirectory "storyflow-workshop-vault" $ \dir ->
    withEnvVars [("STORYFLOW_VAULTS", dir </> "vaults.toml")] $ do
      _ <- orDie =<< createVault dir "liftgame"
      act dir

-- | 用真正的 @types\/registry\/@ 對指定的 vault 目錄開 @Env@。
withRealRegistryEnv :: FilePath -> (Env -> IO a) -> IO a
withRealRegistryEnv dir act = do
  reg <- registryDir
  withCustomRegistryEnv dir reg act

-- | 兩步合一:建臨時 Vault 目錄 + 用真實註冊表開 @Env@。多數測試只需要這個。
withWorkshopVault :: (Env -> IO a) -> IO a
withWorkshopVault act = withWorkshopVaultDir (`withRealRegistryEnv` act)

-- 臨時 Vault(自訂型別註冊表)-----------------------------------------------------

-- | 建一個只含一份自訂型別宣告的臨時註冊表目錄。__讓 T9\/T10 能證明「改 TOML
-- 就改得動」__ ——不必去動樹上真正的 @types\/registry\/@。
withCustomRegistryDir :: Text -> (FilePath -> IO a) -> IO a
withCustomRegistryDir tomlContent act =
  withSystemTempDirectory "storyflow-workshop-registry" $ \regDir -> do
    BS.writeFile (regDir </> "custom.toml") (TE.encodeUtf8 tomlContent)
    act regDir

-- | 用指定的（可能是自訂的）註冊表目錄對指定的 vault 目錄開 @Env@。
withCustomRegistryEnv :: FilePath -> FilePath -> (Env -> IO a) -> IO a
withCustomRegistryEnv dir regDir act =
  withEnvVars [("STORYFLOW_REGISTRY", regDir)] $
    bracket (fst <$> (orDie =<< openEnv Nothing dir)) closeEnv act

-- | 三步合一:臨時 Vault 目錄 + 自訂註冊表內容 + 開 @Env@。
withCustomVault :: Text -> (Env -> IO a) -> IO a
withCustomVault tomlContent act =
  withWorkshopVaultDir $ \dir ->
    withCustomRegistryDir tomlContent $ \regDir ->
      withCustomRegistryEnv dir regDir act

-- 共用小工具 ----------------------------------------------------------------------

-- | 整合測試需要真正的型別註冊表。候選路徑涵蓋「從套件目錄跑」與「從專案根跑」。
registryDir :: IO FilePath
registryDir = go ["../types/registry", "types/registry", "../../types/registry"]
  where
    go [] = fail "找不到 types/registry/;整合測試需要真正的型別註冊表"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

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

orDie :: Either ServiceError a -> IO a
orDie = either (fail . T.unpack . renderServiceError) pure
