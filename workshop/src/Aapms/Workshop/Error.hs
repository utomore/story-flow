-- | 工作坊自己的錯誤語彙(llm-workshop-mcp/F002)。
--
-- __不進 @ServiceError@__:那會讓契約層的錯誤型別認識 P5 的概念,而
-- 'Aapms.Service' 的門面註解明寫著「明確不做的:conflict(P4)、
-- workshop(P5)、LLM」。與 'Aapms.Llm.Error.LlmError' 是同一種形狀
-- ——下層的錯誤型別不認識上層,呈現一律交給介面層(workshop-interface)。
module Aapms.Workshop.Error
  ( WorkshopError (..)
  , renderWorkshopError
  , workshopErrorCode
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Llm (LlmError, llmErrorCode, renderLlmError)

-- | 一次工作坊操作可能的失敗。__八個建構子逐字等於 @design.md@ 的對外契約__。
--
-- 本套件(F002)只產生前五個與 'WsLlmFailed';'WsNothingToCommit' 與
-- 'WsMissingRequiredField' 是 @commitStage@(workshop-emit \/ F003)的事,
-- 這裡只定義建構子與渲染,讓 'renderWorkshopError' \/ 'workshopErrorCode' 對
-- 全部八個建構子窮盡(@-Wincomplete-uni-patterns@ 的完整性要求),F003 因此
-- 不必再改這個模組。
data WorkshopError
  = -- | 'Aapms.Workshop.Session.loadSession' 找不到這個 session id 的快照檔
    WsSessionNotFound Text
  | -- | 快照檔在,但不是合法的 'Aapms.Workshop.Session.Session' JSON
    WsSnapshotCorrupt FilePath Text
  | -- | 寫快照時的 IO 失敗(磁碟滿、權限…)
    WsSnapshotWriteFailed FilePath Text
  | -- | 型別沒有宣告任何 stages('Aapms.Workshop.Stages.startWorkshop')
    WsNoStages Text
  | -- | session 已經沒有下一階段('Aapms.Workshop.Stages.stepWorkshop')
    WsStagesExhausted Text
  | -- | @wsPending@ 是空的(@commitStage@,F003 產生;本套件只定義建構子與渲染)
    WsNothingToCommit Text
  | -- | 型別鍵 + 還缺的必填欄位名(@commitStage@,F003 產生;本套件只定義建構子與渲染)
    WsMissingRequiredField Text [Text]
  | -- | 模型那一跳,原樣包住不攤平
    WsLlmFailed LlmError
  deriving stock (Show, Eq)

-- | 繁中訊息,每一則都說出下一步。形狀比照 'Aapms.Service.Error.renderServiceError'。
renderWorkshopError :: WorkshopError -> Text
renderWorkshopError = \case
  WsSessionNotFound sid ->
    "找不到 session「" <> sid <> "」的快照;請確認 id 是否打錯,或用 `workshop start` 開新的"
  WsSnapshotCorrupt path detail ->
    "快照檔 " <> T.pack path <> " 讀得到但不是合法的 Session JSON:" <> detail
      <> ";如果不是手動改壞的,請回報這個問題"
  WsSnapshotWriteFailed path detail ->
    "寫入快照 " <> T.pack path <> " 失敗:" <> detail <> ";請檢查磁碟空間與寫入權限"
  WsNoStages ty ->
    "型別「" <> ty <> "」在型別註冊表裡沒有宣告任何 stages,無法開始工作坊;"
      <> "請先在 types/registry/ 補上 stages"
  WsStagesExhausted sid ->
    "session「" <> sid <> "」的階段已經走完,不能再 step;請改用 `workshop commit` 定案"
  WsNothingToCommit sid ->
    "session「" <> sid <> "」目前沒有待定案的草稿;請先 `workshop step` 讓模型產出草稿"
  WsMissingRequiredField ty missing ->
    "型別「" <> ty <> "」還缺這些必填欄位:" <> T.intercalate "、" missing
      <> ";請再 `workshop step` 一輪,把這些內容講清楚後再定案"
  WsLlmFailed e -> renderLlmError e

-- | snake_case 的穩定識別碼。字串逐字採用 @llm-workshop-mcp\/F004@ 設計文檔
-- 「@WorkshopError@ 的狀態碼與 code 映射表」提議的那一組,讓 F004 實作時不必
-- 再同步一次。'WsLlmFailed' 往內取 'llmErrorCode',與 'Aapms.Service.Error.errorCode'
-- 對 @StoreFailed@ 往內取 @storeErrorCode@ 同一個做法。
workshopErrorCode :: WorkshopError -> Text
workshopErrorCode = \case
  WsSessionNotFound _ -> "workshop_session_not_found"
  WsSnapshotCorrupt _ _ -> "workshop_snapshot_corrupt"
  WsSnapshotWriteFailed _ _ -> "workshop_snapshot_write_failed"
  WsNoStages _ -> "workshop_no_stages"
  WsStagesExhausted _ -> "workshop_stages_exhausted"
  WsNothingToCommit _ -> "workshop_nothing_to_commit"
  WsMissingRequiredField _ _ -> "workshop_missing_required_field"
  WsLlmFailed e -> llmErrorCode e
