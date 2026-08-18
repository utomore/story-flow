-- | server 測試的共用底稿:一個臨時 Vault、一台跑在隨機埠上的 warp,
-- 以及由 __同一份 API 型別__ 產生的 @servant-client@ 呼叫函式。
--
-- client 由 'client' 'storyFlowAPI' 產生而不是自己拼 URL:這一組測試要驗的正是
-- 「server 與 client 由同一個型別產生,不可能悄悄長歪」,自己拼 URL 就把那個保證
-- 繞過去了。
module StoryFlow.Server.Fixtures
  ( -- * 環境
    withServer
  , withServerToken
  , withVaultDir
  , withEnvVars
  , registryDir

    -- * 呼叫
  , Api (..)
  , api
  , runC
  , runE
  , statusOf
  , codeOf

    -- * 樣本
  , newEntity
  , newFragment
  , newLevel
  , newNode
  , idOf
  , refOf
  ) where

import Control.Exception (bracket)
import Data.Aeson (Value (Object, String), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
  ( ManagerSettings
  , defaultManagerSettings
  , managerModifyRequest
  , newManager
  , requestHeaders
  )
import Network.HTTP.Types (hAuthorization, statusCode)
import qualified Network.Wai.Handler.Warp as Warp
import Servant.API ((:<|>) (..))
import Servant.Client
import StoryFlow.Api
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Core.Level (NodeKind (KCast, KScene))
import StoryFlow.Core.Link (Link, LinkKind)
import StoryFlow.Core.Meta (Meta, Source (Human), Status (Canon), emptyTimeline)
import StoryFlow.Core.Registry (EntityTypeSpec)
import StoryFlow.Server (app)
import StoryFlow.Server.State (newAppState)
import StoryFlow.Service
import System.Directory (doesDirectoryExist, getCurrentDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- 環境 -------------------------------------------------------------------------

registryDir :: IO FilePath
registryDir = go ["../types/registry", "types/registry", "../../types/registry"]
  where
    go [] = fail "找不到 types/registry/;測試需要真正的型別註冊表"
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

-- | 臨時目錄 + 環境變數指向它自己的 @vaults.toml@ 與真正的註冊表。
withVaultDir :: (FilePath -> IO a) -> IO a
withVaultDir act =
  withSystemTempDirectory "storyflow-server" $ \dir -> do
    reg <- registryDir
    absReg <- makeAbs reg
    withEnvVars
      [("STORYFLOW_VAULTS", dir </> "vaults.toml"), ("STORYFLOW_REGISTRY", absReg)]
      (act dir)
  where
    -- 伺服器會 setCurrentDirectory 到 Vault 目錄,相對的註冊表路徑會因此失效
    makeAbs p = do
      cwd <- getCurrentDirectory
      pure (cwd </> p)

-- | 建好 Vault、起一台 warp、把 'ClientEnv' 交出去。
--
-- 伺服器的 'AppState' 以 __Vault 名稱__定址(而不是靠 cwd 向上搜尋),測試因此
-- 不必動全域的工作目錄。
withServer :: (ClientEnv -> IO a) -> IO a
withServer = withServerToken Nothing Nothing

-- | 帶 token 的版本:第一個是 server 要求的,第二個是 client 會送出去的
-- (故意送錯或不送,就是 T10 要驗的東西)。
withServerToken :: Maybe Text -> Maybe Text -> (ClientEnv -> IO a) -> IO a
withServerToken serverToken clientToken act = withVaultDir $ \dir -> do
  _ <- orDie =<< createVault dir "liftgame"
  st <- newAppState (Just "liftgame") dir
  mgr <- newManager (managerWith clientToken)
  Warp.testWithApplication (pure (app serverToken st)) $ \port ->
    act (mkClientEnv mgr (BaseUrl Http "127.0.0.1" port ""))

-- | client 端的 token 走 @managerModifyRequest@ 加 header。
--
-- 這正是 middleware 式認證的好處:API 型別裡沒有認證,client 也就不必為它多一層
-- @AuthenticatedRequest@ 包裝——加一個 header 就結束了。
managerWith :: Maybe Text -> ManagerSettings
managerWith Nothing = defaultManagerSettings
managerWith (Just t) =
  defaultManagerSettings
    { managerModifyRequest = \r ->
        pure r {requestHeaders = (hAuthorization, "Bearer " <> TE.encodeUtf8 t) : requestHeaders r}
    }

orDie :: Either ServiceError a -> IO a
orDie = either (fail . T.unpack . renderServiceError) pure

-- 呼叫 -------------------------------------------------------------------------

-- | 由 API 型別產生的 23 個呼叫函式。
--
-- 少一個、多一個、或參數順序錯了都是編譯錯誤——這就是「同一份型別產生 server
-- 與 client」的實際保障。
data Api = Api
  { cListVaults :: ClientM [VaultView]
  , cCreateVault :: NewVaultReq -> ClientM VaultView
  , cVaultInfo :: ClientM VaultView
  , cReindex :: ClientM IndexReport
  , cRefresh :: ClientM IndexReport
  , cListEntities :: Maybe Text -> Maybe Status -> Maybe Text -> Maybe Int -> ClientM [Meta]
  , cCreateEntity :: NewEntityReq -> ClientM EntityView
  , cGetEntity :: Id -> ClientM EntityView
  , cUpdateEntity :: Id -> Int -> EntityPatch -> ClientM EntityView
  , cSetBody :: Id -> Int -> BodyReq -> ClientM EntityView
  , cDeleteEntity :: Id -> Int -> Maybe Bool -> ClientM DeleteReport
  , cAddFragment :: Id -> NewFragmentReq -> ClientM EntityView
  , cLinksOf :: Id -> ClientM LinkReport
  , cAddLink :: Id -> Int -> Link -> ClientM EntityView
  , cRemoveLink :: Id -> Int -> LinkKind -> Ref -> ClientM EntityView
  , cListLevels :: Maybe Status -> Maybe Int -> ClientM [Meta]
  , cCreateLevel :: NewLevelReq -> ClientM LevelView
  , cGetLevel :: Id -> ClientM LevelView
  , cDeleteLevel :: Id -> Int -> Maybe Bool -> ClientM DeleteReport
  , cAddNode :: Id -> Id -> Int -> NewNodeReq -> ClientM LevelView
  , cRemoveNode :: Id -> Id -> Int -> Maybe Bool -> ClientM LevelView
  , cTypes :: ClientM [EntityTypeSpec]
  , cSearch :: Text -> Maybe Text -> Maybe Status -> Maybe Text -> Maybe Int -> ClientM [SearchHit]
  }

api :: Api
api = Api {..}
  where
    ( cListVaults
        :<|> cCreateVault
        :<|> cVaultInfo
        :<|> cReindex
        :<|> cRefresh
      )
      :<|> ( cListEntities
              :<|> cCreateEntity
              :<|> cGetEntity
              :<|> cUpdateEntity
              :<|> cSetBody
              :<|> cDeleteEntity
              :<|> cAddFragment
            )
      :<|> (cLinksOf :<|> cAddLink :<|> cRemoveLink)
      :<|> (cListLevels :<|> cCreateLevel :<|> cGetLevel :<|> cDeleteLevel)
      :<|> (cAddNode :<|> cRemoveNode)
      :<|> (cTypes :<|> cSearch) = client (Proxy :: Proxy StoryFlowAPI)

runC :: ClientEnv -> ClientM a -> IO a
runC env m =
  runClientM m env >>= \case
    Right a -> pure a
    Left e -> fail ("預期成功,實際失敗:" <> show e)

runE :: ClientEnv -> ClientM a -> IO (Either ClientError a)
runE env m = runClientM m env

-- | 失敗回應的 HTTP 狀態碼。
statusOf :: Either ClientError a -> Maybe Int
statusOf (Left (FailureResponse _ r)) = Just (statusCode (responseStatusCode r))
statusOf _ = Nothing

-- | 失敗回應 body 裡的 @error.code@ ——與 CLI @--json@ 用的是同一套代碼。
codeOf :: Either ClientError a -> Maybe Text
codeOf (Left (FailureResponse _ r)) = do
  v <- decode (responseBody r) :: Maybe Value
  err <- lookupKey "error" v
  s <- lookupKey "code" err
  case s of
    String t -> Just t
    _ -> Nothing
codeOf _ = Nothing

lookupKey :: Text -> Value -> Maybe Value
lookupKey k (Object o) = KM.lookup (K.fromText k) o
lookupKey _ _ = Nothing

-- 樣本 -------------------------------------------------------------------------

newEntity :: Text -> Text -> Text -> NewEntityReq
newEntity ty title summary =
  NewEntityReq ty title summary "" [] [] Canon emptyTimeline [] Human

newFragment :: Text -> Text -> NewFragmentReq
newFragment title summary =
  NewFragmentReq title summary "" Nothing [] [] Nothing Nothing [] Nothing

newLevel :: Text -> Text -> NewLevelReq
newLevel title rootTitle = NewLevelReq title (title <> "的說明") "" rootTitle KScene Canon

newNode :: Text -> NewNodeReq
newNode title = NewNodeReq title KCast "" "" []

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("測試裡的 ref 不合法:" <> show e)
