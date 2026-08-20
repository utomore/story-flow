-- | conflict-detection/F004 T3 \/ T5:前兩層在真的 Vault 上合流。
--
-- 建臨時 Vault __只靠 @storyflow-service@ 的門面__(@createVault@ \/ @openEnv@ \/
-- @runService@),@storyflow-store@ 一次都不必露臉——這正是子系統界線
-- 「所有讀取經 ServiceM」在測試端的證明。
--
-- __完全沒有模型__:這一整檔跑得完就是驗收標準 1(「在完全沒有模型的環境跑得完」)
-- 的證明,沒有任何 stub 或旗標。
module StoryFlow.Conflict.PipelineSpec (spec) where

import Control.Exception (bracket)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Conflict.Pipeline
import StoryFlow.Conflict.Retrieval (metaSnippet)
import StoryFlow.Conflict.Types
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, localRef, parseId, renderId)
import StoryFlow.Core.Link (Link (..), LinkKind (Contradicts, Supersedes))
import StoryFlow.Core.Meta (Meta (..), Source (Human), emptyTimeline)
import qualified StoryFlow.Core.Meta as CM
import StoryFlow.Service
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "第 1 層命中補 Meta" $ do
    it "A contradicts B:drRefs = [A] 命中 B,證據三欄正確" $
      withVault $ \env -> do
        (a, b) <- contradictionWorld env
        hs <- runS env (graphContextHits opts (Draft "" [a]))

        map (renderId . metaId . xhMeta) hs `shouldBe` [renderId b]
        map xhVia hs `shouldBe` [ByGraph (GraphEvidence a Contradicts (localRef b))]

    it "snippet 走 metaSnippet(第 1 層命中的是一條關聯,沒有 FTS5 片段)" $
      withVault $ \env -> do
        (a, b) <- contradictionWorld env
        hs <- runS env (graphContextHits opts (Draft "" [a]))
        bMeta <- runS env (metaOf b)
        map xhSnippet hs `shouldBe` [metaSnippet bMeta]
        -- metaOf 的 summary 非空,所以它就是 summary 而不是 title
        map xhSnippet hs `shouldBe` [metaSummary bMeta]

    it "反向也算數:B 被 A 標了 contradicts 時,drRefs = [B] 命中 A" $
      withVault $ \env -> do
        (a, b) <- contradictionWorld env
        hs <- runS env (graphContextHits opts (Draft "" [b]))
        map (renderId . metaId . xhMeta) hs `shouldBe` [renderId a]

    it "關聯指向不存在的片段時該筆丟棄,而且不拋錯" $
      withVault $ \env -> do
        -- 這是資料錯誤(關聯指向不存在的片段)。xhMeta 不是 Maybe 是刻意的,
        -- 硬塞一個佔位 Meta 會讓外部 Agent 拿到一個 id 是 ent-00000000 的東西。
        a <- newE env (entity "character" "起點" "草稿引用的那一個") {nerLinks = [dangling]}
        hs <- runS env (graphContextHits opts (Draft "" [a]))
        hs `shouldBe` []

    it "存在的與不存在的混在一起時,只丟掉查不到的那一筆" $
      withVault $ \env -> do
        b <- newE env (entity "character" "被推翻的設定" "舊的說法")
        a <-
          newE env $
            (entity "character" "起點" "草稿引用的那一個")
              { nerLinks = [Link Contradicts (localRef b) Nothing, dangling]
              }
        hs <- runS env (graphContextHits opts (Draft "" [a]))
        map (renderId . metaId . xhMeta) hs `shouldBe` [renderId b]

    it "drRefs 為空時第 1 層回空清單(沒有起點就沒有圖可以走)" $
      withVault $ \env -> do
        _ <- contradictionWorld env
        runS env (graphContextHits opts (Draft "琳達走進廢墟" [])) `shouldReturn` []

    it "supersedes 也命中,而且證據的 kind 是 supersedes" $
      withVault $ \env -> do
        old <- newE env (entity "character" "舊版設定" "已經被推翻")
        new <-
          newE env $
            (entity "character" "新版設定" "取代舊版的那一份")
              {nerLinks = [Link Supersedes (localRef old) Nothing]}
        hs <- runS env (graphContextHits opts (Draft "" [old]))
        map (renderId . metaId . xhMeta) hs `shouldBe` [renderId new]
        map xhVia hs `shouldBe` [ByGraph (GraphEvidence new Supersedes (localRef old))]

  describe "gatherContext" $ do
    it "兩層的命中都出現在結果裡,而且 graph 排在 retrieval 之前" $
      withVault $ \env -> do
        (a, b) <- contradictionWorld env
        hs <- runS env (gatherContext opts (draft [a]))

        -- b 只由第 1 層命中(它的文字裡沒有「琳達」),a 由第 2 層命中
        lookupVia b hs `shouldBe` Just "graph"
        lookupVia a hs `shouldBe` Just "retrieval"
        map (layerTag . xhVia) hs `shouldBe` sort (map (layerTag . xhVia) hs)

    it "drRefs = [] 時只剩第 2 層,而且不報錯" $
      withVault $ \env -> do
        _ <- contradictionWorld env
        hs <- runS env (gatherContext opts (draft []))
        hs `shouldSatisfy` not . null
        map (layerTag . xhVia) hs `shouldSatisfy` all (== "retrieval")

    it "drText = \"\" 且 drRefs = [] 時回 [] 而不是報錯" $
      withVault $ \env -> do
        _ <- contradictionWorld env
        runS env (gatherContext opts (Draft "" [])) `shouldReturn` []

    it "第 2 層候選數 > coTopN 時,第 1 層的命中不被截掉" $
      withVault $ \env -> do
        (a, b) <- contradictionWorld env
        mapM_
          (\n -> newE env (entity "character" ("琳達的側寫" <> T.pack (show n)) "琳達的另一個側面"))
          [1 .. 5 :: Int]

        hs <- runS env (gatherContext opts {coTopN = 1} (draft [a]))
        -- coTopN 只約束第 2 層;第 1 層是零成本的事實,拿 topN 去砍它會砍掉
        -- 最有價值的那一批
        lookupVia b hs `shouldBe` Just "graph"
        length hs `shouldSatisfy` (>= 2)

    it "同一個片段兩層都命中時只出現一次,且 via 是 graph" $
      withVault $ \env -> do
        -- b 的文字裡也放了「琳達」,所以第 2 層也撈得到它
        b <- newE env (entity "character" "被推翻的設定" "琳達的舊說法")
        a <-
          newE env $
            (entity "character" "琳達" "埃提亞的第七織手")
              {nerLinks = [Link Contradicts (localRef b) Nothing]}
        hs <- runS env (gatherContext opts (draft [a]))
        length (filter ((== renderId b) . ident) hs) `shouldBe` 1
        lookupVia b hs `shouldBe` Just "graph"

    it "連跑兩次結果逐筆相同(全序)" $
      withVault $ \env -> do
        (a, _) <- contradictionWorld env
        first_ <- runS env (gatherContext opts (draft [a]))
        again <- runS env (gatherContext opts (draft [a]))
        again `shouldBe` first_

    it "跑完之後每個片段的 metaRevision 不變(整條路徑只有讀取)" $
      withVault $ \env -> do
        (a, _) <- contradictionWorld env
        wasBefore <- revisions env
        _ <- runS env (gatherContext opts (draft [a]))
        isAfter <- revisions env
        isAfter `shouldBe` wasBefore

