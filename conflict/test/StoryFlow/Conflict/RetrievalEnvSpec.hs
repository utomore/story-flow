-- | conflict-detection/F003 T7 \/ T8 \/ T9 \/ T11:第 2 層跑在真的 Vault 上。
--
-- 建臨時 Vault __只靠 @storyflow-service@ 的門面__:@createVault@ \/ @openEnv@ \/
-- @runService@ 都在上面,@storyflow-store@ 一次都不必露臉。這正是子系統界線
-- 「所有讀取經 ServiceM」在測試端的證明——測試自己都不需要落地層。
module StoryFlow.Conflict.RetrievalEnvSpec (spec) where

import Control.Exception (bracket)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Conflict.Retrieval.Internal
import StoryFlow.Conflict.Types
import StoryFlow.Core.Id (Id, Ref (..), localRef, parseId, renderId)
import StoryFlow.Core.Link (Link (..), LinkKind (Involves, OccursIn, PartOf, References))
-- @Status@ 的 @Draft@ 建構子與 'StoryFlow.Conflict.Types.Draft' 同名,
-- 所以 core 的 'Status' 走 qualified。
import StoryFlow.Core.Meta (Meta (..), Source (Human), Timeline (..), emptyTimeline)
import qualified StoryFlow.Core.Meta as CM
import StoryFlow.Service
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "T7 rrScanned 含被 timeline 剔除的候選" $ do
    it "開了 window 之後候選變少,但 rrScanned 不變" $
      withVault $ \env -> do
        anchor <- newE env (entity "character" "錨點" "草稿已經引用的起點") {nerTimeline = at 10}
        mapM_
          (\(t, o) -> newE env (echo t o))
          [("殘響甲", 10), ("殘響乙", 12), ("殘響丙", 40)]

        wide <- runS env (retrieveCandidates opts {coTimelineWindow = Nothing} (draft [anchor]))
        length (rrCandidates wide) `shouldBe` 3

        narrow <- runS env (retrieveCandidates opts {coTimelineWindow = Just 2} (draft [anchor]))
        -- 基準點是 10,window 是 2:殘響丙(40)被剔除。
        -- 這裡只看集合,排序本身由 T9 那一節驗(排序鍵是分數,不是標題)
        sort (map title (rrCandidates narrow)) `shouldBe` ["殘響乙", "殘響甲"]
        -- 過濾發生在 SQL 之後、截斷之前,所以掃過的數量不受它影響
        rrScanned narrow `shouldBe` rrScanned wide

    it "沒有基準點時不過濾(而不是全部剔除)" $
      withVault $ \env -> do
        mapM_ (\(t, o) -> newE env (echo t o)) [("殘響甲", 10), ("殘響丙", 40)]
        r <- runS env (retrieveCandidates opts {coTimelineWindow = Just 1} (draft []))
        length (rrCandidates r) `shouldBe` 2

    it "drRefs 帶一個不存在的 id 時不失敗" $
      withVault $ \env -> do
        anchor <- newE env (entity "character" "錨點" "起點") {nerTimeline = at 10}
        _ <- newE env (echo "殘響甲" 10)
        r <-
          runS env $
            retrieveCandidates
              opts {coTimelineWindow = Just 2}
              (draft [anchor, idOf "ent-deadbeef"])
        map title (rrCandidates r) `shouldBe` ["殘響甲"]

  describe "T8 partOf / occursIn 一跳擴充" $ do
    it "帶得進 partOf / occursIn 的本地 canon 目標,並標得出來源" $
      withVault $ \env -> do
        w <- expansionWorld env
        r <- runS env (retrieveCandidates opts (grudgeDraft []))

        sort (map title (rrCandidates r)) `shouldBe` sort ["與塔主的過節", "琳達", "白塔"]
        lookup "琳達" (origins r) `shouldBe` Just (FromExpansion (wGrudge w) PartOf)
        lookup "白塔" (origins r) `shouldBe` Just (FromExpansion (wGrudge w) OccursIn)

    it "involves / references 的目標不被帶入" $
      withVault $ \env -> do
        _ <- expansionWorld env
        r <- runS env (retrieveCandidates opts (grudgeDraft []))
        map title (rrCandidates r) `shouldNotContain` ["路人甲"]

    it "draft 狀態的擴充目標被丟棄" $
      withVault $ \env -> do
        _ <- expansionWorld env
        r <- runS env (retrieveCandidates opts (grudgeDraft []))
        map title (rrCandidates r) `shouldNotContain` ["被埋起來的祕密"]

    it "跨 Vault 的 linkTarget 不被展開(這一層只存不解析)" $
      withVault $ \env -> do
        _ <- expansionWorld env
        r <- runS env (retrieveCandidates opts (grudgeDraft []))
        -- 跨 Vault 的目標在本地根本查不到,硬撈只會拿到 EntityNotFound
        map ident (rrCandidates r) `shouldNotContain` [renderId foreignId]

    it "擴充候選的 caSnippet 就是 metaSnippet(conflict-detection/F004 T2:規則只有一份)" $
      withVault $ \env -> do
        -- F004 把 expandOneHop 內部的 snippetOf 提升成公開的 metaSnippet 讓
        -- 第 1 層共用。這一條釘住「提升之後兩處仍然是同一個答案」——
        -- 不然規則就變成兩份,而其中一份會先過期。
        _ <- expansionWorld env
        r <- runS env (retrieveCandidates opts (grudgeDraft []))
        let expanded = [c | c <- rrCandidates r, isExpansion (caOrigin c)]
        expanded `shouldSatisfy` not . null
        map caSnippet expanded `shouldBe` map (metaSnippet . caMeta) expanded

    it "擴充候選的分數嚴格小於它的母候選" $
      withVault $ \env -> do
        _ <- expansionWorld env
        r <- runS env (retrieveCandidates opts (grudgeDraft []))
        let scoreOfTitle t = lookup t [(title c, caScore c) | c <- rrCandidates r]
        scoreOfTitle "與塔主的過節" `shouldSatisfy` (> scoreOfTitle "琳達")
        scoreOfTitle "琳達" `shouldBe` scoreOfTitle "白塔"

    it "只做一跳:兩跳外的片段不出現" $
      withVault $ \env -> do
        _ <- expansionWorld env
        r <- runS env (retrieveCandidates opts (grudgeDraft []))
        map title (rrCandidates r) `shouldNotContain` ["更深的一層"]

  describe "T9 topN 控制輸出且排序確定" $ do
    it "coTopN = 3 時恰 3 筆,而 rrScanned 記得掃過 8 筆" $
      withVault $ \env -> do
        echoWorld env
        r <- runS env (retrieveCandidates opts {coTopN = 3} collapseDraft)
        length (rrCandidates r) `shouldBe` 3
        rrScanned r `shouldSatisfy` (>= 8)

    it "連跑兩次結果逐筆相同(全序)" $
      withVault $ \env -> do
        echoWorld env
        first_ <- runS env (retrieveCandidates opts collapseDraft)
        again <- runS env (retrieveCandidates opts collapseDraft)
        again `shouldBe` first_

    it "分數遞減,同分依 id 字典序" $
      withVault $ \env -> do
        echoWorld env
        r <- runS env (retrieveCandidates opts collapseDraft)
        let keys = [(negate (caScore c), ident c) | c <- rrCandidates r]
        keys `shouldBe` sort keys

    it "coTopN = 0 回空候選,但 rrScanned 照樣記錄" $
      withVault $ \env -> do
        echoWorld env
        r <- runS env (retrieveCandidates opts {coTopN = 0} collapseDraft)
        -- 「你把上限設成 0」和「什麼都沒撈到」是兩件事
        rrCandidates r `shouldBe` []
        rrScanned r `shouldSatisfy` (> 0)

    it "rrKeywords 非空,且與 defaultKeywordStrategy 的輸出一致" $
      withVault $ \env -> do
        echoWorld env
        r <- runS env (retrieveCandidates opts collapseDraft)
        idx <- runS env (aliasIndex emptyFilter {efStatus = Just CM.Canon})
        rrKeywords r `shouldSatisfy` not . null
        rrKeywords r
          `shouldBe` runKeywordStrategy defaultKeywordStrategy idx (drText collapseDraft)

  describe "T11 換策略只換一個值" $ do
    it "換一個 KeywordStrategy 就換掉候選集合,其餘模組零改動" $
      withVault $ \env -> do
        strategyWorld env
        byDefault <- runS env (retrieveCandidates opts bladeDraft)
        map title (rrCandidates byDefault) `shouldBe` ["甲"]

        stubbed <- runS env (retrieveCandidatesWith (stub ["埃提亞崩塌"]) opts bladeDraft)
        map title (rrCandidates stubbed) `shouldBe` ["乙"]
        rrKeywords stubbed `shouldBe` ["埃提亞崩塌"]

    it "回傳空清單的 stub 得到空候選,rrScanned 是 0" $
      withVault $ \env -> do
        strategyWorld env
        r <- runS env (retrieveCandidatesWith (stub []) opts bladeDraft)
        rrCandidates r `shouldBe` []
        rrScanned r `shouldBe` 0
        rrKeywords r `shouldBe` []

