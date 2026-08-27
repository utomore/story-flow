-- | servant handler 與 warp 啟動。
--
-- __每個 handler 都是一行結構__:把 query parameter 與 body 組成 service 的請求
-- 型別,交給 'run1',狀態碼由 'toServerError' 決定。這一層不含任何業務判斷
-- (service-and-interfaces/F003 驗收標準 3);handler 若比一行長,多出來的部分十之八九屬於 @service@。
--
-- 並發、'Env' 的延遲取得與那個互斥鎖的取捨都在 "Aapms.Server.State";
-- 狀態碼對照表在 "Aapms.Server.Error";認證在 "Aapms.Server.Auth"。
module Aapms.Server
  ( -- * 啟動
    ServeOpts (..)
  , defaultServeOpts
  , runServer
  , validateServeOpts
  , isLoopback
  , serverVersion

    -- * WAI
  , app

    -- * 重新匯出
  , module Aapms.Server.Auth
  , module Aapms.Server.Error
  ) where

import Data.Version (showVersion)
import Paths_aapms_server (version)
import Control.Exception (finally)
import Control.Monad.IO.Class (liftIO)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Network.Wai.Handler.Warp as Warp
import Servant
import Aapms.Api
  ( BodyReq (..)
  , CheckReq (..)
  , ConflictAPI
  , ContextReq (..)
  , EntityAPI
  , LevelAPI
  , LinkAPI
  , MiscAPI
  , NewVaultReq (..)
  , NodeAPI
  , AapmsAPI
  , VaultAPI
  , WorkshopAPI
  , WorkshopCommitResp (..)
  , WorkshopStartReq (..)
  , WorkshopStepReq (..)
  , WorkshopStepResp (..)
  , aapmsAPI
  )
import Aapms.Conflict.Pipeline (acquireJudge, checkConflict, gatherContext)
import Aapms.Llm (LlmClient, llmConfig, newLlmClient)
import Aapms.Server.Auth
import Aapms.Server.Error
import Aapms.Server.State (AppState, closeAppState, newAppState, run1, runEither, runIO)
import qualified Aapms.Service as S
import Aapms.Service (EntityFilter (..), ServiceM)
import Aapms.Workshop
  ( WorkshopError (..)
  , commitStage
  , loadSession
  , startWorkshop
  , stepWorkshop
  )
import System.Directory (getCurrentDirectory)
import System.IO (hPutStrLn, stderr)

-- 啟動選項 ---------------------------------------------------------------------

data ServeOpts = ServeOpts
  { soPort :: Int
  , soBind :: Text
  , soToken :: Maybe Text
  -- ^ @STORYFLOW_TOKEN@ 或 Vault 設定裡的 @token@
  , soVault :: Maybe Text
  }
  deriving stock (Show, Eq)

defaultServeOpts :: ServeOpts
defaultServeOpts = ServeOpts 8787 "127.0.0.1" Nothing Nothing

-- | 綁非 loopback 位址時__強制要求 token__。
--
-- ADR-006 只要求「明確加旗標並顯示警告」,這裡收得更緊:警告會被忽略,而
-- 「整個 Vault 暴露在區域網路上」不是可以靠使用者留意來緩解的事。沒設 token 就
-- 拒絕啟動,並說明要怎麼設。
validateServeOpts :: ServeOpts -> Either Text ()
validateServeOpts ServeOpts {..}
  | isLoopback soBind = Right ()
  | Just t <- soToken, not (T.null t) = Right ()
  | otherwise =
      Left $
        "拒絕啟動:--bind "
          <> soBind
          <> " 不是 loopback 位址,整個 Vault 會暴露在網路上,而且沒有設定 token。\n"
          <> "請設定環境變數 STORYFLOW_TOKEN=<一段夠長的隨機字串> 後重試,"
          <> "或改用預設的 --bind 127.0.0.1(只有本機連得上)。"

-- | 只有真正回到本機的位址算數。
--
-- __warp 的萬用字元(@*@ \/ @*4@ \/ @*6@)不算__:它們是「綁全部介面」,正是這條
-- 檢查要擋的東西。整個 @127.0.0.0\/8@ 都算,因為那一段全部路由回本機。
isLoopback :: Text -> Bool
isLoopback b = b `elem` ["localhost", "::1", "[::1]"] || "127." `T.isPrefixOf` b

