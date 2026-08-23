-- | conflict-detection/F006 T1 \/ T4 \/ T5:@check@ 這條路上第 1 層的產物、第 3 層
-- 的三種退化與連不上的升格,以及三層合流的門面。
--
-- 建臨時 Vault __只靠 @aapms-service@ 的門面__(@createVault@ \/ @openEnv@ \/
-- @runService@),@aapms-store@ 一次都不必露臉——與
-- "Aapms.Conflict.PipelineSpec" \/ "Aapms.Conflict.JudgeEnvSpec" 同一條
-- 界線。__hermetic__(D6):全程用假 runner 或直接餵 'JudgeStage',不建立任何真正
-- 指向網路端點的用戶端,不發任何網路請求(@acquireJudge@ 分支 3 只建 'Manager',
-- 不呼叫 @chat@)。
module Aapms.Conflict.CheckEnvSpec (spec) where

import Control.Exception (bracket)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Conflict.Judge (JudgeRunner, JudgeSkip (..))
import Aapms.Conflict.Pipeline
import qualified Aapms.Conflict.Retrieval as Retrieval
import Aapms.Conflict.Types
import Aapms.Core.Id (Id, localRef, parseId)
import Aapms.Core.Link (Link (..), LinkKind (Contradicts))
import Aapms.Core.Meta (Source (Human), emptyTimeline)
import qualified Aapms.Core.Meta as CM
-- 走門面 'Aapms.Llm' 而不是內部模組(閘門裁定 B-1):消費者只 import 一個
-- 名字,不必知道套件內部分了幾個模組。
import Aapms.Llm (LlmError (..), renderLlmError)
import Aapms.Service
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "第 1 層在 check 這條路上" $ do
    it "graphStage 回命中(不補 Meta)與完全沒有關聯的起點" $
      withVault $ \env -> do
        b <- newE env (entity "被推翻的設定" "舊的說法")
        a <- newE env $ (entity "琳達" "埃提亞的第七織手") {nerLinks = [Link Contradicts (localRef b) Nothing]}
        e <- newE env (entity "完全沒有關聯" "誰都不認識")

        (hits, unlinked) <- runS env (graphStage opts (Draft "" [a, e]))
        map chTarget hits `shouldContain` [b]
        map chSnippet hits `shouldBe` replicate (length hits) Nothing
        map chLayer hits `shouldSatisfy` any isByGraph
        unlinked `shouldBe` [e]

    it "drRefs 為空時兩者都是 []" $
      withVault $ \env -> do
        _ <- seedContradiction env
        runS env (graphStage opts (Draft "" [])) `shouldReturn` ([], [])

    it "graphStage 不補 Meta:懸空關聯照樣回得出命中,而 graphContextHits 會把它丟掉" $
      withVault $ \env -> do
        a <- newE env $ (entity "起點" "草稿引用的那一個") {nerLinks = [dangling]}
        (hits, _) <- runS env (graphStage opts (Draft "" [a]))
        hs2 <- runS env (graphContextHits opts (Draft "" [a]))
        hits `shouldSatisfy` (not . null)
        hs2 `shouldBe` []

  describe "第 3 層的三種退化與連不上的升格" $ do
    it "三種 JudgeSkipped 分別產出三個不同的 rnCode,後兩者的 detail 含 renderLlmError 的內容" $
      withVault $ \env -> do
        -- 沒有 drRefs(第 1 層因此不會多出一則 graph_unlinked_refs),但第 2 層
        -- 撈得到候選,才能觀察到第 3 層的退化 note。
        _ <- oneRealCandidate env
        let d = Draft "琳達走進廢墟" []
        rDisabled <- runS env (checkConflict (JudgeSkipped SkipDisabled) opts d)
        rNotConf <- runS env (checkConflict (JudgeSkipped (SkipNotConfigured LlmConfigMissing)) opts d)
        rUnreach <-
          runS env (checkConflict (JudgeSkipped (SkipUnreachable (LlmUnavailable "連線被拒"))) opts d)

        codeOf rDisabled `shouldBe` Just "judge_disabled"
        codeOf rNotConf `shouldBe` Just "judge_not_configured"
        codeOf rUnreach `shouldBe` Just "judge_unreachable"

        detailOf rNotConf `shouldBe` Just (renderLlmError LlmConfigMissing)
        detailOf rUnreach `shouldBe` Just (renderLlmError (LlmUnavailable "連線被拒"))

    it "候選為空時三種退化都不產生 note" $
      withVault $ \env -> do
        let d = Draft "" []
        rDisabled <- runS env (checkConflict (JudgeSkipped SkipDisabled) opts d)
        rNotConf <- runS env (checkConflict (JudgeSkipped (SkipNotConfigured LlmConfigMissing)) opts d)
        rUnreach <-
          runS env (checkConflict (JudgeSkipped (SkipUnreachable (LlmUnavailable "連線被拒"))) opts d)
        crNotes rDisabled `shouldBe` []
        crNotes rNotConf `shouldBe` []
        crNotes rUnreach `shouldBe` []

    it "假 runner 第一次就回 Left (LlmUnavailable …):crNotes 含 judge_unreachable 且不含 judge_aborted,crLlmUsed == False" $
      withVault $ \env -> do
        _ <- oneRealCandidate env
        let runner :: JudgeRunner ServiceM
            runner _ = pure (Left (LlmUnavailable "連不上"))
        r <- runS env (checkConflict (JudgeWith runner) opts (Draft "琳達走進廢墟" []))
        map rnCode (crNotes r) `shouldContain` ["judge_unreachable"]
        map rnCode (crNotes r) `shouldSatisfy` notElem "judge_aborted"
        crLlmUsed r `shouldBe` False

    it "第三對才連不上(前兩對成功):保留 judge_aborted、不升格,crLlmUsed == True" $
      withVault $ \env -> do
        draftText <- threeRealCandidates env
        callsRef <- liftIO (newIORef (0 :: Int))
        let runner :: JudgeRunner ServiceM
            runner _ = do
              n <- liftIO (readIORef callsRef)
              liftIO (modifyIORef' callsRef (+ 1))
              pure $
                if n < 2
                  then Right "{\"contradicts\":false,\"confidence\":0.1,\"reason\":\"\"}"
                  else Left (LlmUnavailable "連不上")
        r <- runS env (checkConflict (JudgeWith runner) opts {coJudgeN = 3} (Draft draftText []))
        map rnCode (crNotes r) `shouldContain` ["judge_aborted"]
        map rnCode (crNotes r) `shouldSatisfy` notElem "judge_unreachable"
        crLlmUsed r `shouldBe` True

  describe "acquireJudge" $ do
    it "noLlm == True 或 coJudgeN <= 0 都回 JudgeSkipped SkipDisabled,即使沒有 [llm] 段也不會變成 judge_not_configured" $
      withVault $ \env -> do
        s1 <- runS env (acquireJudge True opts)
        s2 <- runS env (acquireJudge False opts {coJudgeN = 0})
        isSkipDisabled s1 `shouldBe` True
        isSkipDisabled s2 `shouldBe` True

    it "沒有 [llm] 段時 acquireJudge False opts 回 JudgeSkipped (SkipNotConfigured LlmConfigMissing)" $
      withVault $ \env -> do
        s <- runS env (acquireJudge False opts)
        case s of
          JudgeSkipped (SkipNotConfigured LlmConfigMissing) -> pure ()
          _ -> expectationFailure "預期 JudgeSkipped (SkipNotConfigured LlmConfigMissing)"

    it "有合法 [llm] 段時回 JudgeWith(不呼叫 chat)" $
      withLlmVault $ \env -> do
        s <- runS env (acquireJudge False opts)
        isJudgeWith s `shouldBe` True

  describe "三層合流的門面" $ do
    it "報告同時含三層的命中" $
      withVault $ \env -> do
        (a, b) <- seedContradiction env
        let runner :: JudgeRunner ServiceM
            runner _ = pure (Right "{\"contradicts\":true,\"confidence\":0.9,\"reason\":\"理由\"}")
        r <- runS env (checkConflict (JudgeWith runner) opts (Draft "琳達走進廢墟" [a]))
        let layers = sort (map (layerTag . chLayer) (crHits r))
        layers `shouldContain` ["graph"]
        layers `shouldContain` ["judge"]
        map chTarget (crHits r) `shouldContain` [b]

    it "crScanned 與直接呼叫 retrieveCandidates 的值相等" $
      withVault $ \env -> do
        _ <- seedContradiction env
        rr <- runS env (Retrieval.retrieveCandidates opts (Draft "琳達走進廢墟" []))
        r <- runS env (checkConflict (JudgeSkipped SkipDisabled) opts (Draft "琳達走進廢墟" []))
        crScanned r `shouldBe` Retrieval.rrScanned rr

    it "crLlmUsed 在至少一對成功時 True,全部解析失敗時 False 且 crNotes 有 judge_parse_failed" $
      withVault $ \env -> do
        _ <- oneRealCandidate env
        let runner :: JudgeRunner ServiceM
            runner _ = pure (Right "不是 JSON")
        r <- runS env (checkConflict (JudgeWith runner) opts (Draft "琳達走進廢墟" []))
        crLlmUsed r `shouldBe` False
        map rnCode (crNotes r) `shouldContain` ["judge_parse_failed"]

    it "acquireJudge True opts >>= \\stage -> checkConflict stage 等價於直接餵 JudgeSkipped SkipDisabled" $
      withVault $ \env -> do
        -- 生產路徑(server / cli)是先 acquireJudge 再 checkConflict 兩步;這裡
        -- 斷言那兩步接起來的結果,與測試裡常用的「直接餵 JudgeSkipped」捷徑
        -- 完全等價——閘門裁定 B-2 把 checkConflict 從吃 Maybe LlmClient 改吃
        -- JudgeStage 之後,原本比較兩種簽名的這條測試改成比較兩種構造
        -- JudgeStage 的方式,驗收的東西不變:acquireJudge 的退化分支與
        -- checkConflict 的退化分支接得起來。
        _ <- seedContradiction env
        let d = Draft "琳達走進廢墟" []
        stage <- runS env (acquireJudge True opts)
        a <- runS env (checkConflict stage opts d)
        b <- runS env (checkConflict (JudgeSkipped SkipDisabled) opts d)
        a `shouldBe` b

    it "空草稿 + 空 drRefs 回 crHits == [] 且不報錯" $
      withVault $ \env -> do
        _ <- seedContradiction env
        r <- runS env (checkConflict (JudgeSkipped SkipDisabled) opts (Draft "" []))
        crHits r `shouldBe` []

    it "note 順序:第 1 層 → 第 3 層 → judge_budget → link_suggested" $
      withVault $ \env -> do
        e <- newE env (entity "完全沒有關聯" "誰都不認識")
        (a, _) <- seedContradiction env
        let runner :: JudgeRunner ServiceM
            runner _ = pure (Right "{\"contradicts\":true,\"confidence\":0.9,\"reason\":\"理由\"}")
        r <- runS env (checkConflict (JudgeWith runner) opts {coJudgeN = 1} (Draft "琳達走進廢墟" [a, e]))
        let codes = map rnCode (crNotes r)
            stageOf c
              | c == "graph_unlinked_refs" = 0 :: Int
              | c == "judge_budget" = 2
              | c == "link_suggested" = 3
              | otherwise = 1 -- judge_* 系列(F005 給什麼順序就什麼順序)
        -- sortOn 是穩定排序,同一階段內的原始相對順序因此保留。
        codes `shouldBe` sortOn stageOf codes

    it "整條路徑沒有任何寫入(跑完後 linksOf 的結果與跑之前逐筆相同)" $
      withVault $ \env -> do
        (a, _) <- seedContradiction env
        linksBefore <- runS env (linksOf a)
        _ <- runS env (checkConflict (JudgeSkipped SkipDisabled) opts (Draft "琳達走進廢墟" [a]))
        linksAfter <- runS env (linksOf a)
        linksAfter `shouldBe` linksBefore

-- 世界 -------------------------------------------------------------------------

opts :: ConflictOpts
opts = defaultConflictOpts

entity :: Text -> Text -> NewEntityReq
entity t s =
  NewEntityReq
    { nerType = "character"
    , nerTitle = t
    , nerSummary = s
    , nerBody = ""
    , nerTags = []
    , nerAliases = []
    , nerStatus = CM.Canon
    , nerTimeline = emptyTimeline
    , nerLinks = []
    , nerSource = Human
    }

-- | @a contradicts b@。回 @(a, b)@。
seedContradiction :: Env -> IO (Id, Id)
seedContradiction env = do
  b <- newE env (entity "被推翻的設定" "舊的說法")
  a <- newE env (entity "琳達" "埃提亞的第七織手") {nerLinks = [Link Contradicts (localRef b) Nothing]}
  pure (a, b)

-- | 建一個真的存在於 Vault 的候選,回它的 id(標題含「琳達」讓第 2 層撈得到)。
oneRealCandidate :: Env -> IO Id
oneRealCandidate env = newE env (entity "琳達" "埃提亞的第七織手")

-- | 建三個真的存在於 Vault 的候選,回一段__逐字包含三個標題__的草稿文字
-- ——'Aapms.Conflict.Retrieval.matchedNames' 靠「既有名稱是否出現在草稿裡」
-- 精準比對,標題本身當關鍵詞比讓 FTS5 的相關度排序碰運氣可靠。
threeRealCandidates :: Env -> IO Text
threeRealCandidates env = do
  let titles = ["候選姓名一", "候選姓名二", "候選姓名三"]
  mapM_ (\t -> newE env (entity t "殘響")) titles
  pure (T.intercalate "、" titles)

-- | 指向一個不存在的 id 的關聯。
dangling :: Link
dangling = Link Contradicts (localRef (idOf "ent-00000000")) Nothing

isByGraph :: HitLayer -> Bool
isByGraph (ByGraph _) = True
isByGraph _ = False

isSkipDisabled :: JudgeStage -> Bool
isSkipDisabled (JudgeSkipped SkipDisabled) = True
isSkipDisabled _ = False

isJudgeWith :: JudgeStage -> Bool
isJudgeWith (JudgeWith _) = True
isJudgeWith _ = False

-- | 拿報告裡__唯一一則__ note 的 code \/ detail(候選只有一個時第 3 層的退化
-- note 恰好一則,拿來斷言最直接)。
codeOf :: ConflictReport -> Maybe Text
codeOf r = case crNotes r of
  [n] -> Just (rnCode n)
  _ -> Nothing

detailOf :: ConflictReport -> Maybe Text
detailOf r = case crNotes r of
  [n] -> Just (rnDetail n)
  _ -> Nothing

-- 觀測 -------------------------------------------------------------------------

runS :: Env -> ServiceM a -> IO a
runS env m = orDie =<< runService env m

orDie :: Either ServiceError a -> IO a
orDie = either (fail . T.unpack . renderServiceError) pure

newE :: Env -> NewEntityReq -> IO Id
newE env req = evId <$> runS env (createEntity req)

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

-- 環境 -------------------------------------------------------------------------

withVault :: (Env -> IO a) -> IO a
withVault act =
  withSystemTempDirectory "aapms-conflict-check" $ \dir -> do
    reg <- registryDir
    withEnvVars
      [ ("STORYFLOW_VAULTS", dir </> "vaults.toml")
      , ("STORYFLOW_REGISTRY", reg)
      ]
      $ do
        _ <- orDie =<< createVault dir "liftgame"
        bracket (fst <$> (orDie =<< openEnv Nothing dir)) closeEnv act

-- | 帶合法 @[llm]@ 段的臨時 Vault,@base_url@ 指向一個保證連不上的位址
-- ——@acquireJudge@ 分支 3 只建 'Manager',不呼叫 @chat@,連得到連不到都不影響
-- 這條測試。
withLlmVault :: (Env -> IO a) -> IO a
withLlmVault act =
  withSystemTempDirectory "aapms-conflict-check-llm" $ \dir -> do
    reg <- registryDir
    withEnvVars
      [ ("STORYFLOW_VAULTS", dir </> "vaults.toml")
      , ("STORYFLOW_REGISTRY", reg)
      ]
      $ do
        _ <- orDie =<< createVault dir "liftgame"
        -- 用 appendFile 而不是 readFile → writeFile:同一個檔案先讀再寫在
        -- Windows 上會撞上「resource busy」(String 版 readFile 是惰性的,
        -- handle 還沒真正關閉 writeFile 就搶著開)。
        appendFile
          (dir </> ".storyflow" </> "config.toml")
          "\n[llm]\nbase_url = \"http://127.0.0.1:1/v1\"\nmodel = \"m\"\n"
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
