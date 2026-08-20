-- | 衝突偵測第 2 層:關鍵詞候選撈取。
--
-- 這一層回答的是__哪些既有的 canon 片段和這段草稿有關__ ——注意是「有關」而不是
-- 「矛盾」。第 2 層只負責把比對範圍從整個 Vault 收斂到 top-N,判斷矛盾是第 3 層
-- 的事(ADR-007)。它因此是 ADR-007 那句「大部分查詢在前兩層就結束」的承載者,
-- 也是 @story-flow context@ 唯一的候選來源。
--
-- __完全確定性__:同一份草稿加同一份 Vault 永遠得到逐筆相同的候選,沒有模型、
-- 沒有隨機性。排序是全序(分數遞減 → id 字典序),不是「大致上這個順序」。
--
-- __所有讀取經 @ServiceM@__:本模組不開索引連線、不碰檔案,
-- @build-depends@ 因此沒有 @storyflow-store@。
--
-- 管線:
--
-- @
-- aliasIndex(canon)
--   → KeywordStrategy(反向名稱比對 + 切詞)
--   → 每個關鍵詞一次 searchEntity(canon 過濾 + 過度撈取)
--   → mergeCandidates(依 id 去重,同 id 取最高分)
--   → timeline 過濾(在 SQL 之後、截斷之前)
--   → partOf \/ occursIn 一跳擴充
--   → 排序 → take coTopN
-- @
module StoryFlow.Conflict.Retrieval
  ( -- * 門面
    retrieveCandidates
  , retrieveCandidatesWith
  , RetrievalResult (..)
  , Candidate (..)
  , CandidateOrigin (..)

    -- * 策略接縫
  , KeywordStrategy (..)
  , defaultKeywordStrategy

    -- * 輸出轉換
  , candidateContextHit
  , candidateConflictHit
  , renderRetrievalReason

    -- * 純函式部件(供 Pipeline 與測試使用)
  , matchedNames
  , segmentDraft
  , rankFallbackScore
  , withinWindow
  , mergeCandidates
  , overFetchLimit

    -- * 調校常數
  , segMinLen
  , chunkLen
  , maxKeywordLen
  , maxKeywords
  , overFetchFactor
  , expansionDecay
  ) where

import Control.Monad (foldM)
import Control.Monad.Except (catchError)
import Data.Char (isAlphaNum)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Conflict.Types
  ( ConflictHit (..)
  , ConflictOpts (..)
  , ContextHit (..)
  , Draft (..)
  , HitLayer (ByRetrieval)
  )
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, Ref (..), renderId)
import StoryFlow.Core.Link (Link (..), LinkKind (OccursIn, PartOf), renderLinkKind)
import StoryFlow.Core.Meta (Meta (..), Status (Canon), Timeline (..), isCanon)
import StoryFlow.Service
  ( EntityFilter (..)
  , EntityView (..)
  , LinkReport (..)
  , SearchHit (..)
  , ServiceM
  , aliasIndex
  , emptyFilter
  , getEntity
  , linksOf
  , searchEntity
  )

-- 型別 -------------------------------------------------------------------------

-- | 這一筆候選是怎麼進來的。
--
-- 壓成 'ConflictHit' 之後就取不回來了,而理由文案、排序與測試都需要它。
data CandidateOrigin
  = -- | 由哪個關鍵詞撈到
    FromKeyword Text
  | -- | 由哪個候選、經哪條一跳關聯帶入
    FromExpansion Id LinkKind
  deriving stock (Show, Eq)

-- | 一個候選片段。
--
-- 帶 'Meta' 而不只帶 id:@context@ 出口要的就是內容本身,外部 Agent 不必再往返
-- 一次。
data Candidate = Candidate
  { caMeta :: Meta
  , caSnippet :: Text
  , caScore :: Double
  -- ^ 0–1,越大越相關
  , caOrigin :: CandidateOrigin
  }
  deriving stock (Show, Eq)