-- | 啟動 warp。
--
-- 回 @Either Text ()@ 而不是直接 @exitFailure@:呼叫端(執行檔與測試)各自決定
-- 怎麼呈現失敗。驗證通過的話這個動作__不會回來__ ——warp 一直跑到行程結束。
runServer :: ServeOpts -> IO (Either Text ())
runServer opts = case validateServeOpts opts of
  Left e -> pure (Left e)
  Right () -> do
    cwd <- getCurrentDirectory
    st <- newAppState (soVault opts) cwd
    announce opts
    let settings =
          Warp.setPort (soPort opts)
            . Warp.setHost (fromString (T.unpack (soBind opts)))
            $ Warp.defaultSettings
    Warp.runSettings settings (app (soToken opts) st) `finally` closeAppState st
    pure (Right ())

-- | 啟動訊息到 __stderr__,stdout 留給 @--openapi@ 那條路徑
-- ——@aapms-serve --openapi > openapi.json@ 不該把啟動訊息寫進 JSON 檔。
announce :: ServeOpts -> IO ()
announce ServeOpts {..} = do
  say $ "aapms 伺服器啟動於 http://" <> soBind <> ":" <> T.pack (show soPort)
  say $
    if isLoopback soBind
      then "  綁定 loopback,只有本機連得上" <> tokenNote
      else "  警告:綁定 " <> soBind <> ",區域網路上的其他機器連得上" <> tokenNote
  where
    say = hPutStrLn stderr . T.unpack
    tokenNote = maybe ";未啟用 token 驗證" (const ";已啟用 Bearer token 驗證") soToken

-- WAI ---------------------------------------------------------------------------

-- | 認證是 middleware,不在路由型別裡(理由見 "Aapms.Server.Auth")。
app :: Maybe Text -> AppState -> Application
app token st = bearerAuth token (serve aapmsAPI (handlers st))

-- Handler -----------------------------------------------------------------------

handlers :: AppState -> Server AapmsAPI
handlers st =
  vaultH st
    :<|> entityH st
    :<|> linkH st
    :<|> levelH st
    :<|> nodeH st
    :<|> miscH st
    :<|> conflictH st
    :<|> workshopH st

-- | 前兩條走 'runIO':它們對應 service 不需要 @Env@ 的兩個函式,所以在沒有目前
-- Vault 的目錄裡也答得出來。
vaultH :: AppState -> Server VaultAPI
vaultH st =
  runIO S.listVaults
    :<|> (\NewVaultReq {..} -> runIO (S.createVault nvRoot nvName))
    :<|> run1 st S.vaultInfo
    :<|> run1 st S.reindex
    :<|> run1 st S.refreshIndex

entityH :: AppState -> Server EntityAPI
entityH st =
  (\ty sta tag lim -> run1 st (S.listEntities (EntityFilter ty sta tag lim)))
    :<|> (run1 st . S.createEntity)
    :<|> (run1 st . S.getEntity)
    :<|> (\i rev p -> run1 st (S.updateEntity i rev p))
    :<|> (\i rev b -> run1 st (S.setEntityBody i rev (brBody b)))
    :<|> (\i rev force -> run1 st (S.deleteEntity i rev (force == Just True)))
    :<|> (\i req -> run1 st (S.addFragment i req))

linkH :: AppState -> Server LinkAPI
linkH st =
  (run1 st . S.linksOf)
    :<|> (\i rev l -> run1 st (S.addLink i rev l))
    :<|> (\i rev k t -> run1 st (S.removeLink i rev k t))

levelH :: AppState -> Server LevelAPI
levelH st =
  (\sta lim -> run1 st (S.listLevels (EntityFilter Nothing sta Nothing lim)))
    :<|> (run1 st . S.createLevel)
    :<|> (run1 st . S.getLevel)
    :<|> (\i rev force -> run1 st (S.deleteLevel i rev (force == Just True)))

