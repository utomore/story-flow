-- | T2\/T3\/T4\/T5\/T6:'StoryFlow.Workshop.Emit.commitStage'。
module StoryFlow.Workshop.EmitSpec (spec) where

import Control.Monad (forM_)
import Data.List (find)
import Data.Text (Text)
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Link (Link (..), LinkKind (PartOf))
import StoryFlow.Core.Id (localRef)
import StoryFlow.Core.Meta (Meta (..), Source (..), Status (..), Timeline (..))
import StoryFlow.Service
  ( EntityView (..)
  , emptyFilter
  , evId
  , getEntity
  , listEntities
  , runService
  )
import StoryFlow.Workshop.Emit (commitStage)
import StoryFlow.Workshop.Error (WorkshopError (..))
import StoryFlow.Workshop.Fixtures (runS, withWorkshopVault)
import StoryFlow.Workshop.Session (Session (..), StageDraft (..), loadSession)
import Test.Hspec

spec :: Spec
spec = do
  it "wsPending 為空時回 Right (Left (WsNothingToCommit sid)),Vault 沒有新增任何 Entity" $
    withWorkshopVault $ \env -> do
      countBefore <- runS env (listEntities emptyFilter)
      let session = emptySession "character-fragment"
      result <- runService env (commitStage session)
      case result of
        Right (Left (WsNothingToCommit sid)) -> sid `shouldBe` wsId session
        other -> expectationFailure ("預期 Right (Left (WsNothingToCommit _)),拿到 " <> show other)
      countAfter <- runS env (listEntities emptyFilter)
      length countAfter `shouldBe` length countBefore

  it "lore-fragment / plot-fragment 缺 timeline 時擋下,一個位元組都沒寫" $
    forM_ [("lore-fragment", "起源"), ("plot-fragment", "轉折")] $ \(ty, title) ->
      withWorkshopVault $ \env -> do
        countBefore <- runS env (listEntities emptyFilter)
        let session =
              (emptySession ty)
                { wsPending = [mkDraft title "一句話總結" "" [] Nothing]
                }
        result <- runService env (commitStage session)
        case result of
          Right (Left (WsMissingRequiredField ty' missing)) -> do
            ty' `shouldBe` ty
            missing `shouldBe` ["timeline"]
          other -> expectationFailure ("預期 Right (Left (WsMissingRequiredField _ _)),拿到 " <> show other)
        countAfter <- runS env (listEntities emptyFilter)
        length countAfter `shouldBe` length countBefore

  it "lore-fragment 給了 timeline 就寫得進去,主體與片段的 metaTimeline 對應" $
    withWorkshopVault $ \env -> do
      let tl1 = Timeline (Just "崩塌前") (Just 1)
          tl2 = Timeline (Just "崩塌後") (Just 2)
          drafts =
            [ mkDraft "起源" "一句話總結" "正文一" [] (Just tl1)
            , mkDraft "餘波" "另一句總結" "正文二" [] (Just tl2)
            ]
          session = (emptySession "lore-fragment") {wsPending = drafts}
      result <- runService env (commitStage session)
      case result of
        Right (Right (newSession, _views)) -> do
          ownerId <- case wsOwner newSession of
            Just oid -> pure oid
            Nothing -> fail "預期 wsOwner 是 Just _"
          ownerView <- runS env (getEntity ownerId)
          metaTimeline (entMeta (evEntity ownerView)) `shouldBe` tl1
          fragTimelines <- mapM (runS env . getEntity) (wsCommitted newSession)
          map (metaTimeline . entMeta . evEntity) fragTimelines `shouldBe` [tl1, tl2]
        other -> expectationFailure ("預期 Right (Right _),拿到 " <> show other)

  it "首次定案建主體:type 取 owner_type,沒有就退回型別鍵本身" $
    withWorkshopVault $ \env -> do
      result1 <- runService env (commitStage sessionForCharacter)
      case result1 of
        Right (Right (newSession, _views)) -> do
          ownerId <- case wsOwner newSession of
            Just oid -> pure oid
            Nothing -> fail "預期 wsOwner 是 Just _"
          ownerView <- runS env (getEntity ownerId)
          let m = entMeta (evEntity ownerView)
          metaType m `shouldBe` "character"
          metaStatus m `shouldBe` Draft
          metaSource m `shouldBe` Workshop "character-fragment"
        other -> expectationFailure ("預期 Right (Right _),拿到 " <> show other)
      result2 <- runService env (commitStage sessionForDialogue)
      case result2 of
        Right (Right (newSession2, _views2)) -> do
          ownerId2 <- case wsOwner newSession2 of
            Just oid -> pure oid
            Nothing -> fail "預期 wsOwner 是 Just _"
          ownerView2 <- runS env (getEntity ownerId2)
          metaType (entMeta (evEntity ownerView2)) `shouldBe` "dialogue"
        other -> expectationFailure ("預期 Right (Right _),拿到 " <> show other)

  it "片段逐筆建立:回傳的 [EntityView] 扣掉首次定案的主體那 1 筆有 3 筆" $
    withWorkshopVault $ \env -> do
      let drafts =
            [ mkDraft "外貌" "一句話總結" "正文一" [] Nothing
            , mkDraft "舉止" "另一句總結" "正文二" ["外觀"] Nothing
            , mkDraft "習慣" "第三句總結" "正文三" [] Nothing
            ]
          session = (emptySession "character-fragment") {wsPending = drafts}
      result <- runService env (commitStage session)
      case result of
        Right (Right (newSession, views)) -> do
          ownerId <- case wsOwner newSession of
            Just oid -> pure oid
            Nothing -> fail "預期 wsOwner 是 Just _"
          let fragViews = filter ((/= ownerId) . evId) views
          length fragViews `shouldBe` 3
          forM_ fragViews $ \v -> do
            let m = entMeta (evEntity v)
            metaType m `shouldBe` "character-fragment"
            metaStatus m `shouldBe` Draft
            metaSource m `shouldBe` Workshop "character-fragment"
            metaLinks m `shouldSatisfy` any (== Link PartOf (localRef ownerId) Nothing)
          -- 第一筆的 sdTimeline = Nothing(非必填欄位),片段照樣建得成、
          -- 繼承主體的 metaTimeline,commitStage 不因此擋下。
          ownerView <- runS env (getEntity ownerId)
          case find ((== "外貌") . metaTitle . entMeta . evEntity) fragViews of
            Just v -> metaTimeline (entMeta (evEntity v)) `shouldBe` metaTimeline (entMeta (evEntity ownerView))
            Nothing -> expectationFailure "找不到「外貌」片段"
        other -> expectationFailure ("預期 Right (Right _),拿到 " <> show other)

  it "session 狀態更新與快照:wsPending 清空、wsCommitted 增量、wsCurrent 前進、快照同步;再跑一次不會產生第二個主體" $
    withWorkshopVault $ \env -> do
      let drafts =
            [ mkDraft "外貌" "一句話總結" "正文一" [] Nothing
            , mkDraft "舉止" "另一句總結" "正文二" [] Nothing
            , mkDraft "習慣" "第三句總結" "正文三" [] Nothing
            ]
          session0 = (emptySession "character-fragment") {wsPending = drafts}
      result1 <- runService env (commitStage session0)
      session1 <- case result1 of
        Right (Right (s, _)) -> pure s
        other -> fail ("預期 Right (Right _),拿到 " <> show other)
      wsPending session1 `shouldBe` []
      length (wsCommitted session1) `shouldBe` length (wsCommitted session0) + 3
      wsCurrent session1 `shouldBe` wsCurrent session0 + 1
      loaded <- runService env (loadSession (wsId session1))
      case loaded of
        Right (Right s) -> s `shouldBe` session1
        other -> expectationFailure ("預期 loadSession 讀回 Right (Right _),拿到 " <> show other)

      let session1' = session1 {wsPending = [mkDraft "關係網" "第四句總結" "正文四" [] Nothing]}
      result2 <- runService env (commitStage session1')
      case result2 of
        Right (Right (session2, _)) -> wsOwner session2 `shouldBe` wsOwner session1
        other -> expectationFailure ("預期 Right (Right _),拿到 " <> show other)

  it "底稿本身可用:withWorkshopVault 建出的 Env 能被 runS 直接用,兩個 it 的臨時 Vault 互不污染" $ do
    countA <- withWorkshopVault $ \env -> length <$> runS env (listEntities emptyFilter)
    countB <- withWorkshopVault $ \env -> length <$> runS env (listEntities emptyFilter)
    countA `shouldBe` (0 :: Int)
    countB `shouldBe` (0 :: Int)

-- fixtures ---------------------------------------------------------------------

emptySession :: Text -> Session
emptySession ty =
  Session
    { wsId = "wksp-emit-test-" <> ty
    , wsType = ty
    , wsConstraints = []
    , wsStages = []
    , wsCurrent = 0
    , wsHistory = []
    , wsOwner = Nothing
    , wsPending = []
    , wsCommitted = []
    }

mkDraft :: Text -> Text -> Text -> [Text] -> Maybe Timeline -> StageDraft
mkDraft = StageDraft

sessionForCharacter :: Session
sessionForCharacter =
  (emptySession "character-fragment")
    {wsPending = [mkDraft "定位" "一句話總結" "正文" [] Nothing]}

sessionForDialogue :: Session
sessionForDialogue =
  (emptySession "dialogue")
    {wsPending = [mkDraft "情境" "一句話總結" "正文" [] Nothing]}
