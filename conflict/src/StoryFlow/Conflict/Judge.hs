-- | 衝突偵測第 3 層:草稿 × 候選逐對送 LLM 問「是否矛盾、矛盾在哪」。
--
-- 三層裡__成本最高、輸出最少__的一層(ADR-007)。第 1 層交的是事實、第 2 層
-- 交的是相關,本層交的是__判斷__ ——三者的可信度完全不同,而 'HitLayer' 分
-- 三個建構子的意義就在這裡。
--
-- 本層因此有兩條與前兩層不同的紀律:
--
-- * __不可靠是常態而非例外__。地端 12B 模型會回 markdown code fence 包起來的
--   JSON、會逾時、會在第 N 對突然連不上。整條管線__不能因為第 3 層而失敗__
--   ——外部 Agent 靠前兩層吃飯
-- * __拿不到判斷時不得捏一個__。解析不出來就是該對判斷失敗,記進 'ReportNote'
--   的 @judge_parse_failed@,__不得捏一個信心值混進 @ByJudge@__(D5)
--
-- 兩層切分是刻意的(見 'resolveTargets' 與 'judgeLoop' 的文件):
-- 'resolveTargets' 是唯一需要 'ServiceM' 的一步,'judgeLoop' 則對任意 'Monad'
-- 成立,讓四條必測路徑(退化、部分失敗、fence 剝除、JSON 解析失敗)全部可以
-- 在不開 Vault、不發請求的情況下測到。
module StoryFlow.Conflict.Judge
  ( -- * 門面
    judgeCandidates
  , judgeCandidatesWith
  , JudgeResult (..)

    -- * 注入接縫(D6:公開面吃 LlmClient,內部吃可替換的 runner)
  , JudgeRunner
  , llmRunner
  , judgeLoop

    -- * 送出去的那一段
  , JudgeTarget (..)
  , resolveTargets

    -- * 退化的詞彙(F006 決定用哪一個)
  , JudgeSkip (..)
  , skipNote

    -- * 逐對判斷的純函式部件
  , Verdict (..)
  , judgeSystemPrompt
  , renderPairPrompt
  , judgeMessages
  , stripCodeFence
  , parseVerdict
  , verdictHit
  ) where

import Control.Monad.Except (catchError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), eitherDecodeStrictText, withObject, (.:))
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Conflict.Retrieval (Candidate (..), metaSnippet)
import StoryFlow.Conflict.Types
  ( ConflictHit (..)
  , ConflictOpts (..)
  , Draft (..)
  , HitLayer (ByJudge)
  , ReportNote (..)
  )
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, renderId)
import StoryFlow.Core.Meta (Meta (..))
import StoryFlow.Llm.Client (LlmClient, Message (..), Role (..), chat)
import StoryFlow.Llm.Error (LlmError (..), renderLlmError)
import StoryFlow.Service (EntityView (..), ServiceM, getEntity)

-- 送出去的那一段 -----------------------------------------------------------------

-- | 送給模型的那一對裡,__候選那一半__。
data JudgeTarget = JudgeTarget
  { jtId :: Id
  , jtTitle :: Text
  , jtText :: Text
  -- ^ 實際送出去的內容:預設 'metaSnippet',@coExpandBody@ 時是 @entBody@
  , jtExpanded :: Bool
  -- ^ 這一對送的是不是展開的 body。理由文案不需要它,但測試需要它。
  }
  deriving stock (Show, Eq)

-- | 候選 → 送出去的那一段。__先套 'coJudgeN' 預算,再讀 body__(不在預算內的
-- 候選連 'getEntity' 都不會發生)。
--
-- 順序反過來的話,@--expand-body@ 會為了 20 個候選讀 20 份正文,再丟掉 15 份。
resolveTargets :: ConflictOpts -> [Candidate] -> ServiceM [JudgeTarget]
resolveTargets opts cs = mapM toTarget (take (max 0 (coJudgeN opts)) cs)
  where
    toTarget c
      | coExpandBody opts = do
          mBody <- (Just . entBody . evEntity <$> getEntity tid) `catchError` const (pure Nothing)
          pure $ case mBody of
            Just b | not (T.null (T.strip b)) -> JudgeTarget tid title_ b True
            _ -> fallback
      | otherwise = pure fallback
      where
        m = caMeta c
        tid = metaId m
        title_ = metaTitle m
        -- 展開失敗、或正文為空白時退回 summary:拿到空正文就沒有展開的意義,
        -- 退回 summary 比送一段空白好。
        fallback = JudgeTarget tid title_ (metaSnippet m) False

-- prompt --------------------------------------------------------------------