-- | 兩條路由的 capture 都是 Node,Level 走 query parameter。
-- @rev@ 是 __Level 主體__的 revision(見 "Aapms.Api" 的 @NodeAPI@ 註解)。
nodeH :: AppState -> Server NodeAPI
nodeH st =
  (\parent lvl rev req -> run1 st (S.addNode lvl parent rev req))
    :<|> (\i lvl rev force -> run1 st (S.removeNode lvl i rev (force == Just True)))

miscH :: AppState -> Server MiscAPI
miscH st =
  run1 st S.listEntityTypes
    :<|> (\q ty sta tag lim -> run1 st (S.searchEntity q (EntityFilter ty sta tag lim)))

-- | 衝突偵測的兩個出口:@context@(conflict-detection/F004)與
-- @check@(conflict-detection/F006)。
--
-- 兩個都是一行結構:body 拆成參數交給 'gatherContext' \/ 'acquireJudge' +
-- 'checkConflict',handler 本身不含任何業務判斷。__整張關聯圖不會離開這個
-- 行程__ ——它們在 'ServiceM' 裡自己呼叫 @linkGraph@。@check@ 這條路上,第 3
-- 層要用的 'Aapms.Llm.LlmClient' 同理不跨 HTTP:'acquireJudge' 自己在
-- 'ServiceM' 裡讀這個 Vault 的 @[llm]@ 設定並建 client(或決定退化原因),
-- 'checkConflict' 只吃它決定好的 'JudgeStage'(閘門裁定 B-2)。
--
-- 走 'run1'(而不是 'runIO'):兩者都需要目前 Vault 的
-- 'Aapms.Service.Monad.Env'。
conflictH :: AppState -> Server ConflictAPI
conflictH st =
  (\ContextReq {..} -> run1 st (gatherContext crqOpts crqDraft))
    :<|> (\CheckReq {..} -> run1 st (acquireJudge ckNoLlm ckOpts >>= \stage -> checkConflict stage ckOpts ckDraft))

-- | 工作坊的三個出口(llm-workshop-mcp/F004)。走 'runEither'(而不是 'run1'):
-- 每一條都可能再短路成 @Left WorkshopError@,'toWorkshopServerError' 決定那個
-- 分支的狀態碼與 body。
--
-- 'stepFlow' \/ 'commitFlow' \/ 'acquireLlmClient' 在這裡__重複定義一份__,與
-- "Aapms.Cli.Backend" 那份程式碼相同——工作坊沒有對應的既有接線層函式可
-- 共用(見 F004 文檔「實作方式」的 @LlmClient@ 小節)。
workshopH :: AppState -> Server WorkshopAPI
workshopH st =
  (\WorkshopStartReq {..} -> runEither st toWorkshopServerError (startWorkshop wsrType wsrConstraints))
    :<|> (\sid WorkshopStepReq {..} -> runEither st toWorkshopServerError (stepFlow sid wsiInput))
    :<|> (\sid -> runEither st toWorkshopServerError (commitFlow sid))

stepFlow :: Text -> Text -> ServiceM (Either WorkshopError WorkshopStepResp)
stepFlow sid input =
  loadSession sid >>= \case
    Left e -> pure (Left e)
    Right session ->
      acquireLlmClient >>= \case
        Left e -> pure (Left e)
        Right client ->
          stepWorkshop client session input >>= \case
            Left e -> pure (Left e)
            Right (session', reply) -> pure (Right (WorkshopStepResp session' reply))

commitFlow :: Text -> ServiceM (Either WorkshopError WorkshopCommitResp)
commitFlow sid =
  loadSession sid >>= \case
    Left e -> pure (Left e)
    Right session ->
      commitStage session >>= \case
        Left e -> pure (Left e)
        Right (session', views) -> pure (Right (WorkshopCommitResp session' views))

acquireLlmClient :: ServiceM (Either WorkshopError LlmClient)
acquireLlmClient =
  llmConfig >>= \case
    Left e -> pure (Left (WsLlmFailed e))
    Right cfg -> Right <$> liftIO (newLlmClient cfg)

-- | @--version@ 印的那一行,格式與 @aapms@ / @aapms-mcp@ 相同(G-E002)。
-- 住在 library 而不是 @app/Main.hs@,測試才碰得到。
serverVersion :: String
serverVersion = "aapms-serve " <> showVersion version
