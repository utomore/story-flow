-- | T7 / T10:第 3 層跑在真的 Vault 上(@resolveTargets@ 要用 'ServiceM' 的
-- @getEntity@ 展開 body)與門面 @judgeCandidatesWith@。
--
-- 建臨時 Vault __只靠 @storyflow-service@ 的門面__:與
-- "StoryFlow.Conflict.RetrievalEnvSpec" 同一條界線——@storyflow-store@ 一次都
-- 不必露臉。__hermetic__(D6):全程用假 runner,不建立任何真正指向網路端點的
-- 用戶端,不發任何網路請求。
module StoryFlow.Conflict.JudgeEnvSpec (spec) where

import Control.Exception (bracket)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Conflict.Fixtures (metaOf)
import StoryFlow.Conflict.Judge
import StoryFlow.Conflict.Retrieval (Candidate (..), CandidateOrigin (FromKeyword), metaSnippet)
import StoryFlow.Conflict.Types (ConflictOpts (..), Draft (..), ReportNote (..), defaultConflictOpts)
import StoryFlow.Core.Id (Id, renderId)
import StoryFlow.Core.Meta (Meta (..), Source (Human), Status (Canon), emptyTimeline)
import StoryFlow.Llm.Client (Message)
import StoryFlow.Llm.Error (LlmError)
import StoryFlow.Service
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "T7 送出去的那一段:summary 與 body" $ do
    it "coExpandBody = False 時每個 jtText 是 metaSnippet,jtExpanded 是 False" $
      withVault $ \env -> do
        cs <- threeCandidates env
        ts <- runS env (resolveTargets defaultConflictOpts {coJudgeN = 3} cs)
        map jtText ts `shouldBe` map (metaSnippet . caMeta) cs
        map jtExpanded ts `shouldBe` [False, False, False]

    it "coExpandBody = True 時 jtText 是 entBody,jtExpanded 是 True" $
      withVault $ \env -> do
        cs <- threeCandidates env
        ts <- runS env (resolveTargets defaultConflictOpts {coJudgeN = 3, coExpandBody = True} cs)
        map jtText ts `shouldBe` ["甲的完整正文,比摘要長得多", "乙的完整正文,比摘要長得多", "丙的完整正文,比摘要長得多"]
        map jtExpanded ts `shouldBe` [True, True, True]

    it "正文為空白的片段在 coExpandBody = True 下退回 summary,jtExpanded 是 False" $
      withVault $ \env -> do
        blankId <- newE env (entityOf "空白正文" "空白正文的摘要" "   ")
        let c = candidateOf (metaOf' blankId "空白正文" "空白正文的摘要")
        [t] <- runS env (resolveTargets defaultConflictOpts {coJudgeN = 1, coExpandBody = True} [c])
        jtText t `shouldBe` "空白正文的摘要"
        jtExpanded t `shouldBe` False

    it "coJudgeN = 2 而候選 5 個時只回 2 筆,且順序是輸入的前兩筆" $
      withVault $ \env -> do
        let cs = [dummyCandidate n | n <- [1 .. 5 :: Int]]
        ts <- runS env (resolveTargets defaultConflictOpts {coJudgeN = 2} cs)
        map jtId ts `shouldBe` [jtId0 (cs !! 0), jtId0 (cs !! 1)]

    it "coJudgeN = 0 回 []" $
      withVault $ \env -> do
        let cs = [dummyCandidate n | n <- [1 .. 5 :: Int]]
        ts <- runS env (resolveTargets defaultConflictOpts {coJudgeN = 0} cs)
        ts `shouldBe` []

  describe "T10 門面與零預算" $ do
    it "candidates 3 個、coJudgeN = 2 時 runner 恰被呼叫 2 次" $
      withVault $ \env -> do
        let cs = [dummyCandidate n | n <- [1 .. 3 :: Int]]
        (result, calls) <- runFacade env defaultConflictOpts {coJudgeN = 2} cs
        length calls `shouldBe` 2
        jrJudged result `shouldBe` 2

    it "coJudgeN = 0 而候選非空時 runner 一次都沒被呼叫,jrJudged == 0,jrNotes 恰一則 judge_disabled" $
      withVault $ \env -> do
        let cs = [dummyCandidate 1]
        (result, calls) <- runFacade env defaultConflictOpts {coJudgeN = 0} cs
        calls `shouldBe` []
        jrJudged result `shouldBe` 0
        case jrNotes result of
          [ReportNote code _] -> code `shouldBe` "judge_disabled"
          ns -> expectationFailure ("預期恰一則 note,拿到 " <> show ns)

    it "候選為空清單時 runner 沒被呼叫,jrNotes == []" $
      withVault $ \env -> do
        (result, calls) <- runFacade env defaultConflictOpts []
        calls `shouldBe` []
        jrNotes result `shouldBe` []
        jrJudged result `shouldBe` 0

-- 世界 -------------------------------------------------------------------------

-- | 三個 canon 片段,summary 與 body 內容可區分。
threeCandidates :: Env -> IO [Candidate]
threeCandidates env = do
  a <- newE env (entityOf "甲" "甲的摘要" "甲的完整正文,比摘要長得多")
  b <- newE env (entityOf "乙" "乙的摘要" "乙的完整正文,比摘要長得多")
  c <- newE env (entityOf "丙" "丙的摘要" "丙的完整正文,比摘要長得多")
  pure
    [ candidateOf (metaOf' a "甲" "甲的摘要")
    , candidateOf (metaOf' b "乙" "乙的摘要")
    , candidateOf (metaOf' c "丙" "丙的摘要")
    ]

entityOf :: Text -> Text -> Text -> NewEntityReq
entityOf title summary body =
  NewEntityReq
    { nerType = "character"
    , nerTitle = title
    , nerSummary = summary
    , nerBody = body
    , nerTags = []
    , nerAliases = []
    , nerStatus = Canon
    , nerTimeline = emptyTimeline
    , nerLinks = []
    , nerSource = Human
    }

-- | 用真正配到的 id 重建一份 Meta,供 Candidate 使用(candidateOf 只讀
-- caMeta,不需要完整重讀 Entity)。
metaOf' :: Id -> Text -> Text -> Meta
metaOf' i title summary = (metaOf (renderId i) title) {metaSummary = summary, metaId = i}

candidateOf :: Meta -> Candidate
candidateOf m = Candidate {caMeta = m, caSnippet = metaSummary m, caScore = 1, caOrigin = FromKeyword "測試"}

-- | 不需要真的存在於 Vault 的候選:只用在 @coExpandBody = False@ 的路徑
-- (budget / facade 測試),那條路徑不呼叫 'getEntity'。
dummyCandidate :: Int -> Candidate
dummyCandidate n =
  candidateOf ((metaOf idText name) {metaSummary = name <> "的摘要"})
  where
    idText = "ent-a" <> T.pack (show n)
    name = "候選" <> T.pack (show n)

jtId0 :: Candidate -> Id
jtId0 = metaId . caMeta

runS :: Env -> ServiceM a -> IO a
runS env m = orDie =<< runService env m

orDie :: Either ServiceError a -> IO a
orDie = either (fail . show) pure

newE :: Env -> NewEntityReq -> IO Id
newE env req = evId <$> runS env (createEntity req)

-- | 假 runner + 呼叫紀錄,套上 'judgeCandidatesWith' 跑真 'ServiceM'。
-- 每次呼叫都回傳「判定為矛盾」的合法 JSON,用來數呼叫次數與 jrJudged。
runFacade :: Env -> ConflictOpts -> [Candidate] -> IO (JudgeResult, [[Message]])
runFacade env opts cs = do
  callsRef <- newIORef []
  result <- runS env (judgeCandidatesWith (stubRunner callsRef) opts (Draft "草稿" []) cs)
  calls <- readIORef callsRef
  pure (result, calls)

stubRunner :: IORef [[Message]] -> [Message] -> ServiceM (Either LlmError Text)
stubRunner callsRef msgs = do
  liftIO (modifyIORef' callsRef (++ [msgs]))
  pure (Right "{\"contradicts\":true,\"confidence\":0.9,\"reason\":\"理由\"}")

-- 環境 -------------------------------------------------------------------------

-- | 臨時目錄 + 已建好並登記的 Vault + 開好的 'Env'。與
-- "StoryFlow.Conflict.RetrievalEnvSpec" 的 @withVault@ 是同一份寫法。
withVault :: (Env -> IO a) -> IO a
withVault act =
  withSystemTempDirectory "storyflow-conflict-judge" $ \dir -> do
    reg <- registryDir
    withEnvVars
      [ ("STORYFLOW_VAULTS", dir </> "vaults.toml")
      , ("STORYFLOW_REGISTRY", reg)
      ]
      $ do
        _ <- orDie =<< createVault dir "liftgame"
        bracket (fst <$> (orDie =<< openEnv Nothing dir)) closeEnv act

registryDir :: IO FilePath
registryDir = go ["../types/registry", "types/registry", "../../types/registry"]
  where
    go [] = fail "找不到 types/registry/;整合測試需要真正的型別註冊表"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

withEnvVars :: [(String, String)] -> IO a -> IO a
withEnvVars vars act = bracket save restore (const act)
  where
    save = mapM apply vars
    apply (k, v) = do
      old <- lookupEnv k
      setEnv k v
      pure (k, old)
    restore = mapM_ (\(k, mv) -> maybe (unsetEnv k) (setEnv k) mv)