-- | 第 2 層的完整結果。
data RetrievalResult = RetrievalResult
  { rrCandidates :: [Candidate]
  -- ^ 已排序、已截到 @coTopN@
  , rrScanned :: Int
  -- ^ 掃過的相異片段數(__含被 timeline 剔除的__)→ @ConflictReport.crScanned@。
  --
  -- 它就是使用者判斷 @topN@ 夠不夠的依據:回了 20 筆而 @rrScanned@ 也是 20,
  -- 代表很可能被截斷了;回了 20 筆而 @rrScanned@ 是 180,代表過濾與截斷都在
  -- 正常運作。
  , rrKeywords :: [Text]
  -- ^ 實際用了哪些關鍵詞(CLI 說得出「我拿什麼去找」)
  }
  deriving stock (Show, Eq)

-- | 候選撈取策略。
--
-- ADR-007 的「第 2 層的介面刻意設計成候選撈取策略可替換」就是這個型別:未來要加
-- embedding 檢索,是多一個 'KeywordStrategy'(或在它之後多一路合併),
-- 第 1、3 層與 @Conflict.Pipeline@ 完全不動。
--
-- 吃的是 @[(Id, [Text])]@(既有 canon 名稱的索引)與草稿全文,吐關鍵詞清單。
newtype KeywordStrategy = KeywordStrategy
  { runKeywordStrategy :: [(Id, [Text])] -> Text -> [Text]
  }

-- 調校常數 ---------------------------------------------------------------------

-- | 片段短於這個長度就丟掉:一個字的召回率等於雜訊。
segMinLen :: Int
segMinLen = 2

-- | 超長片段切成這個長度的__不重疊__塊。
--
-- 切在任意邊界仍然有效,因為索引是 __trigram__:@提亞崩塌@ 的 trigram 是
-- @提亞崩@ \/ @亞崩塌@,照樣命中含「埃提亞崩塌」的正文。
chunkLen :: Int
chunkLen = 4

-- | 超過這個長度就切塊。沒有標點的長串中文(「琳達在埃提亞崩塌之後失去雙親」)
-- 否則會變成一個誰都命不中的巨型 phrase query。
maxKeywordLen :: Int
maxKeywordLen = 8

-- | 關鍵詞總數上限。
--
-- 這是__成本閘門__而不只是調校值:每個關鍵詞是一次 SQL,沒有上限的話一段長草稿
-- 可以打出上百次查詢。
maxKeywords :: Int
maxKeywords = 16

-- | SQL 撈 @coTopN@ 的幾倍。
--
-- @EntityFilter@ 沒有 timeline 欄位,timeline 過濾只能發生在 SQL 之後;先撈
-- @topN@ 再過濾,會讓「開了 timeline window 之後候選憑空少一截」,而調大 @topN@
-- 也未必補得回來。
overFetchFactor :: Int
overFetchFactor = 4

-- | 一跳擴充的分數衰減係數。
--
-- 擴充候選__恆低於它的母候選__:它不是被草稿的詞彙命中的,只是「和被命中的東西
-- 有結構關係」,排在母候選前面沒有道理。
expansionDecay :: Double
expansionDecay = 0.5

-- 關鍵詞抽取 --------------------------------------------------------------------

-- | 兩路併用:反向名稱比對(精準)在前、切詞(補召回)在後,合併去重、截到
-- 'maxKeywords'。
--
-- 只做其中一路都不合格:只切詞則中文沒有空白、品質全看作者標點;只比對 alias
-- 則作者沒寫 alias 的片段完全撈不到,等於把 ADR-007 的緩解措施當成唯一手段。
defaultKeywordStrategy :: KeywordStrategy
defaultKeywordStrategy =
  KeywordStrategy $ \idx txt ->
    take maxKeywords (dedupe (matchedNames idx txt ++ segmentDraft txt))

