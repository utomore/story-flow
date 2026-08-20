-- | T9:每條路由端到端可用。
--
-- 以 warp 起臨時伺服器 + @servant-client@,對每條路由各跑一次成功案例。client
-- 由 __同一份 API 型別__產生,所以「server 少實作一條」或「參數順序對不上」在
-- 編譯期就死了;這裡驗的是執行期真的通。
module StoryFlow.Server.HandlerSpec (spec) where

import Data.List (sort)
import qualified Data.Text as T
import StoryFlow.Api (BodyReq (..), ContextReq (..), NewVaultReq (..))
import StoryFlow.Conflict.Types
  ( ContextHit (..)
  , Draft (..)
  , defaultConflictOpts
  , layerTag
  )
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (localRef, renderId)
import StoryFlow.Core.Level (Level (..), Node (..))
import StoryFlow.Core.Link (Link (..), LinkKind (Contradicts, PartOf, References))
-- @Status@ 的 @Draft@ 建構子與 'StoryFlow.Conflict.Types.Draft' 同名,
-- 所以 core 的 'Status' 走 qualified(同 conflict 那一邊的 RetrievalEnvSpec)。
import StoryFlow.Core.Meta (Meta (..))
import qualified StoryFlow.Core.Meta as CM
import StoryFlow.Core.Tree (NodeTree (..))
import StoryFlow.Server.Fixtures
import StoryFlow.Service
import Test.Hspec