-- | 固定的系統訊息:只判斷事實矛盾、只輸出一個 JSON 物件、三個鍵、reason
-- 用繁中一句話。
--
-- 「不要輸出 JSON 以外的任何文字」這一條__明知會被違反還是要寫__:實測回的
-- 就是 @```json@ 包起來的內容。寫了能讓乖一點的模型直接給裸 JSON,不寫則連
-- fence 都不一定成形。真正的防線是 'stripCodeFence'。
judgeSystemPrompt :: Text
judgeSystemPrompt =
  T.unlines
    [ "你是一位故事設定一致性檢查員。你的任務是判斷【既有設定】與【新草稿】之間"
        <> "是否存在事實上的矛盾——只判斷事實是否矛盾,不評論文筆或風格。"
    , "只輸出一個 JSON 物件,不要輸出 JSON 以外的任何文字,不要用 markdown"
        <> " code fence 包住,不要加任何說明。"
    , "這個 JSON 物件必須恰好包含三個鍵:"
    , "- contradicts:布林值,是否存在事實矛盾"
    , "- confidence:0 到 1 之間的小數,你對這個判斷的信心程度"
    , "- reason:繁體中文,一句話說明理由(沒有矛盾時可以是空字串)"
    ]

-- | 使用者訊息:【新草稿】…【既有設定 \<id\>(\<標題\>)】…。@drRefs@ 不進 prompt
-- ——那是第 1 層的起點,對「這兩段文字矛不矛盾」沒有幫助,只會多燒 token。
renderPairPrompt :: Draft -> JudgeTarget -> Text
renderPairPrompt d t =
  T.unlines
    [ "【新草稿】"
    , drText d
    , ""
    , "【既有設定 " <> renderId (jtId t) <> "(" <> jtTitle t <> ")】"
    , jtText t
    ]

-- | @[Message System judgeSystemPrompt, Message User (renderPairPrompt d t)]@
-- ——@system@ role 已對真端點實測可用,不必折進 user 訊息。
judgeMessages :: Draft -> JudgeTarget -> [Message]
judgeMessages d t = [Message System judgeSystemPrompt, Message User (renderPairPrompt d t)]

-- 回應解析 ------------------------------------------------------------------

-- | 模型回覆解析後的結果。__不是 DTO__:沒有任何消費者看得見它,所以它的
-- @FromJSON@ 私有地留在本模組,不進 "StoryFlow.Conflict.Json"(先例:
-- @storyflow-llm@ 的 @ChatResponse@ \/ @ChatChoice@)。
data Verdict = Verdict
  { vdContradicts :: Bool
  , vdConfidence :: Double
  -- ^ 已 clamp 到 @[0, 1]@
  , vdReason :: Text
  }
  deriving stock (Show, Eq)

-- | 剝除 markdown code fence。
--
-- 規則(去空白後判斷):
--
-- 1. 內容以 @```@ 開頭 → 丟掉第一行整行(它可能是 @```json@、@```@、
--    @```JSON@),再丟掉尾端的 @```@ 那一行
-- 2. 內容裡__存在__一段 @```@ 圍起來的區塊(模型先講了一句「以下是判斷結果:」)
--    → 取__第一個__區塊的內容
-- 3. 都不是 → 原樣回傳(已去空白)
stripCodeFence :: Text -> Text
stripCodeFence raw =
  let s = T.strip raw
   in maybe s T.strip (locateFence s)

-- | 找出第一段 fence 圍起來的內容(不論它在開頭還是後面)。
locateFence :: Text -> Maybe Text
locateFence s =
  let (_, after) = T.breakOn fence s
   in if T.null after
        then Nothing
        else
          let content = dropLangTagLine (T.drop (T.length fence) after)
              (inner, closing) = T.breakOn fence content
           in if T.null closing then Nothing else Just inner
  where
    fence = "```"

-- | fence 標記後的第一行若「看起來像語言標記」(短、不含 @{@)就整行丟掉
-- (含換行);否則原樣回傳,代表內容緊接在標記之後。
dropLangTagLine :: Text -> Text
dropLangTagLine t =
  let (tag, rest) = T.breakOn "\n" t
   in if not (T.null rest) && T.length (T.strip tag) <= 12 && not ("{" `T.isInfixOf` tag)
        then T.drop 1 rest
        else t

-- | 剝 fence → decode;失敗再試「第一個 @{@ 到最後一個 @}@」的切片；
-- 兩次都失敗回 'Left'(訊息帶截斷後的原文)。
--
-- @confidence@ 超出 @[0, 1]@ 就 clamp;@contradicts = true@ 但 @reason@ 空白
-- 視為解析失敗。
parseVerdict :: Text -> Either Text Verdict
parseVerdict raw =
  case tryDecode stripped of
    Right rv -> finalize rv
    Left _ -> case sliceBraces stripped of
      Just sliced -> either (const (Left (failMsg stripped))) finalize (tryDecode sliced)
      Nothing -> Left (failMsg stripped)
  where
    stripped = stripCodeFence raw
    tryDecode :: Text -> Either String RawVerdict
    tryDecode = eitherDecodeStrictText
    -- contradicts = true 但沒有理由:驗收標準 4 要「模型給的理由」,唯一
    -- 不捏理由的作法就是沒有理由時不產生命中(這裡的 Left 讓迴圈記
    -- judge_parse_failed,而不是產生一筆理由是空的命中)。
    finalize RawVerdict {..}
      | rvContradicts && T.null (T.strip rvReason) = Left (failMsg stripped)
      | otherwise = Right (Verdict rvContradicts (clamp01 rvConfidence) rvReason)

-- | 模型回覆的線上形狀(私有)。三個鍵都必填,__不做同義詞容忍__:容忍表會
-- 無限長,而 prompt 已經把鍵名寫死了。
data RawVerdict = RawVerdict
  { rvContradicts :: Bool
  , rvConfidence :: Double
  , rvReason :: Text
  }

instance FromJSON RawVerdict where
  parseJSON = withObject "Verdict" $ \o ->
    RawVerdict <$> o .: "contradicts" <*> o .: "confidence" <*> o .: "reason"

-- | 「第一個 @{@ 到最後一個 @}@」的切片。吃掉的是「fence 沒成形但前後有贅字」
-- 那一類回覆,__仍然是擷取而不是編造__。
sliceBraces :: Text -> Maybe Text
sliceBraces t = do
  i <- T.findIndex (== '{') t
  j <- lastIndexOf '}' t
  if j >= i then Just (T.take (j - i + 1) (T.drop i t)) else Nothing

lastIndexOf :: Char -> Text -> Maybe Int
lastIndexOf c t = case T.findIndex (== c) (T.reverse t) of
  Nothing -> Nothing
  Just k -> Just (T.length t - 1 - k)

-- | @[0, 1]@ 之外就 clamp,不是判斷失敗。模型已經明確回答了矛盾與否,為了
-- 一個超界的機率丟掉整筆判斷,損失比校正大。clamp 的是__範圍__,不是把沒有
-- 的值生出來。
clamp01 :: Double -> Double
clamp01 x = max 0 (min 1 x)

-- | 解析失敗的訊息,帶截斷後的原文(200 字上限;端點回一整頁 HTML 時不該把
-- 終端機洗掉)。
failMsg :: Text -> Text
failMsg t = "無法解析模型回覆為判斷結果:" <> truncated
  where
    truncated
      | T.length t <= 200 = t
      | otherwise = T.take 200 t <> "…(已截斷)"

-- | 判定為矛盾的 'Verdict' → 'ConflictHit'。@chSnippet@ 就是送給模型看的那一段
-- ——它誠實地反映了 @--expand-body@ 的效果,而且使用者要複核模型的判斷時,
-- 看到的必須是模型看到的東西。
verdictHit :: JudgeTarget -> Verdict -> ConflictHit
verdictHit t v =
  ConflictHit
    { chTarget = jtId t
    , chLayer = ByJudge (vdConfidence v)
    , chReason = vdReason v
    , chSnippet = Just (jtText t)
    }

-- 退化 ------------------------------------------------------------------------

-- | 第 3 層沒有跑起來的三種原因。__三個不同的 rnCode__,因為對使用者是三個
-- 不同的下一步。__誰決定用哪一個是 F006 的事__(它才知道有沒有 @--no-llm@、
-- 才呼叫 @llmConfig@ 與 @newLlmClient@);本模組只提供詞彙與文案。
data JudgeSkip
  = -- | @--no-llm@,或 @coJudgeN <= 0@
    SkipDisabled
  | -- | @LlmConfigMissing@ \/ @LlmConfigInvalid@
    SkipNotConfigured LlmError
  | -- | 建 client 或第一次呼叫就連不上
    SkipUnreachable LlmError
  deriving stock (Show, Eq)

-- | 'JudgeSkip' → 'ReportNote'。@rnDetail@ 的內容盡量取用
-- 'StoryFlow.Llm.Error.renderLlmError' 的原文,__不重寫下層訊息__。
skipNote :: JudgeSkip -> ReportNote
skipNote = \case
  SkipDisabled ->
    ReportNote
      "judge_disabled"
      "這份報告只有前兩層;拿掉 --no-llm(或把 --judge-n 調大)才會跑語意判斷"
  SkipNotConfigured e -> ReportNote "judge_not_configured" (renderLlmError e)
  SkipUnreachable e -> ReportNote "judge_unreachable" (renderLlmError e)

-- 逐對迴圈 ----------------------------------------------------------------------

-- | 呼叫模型的接縫。__型別參數是 Monad 而不是 IO__:'judgeLoop' 因此碰不到
-- IO,除了 runner 給它的東西以外什麼都做不了。
type JudgeRunner m = [Message] -> m (Either LlmError Text)

-- | 唯一真的呼叫 'chat' 的地方。
llmRunner :: LlmClient -> JudgeRunner ServiceM
llmRunner c = liftIO . chat c

-- | 逐對判斷。__不讀資料__,所以對任意 'Monad' 成立,四條必測路徑都可在零
-- IO 下觸發。
--
-- 逐對依序處理(__不併發__:地端端點通常是單一 worker,併發只會讓每一對都
-- 變慢,而且會讓輸出順序不確定):
--
-- * 解析成功且矛盾 → 一筆命中,'jrJudged' + 1
-- * 解析成功但不矛盾 → 無命中,'jrJudged' + 1(這仍是一筆有效判斷)
-- * 解析失敗 → 記 @judge_parse_failed@,繼續下一對
-- * 'LlmUnavailable'(以外的錯誤)→ 記 @judge_call_failed@,繼續下一對
-- * 'LlmUnavailable' → 記 @judge_aborted@,__中止剩餘的對__——@chat@ 內部已經
--   重試過,走到這裡代表服務真的不在,繼續打剩下的對只會讓每一對都再等一次
--   逾時,換來必然相同的失敗
--
-- __已成功的一律保留__:中止只影響「還沒送的」,已經燒掉的 token 不該因為
-- 第 N 對逾時就整批作廢。
judgeLoop :: (Monad m) => JudgeRunner m -> Draft -> [JudgeTarget] -> m JudgeResult
judgeLoop _ _ [] = pure (JudgeResult [] 0 [])
judgeLoop runner d (t : ts) = do
  r <- runner (judgeMessages d t)
  case r of
    Left (LlmUnavailable _) ->
      pure
        JudgeResult
          { jrHits = []
          , jrJudged = 0
          , jrNotes = [ReportNote "judge_aborted" (abortedDetail (length ts))]
          }
    Left err -> do
      rest <- judgeLoop runner d ts
      pure rest {jrNotes = ReportNote "judge_call_failed" (callFailedDetail t err) : jrNotes rest}
    Right raw -> case parseVerdict raw of
      Left err -> do
        rest <- judgeLoop runner d ts
        pure rest {jrNotes = ReportNote "judge_parse_failed" (parseFailedDetail t err) : jrNotes rest}
      Right v -> do
        rest <- judgeLoop runner d ts
        let judged = rest {jrJudged = jrJudged rest + 1}
        pure $
          if vdContradicts v
            then judged {jrHits = verdictHit t v : jrHits judged}
            else judged
  where
    abortedDetail n = "尚有 " <> T.pack (show n) <> " 對未判斷;LLM 端點已連不上,中止剩餘的判斷"
    callFailedDetail tgt err =
      renderId (jtId tgt) <> " 這一對的判斷失敗:" <> renderLlmError err
    parseFailedDetail tgt err =
      renderId (jtId tgt) <> " 這一對沒有判斷結果,不是判定為沒有矛盾:" <> err

-- 門面 --------------------------------------------------------------------------

-- | 第 3 層的完整結果。
data JudgeResult = JudgeResult
  { jrHits :: [ConflictHit]
  -- ^ 'HitLayer' 恆為 @ByJudge@;只有判定為矛盾的才成為命中
  , jrJudged :: Int
  -- ^ __成功取得判斷的對數__(含判定為不矛盾的)→ @crLlmUsed = jrJudged > 0@
  , jrNotes :: [ReportNote]
  -- ^ 逐對失敗、中止、預算為零 → 'StoryFlow.Conflict.Types.ConflictReport'
  -- 的 @crNotes@
  }
  deriving stock (Show, Eq)

-- | 換 runner 用的版本;'judgeCandidates' 就是它套上 'llmRunner'。
--
-- @coJudgeN <= 0@ 而候選非空時記一則 @judge_disabled@,__一次都不呼叫
-- runner__(也不呼叫 'resolveTargets',所以連 'getEntity' 都不會發生)。
judgeCandidatesWith :: JudgeRunner ServiceM -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult
judgeCandidatesWith runner opts d cs
  | coJudgeN opts <= 0 =
      pure
        JudgeResult
          { jrHits = []
          , jrJudged = 0
          , jrNotes = [skipNote SkipDisabled | not (null cs)]
          }
  | otherwise = do
      targets <- resolveTargets opts cs
      judgeLoop runner d targets

-- | 公開面:照契約卡吃不透明的 'LlmClient'。
judgeCandidates :: LlmClient -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult
judgeCandidates client = judgeCandidatesWith (llmRunner client)
