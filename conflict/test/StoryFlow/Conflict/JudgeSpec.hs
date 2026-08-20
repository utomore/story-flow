-- | T5 / T6 / T8 / T9:第 3 層的純函式部件(fence 剝除、JSON 解析、prompt 形狀、
-- 逐對迴圈、退化詞彙)。
--
-- __hermetic__(D6):全部用假 runner 跑在 'IO' 上,__不 import @Network.*@、
-- 不建立任何真正指向網路端點的用戶端__。'StoryFlow.Conflict.Judge.judgeLoop'
-- 的型別參數是 @Monad m@ 而不是 @IO@,它因此碰不到真正的網路呼叫,只能用
-- runner 給它的東西。
module StoryFlow.Conflict.JudgeSpec (spec) where

import qualified Data.ByteString as BS
import Data.IORef
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Conflict.Fixtures (idOf)
import StoryFlow.Conflict.Judge
import StoryFlow.Conflict.Types (ConflictHit (..), Draft (..), HitLayer (..), ReportNote (..))
import StoryFlow.Core.Id (Id, renderId)
import StoryFlow.Llm.Client (Message (..), Role (..))
import StoryFlow.Llm.Error (LlmError (..), renderLlmError)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "fence 剝除與 JSON 解析" $ do
    it "```json 包起來的內容(實測地端 gemma-4-12b-it 的真實形狀)" $
      stripCodeFence "```json\n{\"a\":1}\n```" `shouldBe` "{\"a\":1}"

    it "``` 無語言標記" $
      stripCodeFence "```\n{\"a\":1}\n```" `shouldBe` "{\"a\":1}"

    it "前面有贅句的 fence" $
      stripCodeFence "以下是判斷結果:\n```json\n{\"a\":1}\n```" `shouldBe` "{\"a\":1}"

    it "沒有 fence 的裸 JSON 回原文(去空白)" $
      stripCodeFence "  {\"a\":1}  " `shouldBe` "{\"a\":1}"

    it "合法 JSON 解得出三欄" $ do
      case parseVerdict validJson of
        Right v -> do
          vdContradicts v `shouldBe` True
          vdConfidence v `shouldBe` 0.7
          vdReason v `shouldBe` "兩段對徵召的結果描述不一致"
        Left e -> expectationFailure ("預期解析成功,卻是 Left " <> T.unpack e)

    it "confidence 超界會被 clamp,不算解析失敗" $ do
      case parseVerdict (verdictJson True 1.4 "理由") of
        Right v -> vdConfidence v `shouldBe` 1.0
        Left e -> expectationFailure ("預期解析成功,卻是 Left " <> T.unpack e)
      case parseVerdict (verdictJson True (-0.3) "理由") of
        Right v -> vdConfidence v `shouldBe` 0.0
        Left e -> expectationFailure ("預期解析成功,卻是 Left " <> T.unpack e)

    it "contradicts = false 且 reason 空白是合法的" $
      case parseVerdict (verdictJson False 0.1 "") of
        Right v -> do
          vdContradicts v `shouldBe` False
          vdReason v `shouldBe` ""
        Left e -> expectationFailure ("預期解析成功,卻是 Left " <> T.unpack e)

    it "純散文、缺 confidence、confidence 是字串、contradicts=true 但 reason 空白,四種都回 Left" $ do
      shouldBeLeft (parseVerdict "這不是 JSON,只是一段散文")
      shouldBeLeft (parseVerdict "{\"contradicts\":true,\"reason\":\"理由\"}")
      shouldBeLeft (parseVerdict "{\"contradicts\":true,\"confidence\":\"高\",\"reason\":\"理由\"}")
      shouldBeLeft (parseVerdict (verdictJson True 0.5 ""))

    it "Left 的訊息帶得出原文片段且長度受限" $ do
      let longText = T.replicate 500 "壞"
      case parseVerdict longText of
        Left msg -> do
          T.isInfixOf "壞壞壞" msg `shouldBe` True
          T.length msg `shouldSatisfy` (< 300)
        Right _ -> expectationFailure "預期解析失敗"

  describe "prompt 的形狀" $ do
    it "judgeMessages 恰兩則,第一則 System、第二則 User" $ do
      let msgs = judgeMessages draft target
      length msgs `shouldBe` 2
      msgRole (msgs !! 0) `shouldBe` System
      msgRole (msgs !! 1) `shouldBe` User

    it "judgeSystemPrompt 含三個鍵名與「只輸出」字樣" $ do
      "contradicts" `T.isInfixOf` judgeSystemPrompt `shouldBe` True
      "confidence" `T.isInfixOf` judgeSystemPrompt `shouldBe` True
      "reason" `T.isInfixOf` judgeSystemPrompt `shouldBe` True
      "只輸出" `T.isInfixOf` judgeSystemPrompt `shouldBe` True

    it "renderPairPrompt 含 drText、renderId jtId、jtTitle、jtText,不含 drRefs 的 id" $ do
      let p = renderPairPrompt draftWithRefs target
      drText draftWithRefs `T.isInfixOf` p `shouldBe` True
      renderId (jtId target) `T.isInfixOf` p `shouldBe` True
      jtTitle target `T.isInfixOf` p `shouldBe` True
      jtText target `T.isInfixOf` p `shouldBe` True
      renderId refId `T.isInfixOf` p `shouldBe` False

  describe "逐對迴圈:成功、部分失敗、中止" $ do
    it "全部成功:矛盾/不矛盾/矛盾" $ do
      (result, calls) <- runLoop [right True 0.9 "理由甲", right False 0.1 "", right True 0.5 "理由丙"]
      jrJudged result `shouldBe` 3
      length (jrHits result) `shouldBe` 2
      jrNotes result `shouldBe` []
      length calls `shouldBe` 3
      -- 命中順序 = 候選順序(輸入即優先序)
      map chTarget (jrHits result) `shouldBe` [jtId t1, jtId t3]

    it "部分失敗(非連線類):保留已成功的,繼續下一對" $ do
      (result, calls) <-
        runLoop [right True 0.9 "理由甲", Left (LlmHttpStatus 500 "err"), right True 0.5 "理由丙"]
      jrJudged result `shouldBe` 2
      length (jrHits result) `shouldBe` 2
      length calls `shouldBe` 3
      case jrNotes result of
        [ReportNote code detail] -> do
          code `shouldBe` "judge_call_failed"
          renderId (jtId t2) `T.isInfixOf` detail `shouldBe` True
        ns -> expectationFailure ("預期恰一則 note,拿到 " <> show ns)

    it "LlmUnavailable 中止剩餘的對,已成功的保留" $ do
      (result, calls) <-
        runLoop [right True 0.9 "理由甲", Left (LlmUnavailable "連不上"), right True 0.5 "理由丙"]
      length calls `shouldBe` 2
      length (jrHits result) `shouldBe` 1
      map chTarget (jrHits result) `shouldBe` [jtId t1]
      case jrNotes result of
        [ReportNote code detail] -> do
          code `shouldBe` "judge_aborted"
          "1" `T.isInfixOf` detail `shouldBe` True
        ns -> expectationFailure ("預期恰一則 note,拿到 " <> show ns)

    it "純散文回覆:不產生命中,記一則 judge_parse_failed" $ do
      (result, _) <- runLoop [Right "這不是 JSON"]
      jrHits result `shouldBe` []
      jrJudged result `shouldBe` 0
      case jrNotes result of
        [ReportNote code _] -> code `shouldBe` "judge_parse_failed"
        ns -> expectationFailure ("預期恰一則 note,拿到 " <> show ns)

    it "命中的 chLayer 全是 ByJudge、chReason 是模型原話、chSnippet 是 Just jtText" $ do
      (result, _) <- runLoop [right True 0.77 "獨特的理由文字"]
      case jrHits result of
        [h] -> do
          chLayer h `shouldBe` ByJudge 0.77
          chReason h `shouldBe` "獨特的理由文字"
          chSnippet h `shouldBe` Just (jtText t1)
        hs -> expectationFailure ("預期恰一筆命中,拿到 " <> show hs)

  describe "退化的三種原因分得出來" $ do
    it "三個建構子的 rnCode 兩兩不同、都以 judge_ 開頭" $ do
      let codes = map (rnCode . skipNote) [SkipDisabled, SkipNotConfigured LlmConfigMissing, SkipUnreachable (LlmUnavailable "x")]
      codes `shouldBe` ["judge_disabled", "judge_not_configured", "judge_unreachable"]
      mapM_ (\c -> "judge_" `isInfixOf` T.unpack c `shouldBe` True) codes

    it "rnDetail 都非空" $ do
      mapM_
        (\s -> T.null (rnDetail (skipNote s)) `shouldBe` False)
        [SkipDisabled, SkipNotConfigured LlmConfigMissing, SkipUnreachable (LlmUnavailable "x")]

    it "SkipNotConfigured 的 detail 含 renderLlmError 的內容,不重寫下層訊息" $
      rnDetail (skipNote (SkipNotConfigured LlmConfigMissing))
        `shouldBe` renderLlmError LlmConfigMissing

    it "SkipUnreachable 的 detail 含 renderLlmError 的內容" $
      rnDetail (skipNote (SkipUnreachable (LlmUnavailable "連線被拒")))
        `shouldBe` renderLlmError (LlmUnavailable "連線被拒")

  -- conflict-detection/F005 T11:hermetic(D6)。judgeLoop 的 Monad m 拿不到
  -- MonadIO 是型別層的保證,這一條是文字層的補強:整個 conflict 測試套件
  -- 不匯入 Network 家族的模組、不建立任何真正指向網路端點的用戶端。
  describe "hermetic(D6)" $
    it "測試檔裡沒有 Network.* 的 import,也不建立真正的 LLM 用戶端" $ do
      dir <- testDir
      files <- allHsFiles dir
      contents <- mapM readUtf8 files
      let allLines = concatMap lines contents
      any importsNetwork allLines `shouldBe` False
      -- 建立用戶端的入口只有一個:llm-workshop-mcp 那個建立 client 的函式。
      -- 測試檔不該出現這段字面,出現了就代表有測試偷偷打了真端點。
      --
      -- forbiddenCtor 刻意拆成兩段字串再接起來:這個檔案自己也在
      -- conflict/test 底下,若直接寫死完整字面,這條斷言會抓到自己。
      any (forbiddenCtor `isInfixOf`) contents `shouldBe` False

