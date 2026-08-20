-- | 兩條執行路徑:內嵌直接呼叫 @service@,遠端走 @servant-client@。
--
-- __分派發生在「操作」這一層,不是「指令」這一層__。service-and-interfaces/F003 原本寫的是
-- 「每個 @Command@ 各自有內嵌怎麼跑與遠端怎麼跑兩個實作」,那會有 21 組平行的
-- 程式碼要對齊。改成每個 __service 操作__一個三行的分派函式之後,指令層完全
-- 看不見 'Backend' 的兩個建構子——它只呼叫這裡的函式,拿到的是同一批 View 型別,
-- 交給同一個渲染器。
--
-- 驗收標準 4(兩種模式輸出完全相同)因此是__結構上成立__的,不是靠對照測試碰運氣:
-- 渲染器只有一份,而餵給它的資料在兩條路徑上是同一個型別——內嵌路徑直接拿到,
-- 遠端路徑由 @servant-client@ 依同一份 API 型別解碼出來。
module StoryFlow.Cli.Backend
  ( -- * 後端
    Backend (..)
  , withBackend

    -- * 執行
  , M
  , runM
  , throw

    -- * Vault / 索引 / 型別
  , listVaultsB
  , createVaultB
  , vaultInfoB
  , reindexB
  , refreshIndexB
  , listEntityTypesB

    -- * Entity
  , createEntityB
  , addFragmentB
  , getEntityB
  , listEntitiesB
  , searchEntityB
  , updateEntityB
  , setEntityBodyB
  , deleteEntityB

    -- * Link
  , addLinkB
  , removeLinkB
  , linksOfB

    -- * Level / Node
  , createLevelB
  , getLevelB
  , listLevelsB
  , deleteLevelB
  , addNodeB
  , removeNodeB

    -- * 衝突偵測
  , gatherContextB
  ) where

import Control.Exception (finally)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
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
import Servant.API ((:<|>) (..))
import Servant.Client
import StoryFlow.Api (BodyReq (..), ContextReq (..), NewVaultReq (..), StoryFlowAPI)
import StoryFlow.Cli.Error
import StoryFlow.Conflict.Pipeline (gatherContext)
import StoryFlow.Conflict.Types (ConflictOpts, ContextHit, Draft)
import StoryFlow.Cli.Options (GlobalOpts (..))
import StoryFlow.Core.Id (Id, Ref)
import StoryFlow.Core.Link (Link, LinkKind)
import StoryFlow.Core.Meta (Meta, Status)
import StoryFlow.Core.Registry (EntityTypeSpec)
import qualified StoryFlow.Service as S
import StoryFlow.Service
  ( DeleteReport
  , EntityFilter (..)
  , EntityPatch
  , EntityView
  , Env
  , IndexReport
  , LevelView
  , LinkReport
  , NewEntityReq
  , NewFragmentReq
  , NewLevelReq
  , NewNodeReq
  , SearchHit
  , ServiceM
  , VaultView
  )
import System.Directory (getCurrentDirectory)
import System.Environment (lookupEnv)

-- 後端 -------------------------------------------------------------------------

data Backend
  = Embedded Env
  | -- | token 不在這裡:它掛在 'ClientEnv' 的 @Manager@ 上
    -- (@managerModifyRequest@ 加一個 @Authorization@ header)。認證是傳輸層的
    -- 關切,而 'ClientEnv' 正是傳輸層。
    Remote ClientEnv

