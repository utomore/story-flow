-- | 前兩層的合流,以及 @context@ 出口。
--
-- 這是 @conflict-detection@ 階段一__對外真正交付的東西__:把第 1 層
-- ("StoryFlow.Conflict.Graph")與第 2 層("StoryFlow.Conflict.Retrieval")接上
-- @service@,合流成 'gatherContext',再由 CLI 的 @story-flow context@ 與 REST 的
-- @POST \/conflict\/context@ 兩種形式露出去。
--
-- ADR-007 那條與三層同等重要的需求——__外部 Agent 常常只需要精準的 context,
-- 不需要 story-flow 代它判斷__——就是靠這個出口滿足的:回的是「和這段草稿有關的
-- 既有片段,連內容一起給你」,不是一份誰對誰錯的報告。
--
-- 三個性質是規格而不只是實作:
--
-- * __完全沒有模型__:不 import @storyflow-llm@,不發任何外部請求。第 3 層
--   ('StoryFlow.Conflict.Types.ByJudge')在這條管線上根本不會出現
-- * __只讀__:整條路徑只呼叫 @linkGraph@ \/ @getEntity@ \/ @aliasIndex@ \/
--   @searchEntity@ \/ @linksOf@ 五個讀取操作,沒有任何 'ServiceM' 寫入
-- * __確定性__:同一份草稿加同一份 Vault 永遠得到逐筆相同的輸出。排序是__全序__
--   (層級 → 分數遞減 → id 字典序),不是「大致上這個順序」
--
-- 管線:
--
-- @
-- Draft
--   ├─ 第 1 層 graphContextHits:linkGraph → graphHits → getEntity 補 Meta
--   └─ 第 2 層 retrieveCandidates → candidateContextHit
--        → mergeContextHits(依 metaId 去重 → 合併 → 排序)
--        → [ContextHit]
-- @
module StoryFlow.Conflict.Pipeline
  ( -- * 出口(Level 2 對外契約)
    gatherContext

    -- * 中間結果(供測試與未來的 checkConflict 使用)
  , graphContextHits
  , mergeContextHits
  , sortContextHits
  ) where

import Control.Monad.Except (catchError)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Ord (Down (..))
import StoryFlow.Conflict.Graph (graphHits)
import StoryFlow.Conflict.Retrieval
  ( RetrievalResult (..)
  , candidateContextHit
  , metaSnippet
  , retrieveCandidates
  )
import StoryFlow.Conflict.Types
  ( ConflictHit (..)
  , ConflictOpts
  , ContextHit (..)
  , Draft (..)
  , HitLayer (..)
  )
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Meta (Meta (..))
import StoryFlow.Service (EntityView (..), ServiceM, getEntity, linkGraph)

-- 出口 -------------------------------------------------------------------------

-- | 第 1 層 + 第 2 層 → 出口 A。
--
-- 兩層都是確定性的,所以整個出口也是。空輸入都是__合法__的,不報錯:
--
-- * @drRefs@ 為空清單 → 第 1 層沒有起點,只剩第 2 層的結果
-- * @drText@ 為空 → 第 2 層抽不出關鍵詞,只剩第 1 層的結果
-- * 兩者皆空 → 回 @[]@
--
-- __'StoryFlow.Conflict.Types.coTopN' 不在這裡再截一次__:它是__第 2 層的候選
-- 上限__(F001 的欄位註解明說),@retrieveCandidates@ 內部已經套用了。第 1 層的
-- 命中是零成本的__事實__,數量本來就受作者的標註量約束,拿 topN 去砍它會砍掉
-- 最有價值的那一批。
gatherContext :: ConflictOpts -> Draft -> ServiceM [ContextHit]
gatherContext opts d = do
  gs <- graphContextHits opts d
  rr <- retrieveCandidates opts d
  pure (mergeContextHits (gs ++ map candidateContextHit (rrCandidates rr)))

-- 第 1 層 ----------------------------------------------------------------------