-- | 既有名稱(@metaTitle@ \/ @metaAliases@)出現在草稿裡的那些。
--
-- 這是 ADR-007「比對到的 aliases」的字面意思——精準、零誤判,而且中文完全不受
-- 斷詞問題影響。順序沿用 'StoryFlow.Service.aliasIndex'(id 字典序)以保證
-- 確定性。
--
-- 長度 < 'segMinLen' 的名稱(含空字串)一律略過:單字名稱在任何一段中文裡都
-- 幾乎必然命中。
matchedNames :: [(Id, [Text])] -> Text -> [Text]
matchedNames idx draft =
  dedupe
    [ n
    | (_, names) <- idx
    , n <- names
    , T.length n >= segMinLen
    , n `T.isInfixOf` draft
    ]

-- | 依「非 'isAlphaNum'」切草稿。
--
-- 'Data.Char.isAlphaNum' 對中日韓表意文字回 'True'(它們的 general category 是
-- @OtherLetter@),對全形標點與全形空白回 'False' ——所以同一條規則同時處理了
-- 中文標點與英文空白,不必自己列一張標點表。
--
-- 之後:丟掉 < 'segMinLen' 的片段、把 > 'maxKeywordLen' 的片段切成 'chunkLen'
-- 的不重疊塊(尾巴不足 'segMinLen' 的丟掉)、去重保序。
segmentDraft :: Text -> [Text]
segmentDraft =
  dedupe . concatMap explode . filter (not . T.null) . T.split (not . isAlphaNum)
  where
    explode t
      | T.length t < segMinLen = []
      | T.length t <= maxKeywordLen = [t]
      | otherwise = filter ((>= segMinLen) . T.length) (chunksOf chunkLen t)

chunksOf :: Int -> Text -> [Text]
chunksOf n t
  | T.null t = []
  | otherwise = let (h, r) = T.splitAt n t in h : chunksOf n r

-- 分數 -------------------------------------------------------------------------

-- | 'shScore' 為 'Nothing' 時的名次回退:@1 \/ (k + 2)@,@k@ 是 0-based 名次。
--
-- __封頂 0.5 是刻意的__:'Nothing' 來自 @LIKE@ 路徑,而那條查詢是
-- @ORDER BY e.id@ ——名次是 id 字典序,它不知道自己有多相關,不該壓過任何一個
-- 真實的 bm25 高分。
rankFallbackScore :: Int -> Double
rankFallbackScore k = 1 / fromIntegral (k + 2)

-- | 過度撈取的 SQL 上限:@coTopN * 'overFetchFactor'@,下限 1。
--
-- 下限存在的理由是 @coTopN = 0@:那時仍然要掃一點東西,'rrScanned' 才說得出
-- 「你把上限設成 0」與「什麼都沒撈到」的差別。
overFetchLimit :: Int -> Int
overFetchLimit n = max 1 (n * overFetchFactor)

-- | 依 @metaId@ 去重,同 id 取__最高分__那一筆(連同它的 snippet 與來源)。
--
-- 分數相同時取先出現者;輸出維持每個 id __第一次出現__的相對順序。輸入順序
-- 即優先序,而關鍵詞順序本身是確定的,合併因此也是確定的。
mergeCandidates :: [Candidate] -> [Candidate]
mergeCandidates cs =
  map snd . sortOn fst . M.elems $ foldl' step M.empty (zip [0 :: Int ..] cs)
  where
    step acc (n, c) = M.insertWith better (metaId (caMeta c)) (n, c) acc
    better (_, new) (nOld, old)
      | caScore new > caScore old = (nOld, new)
      | otherwise = (nOld, old)

-- timeline 過濾 -----------------------------------------------------------------

-- | timeline 過濾。四條保留規則,任一成立就留下:
--
-- 1. @window@ 是 'Nothing' ——沒開過濾
-- 2. 基準點為空 ——@drRefs@ 是空的、或它們都沒有 @tlOrder@。
--    __沒有基準就不過濾__,而不是全部剔除:後者會讓一個沒填 timeline 的 Vault
--    在使用者加了 @--timeline-window@ 之後靜默回空清單
-- 3. 候選的 @tlOrder@ 是 'Nothing' ——@tlLabel@ 是模糊字串(「崩塌前後」),
--    算不出距離
-- 4. 存在某個基準點 @a@ 使 @abs (cand - a) <= w@
withinWindow :: Maybe Int -> [Int] -> Meta -> Bool
withinWindow Nothing _ _ = True
withinWindow (Just w) anchors m
  | null anchors = True
  | otherwise = case tlOrder (metaTimeline m) of
      Nothing -> True
      Just o -> any (\a -> abs (o - a) <= w) anchors

