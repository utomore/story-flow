-- | 三層的合流:@context@ 出口(A)與 @check@ 出口(B)。
--
-- 出口 A(F004)__對外真正交付__把第 1 層("StoryFlow.Conflict.Graph")與第 2 層
-- ("StoryFlow.Conflict.Retrieval")接上 @service@,合流成 'gatherContext',
-- 再由 CLI 的 @story-flow context@ 與 REST 的 @POST \/conflict\/context@ 兩種
-- 形式露出去。ADR-007 那條與三層同等重要的需求——__外部 Agent 常常只需要精準的
-- context,不需要 story-flow 代它判斷__——就是靠這個出口滿足的:回的是「和這段
-- 草稿有關的既有片段,連內容一起給你」,不是一份誰對誰錯的報告。
--
-- 出口 B(F006)把第 3 層("StoryFlow.Conflict.Judge")也接上來,合流成
-- 'checkConflict',再由 @story-flow conflict check@ 與 @POST \/conflict\/check@
-- 兩種形式露出去:回的是「和這段草稿矛盾的是哪幾筆、憑什麼」——一份報告。
--
-- 三個性質是規格而不只是實作:
--
-- * __完全沒有模型__是 'gatherContext' 這條路徑的性質,不是整個模組的:它不
--   import @storyflow-llm@,不發任何外部請求。'checkConflict' 這條路徑則會在
--   第 3 層真的要跑時才建立 'StoryFlow.Llm.LlmClient' 並發出請求
-- * __只讀__:兩條路徑合計只呼叫 @linkGraph@ \/ @getEntity@ \/ @aliasIndex@ \/
--   @searchEntity@ \/ @linksOf@ 五個讀取操作,沒有任何 'ServiceM' 寫入
-- * __確定性__:同一份草稿加同一份 Vault(與同一個第 3 層 runner)永遠得到逐筆
--   相同的輸出。排序是__全序__(層級 → 分數遞減 → id 字典序 → 去重槽),不是
--   「大致上這個順序」
--
-- 管線:
--
-- @
-- Draft
--   ├─ 第 1 層 graphContextHits:linkGraph → graphHits → getEntity 補 Meta
--   └─ 第 2 層 retrieveCandidates → candidateContextHit
--        → mergeContextHits(依 metaId 去重 → 合併 → 排序)
--        → [ContextHit]                                            -- 出口 A
--
-- Draft
--   ├─ 第 1 層 graphStage:linkGraph → graphHits \/ unlinkedRefs(不補 Meta)
--   ├─ 第 2 層 retrieveCandidates → candidateConflictHit
--   └─ 第 3 層 runJudge:JudgeStage → judgeCandidatesWith(監看 LlmUnavailable)
--        → mergeConflictHits(去重 → 排序)→ crHits
--        → crNotes(unlinked → judge_* → judge_budget → link_suggested)
--        → ConflictReport                                          -- 出口 B
-- @
module StoryFlow.Conflict.Pipeline
  ( -- * 出口(Level 2 對外契約)
    gatherContext
  , checkConflict

    -- * 接線層(CLI / REST 共用同一份)
  , JudgeStage (..)
  , acquireJudge

    -- * 中間結果(供測試使用)
  , graphContextHits
  , graphStage
  , mergeContextHits
  , sortContextHits
  , mergeConflictHits
  , sortConflictHits
  , unlinkedNote
  , budgetNote
  , suggestionNote
  ) where

import Control.Monad.Except (catchError)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes)
import Data.Ord (Down (..))
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Conflict.Graph (graphHits, unlinkedRefs)
import StoryFlow.Conflict.Judge
  ( JudgeResult (..)
  , JudgeRunner
  , JudgeSkip (..)
  , judgeCandidatesWith
  , llmRunner
  , skipNote
  )
import StoryFlow.Conflict.Retrieval
  ( Candidate
  , RetrievalResult (..)
  , candidateConflictHit
  , candidateContextHit
  , metaSnippet
  , retrieveCandidates
  )
