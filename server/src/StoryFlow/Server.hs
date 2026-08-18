-- | servant handler 與 warp 啟動。
--
-- __每個 handler 都是一行結構__:把 query parameter 與 body 組成 service 的請求
-- 型別,交給 'run1',狀態碼由 'toServerError' 決定。這一層不含任何業務判斷
-- (func-0008 驗收標準 3);handler 若比一行長,多出來的部分十之八九屬於 @service@。
--
-- 並發、'Env' 的延遲取得與那個互斥鎖的取捨都在 "StoryFlow.Server.State";
-- 狀態碼對照表在 "StoryFlow.Server.Error";認證在 "StoryFlow.Server.Auth"。
module StoryFlow.Server
  ( -- * 啟動
    ServeOpts (..)
  , defaultServeOpts
  , runServer
  , validateServeOpts
  , isLoopback

    -- * WAI
  , app

    -- * 重新匯出
  , module StoryFlow.Server.Auth
  , module StoryFlow.Server.Error
  ) where

import Control.Exception (finally)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Network.Wai.Handler.Warp as Warp
import Servant
import StoryFlow.Api
  ( BodyReq (..)
  , EntityAPI
  , LevelAPI
  , LinkAPI
  , MiscAPI
  , NewVaultReq (..)
  , NodeAPI
  , StoryFlowAPI
  , VaultAPI
  , storyFlowAPI
  )
import StoryFlow.Server.Auth
import StoryFlow.Server.Error
import StoryFlow.Server.State (AppState, closeAppState, newAppState, run1, runIO)
import qualified StoryFlow.Service as S
import StoryFlow.Service (EntityFilter (..))
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
-- ADR-0006 只要求「明確加旗標並顯示警告」,這裡收得更緊:警告會被忽略,而
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
-- ——@story-flow-serve --openapi > openapi.json@ 不該把啟動訊息寫進 JSON 檔。
announce :: ServeOpts -> IO ()
announce ServeOpts {..} = do
  say $ "story-flow 伺服器啟動於 http://" <> soBind <> ":" <> T.pack (show soPort)
  say $
    if isLoopback soBind
      then "  綁定 loopback,只有本機連得上" <> tokenNote
      else "  警告:綁定 " <> soBind <> ",區域網路上的其他機器連得上" <> tokenNote
  where
    say = hPutStrLn stderr . T.unpack
    tokenNote = maybe ";未啟用 token 驗證" (const ";已啟用 Bearer token 驗證") soToken

-- WAI ---------------------------------------------------------------------------

-- | 認證是 middleware,不在路由型別裡(理由見 "StoryFlow.Server.Auth")。
app :: Maybe Text -> AppState -> Application
app token st = bearerAuth token (serve storyFlowAPI (handlers st))

-- Handler -----------------------------------------------------------------------

handlers :: AppState -> Server StoryFlowAPI
handlers st = vaultH st :<|> entityH st :<|> linkH st :<|> levelH st :<|> nodeH st :<|> miscH st

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
-- @rev@ 是 __Level 主體__的 revision(見 "StoryFlow.Api" 的 @NodeAPI@ 註解)。
nodeH :: AppState -> Server NodeAPI
nodeH st =
  (\parent lvl rev req -> run1 st (S.addNode lvl parent rev req))
    :<|> (\i lvl rev force -> run1 st (S.removeNode lvl i rev (force == Just True)))

miscH :: AppState -> Server MiscAPI
miscH st =
  run1 st S.listEntityTypes
    :<|> (\q ty sta tag lim -> run1 st (S.searchEntity q (EntityFilter ty sta tag lim)))