-- 世界 -------------------------------------------------------------------------

-- | 第 2 層的預設選項:@coTopN = 20@、不做 timeline 過濾。
opts :: ConflictOpts
opts = defaultConflictOpts

-- | 一批都會命中同一個關鍵詞的片段;正文含「埃提亞崩塌」。
echo :: Text -> Int -> NewEntityReq
echo t o =
  (entity "character" t "崩塌之後的一段殘響")
    { nerBody = "那一天之後,埃提亞崩塌的餘波還在。"
    , nerTimeline = at o
    }

echoWorld :: Env -> IO ()
echoWorld env =
  mapM_
    (\n -> newE env (echo (T.pack ("殘響" <> show n)) n))
    [1 .. 8 :: Int]

collapseDraft :: Draft
collapseDraft = Draft "埃提亞崩塌,然後呢?" []

-- | 一跳擴充用的世界。@grudge@ 是唯一被關鍵詞命中的片段,其餘全部只能靠關聯
-- 帶進來(或被規則擋掉)。
data World = World {wGrudge :: Id}

expansionWorld :: Env -> IO World
expansionWorld env = do
  linda <- newE env (entity "character" "琳達" "第七織手")
  tower <- newE env (entity "character" "白塔" "埃提亞的白塔")
  bystander <- newE env (entity "character" "路人甲" "只是路過")
  hidden <- newE env (entity "character" "被埋起來的祕密" "還沒定案") {nerStatus = CM.Draft}
  deep <- newE env (entity "character" "更深的一層" "兩跳之外")

  -- 琳達 partOf 更深的一層:琳達自己是一跳擴充帶進來的,所以「更深的一層」
  -- 在兩跳外——第 2 層不遞迴,它不該出現。
  rev <- runS env (evRevision <$> getEntity linda)
  _ <- runS env (addLink linda rev (Link PartOf (localRef deep) Nothing))

  grudge <-
    newE
      env
      (entity "character" "與塔主的過節" "琳達與白塔塔主的舊怨")
        { nerAliases = ["斷紋鎖"]
        , nerLinks =
            [ Link PartOf (localRef linda) Nothing
            , Link OccursIn (localRef tower) Nothing
            , Link Involves (localRef bystander) Nothing
            , Link References (localRef bystander) Nothing
            , Link PartOf (localRef hidden) Nothing
            , Link PartOf (Ref (Just "elsewhere") foreignId) Nothing
            ]
        }
  pure (World grudge)