-- | 開後端 → 用 → 關。
--
-- 內嵌模式順便把 @openEnv@ 回的索引警告帶出來(遠端模式沒有:那些警告印在
-- 伺服器那一端的 stderr)。
withBackend :: GlobalOpts -> (Either CliError (Backend, [Text]) -> IO a) -> IO a
withBackend g k = case goRemote g of
  Just url
    -- --vault 送不過去:伺服器已經綁定了它自己的 Vault。靜默忽略會讓使用者
    -- 以為自己操作的是另一個 Vault,那比報錯糟得多。
    | Just v <- goVault g ->
        k . Left . CliUsage $
          "--remote 與 --vault 不能併用:伺服器已經綁定了它自己的 Vault("
            <> v
            <> " 送不過去)。要換 Vault 請改在伺服器那一端指定。"
    -- parseBaseUrl 跑在 MonadThrow 裡;取 Maybe 那個實例就不會對格式錯誤拋例外
    | otherwise -> case parseBaseUrl (T.unpack url) :: Maybe BaseUrl of
        Nothing -> k (Left (CliUsage ("--remote 的網址解不出來:" <> url)))
        Just base -> do
          token <- fmap T.pack <$> lookupEnv "STORYFLOW_TOKEN"
          mgr <- newManager (managerWith token)
          k (Right (Remote (mkClientEnv mgr base), []))
  Nothing -> do
    cwd <- getCurrentDirectory
    S.openEnv (goVault g) cwd >>= \case
      Left e -> k (Left (CliService e))
      Right (env, issues) ->
        k (Right (Embedded env, map S.renderIndexIssue issues)) `finally` S.closeEnv env

-- | token 走 header,不進 API 型別(見 @storyflow-server@ 的
-- "StoryFlow.Server.Auth")。
managerWith :: Maybe Text -> ManagerSettings
managerWith Nothing = defaultManagerSettings
managerWith (Just t)
  | T.null t = defaultManagerSettings
  | otherwise =
      defaultManagerSettings
        { managerModifyRequest = \r ->
            pure r {requestHeaders = (hAuthorization, "Bearer " <> TE.encodeUtf8 t) : requestHeaders r}
        }

-- 執行 -------------------------------------------------------------------------

-- | 指令的執行環境。失敗一律是 'CliError',兩條路徑最後併進同一個出口。
type M = ExceptT CliError IO

runM :: M a -> IO (Either CliError a)
runM = runExceptT

throw :: CliError -> M a
throw = throwE

svc :: Env -> ServiceM a -> M a
svc env op = liftIO (S.runService env op) >>= either (throw . CliService) pure

rmt :: ClientEnv -> ClientM a -> M a
rmt cenv op = liftIO (runClientM op cenv) >>= either (throw . CliRemote . classify) pure

-- | @servant-client@ 的失敗分成「伺服器好好回了一個業務錯誤」與「根本沒通」。
--
-- 前者__原樣取出伺服器給的 code 與 message__ ——那兩個字串是伺服器以
-- 'StoryFlow.Service.errorCode' \/ 'StoryFlow.Service.renderServiceError' 產生的,
-- 與內嵌模式同源。CLI 在這裡重新分類的話,同一個失敗在兩種模式下就會講不同的話。
classify :: ClientError -> RemoteError
classify = \case
  FailureResponse _ r ->
    let st = statusCode (responseStatusCode r)
     in case errorFields (responseBody r) of
          Just (c, m) -> RemoteStatus st c m
          Nothing -> RemoteBadResponse ("伺服器回 HTTP " <> T.pack (show st) <> ",但 body 不是預期的錯誤形狀")
  DecodeFailure t _ -> RemoteBadResponse ("回應解不出預期的型別:" <> t)
  UnsupportedContentType mt _ -> RemoteBadResponse ("非預期的 Content-Type:" <> T.pack (show mt))
  InvalidContentTypeHeader _ -> RemoteBadResponse "Content-Type 標頭不合法"
  ConnectionError e -> RemoteUnavailable (T.pack (show e))
  where
    errorFields body = do
      v <- decode body
      err <- lookupKey "error" v
      c <- lookupKey "code" err >>= asText
      m <- lookupKey "message" err >>= asText
      pure (c, m)
    lookupKey k (Object o) = KM.lookup (K.fromText k) o
    lookupKey _ _ = Nothing
    asText (String t) = Just t
    asText _ = Nothing

-- 由 API 型別產生的 client -------------------------------------------------------