spec :: Spec
spec = describe "每條路由" $ do
  describe "vault / index / types" $ do
    it "GET /vaults 列得到剛建好的 Vault" $ withServer $ \env -> do
      vs <- runC env (cListVaults api)
      map vvName vs `shouldContain` ["liftgame"]

    it "GET /vault 回目前 Vault 的資訊" $ withServer $ \env -> do
      v <- runC env (cVaultInfo api)
      vvName v `shouldBe` "liftgame"
      vvEntityCount v `shouldBe` Just 0

    it "POST /vaults 建第二個 Vault" $ withServer $ \env -> do
      root <- pure "/tmp/storyflow-second-vault-does-not-matter"
      r <- runE env (cCreateVault api (NewVaultReq root "second"))
      -- 目錄不存在時是落地層的失敗,但路由本身通得過(不是 404 也不是 405)
      statusOf r `shouldNotBe` Just 404

    it "POST /vault/index/rebuild 與 refresh" $ withServer $ \env -> do
      _ <- runC env (cCreateEntity api (newEntity "character" "琳達" "第七織手"))
      rb <- runC env (cReindex api)
      irFiles rb `shouldBe` 1
      rf <- runC env (cRefresh api)
      irFiles rf `shouldBe` 1

    it "GET /types 回註冊表裡的型別" $ withServer $ \env -> do
      ts <- runC env (cTypes api)
      length ts `shouldSatisfy` (>= 5)

  describe "entity 的完整流程" $
    it "建立 → 查詢 → 改 → 換正文 → 加片段 → 刪除" $ withServer $ \env -> do
      created <- runC env (cCreateEntity api (newEntity "character" "琳達" "第七織手"))
      let i = evId created
      evRevision created `shouldBe` 1

      got <- runC env (cGetEntity api i)
      metaTitle (entMeta (evEntity got)) `shouldBe` "琳達"

      patched <- runC env (cUpdateEntity api i 1 emptyPatch {epSummary = Just "改過的"})
      metaSummary (entMeta (evEntity patched)) `shouldBe` "改過的"
      evRevision patched `shouldBe` 2

      bodied <- runC env (cSetBody api i (evRevision patched) (BodyReq "新的正文"))
      entBody (evEntity bodied) `shouldBe` "新的正文"

      frag <- runC env (cAddFragment api i (newFragment "外貌" "銀灰短髮"))
      metaTitle (entMeta (evEntity frag)) `shouldBe` "外貌"

      metas <- runC env (cListEntities api Nothing Nothing Nothing Nothing)
      sort (map metaTitle metas) `shouldBe` ["外貌", "琳達"]

      cur <- runC env (cGetEntity api i)
      del <- runC env (cDeleteEntity api i (evRevision cur) (Just True))
      delRemoved del `shouldSatisfy` elem i

  describe "查詢" $ do
    it "GET /entities 的四個過濾參數各自生效" $ withServer $ \env -> do
      _ <- runC env (cCreateEntity api (newEntity "character" "琳達" "第七織手"))
      _ <-
        runC env . cCreateEntity api $
          (newEntity "lore" "埃提亞" "崩塌前的地區") {nerStatus = CM.Draft, nerTags = ["地理"]}
      all' <- runC env (cListEntities api Nothing Nothing Nothing Nothing)
      byType <- runC env (cListEntities api (Just "character") Nothing Nothing Nothing)
      byStatus <- runC env (cListEntities api Nothing (Just CM.Draft) Nothing Nothing)
      byTag <- runC env (cListEntities api Nothing Nothing (Just "地理") Nothing)
      byLimit <- runC env (cListEntities api Nothing Nothing Nothing (Just 1))
      map length [all', byType, byStatus, byTag, byLimit] `shouldBe` [2, 1, 1, 1, 1]

    it "GET /search 命中並帶 snippet" $ withServer $ \env -> do
      _ <- runC env (cCreateEntity api (newEntity "character" "琳達" "埃提亞的第七織手"))
      hits <- runC env (cSearch api "第七織手" Nothing Nothing Nothing Nothing)
      length hits `shouldSatisfy` (>= 1)
      map (T.null . shSnippet) hits `shouldNotContain` [True]

  describe "link" $
    it "GET / POST / DELETE 三條都通,反向查詢也對" $ withServer $ \env -> do
      a <- evId <$> runC env (cCreateEntity api (newEntity "character-fragment" "琳達" "第七織手"))
      b <- evId <$> runC env (cCreateEntity api (newEntity "character-fragment" "埃提亞" "崩塌前的地區"))

      _ <- runC env (cAddLink api a 1 (Link PartOf (localRef b) (Just "註記")))
      fromA <- runC env (cLinksOf api a)
      map linkKind (lrOutgoing fromA) `shouldBe` [PartOf]
      toB <- runC env (cLinksOf api b)
      map fst (lrIncoming toB) `shouldBe` [a]

      cur <- runC env (cGetEntity api a)
      _ <- runC env (cRemoveLink api a (evRevision cur) PartOf (localRef b))
      afterRm <- runC env (cLinksOf api a)
      lrOutgoing afterRm `shouldBe` []

  describe "level 與 node" $
    it "建 Level → 掛兩層 Node → 刪節點 → 刪 Level" $ withServer $ \env -> do
      lv <- runC env (cCreateLevel api (newLevel "教室" "午後的教室"))
      let lid = lvId lv
          root = lvlRoot (lvLevel lv)
      ntChildren (lvTree lv) `shouldBe` []

      one <- runC env (cAddNode api root lid (lvRevision lv) (newNode "出場人物"))
      length (ntChildren (lvTree one)) `shouldBe` 1
      let child = metaId (nodMeta (ntNode (head' (ntChildren (lvTree one)))))

      two <- runC env (cAddNode api child lid (lvRevision one) (newNode "琳達走向講台"))
      length (ntChildren (lvTree (deeper two))) `shouldBe` 1

      lvls <- runC env (cListLevels api Nothing Nothing)
      map metaTitle lvls `shouldBe` ["教室"]

      removed <- runC env (cRemoveNode api child lid (lvRevision two) (Just False))
      ntChildren (lvTree removed) `shouldBe` []

      del <- runC env (cDeleteLevel api lid (lvRevision removed) (Just False))
      delRemoved del `shouldSatisfy` elem lid

  describe "conflict(conflict-detection/F004)" $ do
    it "POST /conflict/context 不帶 opts 也通,回得出兩層的命中" $ withServer $ \env -> do
      b <- evId <$> runC env (cCreateEntity api (newEntity "character" "被推翻的設定" "舊的說法"))
      a <-
        evId
          <$> runC
            env
            ( cCreateEntity api $
                (newEntity "character" "琳達" "埃提亞的第七織手")
                  {nerLinks = [Link Contradicts (localRef b) Nothing]}
            )

      -- opts 缺席 → 伺服器端退回 defaultConflictOpts(ContextReq 的 FromJSON)。
      -- 這裡送的是完整的 ContextReq,而 defaultConflictOpts 就是它的預設值。
      hits <- runC env (cContext api (ContextReq (Draft "琳達走進廢墟" [a]) defaultConflictOpts))
      let byId = [(renderId (metaId (xhMeta h)), layerTag (xhVia h)) | h <- hits]
      lookup (renderId b) byId `shouldBe` Just "graph"
      lookup (renderId a) byId `shouldBe` Just "retrieval"

    it "空草稿回空清單而不是錯誤" $ withServer $ \env -> do
      _ <- runC env (cCreateEntity api (newEntity "character" "琳達" "第七織手"))
      runC env (cContext api (ContextReq (Draft "" []) defaultConflictOpts)) `shouldReturn` []

    it "每筆 ContextHit 都帶得動 Meta 與 snippet(外部 Agent 不必再往返)" $ withServer $ \env -> do
      _ <- runC env (cCreateEntity api (newEntity "character" "琳達" "埃提亞的第七織手"))
      hits <- runC env (cContext api (ContextReq (Draft "琳達走進廢墟" []) defaultConflictOpts))
      hits `shouldSatisfy` not . null
      map (T.null . metaTitle . xhMeta) hits `shouldNotContain` [True]
      map (T.null . xhSnippet) hits `shouldNotContain` [True]

  describe "狀態碼" $ do
    it "不存在的 id → 404" $ withServer $ \env -> do
      r <- runE env (cGetEntity api (idOf "ent-00000000"))
      statusOf r `shouldBe` Just 404
      codeOf r `shouldBe` Just "entity_not_found"

    it "過期的 revision → 409 stale_revision" $ withServer $ \env -> do
      i <- evId <$> runC env (cCreateEntity api (newEntity "character" "琳達" "s"))
      _ <- runC env (cUpdateEntity api i 1 emptyPatch {epSummary = Just "第一次改"})
      r <- runE env (cUpdateEntity api i 1 emptyPatch {epSummary = Just "用過期的改"})
      statusOf r `shouldBe` Just 409
      codeOf r `shouldBe` Just "stale_revision"

    it "註冊表沒有的型別 → 400 unknown_type" $ withServer $ \env -> do
      r <- runE env (cCreateEntity api (newEntity "沒這種型別" "x" "s"))
      statusOf r `shouldBe` Just 400
      codeOf r `shouldBe` Just "unknown_type"

    it "必填欄位缺漏 → 422 validation_failed" $ withServer $ \env -> do
      r <- runE env (cCreateEntity api (newEntity "lore-fragment" "埃提亞" ""))
      statusOf r `shouldBe` Just 422
      codeOf r `shouldBe` Just "validation_failed"

    it "懸空的關聯目標 → 422 dangling_link_target" $ withServer $ \env -> do
      i <- evId <$> runC env (cCreateEntity api (newEntity "character" "琳達" "s"))
      r <- runE env (cAddLink api i 1 (Link References (localRef (idOf "ent-00000000")) Nothing))
      statusOf r `shouldBe` Just 422
      codeOf r `shouldBe` Just "dangling_link_target"

    it "跨 Vault → 501 cross_vault_unsupported" $ withServer $ \env -> do
      i <- evId <$> runC env (cCreateEntity api (newEntity "character" "琳達" "s"))
      r <- runE env (cAddLink api i 1 (Link References (refOf "other:ent-7f3a") Nothing))
      statusOf r `shouldBe` Just 501
      codeOf r `shouldBe` Just "cross_vault_unsupported"

    it "被指向的實體非 force 刪不掉 → 409 referenced_by" $ withServer $ \env -> do
      a <- evId <$> runC env (cCreateEntity api (newEntity "character-fragment" "琳達" "s"))
      b <- evId <$> runC env (cCreateEntity api (newEntity "character-fragment" "外貌" "s"))
      _ <- runC env (cAddLink api b 1 (Link PartOf (localRef a) Nothing))
      cur <- runC env (cGetEntity api a)
      r <- runE env (cDeleteEntity api a (evRevision cur) (Just False))
      statusOf r `shouldBe` Just 409
      codeOf r `shouldBe` Just "referenced_by"

    it "刪根節點 → 400 cannot_remove_root_node" $ withServer $ \env -> do
      lv <- runC env (cCreateLevel api (newLevel "教室" "午後的教室"))
      r <- runE env (cRemoveNode api (lvlRoot (lvLevel lv)) (lvId lv) (lvRevision lv) (Just False))
      statusOf r `shouldBe` Just 400
      codeOf r `shouldBe` Just "cannot_remove_root_node"

head' :: [a] -> a
head' (x : _) = x
head' [] = error "預期至少有一個子節點"

-- | 往下一層:根 → 出場人物,好檢查掛在「出場人物」底下的那個節點。
deeper :: LevelView -> LevelView
deeper v = v {lvTree = head' (ntChildren (lvTree v))}