-- 共用資料 ------------------------------------------------------------------

draft :: Draft
draft = Draft "琳達在崩塌後回到埃提亞" []

refId :: Id
refId = idOf "ent-91cc"

draftWithRefs :: Draft
draftWithRefs = Draft "琳達在崩塌後回到埃提亞" [refId]

t1, t2, t3 :: JudgeTarget
t1 = JudgeTarget (idOf "ent-1111") "殘響甲" "殘響甲的內容" False
t2 = JudgeTarget (idOf "ent-2222") "殘響乙" "殘響乙的內容" False
t3 = JudgeTarget (idOf "ent-3333") "殘響丙" "殘響丙的內容" False

target :: JudgeTarget
target = t1

validJson :: Text
validJson = verdictJson True 0.7 "兩段對徵召的結果描述不一致"

verdictJson :: Bool -> Double -> Text -> Text
verdictJson c conf reason =
  "{\"contradicts\":"
    <> (if c then "true" else "false")
    <> ",\"confidence\":"
    <> T.pack (show conf)
    <> ",\"reason\":\""
    <> reason
    <> "\"}"

right :: Bool -> Double -> Text -> Either LlmError Text
right c conf reason = Right (verdictJson c conf reason)

shouldBeLeft :: Either Text a -> Expectation
shouldBeLeft = \case
  Left _ -> pure ()
  Right _ -> expectationFailure "預期是 Left"

