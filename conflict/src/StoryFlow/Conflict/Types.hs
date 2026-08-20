-- | 三層衝突偵測共用的資料語彙:草稿、選項、命中、命中層級、報告。
--
-- 本模組__不含任何偵測邏輯__。沒有圖遍歷、沒有 FTS5、沒有 LLM;它只回答
-- 「三層各自算完之後,要用什麼形狀把結果交出來」。
--
-- 先有型別才有三層,是 ADR-007 那句「三層各自可獨立演進」的前提:三層只有
-- 對同一組型別工作時才互不牽動。型別若跟著第一層一起長出來,第二、三層就會
-- 各自扭一份自己的形狀,合流那一步(@Conflict.Pipeline@)得負責把三種形狀併起來。
module StoryFlow.Conflict.Types
  ( -- * 輸入
    Draft (..)
  , ConflictOpts (..)
  , defaultConflictOpts

    -- * 命中層級
  , GraphEvidence (..)
  , HitLayer (..)
  , layerTag

    -- * 命中
  , ConflictHit (..)
  , ContextHit (..)

    -- * 報告
  , ConflictReport (..)
  , emptyReport
  , sortHits
  , ReportNote (..)
  ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import StoryFlow.Core.Id (Id, Ref)
import StoryFlow.Core.Link (LinkKind)
import StoryFlow.Core.Meta (Meta)

-- | 待檢查的草稿。
--
-- @drRefs@ 是__作者或 Agent 已經知道這段草稿引用了哪些片段__;第 1 層完全靠
-- 它起步——沒有起點就沒有圖可以遍歷。空清單是合法輸入,那代表只能跑第 2、3 層。
data Draft = Draft
  { drText :: Text
  , drRefs :: [Id]
  }
  deriving stock (Show, Eq)

-- | 三層共用的選項。每一欄都對應 ADR-007 的一條約束。
data ConflictOpts = ConflictOpts
  { coTopN :: Int
  -- ^ 第 2 層的候選上限。「top-N 的 N 要可調,且預設保守」
  , coJudgeN :: Int
  -- ^ __第 3 層的候選預算__:合流排序後送模型判斷的前 N 個。
  --   獨立於 'coTopN' ——那個管「撈多廣」,這個管「燒多少」。
  --   @<= 0@ 代表不跑第 3 層(合法輸入,但候選非空時要記一則 @judge_disabled@)。
  , coExpandBody :: Bool
  -- ^ 第 3 層是否展開 @body@。「優先送 summary 而非全文,必要時才展開 body」
  , coTimelineWindow :: Maybe Int
  -- ^ 比對 'StoryFlow.Core.Meta.tlOrder' 的容許距離;@Nothing@ = 不做時序過濾。
  --
  -- 只有 @tlOrder@ 有值的片段受它影響:@tlLabel@ 是模糊字串(「崩塌前後」),
  -- 無從算距離。
  , coGraphDepth :: Int
  -- ^ 第 1 層的遍歷深度,對應 "StoryFlow.Core.Graph" 的 @follow@ 的 @Int@ 參數。
  }
  deriving stock (Show, Eq)

-- | 保守的預設值:topN=20 / judgeN=5 / expandBody=False / window=Nothing / depth=2。
--
-- @depth = 2@ 是「起點 + 一跳」,與 ADR-007「用關聯圖擴充一跳範圍」一致。
-- @judgeN = 5@:地端 12B 模型實測一對約 7 秒,五對約 35 秒,是一個指令等得起的
-- 長度;@coTopN@ 的 20 全判約 140 秒,那不是一個指令等得起的長度。
defaultConflictOpts :: ConflictOpts
defaultConflictOpts =
  ConflictOpts
    { coTopN = 20
    , coJudgeN = 5
    , coExpandBody = False
    , coTimelineWindow = Nothing
    , coGraphDepth = 2
    }

-- | 第 1 層的證據:__哪一條關聯__造成這次命中。
--
-- 帶的是關聯而不只是層級,因為 @conflict check@ 在確認衝突後要能反問
-- 「要不要建立這條 @contradicts@ 關聯」(ADR-007 的中立影響那一條),
-- 手上必須已經有 (from, kind, to) 三元組,否則得回頭再查一次圖。
--
-- 形狀刻意對齊 "StoryFlow.Core.Graph" 既有的輸出:
--
-- * @contradictionPairs :: LinkGraph -> [(Id, Ref)]@ 回的正是 (來源 Id, 目標 Ref)
-- * @supersededSet :: LinkGraph -> Set Ref@ 回的是 'Ref'
--
-- 所以 @geFrom :: Id@ 而 @geTo :: Ref@,不是兩邊都用 'Id'。跨 Vault 的 target 是
-- 合法的 'Ref',而 core 的圖遍歷明說「跨 Vault 的 target 會被收進結果,但它的
-- 關聯不在這張圖裡」——型別要表達得出那種命中,否則第 1 層得偷偷把它丟掉。
data GraphEvidence = GraphEvidence
  { geFrom :: Id
  , geKind :: LinkKind
  , geTo :: Ref
  }
  deriving stock (Show, Eq)

-- | 命中層級。第 1 層是__事實__,第 3 層是__判斷__——這個區分必須出現在輸出裡
-- (ADR-007:「使用者需要知道差別」)。
data HitLayer
  = -- | 圖遍歷,附上造成命中的那條關聯
    ByGraph GraphEvidence
  | -- | FTS5 相關度
    ByRetrieval Double
  | -- | 模型信心 0–1。刻意不在型別層壓成三級:模型原生給的就是機率,
    -- 先壓成三級會讓「調整閾值」變成不可能。要不要顯示成三級是__渲染__的決定
    ByJudge Double
  deriving stock (Show, Eq)

-- | 命中層級的名稱。渲染與 JSON 標籤共用這一份,不各自寫一次字串。
layerTag :: HitLayer -> Text
layerTag = \case
  ByGraph _ -> "graph"
  ByRetrieval _ -> "retrieval"
  ByJudge _ -> "judge"

-- | 判斷結果:這一筆和草稿矛盾。
--
-- 只帶 @chTarget :: Id@——呼叫端要細節自己去查,報告本身不該把整個 'Meta'
-- 複製一份進去。
data ConflictHit = ConflictHit
  { chTarget :: Id
  , chLayer :: HitLayer
  , chReason :: Text
  , chSnippet :: Maybe Text
  -- ^ 第 1 層沒有片段可指,它命中的是一條關聯,所以是 @Maybe@
  }
  deriving stock (Show, Eq)

-- | 撈出來的素材:這一筆和草稿有關。
--
-- 直接帶 'Meta' 而不是只帶 id:@story-flow context@ 的使用者(通常是 claude code)
-- 要的就是內容本身,省掉一輪往返。撈出來的東西一定有命中的那一段,所以
-- @xhSnippet@ 不是 @Maybe@。
data ContextHit = ContextHit
  { xhMeta :: Meta
  , xhSnippet :: Text
  , xhVia :: HitLayer
  }
  deriving stock (Show, Eq)

-- | 衝突報告。
--
-- @crScanned@ 讓使用者判斷 'coTopN' 夠不夠——回了 20 筆而 @crScanned@ 正好是 20,
-- 代表很可能被截斷了。@crLlmUsed@ 讓客戶端知道這份報告有沒有經過第 3 層:
-- @False@ 時「沒有發現衝突」的份量完全不同,而那個差別不該只靠使用者記得
-- 自己有沒有加 @--no-llm@。
data ConflictReport = ConflictReport
  { crHits :: [ConflictHit]
  , crScanned :: Int
  , crLlmUsed :: Bool
  , crNotes :: [ReportNote]
  -- ^ 命中之外要對使用者說的話(第 3 層的退化/失敗、第 1 層的
  -- @unlinkedRefs@、關聯建議)。填滿三種來源是 F006 的事,本模組只讓型別存在。
  }
  deriving stock (Show, Eq)

-- | 什麼都沒掃到、也沒跑第 3 層的空報告。
emptyReport :: ConflictReport
emptyReport = ConflictReport {crHits = [], crScanned = 0, crLlmUsed = False, crNotes = []}

-- | 報告附帶的提示。__不是命中__,所以不進 'crHits' ——它說的是
-- 「這份報告本身有什麼要注意的」。放進 DTO 而非只在 CLI 渲染,是因為 CLI 與
-- REST 必須拿到同一批結果。
data ReportNote = ReportNote
  { rnCode :: Text
  -- ^ 穩定識別碼,給程式化消費者分派,不隨文案改動
  , rnDetail :: Text
  -- ^ 繁中訊息,每一則都說出下一步
  }
  deriving stock (Show, Eq)

-- | 排序約定的實作:依層級(Graph → Retrieval → Judge),同層依分數遞減。
--
-- 排序的__使用__是 @Conflict.Pipeline@(後續 feature)的事,但約定本身寫在這裡
-- ——三層合流時要照同一個順序,而那個順序屬於共用語彙的一部分。
--
-- 'ByGraph' 沒有分數(它是事實,不是程度),排序鍵給 0;'sortOn' 是穩定排序,
-- 因此同為第 1 層的命中維持傳入的相對順序。
sortHits :: [ConflictHit] -> [ConflictHit]
sortHits = sortOn (\h -> (layerRank (chLayer h), Down (layerScore (chLayer h))))
  where
    layerRank :: HitLayer -> Int
    layerRank = \case
      ByGraph _ -> 0
      ByRetrieval _ -> 1
      ByJudge _ -> 2

    layerScore :: HitLayer -> Double
    layerScore = \case
      ByGraph _ -> 0
      ByRetrieval s -> s
      ByJudge c -> c