-- | 少一個、多一個、參數順序錯了都是編譯錯誤。
cListVaults :: ClientM [VaultView]
cCreateVault :: NewVaultReq -> ClientM VaultView
cVaultInfo :: ClientM VaultView
cReindex :: ClientM IndexReport
cRefresh :: ClientM IndexReport
cListEntities :: Maybe Text -> Maybe Status -> Maybe Text -> Maybe Int -> ClientM [Meta]
cCreateEntity :: NewEntityReq -> ClientM EntityView
cGetEntity :: Id -> ClientM EntityView
cUpdateEntity :: Id -> Int -> EntityPatch -> ClientM EntityView
cSetBody :: Id -> Int -> BodyReq -> ClientM EntityView
cDeleteEntity :: Id -> Int -> Maybe Bool -> ClientM DeleteReport
cAddFragment :: Id -> NewFragmentReq -> ClientM EntityView
cLinksOf :: Id -> ClientM LinkReport
cAddLink :: Id -> Int -> Link -> ClientM EntityView
cRemoveLink :: Id -> Int -> LinkKind -> Ref -> ClientM EntityView
cListLevels :: Maybe Status -> Maybe Int -> ClientM [Meta]
cCreateLevel :: NewLevelReq -> ClientM LevelView
cGetLevel :: Id -> ClientM LevelView
cDeleteLevel :: Id -> Int -> Maybe Bool -> ClientM DeleteReport
cAddNode :: Id -> Id -> Int -> NewNodeReq -> ClientM LevelView
cRemoveNode :: Id -> Id -> Int -> Maybe Bool -> ClientM LevelView
cTypes :: ClientM [EntityTypeSpec]
cSearch :: Text -> Maybe Text -> Maybe Status -> Maybe Text -> Maybe Int -> ClientM [SearchHit]
cContext :: ContextReq -> ClientM [ContextHit]
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
  :<|> (cTypes :<|> cSearch)
  :<|> cContext = client (Proxy :: Proxy StoryFlowAPI)

-- 操作:每個三行 -----------------------------------------------------------------

-- | @listVaults@ 與 @createVault@ 在內嵌模式不需要 'Env',所以它們不吃 'Backend'
-- 的 @Embedded@ ——但遠端模式仍然要走 HTTP,於是這兩個是唯二吃 @Maybe Backend@
-- 的操作:@Nothing@ 代表「還沒開後端,用本機的」。
listVaultsB :: Maybe Backend -> M [VaultView]
listVaultsB (Just (Remote c)) = rmt c cListVaults
listVaultsB _ = liftIO S.listVaults >>= either (throw . CliService) pure

createVaultB :: Maybe Backend -> FilePath -> Text -> M VaultView
createVaultB (Just (Remote c)) root name = rmt c (cCreateVault (NewVaultReq root name))
createVaultB _ root name =
  liftIO (S.createVault root name) >>= either (throw . CliService) pure

vaultInfoB :: Backend -> M VaultView
vaultInfoB (Embedded e) = svc e S.vaultInfo
vaultInfoB (Remote c) = rmt c cVaultInfo

reindexB :: Backend -> M IndexReport
reindexB (Embedded e) = svc e S.reindex
reindexB (Remote c) = rmt c cReindex

refreshIndexB :: Backend -> M IndexReport
refreshIndexB (Embedded e) = svc e S.refreshIndex
refreshIndexB (Remote c) = rmt c cRefresh

listEntityTypesB :: Backend -> M [EntityTypeSpec]
listEntityTypesB (Embedded e) = svc e S.listEntityTypes
listEntityTypesB (Remote c) = rmt c cTypes

createEntityB :: Backend -> NewEntityReq -> M EntityView
createEntityB (Embedded e) r = svc e (S.createEntity r)
createEntityB (Remote c) r = rmt c (cCreateEntity r)

addFragmentB :: Backend -> Id -> NewFragmentReq -> M EntityView
addFragmentB (Embedded e) i r = svc e (S.addFragment i r)
addFragmentB (Remote c) i r = rmt c (cAddFragment i r)

getEntityB :: Backend -> Id -> M EntityView
getEntityB (Embedded e) i = svc e (S.getEntity i)
getEntityB (Remote c) i = rmt c (cGetEntity i)

listEntitiesB :: Backend -> EntityFilter -> M [Meta]
listEntitiesB (Embedded e) f = svc e (S.listEntities f)
listEntitiesB (Remote c) EntityFilter {..} = rmt c (cListEntities efType efStatus efTag efLimit)