-- | 第 1 層的命中補上 'Meta' 之後的形狀。
--
-- 型別上的落差是真的:'graphHits' 吐的 'ConflictHit' 只有 @chTarget :: Id@ 與
-- @chSnippet :: Maybe Text@(第 1 層恆為 'Nothing'),而 'ContextHit' 的
-- @xhMeta@ 與 @xhSnippet@ 兩個都不是 @Maybe@。三個判斷各有理由:
--
-- * __補 'Meta' 走 'getEntity'__:它是 @service@ 唯一的單筆讀取出口,而第 2 層的
--   一跳擴充補 'Meta' 走的就是它。兩處同一條路徑,行為(含錯誤時的 @catchError@)
--   才會一致
-- * __查不到就丟棄__,不捏一個空 'Meta':@xhMeta@ 不是 @Maybe@ 是刻意的(F001),
--   硬塞一個佔位 'Meta' 會讓外部 Agent 拿到一個 id 是 @ent-00000000@ 的東西。
--   關聯指向不存在的片段本身是__資料錯誤__,把它變成使用者看得見的提示是
--   @conflict check@(F006)的事
-- * __snippet 用 'metaSnippet'__:第 1 層命中的是一條__關聯__,不是某一段文字,
--   所以它沒有 FTS5 給的 snippet;總結是這個片段身上最接近「一句話說明」的東西
--
-- __理由文案沒有遺失__:'ContextHit' 沒有 @reason@ 欄位,但 @xhVia@ 帶著造成命中的
-- 完整三元組('StoryFlow.Conflict.Types.GraphEvidence'),JSON 出去就是
-- @{"layer":"graph","from":…,"kind":…,"to":…}@。
-- 'StoryFlow.Conflict.Graph.renderGraphReason' 產出的那句繁中本來就只是這個三元組的
-- __渲染__,要它的人自己組得出來,不必也不該塞進 DTO。
graphContextHits :: ConflictOpts -> Draft -> ServiceM [ContextHit]
graphContextHits opts d = do
  g <- linkGraph
  catMaybes <$> mapM withMeta (graphHits opts g (drRefs d))
  where
    withMeta h =
      (Just . contextOf h <$> metaOf (chTarget h)) `catchError` const (pure Nothing)

    metaOf = fmap (entMeta . evEntity) . getEntity

    contextOf h m =
      ContextHit {xhMeta = m, xhSnippet = metaSnippet m, xhVia = chLayer h}

-- 合流 -------------------------------------------------------------------------

-- | 依 @metaId@ 去重、合併、排序。__純函式__,可以單獨測,不必開 Vault。
--
-- * __去重鍵是 @'metaId' . 'xhMeta'@__。同一個片段既被作者標了 @contradicts@、
--   又被關鍵詞撈到,對使用者來說是__一筆__,不是兩筆
-- * __合併規則__:@xhVia@ 取層級較前的那一筆(graph → retrieval);@xhSnippet@ 取
--   __來自 'ByRetrieval' 的那一筆__(它是 FTS5 真正命中的那一段,比退化成 summary
--   的好),沒有就保留既有的。「兩層都命中」的片段因此同時拿到最強的層級標示與
--   最好的片段
mergeContextHits :: [ContextHit] -> [ContextHit]
mergeContextHits hs =
  sortContextHits (M.elems (foldl' step M.empty hs))
  where
    step acc h = M.insertWith combine (metaId (xhMeta h)) h acc

    -- M.insertWith 呼叫的是 @f new old@。
    combine new old =
      ContextHit
        { xhMeta = xhMeta winner
        , xhSnippet = bestSnippet new old
        , xhVia = xhVia winner
        }
      where
        -- 平手時留舊的:輸入順序即優先序,而最終排序是全序,不受這個選擇影響。
        winner
          | layerRank (xhVia new) < layerRank (xhVia old) = new
          | otherwise = old

    bestSnippet new old
      | fromRetrieval new = xhSnippet new
      | fromRetrieval old = xhSnippet old
      | otherwise = xhSnippet old

    fromRetrieval h = case xhVia h of
      ByRetrieval _ -> True
      _ -> False

-- | 排序鍵:@(層級序, 'Down' 分數, 'metaId')@。
--
-- * 層級序 graph = 0、retrieval = 1、judge = 2,與
--   'StoryFlow.Conflict.Types.sortHits' 的約定同一個方向——第 1 層是__事實__,
--   排前面
-- * 分數:'ByGraph' 一律取 0(它是事實不是程度),'ByRetrieval' 與 'ByJudge' 取
--   各自的數值
-- * 第三鍵是 id 字典序,讓輸出成為__全序__。第 1、2 層都是確定性層,
--   「大致上這個順序」不夠
sortContextHits :: [ContextHit] -> [ContextHit]
sortContextHits =
  sortOn (\h -> (layerRank (xhVia h), Down (layerScore (xhVia h)), metaId (xhMeta h)))

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