-- 世界 -------------------------------------------------------------------------

opts :: ConflictOpts
opts = defaultConflictOpts

-- | 只命中 @a@ 的標題「琳達」——@b@ 的文字裡沒有它,所以 @b@ 只進得了第 1 層。
draft :: [Id] -> Draft
draft = Draft "琳達走進廢墟"

-- | @a contradicts b@。回 @(a, b)@。
contradictionWorld :: Env -> IO (Id, Id)
contradictionWorld env = do
  b <- newE env (entity "character" "被推翻的設定" "舊的說法")
  a <-
    newE env $
      (entity "character" "琳達" "埃提亞的第七織手")
        {nerLinks = [Link Contradicts (localRef b) Nothing]}
  pure (a, b)

-- | 指向一個不存在的 id 的關聯。
--
-- __由 'createEntity' 建得出來__:目標存在性的檢查在 'addLink'(它才是 service
-- 唯一會驗證關聯目標的入口),建檔那一條路徑不驗——所以這正是真實世界裡
-- 懸空關聯會出現的方式。
dangling :: Link
dangling = Link Contradicts (localRef (idOf "ent-00000000")) Nothing

-- 觀測 -------------------------------------------------------------------------

ident :: ContextHit -> Text
ident = renderId . metaId . xhMeta

lookupVia :: Id -> [ContextHit] -> Maybe Text
lookupVia i hs = lookup (renderId i) [(ident h, layerTag (xhVia h)) | h <- hs]

metaOf :: Id -> ServiceM Meta
metaOf = fmap (entMeta . evEntity) . getEntity

revisions :: Env -> IO [(Text, Int)]
revisions env = do
  ms <- runS env (listEntities emptyFilter)
  pure (sort [(renderId (metaId m), metaRevision m) | m <- ms])

-- 環境 -------------------------------------------------------------------------

-- | 臨時目錄 + 已建好並登記的 Vault + 開好的 'Env'。
withVault :: (Env -> IO a) -> IO a
withVault act =
  withSystemTempDirectory "storyflow-pipeline" $ \dir -> do
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

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)