-- | 草稿已引用片段的 @tlOrder@ ——草稿身上唯一的時序線索。
--
-- 查不到的 id __逐個吞掉__:@drRefs@ 由呼叫端(作者或 Agent)提供,裡面有一個
-- 打錯的 id 不該讓整個 @context@ 指令失敗。
timelineAnchors :: [Id] -> ServiceM [Int]
timelineAnchors is = mapMaybe id <$> mapM one is
  where
    one i = (orderOf <$> getEntity i) `catchError` const (pure Nothing)
    orderOf = tlOrder . metaTimeline . entMeta . evEntity

-- 門面 -------------------------------------------------------------------------

-- | 第 2 層門面。全部讀取經 'ServiceM',不開索引連線。
--
-- 輸出依 (分數遞減, id 字典序) 全序排列並截到 @coTopN@,同一輸入永遠同一輸出。
retrieveCandidates :: ConflictOpts -> Draft -> ServiceM RetrievalResult
retrieveCandidates = retrieveCandidatesWith defaultKeywordStrategy

-- | 換策略用的版本;'retrieveCandidates' 就是它套上 'defaultKeywordStrategy'。
retrieveCandidatesWith :: KeywordStrategy -> ConflictOpts -> Draft -> ServiceM RetrievalResult
retrieveCandidatesWith strat opts (Draft txt refs) = do
  idx <- aliasIndex canonFilter
  let kws = runKeywordStrategy strat idx txt
  fetched <- mergeCandidates . concat <$> mapM fetch kws

  anchors <- timelineAnchors refs
  let kept = filter (withinWindow (coTimelineWindow opts) anchors . caMeta) fetched

  -- 擴充的排除集合是__掃過的全部__而不只是存活的:被 timeline 剔除的候選不該
  -- 再從擴充那條路偷偷回來。
  expanded <- expandOneHop (S.fromList (map (metaId . caMeta) fetched)) kept

  pure
    RetrievalResult
      { rrCandidates = take (coTopN opts) (sortCandidates (kept ++ expanded))
      , rrScanned = length fetched + length expanded
      , rrKeywords = kws
      }
  where
    canonFilter = emptyFilter {efStatus = Just Canon}

    -- 一個關鍵詞一次 SQL。canon 過濾__在 SQL 裡__發生(whereOf 產出的
    -- @AND e.status = ?@),efLimit 才不會被 draft 片段吃掉名額。
    fetch kw = do
      hits <- searchEntity kw canonFilter {efLimit = Just (overFetchLimit (coTopN opts))}
      pure [candidateOf kw k h | (k, h) <- zip [0 ..] hits]

    candidateOf kw k (SearchHit m s sc) =
      Candidate
        { caMeta = m
        , caSnippet = s
        , caScore = maybe (rankFallbackScore k) id sc
        , caOrigin = FromKeyword kw
        }

-- | 排序鍵:分數遞減 → id 字典序。
--
-- 第二鍵讓輸出成為__全序__,同一份輸入永遠同一份輸出——第 2 層與第 1 層一樣是
-- 確定性層,「大致上這個順序」不夠。
sortCandidates :: [Candidate] -> [Candidate]
sortCandidates = sortOn (\c -> (Down (caScore c), metaId (caMeta c)))