-- | 目標數 = 回覆數:回覆序列不夠長時,'judgeLoop' 根本不會再送下一對
-- (要嘛提早中止,要嘛已經 'take' 掉多餘的目標),不需要用 stub 撐住多餘的呼叫。
runLoop :: [Either LlmError Text] -> IO (JudgeResult, [[Message]])
runLoop responses = do
  callsRef <- newIORef []
  respRef <- newIORef responses
  result <- judgeLoop (stubRunner callsRef respRef) draft (take (length responses) [t1, t2, t3])
  calls <- readIORef callsRef
  pure (result, calls)

-- | 依序回傳預先排好的回覆,並把每一次的 @[Message]@ 記下來。
stubRunner :: IORef [[Message]] -> IORef [Either LlmError Text] -> [Message] -> IO (Either LlmError Text)
stubRunner callsRef respRef msgs = do
  modifyIORef' callsRef (++ [msgs])
  rs <- readIORef respRef
  case rs of
    [] -> error "stubRunner: 回覆序列已用盡"
    (r : rest) -> writeIORef respRef rest >> pure r

-- hermetic(T11)---------------------------------------------------------------

-- | @conflict/test@ 目錄,不論目前工作目錄是專案根目錄還是 @conflict/@ 本身。
testDir :: IO FilePath
testDir = go ["test", "conflict/test"]
  where
    go [] = fail "找不到 conflict/test 目錄"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

-- | 遞迴列出目錄下所有 @.hs@ 檔。
allHsFiles :: FilePath -> IO [FilePath]
allHsFiles dir = do
  entries <- listDirectory dir
  concat <$> mapM (classify . (dir </>)) entries
  where
    classify p = do
      isDir <- doesDirectoryExist p
      if isDir
        then allHsFiles p
        else pure [p | takeExtension p == ".hs"]

-- | 以 UTF-8 讀,理由與 "StoryFlow.Conflict.CabalSpec" 的 @readCabal@ 相同:
-- 原始碼裡有繁中,Windows 的預設 code page 會在第一個中文字元就爆掉。
readUtf8 :: FilePath -> IO String
readUtf8 p = T.unpack . TE.decodeUtf8 <$> BS.readFile p

-- | 一行是不是在 import @Network.*@(含 @qualified@ 形式)。
--
-- __needle 刻意拆開再接起來__:同樣的自我抓到問題(見 'forbiddenCtor')
-- ——這個檔案自己也在 conflict/test 底下。
importsNetwork :: String -> Bool
importsNetwork l = any (`isInfixOf` l) [plain, qualified]
  where
    importKw = "import"
    networkMod = "Network" ++ "."
    plain = importKw ++ " " ++ networkMod
    qualified = importKw ++ " qualified " ++ networkMod

-- | @storyflow-llm@ 建立真正用戶端的函式名——__刻意拆成兩段字串再接起來__,
-- 不讓完整字面出現在原始碼裡,否則本檔自己(也在 conflict/test 底下)會被
-- 自己的斷言抓到。
forbiddenCtor :: String
forbiddenCtor = "new" ++ "LlmClient"