searchEntityB :: Backend -> Text -> EntityFilter -> M [SearchHit]
searchEntityB (Embedded e) q f = svc e (S.searchEntity q f)
searchEntityB (Remote c) q EntityFilter {..} = rmt c (cSearch q efType efStatus efTag efLimit)

updateEntityB :: Backend -> Id -> Int -> EntityPatch -> M EntityView
updateEntityB (Embedded e) i rev p = svc e (S.updateEntity i rev p)
updateEntityB (Remote c) i rev p = rmt c (cUpdateEntity i rev p)

setEntityBodyB :: Backend -> Id -> Int -> Text -> M EntityView
setEntityBodyB (Embedded e) i rev b = svc e (S.setEntityBody i rev b)
setEntityBodyB (Remote c) i rev b = rmt c (cSetBody i rev (BodyReq b))

deleteEntityB :: Backend -> Id -> Int -> Bool -> M DeleteReport
deleteEntityB (Embedded e) i rev f = svc e (S.deleteEntity i rev f)
deleteEntityB (Remote c) i rev f = rmt c (cDeleteEntity i rev (Just f))

addLinkB :: Backend -> Id -> Int -> Link -> M EntityView
addLinkB (Embedded e) i rev l = svc e (S.addLink i rev l)
addLinkB (Remote c) i rev l = rmt c (cAddLink i rev l)

removeLinkB :: Backend -> Id -> Int -> LinkKind -> Ref -> M EntityView
removeLinkB (Embedded e) i rev k t = svc e (S.removeLink i rev k t)
removeLinkB (Remote c) i rev k t = rmt c (cRemoveLink i rev k t)

linksOfB :: Backend -> Id -> M LinkReport
linksOfB (Embedded e) i = svc e (S.linksOf i)
linksOfB (Remote c) i = rmt c (cLinksOf i)

createLevelB :: Backend -> NewLevelReq -> M LevelView
createLevelB (Embedded e) r = svc e (S.createLevel r)
createLevelB (Remote c) r = rmt c (cCreateLevel r)

getLevelB :: Backend -> Id -> M LevelView
getLevelB (Embedded e) i = svc e (S.getLevel i)
getLevelB (Remote c) i = rmt c (cGetLevel i)

listLevelsB :: Backend -> EntityFilter -> M [Meta]
listLevelsB (Embedded e) f = svc e (S.listLevels f)
listLevelsB (Remote c) EntityFilter {..} = rmt c (cListLevels efStatus efLimit)

deleteLevelB :: Backend -> Id -> Int -> Bool -> M DeleteReport
deleteLevelB (Embedded e) i rev f = svc e (S.deleteLevel i rev f)
deleteLevelB (Remote c) i rev f = rmt c (cDeleteLevel i rev (Just f))

addNodeB :: Backend -> Id -> Id -> Int -> NewNodeReq -> M LevelView
addNodeB (Embedded e) lvl parent rev r = svc e (S.addNode lvl parent rev r)
addNodeB (Remote c) lvl parent rev r = rmt c (cAddNode parent lvl rev r)

removeNodeB :: Backend -> Id -> Id -> Int -> Bool -> M LevelView
removeNodeB (Embedded e) lvl i rev f = svc e (S.removeNode lvl i rev f)
removeNodeB (Remote c) lvl i rev f = rmt c (cRemoveNode i lvl rev (Just f))

-- | 前兩層合流的 context 出口(conflict-detection/F004)。
--
-- 兩條路徑回的是__同一個型別__ @[ContextHit]@:內嵌直接拿到,遠端由
-- @servant-client@ 依同一份 API 型別解碼。指令層與渲染器因此看不出差別,
-- 「CLI 與 REST 兩種形式回同一批結果」是結構上成立的,不是靠對照測試碰運氣。
--
-- __整張關聯圖不會跨過 HTTP__:遠端模式送出去的是 'ContextReq',伺服器端自己在
-- 'StoryFlow.Service.ServiceM' 裡呼叫 @linkGraph@。
gatherContextB :: Backend -> ConflictOpts -> Draft -> M [ContextHit]
gatherContextB (Embedded e) o d = svc e (gatherContext o d)
gatherContextB (Remote c) o d = rmt c (cContext (ContextReq d o))
