-- | CLI 會回報的全部失敗,__集中在一個模組__。
--
-- 集中的理由是驗收標準 4:「內嵌與遠端的輸出完全相同」。錯誤訊息也是輸出——
-- 兩種模式各有一套錯誤型別的話,那句話最先破在錯誤路徑上,而且是最不容易被
-- 注意到的地方。
--
-- 六種失敗,只有第一種與第六種是業務的:
--
-- * 'CliService' —— @service@ 的 'ServiceError'。內嵌模式直接拿到
-- * 'CliRemote' —— 傳輸層。__其中 'RemoteStatus' 帶著伺服器自己回的 code 與
--   message__,所以遠端模式的業務失敗與內嵌模式__字元級相同__(伺服器那邊也是用
--   同一個 'errorCode' \/ 'renderServiceError' 產生的)
-- * 'CliResolve' —— 用標題找不到 \/ 找到多筆。service 沒有這個概念
-- * 'CliInput' —— @--body-file@ \/ stdin 讀不進來
-- * 'CliUsage' —— 引數組合不合法(例如 @--remote@ 與 @--vault@ 併用)
-- * 'CliWorkshop' —— @aapms-workshop@ 的 'WorkshopError'(llm-workshop-mcp\/F004)。
--   工作坊自己的失敗__不折進 'CliService'__:契約層的 'ServiceError' 刻意不認識 P5
--
-- __這段清單漏過兩次__('CliInput' 與 'CliWorkshop' 都是後補的建構子,註解沒跟上,
-- 由 2026-08-22 階段二的 arch-audit 抓到)。加建構子時記得回來加一行。
module Aapms.Cli.Error
  ( -- * 定址
    Subject (..)
  , ResolveError (..)
  , renderResolveError
  , resolveErrorCode

    -- * 遠端
  , RemoteError (..)
  , renderRemoteError
  , remoteErrorCode

    -- * 總和
  , CliError (..)
  , cliErrorCode
  , cliErrorMessage
  , isUsageError
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (renderId)
import Aapms.Core.Meta (Meta (..), renderStatus)
import Aapms.Service (ServiceError, errorCode, renderServiceError)
import Aapms.Workshop (WorkshopError, renderWorkshopError, workshopErrorCode)

-- 定址 -------------------------------------------------------------------------

-- | 定址的對象種類。
--
-- 存在的理由只有一個:錯誤訊息要說出__下一步該打哪一條指令__,而那三條指令各不
-- 相同。把它折進訊息字串會讓訊息無法被測試比對,折進三個平行的錯誤型別則會讓
-- 呼叫端各寫一次 @case@。
data Subject
  = SubEntity
  | SubLevel
  | SubNode
  deriving stock (Show, Eq)

data ResolveError
  = NotFound Subject Text
  | -- | 標題多筆命中,附上全部候選
    Ambiguous Subject Text [Meta]
  deriving stock (Show, Eq)

-- | 機器可讀的識別碼。與 service 的 'errorCode' 同一個命名法(snake_case),
-- 但這兩個是 CLI 自己的失敗——service 那一層沒有「標題」這個概念。
resolveErrorCode :: ResolveError -> Text
resolveErrorCode = \case
  NotFound _ _ -> "title_not_found"
  Ambiguous _ _ _ -> "title_ambiguous"

renderResolveError :: ResolveError -> Text
renderResolveError = \case
  NotFound s t -> "找不到「" <> t <> "」;以 " <> listCommand s <> " 查看有哪些"
  Ambiguous s t ms ->
    "標題「"
      <> t
      <> "」有 "
      <> T.pack (show (length ms))
      <> " 筆命中,請改用 id 重下:\n"
      <> T.intercalate "\n" (map candidate ms)
      <> extraHint s
  where
    candidate m =
      "  "
        <> renderId (metaId m)
        <> "  "
        <> metaType m
        <> "  "
        <> renderStatus (metaStatus m)
        <> "  "
        <> metaSummary m
    -- Node 的 id 不會出現在 entity/level 的清單裡,要從場景樹上抄
    extraHint SubNode = "\n(節點 id 可以用 aapms level show <Level> 取得)"
    extraHint _ = ""

listCommand :: Subject -> Text
listCommand = \case
  SubEntity -> "aapms entity list"
  SubLevel -> "aapms level list"
  SubNode -> "aapms level show <Level>"

-- 遠端 -------------------------------------------------------------------------

data RemoteError
  = -- | 連不上、逾時、DNS 解不出來
    RemoteUnavailable Text
  | -- | 連上了,但回的東西不是這個 API 的形狀
    RemoteBadResponse Text
  | -- | __伺服器好好地回了一個業務錯誤__:狀態碼、它的 code、它的 message
    RemoteStatus Int Text Text
  deriving stock (Show, Eq)

-- | 'RemoteStatus' __原樣用伺服器給的 code__。
--
-- 這是驗收標準 4 在錯誤路徑上的實作:server 的錯誤 body 由
-- 'Aapms.Service.errorCode' 產生,與內嵌模式是同一個函式,所以
-- @--remote entity show ent-00000000@ 與不帶 @--remote@ 的同一個指令回的
-- @code@ 一模一樣。CLI 在這裡__不重新分類__。
remoteErrorCode :: RemoteError -> Text
remoteErrorCode = \case
  RemoteUnavailable _ -> "remote_unavailable"
  RemoteBadResponse _ -> "remote_bad_response"
  RemoteStatus _ code _ -> code

renderRemoteError :: RemoteError -> Text
renderRemoteError = \case
  RemoteUnavailable d ->
    "連不上遠端伺服器:" <> d <> "\n請確認 aapms-serve 正在跑,而且 --remote 的網址正確"
  RemoteBadResponse d ->
    "遠端伺服器的回應看不懂:" <> d <> "\n這通常代表 --remote 指到的不是 aapms 的伺服器"
  RemoteStatus _ _ msg -> msg

-- 總和 -------------------------------------------------------------------------

data CliError
  = CliService ServiceError
  | CliRemote RemoteError
  | CliResolve ResolveError
  | -- | @--body-file@ \/ stdin 讀不進來
    CliInput Text
  | -- | 引數組合不合法。這一種以 exit 2 收場,與其他的 exit 1 分開
    CliUsage Text
  | -- | 工作坊自己的失敗(llm-workshop-mcp/F004)。'workshopErrorCode' \/
    -- 'renderWorkshopError' 原樣沿用,這一層不重寫下層的訊息(對 'WsLlmFailed'
    -- 又是沿用 'Aapms.Llm.renderLlmError' 的原文,一路不重寫)。
    CliWorkshop WorkshopError
  deriving stock (Show, Eq)

cliErrorCode :: CliError -> Text
cliErrorCode = \case
  CliService e -> errorCode e
  CliRemote e -> remoteErrorCode e
  CliResolve e -> resolveErrorCode e
  CliInput _ -> "input_unreadable"
  CliUsage _ -> "usage_error"
  CliWorkshop e -> workshopErrorCode e

cliErrorMessage :: CliError -> Text
cliErrorMessage = \case
  CliService e -> renderServiceError e
  CliRemote e -> renderRemoteError e
  CliResolve e -> renderResolveError e
  CliInput t -> t
  CliUsage t -> t
  CliWorkshop e -> renderWorkshopError e

-- | 用法錯誤走 exit 2,與業務錯誤的 exit 1 分開:腳本要能區分「我指令打錯了」
-- 與「工具告訴我這件事做不到」。
isUsageError :: CliError -> Bool
isUsageError = \case
  CliUsage _ -> True
  _ -> False