import StoryFlow.Conflict.Types
  ( ConflictHit (..)
  , ConflictOpts (..)
  , ConflictReport (..)
  , ContextHit (..)
  , Draft (..)
  , GraphEvidence (..)
  , HitLayer (..)
  , ReportNote (..)
  , sortHits
  )
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, renderId, renderRef)
import StoryFlow.Core.Link (renderLinkKind)
import StoryFlow.Core.Meta (Meta (..))
-- 走門面 'StoryFlow.Llm' 而不是內部模組:門面的匯出清單就是設計文檔
-- llm-workshop-mcp/F001 列的名字,一個不多一個不少,繞過它等於讓本模組依賴
-- @storyflow-llm@ 內部怎麼切模組(閘門裁定 B-1)。
import StoryFlow.Llm (LlmError (..), llmConfig, newLlmClient)
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

-- 出口 B:第 1 層 ------------------------------------------------------------------

-- | 第 1 層在 @check@ 這條路上的產物:命中(不補 'Meta')與完全沒有關聯的起點。
--
-- __'linkGraph' 只取一次__,兩個問題共用同一張圖。__不補 'Meta'__:出口 B 的
-- 'ConflictHit' 只有 @chTarget :: Id@(F001 的欄位註解明說「呼叫端要細節自己去
-- 查」),所以本出口不呼叫 'getEntity' ——與 'graphContextHits' 的差別完全來自
-- 兩個回傳型別,不是隨意的。
graphStage :: ConflictOpts -> Draft -> ServiceM ([ConflictHit], [Id])
graphStage opts d = do
  g <- linkGraph
  pure (graphHits opts g (drRefs d), unlinkedRefs g (drRefs d))

-- 出口 B:合流 ---------------------------------------------------------------------

-- | 一筆命中的去重槽。'ByGraph' 帶__整條證據__(同一個片段既與草稿矛盾、又出現
-- 在取代鏈上是兩件事,作者兩件都要看到);'ByRetrieval' \/ 'ByJudge' 共用同一槽
-- (每個候選最多一列)。
hitSlot :: HitLayer -> Text
hitSlot (ByGraph ev) =
  "graph:" <> renderId (geFrom ev) <> ":" <> renderLinkKind (geKind ev) <> ":" <> renderRef (geTo ev)
hitSlot (ByRetrieval _) = "candidate"
hitSlot (ByJudge _) = "candidate"

isJudgeHit :: ConflictHit -> Bool
isJudgeHit h = case chLayer h of
  ByJudge _ -> True
  _ -> False