-- | @partOf@ \/ @occursIn@ 的一跳擴充。
--
-- * __只取正向__(@lrOutgoing@)。ADR-007 寫的是「候選的 partOf \/ occursIn
--   目標一併帶進來」;反向是「誰屬於這個候選」,那是另一個問題,而且一個角色
--   主體的反向 @partOf@ 可能有幾十筆,會直接把 @topN@ 淹掉
-- * __只取本地目標__(@refVault == Nothing@)。跨 Vault 的目標要開第二個索引
--   連線,而 @ServiceM@ 這一層明說跨 Vault 只存不解析
-- * __非 canon 丟棄__(驗收標準 2 對擴充候選同樣成立),查不到的略過
-- * 已經掃過的目標不重複加入
-- * 分數 = 母候選分數 × 'expansionDecay'
--
-- __只做一跳,不遞迴__:@coGraphDepth@ 是第 1 層的參數,第 2 層的「一跳」是
-- ADR-007 寫死的。
expandOneHop :: S.Set Id -> [Candidate] -> ServiceM [Candidate]
expandOneHop = go
  where
    go _ [] = pure []
    go seen (p : ps) = do
      rep <- linksOf (metaId (caMeta p))
      (seen', new) <- foldM (visit p) (seen, []) (targetsOf rep)
      (reverse new ++) <$> go seen' ps

    targetsOf rep =
      [ (linkKind l, refId (linkTarget l))
      | l <- lrOutgoing rep
      , linkKind l == PartOf || linkKind l == OccursIn
      , refVault (linkTarget l) == Nothing
      ]

    visit p (seen, acc) (k, tid)
      | tid `S.member` seen = pure (seen, acc)
      | otherwise =
          lookupMeta tid >>= \case
            Just m
              | isCanon m -> pure (S.insert tid seen, expandedFrom p k m : acc)
            _ -> pure (S.insert tid seen, acc)

    expandedFrom p k m =
      Candidate
        { caMeta = m
        , caSnippet = snippetOf m
        , caScore = caScore p * expansionDecay
        , caOrigin = FromExpansion (metaId (caMeta p)) k
        }

    -- 擴充目標不是被檢索命中的,沒有 FTS5 給的 snippet;總結是它身上最接近
    -- 「一句話說明」的東西,總結為空時退回標題。
    snippetOf m
      | not (T.null (T.strip (metaSummary m))) = metaSummary m
      | otherwise = metaTitle m

    lookupMeta i =
      (Just . entMeta . evEntity <$> getEntity i) `catchError` const (pure Nothing)

-- 輸出轉換 ---------------------------------------------------------------------

-- | 繁中理由文案,固定句型,id 一律走 'renderId'。
--
-- __不得出現「矛盾」二字__:第 2 層交出來的是「相關」,不是判斷。把候選講成
-- 矛盾,'HitLayer' 分三層的意義就沒了(ADR-007:第 1 層是事實、第 3 層是判斷,
-- 使用者需要知道差別)。
renderRetrievalReason :: Candidate -> Text
renderRetrievalReason c = case caOrigin c of
  FromKeyword kw ->
    "草稿與 " <> renderId (metaId (caMeta c)) <> " 共同出現「" <> kw <> "」"
  FromExpansion src k ->
    renderId (metaId (caMeta c))
      <> " 經 "
      <> renderId src
      <> " 的 "
      <> renderLinkKind k
      <> " 關聯一跳帶入"

-- | 給 @context@ 出口:'HitLayer' 為 'ByRetrieval','Meta' 直接帶走。
candidateContextHit :: Candidate -> ContextHit
candidateContextHit c =
  ContextHit
    { xhMeta = caMeta c
    , xhSnippet = caSnippet c
    , xhVia = ByRetrieval (caScore c)
    }

-- | 給三層合流用:@chSnippet@ __恆為 'Just'__ ——第 2 層有片段可指,
-- 對比第 1 層恆為 'Nothing'。
candidateConflictHit :: Candidate -> ConflictHit
candidateConflictHit c =
  ConflictHit
    { chTarget = metaId (caMeta c)
    , chLayer = ByRetrieval (caScore c)
    , chReason = renderRetrievalReason c
    , chSnippet = Just (caSnippet c)
    }

-- 共用 -------------------------------------------------------------------------

-- | 去重保序。
dedupe :: (Ord a) => [a] -> [a]
dedupe = go S.empty
  where
    go _ [] = []
    go seen (x : xs)
      | x `S.member` seen = go seen xs
      | otherwise = x : go (S.insert x seen) xs