-- | 只命中 @grudge@ 的別名「斷紋鎖」。
grudgeDraft :: [Id] -> Draft
grudgeDraft = Draft "斷紋鎖的下落至今不明"

foreignId :: Id
foreignId = idOf "ent-0000abcd"

-- | 換策略用的世界:兩個片段,各自只由一個別名撈得到。
strategyWorld :: Env -> IO ()
strategyWorld env = do
  _ <- newE env (entity "character" "甲" "握刀的那一位") {nerAliases = ["織紋刀"]}
  _ <- newE env (entity "character" "乙" "見證崩塌的那一位") {nerAliases = ["埃提亞崩塌"]}
  pure ()

bladeDraft :: Draft
bladeDraft = Draft "織紋刀落在雪地上" []

stub :: [Text] -> KeywordStrategy
stub kws = KeywordStrategy (\_ _ -> kws)

draft :: [Id] -> Draft
draft = Draft "埃提亞崩塌,然後呢?"

-- 觀測 -------------------------------------------------------------------------

title :: Candidate -> Text
title = metaTitle . caMeta

ident :: Candidate -> Text
ident = renderId . metaId . caMeta

origins :: RetrievalResult -> [(Text, CandidateOrigin)]
origins r = [(title c, caOrigin c) | c <- rrCandidates r]

isExpansion :: CandidateOrigin -> Bool
isExpansion = \case
  FromExpansion _ _ -> True
  FromKeyword _ -> False

-- 環境 -------------------------------------------------------------------------

-- | 臨時目錄 + 已建好並登記的 Vault + 開好的 'Env'。
--
-- 兩個環境變數與 @service@ 自己的測試底稿同一套:@STORYFLOW_VAULTS@ 指向臨時
-- 目錄(不動使用者真正的註冊表),@STORYFLOW_REGISTRY@ 指向原始碼樹的
-- @types\/registry\/@。
withVault :: (Env -> IO a) -> IO a
withVault act =
  withSystemTempDirectory "storyflow-conflict" $ \dir -> do
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

runS :: Env -> ServiceM a -> IO a
runS env m = orDie =<< runService env m

orDie :: Either ServiceError a -> IO a
orDie = either (fail . T.unpack . renderServiceError) pure

newE :: Env -> NewEntityReq -> IO Id
newE env req = evId <$> runS env (createEntity req)

entity :: Text -> Text -> Text -> NewEntityReq
entity ty t s =
  NewEntityReq
    { nerType = ty
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

at :: Int -> Timeline
at n = Timeline (Just "崩塌前後") (Just n)

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)