-- | 依 @(chTarget, 去重槽)@ 去重後排序。__純函式__,可以單獨測。
--
-- 同一槽的勝負:'ByJudge' 勝過 'ByRetrieval' ——第 3 層的命中一定來自第 2 層的
-- 候選,兩列並存等於同一個片段講兩次,而「模型判定它與草稿矛盾,理由是…」嚴格
-- 涵蓋「它和草稿有共同的詞」。__注意這與 'mergeContextHits' 的方向相反__:那一邊
-- 問的是「為什麼撈到你」(graph 最強),這一邊問的是「這一筆對『矛不矛盾』說了
-- 什麼」(judge 才說得出來)。
mergeConflictHits :: [ConflictHit] -> [ConflictHit]
mergeConflictHits hs = sortConflictHits (M.elems (foldl' step M.empty hs))
  where
    step acc h = M.insertWith combine (chTarget h, hitSlot (chLayer h)) h acc

    -- M.insertWith 呼叫的是 @f new old@。
    combine new old
      | isJudgeHit new = new
      | isJudgeHit old = old
      | otherwise = old

-- | 全序:層級 → 分數遞減 → 'chTarget' → 去重槽。
--
-- 先依次要鍵排,再交給 F001 的 'sortHits' ——'sortOn' 是穩定排序,所以主鍵覆蓋
-- 在上面,次要鍵在同層同分時決勝。層級順序的約定因此只有一份(F001),全序由
-- 這裡補足。
sortConflictHits :: [ConflictHit] -> [ConflictHit]
sortConflictHits = sortHits . sortOn (\h -> (chTarget h, hitSlot (chLayer h)))

-- 出口 B:crNotes 的三種來源 ---------------------------------------------------------

-- | 第 1 層:草稿引用了但沒有任何本地關聯的片段。空清單 → 'Nothing'。
unlinkedNote :: [Id] -> Maybe ReportNote
unlinkedNote [] = Nothing
unlinkedNote ids =
  Just $
    ReportNote
      "graph_unlinked_refs"
      ( "你引用的 "
          <> T.intercalate "、" (map renderId ids)
          <> " 在本 Vault 沒有任何關聯,第 1 層對它們幫不上忙;用 `story-flow link list` 確認,或補上關聯"
      )

-- | 第 3 層:候選數超過 'coJudgeN' 預算時,說出「其餘的沒有第 3 層的結論」。
--
-- __呼叫端只在第 3 層真的跑過時才呼叫這個函式__(見 'checkConflictWith');
-- 這裡自己也重覆 @coJudgeN <= 0@ 的檢查,讓這個純函式獨立測試時語意仍然完整。
budgetNote :: ConflictOpts -> Int -> Maybe ReportNote
budgetNote opts scanned
  | coJudgeN opts <= 0 = Nothing
  | scanned <= coJudgeN opts = Nothing
  | otherwise =
      Just $
        ReportNote
          "judge_budget"
          ( "候選 "
              <> tshow scanned
              <> " 個,只有前 "
              <> tshow (coJudgeN opts)
              <> " 個送了語意判斷;其餘 "
              <> tshow (scanned - coJudgeN opts)
              <> " 個沒有第 3 層的結論(不是判定為沒有矛盾),把 --judge-n 調大可以判更多"
          )

-- | 關聯建議:只針對 'ByJudge' 的命中,且扣掉已經有 'ByGraph' 命中的 target
-- ——第 1 層的命中已經有關聯了,建議建立一條已經存在的關聯只是雜訊;第 2 層交的
-- 是「相關」不是「矛盾」,對它建議 @contradicts@ 等於替使用者下一個本 feature
-- 沒有下的判斷。
--
-- id 順序沿用輸入(呼叫端傳入排序後的 'crHits'),是確定的。
suggestionNote :: [ConflictHit] -> Maybe ReportNote
suggestionNote hits
  | null suggested = Nothing
  | otherwise =
      Just $
        ReportNote
          "link_suggested"
          ( "第 3 層判定 "
              <> T.intercalate "、" (map renderId suggested)
              <> " 與草稿矛盾;確認成立後替草稿對應的片段建立 contradicts 關聯"
              <> "(story-flow link add <草稿片段 id> --kind contradicts --target "
              <> renderId (headSuggested suggested)
              <> "),下次這些命中就是第 1 層的零成本事實"
          )
  where
    graphTargets = S.fromList [chTarget h | h <- hits, not (isJudgeHit h), isGraphHit h]
    isGraphHit h = case chLayer h of
      ByGraph _ -> True
      _ -> False
    suggested = [chTarget h | h <- hits, isJudgeHit h, chTarget h `S.notMember` graphTargets]
    headSuggested (x : _) = x
    headSuggested [] = error "suggestionNote:suggested 非空時才會走到這裡"

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- 出口 B:第 3 層要不要跑 -------------------------------------------------------------

-- | 第 3 層要怎麼跑:退化(帶原因),或用一個 runner 跑。
--
-- 一個接縫同時服務接線層與測試:接線層給 'llmRunner' 套上真的 client,測試給假
-- runner——'LlmClient' 是不透明型別,造不出指向假端點的實例(F005 留下的接縫)。
data JudgeStage
  = -- | 不跑,原因是這個
    JudgeSkipped JudgeSkip
  | -- | 跑,用這個 runner
    JudgeWith (JudgeRunner ServiceM)

-- | 讀 @[llm]@ 設定並建 client,或決定退化原因。
--
-- 三條分支,順序是刻意的:
--
-- 1. @noLlm == True@,__或__ @coJudgeN <= 0@ → 'SkipDisabled',__不讀設定、
--    不建 client__。先讀設定的話,@--judge-n 0@ 加上沒設定 @[llm]@ 的 Vault
--    會回「你還沒設定 @[llm]@」,而使用者要的是「這次不要判斷」——那是錯的
--    下一步
-- 2. 'StoryFlow.Llm.llmConfig' 回 'Left' → 'SkipNotConfigured'
-- 3. 回 'Right' → 'JudgeWith' 套上 'llmRunner'。'newLlmClient' 是全函式,
--    這裡不包 @try@
acquireJudge :: Bool -> ConflictOpts -> ServiceM JudgeStage
acquireJudge noLlm opts
  | noLlm || coJudgeN opts <= 0 = pure (JudgeSkipped SkipDisabled)
  | otherwise =
      llmConfig >>= \case
        Left e -> pure (JudgeSkipped (SkipNotConfigured e))
        Right cfg -> JudgeWith . llmRunner <$> liftIO (newLlmClient cfg)

-- | 監看用的 runner:把 'LlmUnavailable' 記下來,判斷結束後決定要不要把
-- @judge_aborted@ 換成 @judge_unreachable@。
--
-- 'jrJudged' == 0 且監看到 'LlmUnavailable' → 換成 'skipNote' ('SkipUnreachable');
-- 'jrJudged' > 0 → 不換,第 3 層真的跑過,@judge_aborted@ 說的就是實情。
runJudge :: JudgeStage -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult
runJudge (JudgeSkipped s) _ _ cs =
  pure JudgeResult {jrHits = [], jrJudged = 0, jrNotes = [skipNote s | not (null cs)]}
runJudge (JudgeWith runner) opts d cs = do
  seen <- liftIO (newIORef Nothing)
  jr <- judgeCandidatesWith (watch seen) opts d cs
  unreachable <- liftIO (readIORef seen)
  pure $ case unreachable of
    Just e | jrJudged jr == 0 -> jr {jrNotes = map (upgrade e) (jrNotes jr)}
    _ -> jr
  where
    watch seen msgs = do
      r <- runner msgs
      case r of
        Left e@(LlmUnavailable _) -> liftIO (writeIORef seen (Just e)) >> pure r
        _ -> pure r

    upgrade e n
      | rnCode n == "judge_aborted" = skipNote (SkipUnreachable e)
      | otherwise = n

-- 出口 B:門面 ---------------------------------------------------------------------

-- | Level 2 的對外契約(閘門裁定 B-2):吃 'JudgeStage' 而不是 @Maybe LlmClient@
-- ——呼叫端先 'acquireJudge' 決定第 3 層要不要跑、跑的話用哪個 runner,再把
-- 結果餵進來;本函式因此完全不知道 'StoryFlow.Llm.LlmClient' 存在,也不會自己
-- 決定「沒給 client 就當成 --no-llm」這種事(那是舊契約 @Maybe@ 唯一說得出口的
-- 理由,新契約用三個建構子的 'JudgeSkip' 直接講清楚原因,不必再用 @Maybe@ 猜)。
--
-- 三層合流的本體:第 1 層 + 第 2 層 + 第 3 層 → 去重 → 排序 → 'ConflictReport'。
--
-- 'coTopN' 不在合流之後再截一次(F004 A5 已裁定):它是第 2 層的候選上限,
-- 'retrieveCandidates' 內部已經套用;第 1 層的命中是零成本的事實,拿它去砍會
-- 砍掉最有價值的那一批。送進第 3 層的是__第 2 層排序後__的 'rrCandidates'
-- (見 A5):第 1 層的命中沒有 'Meta',送不進 prompt,而且它們是事實、不需要
-- 模型複判。
checkConflict :: JudgeStage -> ConflictOpts -> Draft -> ServiceM ConflictReport
checkConflict stage opts d = do
  (gHits, unlinked) <- graphStage opts d
  rr <- retrieveCandidates opts d
  let retrievalHits = map candidateConflictHit (rrCandidates rr)
  jr <- runJudge stage opts d (rrCandidates rr)
  let merged = mergeConflictHits (gHits ++ retrievalHits ++ jrHits jr)
      ranJudge = case stage of
        JudgeWith _ -> True
        JudgeSkipped _ -> False
      budget
        | ranJudge = budgetNote opts (length (rrCandidates rr))
        | otherwise = Nothing
      notes =
        catMaybes [unlinkedNote unlinked]
          ++ jrNotes jr
          ++ catMaybes [budget, suggestionNote merged]
  pure
    ConflictReport
      { crHits = merged
      , crScanned = rrScanned rr
      , crLlmUsed = jrJudged jr > 0
      , crNotes = notes
      }
