-- | 工作坊「定案之後」的那一段(llm-workshop-mcp/F003):把 'Session' 的
-- 'wsPending' 寫進圖譜。
--
-- __一次定案產出的是多個片段 Entity,不是一份設計文件__——這是工作坊相對
-- design-studio 的關鍵差異。首次 'commitStage' 用 'createEntity' 建一份主題檔
-- (記進 'wsOwner'),之後每次定案用 'addFragment' 往同一份加節。
--
-- __不直接碰 @storyflow-store@__:寫入走與 CLI 相同的 'ServiceM' 操作
-- ('createEntity' \/ 'addFragment' \/ 'listEntityTypes'),落地失敗照樣講
-- 'ServiceError' 那套話;'WorkshopError' 只講工作坊自己的失敗
-- ('WsNothingToCommit' \/ 'WsMissingRequiredField')。
module StoryFlow.Workshop.Emit
  ( commitStage
  ) where

import Data.List (find, nub)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, localRef)
import StoryFlow.Core.Link (Link (..), LinkKind (PartOf))
import StoryFlow.Core.Meta (Source (..), Status (Draft), Timeline (..), emptyTimeline)
import StoryFlow.Core.Registry (EntityTypeSpec (..), FieldSpec (..))
import StoryFlow.Service
  ( EntityView (..)
  , NewEntityReq (..)
  , NewFragmentReq (..)
  , ServiceError (UnknownType)
  , ServiceM
  , addFragment
  , createEntity
  , evId
  , listEntityTypes
  )
import Control.Monad.Except (throwError)
import StoryFlow.Workshop.Error (WorkshopError (..))
import StoryFlow.Workshop.Session (Session (..), StageDraft (..), saveSession)

-- | 把目前階段定案的草稿(@wsPending@)寫進圖譜。
--
-- 三段短路,依序檢查:
--
-- 1. @wsPending@ 是空的 → 'WsNothingToCommit',不呼叫任何 service 操作
-- 2. 必填欄位缺了(對照型別註冊表)→ 'WsMissingRequiredField',同樣一個
--    @createEntity@\/@addFragment@ 都不呼叫
-- 3. 通過檢查 → 決定主體 id(首次建立、之後沿用)→ 逐筆寫片段 → 存新快照
commitStage :: Session -> ServiceM (Either WorkshopError (Session, [EntityView]))
commitStage session
  | null (wsPending session) = pure (Left (WsNothingToCommit (wsId session)))
  | otherwise =
      checkRequiredFields session >>= \case
        Just werr -> pure (Left werr)
        Nothing -> do
          (ownerId, mOwnerView) <- resolveOwner session
          fragViews <- commitDrafts ownerId session
          -- 待確認假設 A4:首次定案(mOwnerView 為 Just)回傳的 [EntityView]
          -- 含主體 + 全部片段;之後定案(mOwnerView 為 Nothing)只有片段。
          -- wsCommitted 只累加片段 id(不含 ownerId),owner 已單獨記在
          -- wsOwner。
          let views = maybe fragViews (: fragViews) mOwnerView
              newSession =
                session
                  { wsOwner = Just ownerId
                  , wsPending = []
                  , wsCommitted = wsCommitted session ++ map evId fragViews
                  , wsCurrent = wsCurrent session + 1
                  }
          saveSession newSession >>= \case
            Left werr -> pure (Left werr)
            Right () -> pure (Right (newSession, views))

-- 必填欄位檢查 --------------------------------------------------------------------

-- | 該型別在註冊表宣告的必填欄位名清單(逐一取 'fsRequired' 為 'True' 的
-- 'fsName')。__逐欄位名比對,不寫死 @timeline@__——新增型別或改它的必填欄位
-- 不必改這段程式。
requiredFieldNames :: EntityTypeSpec -> [Text]
requiredFieldNames spec = [fsName f | f <- etsFields spec, fsRequired f]

-- | 'StageDraft' 目前能回答的欄位;其餘 'Meta' 欄位(status\/source\/links\/id\/
-- vault\/type\/revision\/created\/updated)一律由 'commitStage' 依契約自動填
-- 滿,不受模型輸入影響,對這些欄位宣告必填恆視為滿足——唯一的例外是
-- @aliases@:'commitStage' 依契約固定填 @nfrAliases = []@,'StageDraft' 從不帶
-- 別名,恆視為不滿足(目前沒有任何型別宣告 @aliases@ 必填,這是為未來型別預先
-- 寫對的防禦性分支,不是本次驗收範圍)。
stageFieldPresent :: Text -> StageDraft -> Bool
stageFieldPresent name StageDraft {..} = case name of
  "title" -> not (T.null (T.strip sdTitle))
  "summary" -> not (T.null (T.strip sdSummary))
  "tags" -> not (null sdTags)
  "timeline" -> maybe False (\t -> isJust (tlLabel t) || isJust (tlOrder t)) sdTimeline
  "aliases" -> False
  _ -> True

-- | 寫入前的必填欄位檢查。__在 'resolveOwner'\/'commitDrafts' 之前跑__,任何一
-- 筆 'StageDraft' 缺了任何一個必填欄位就直接回錯誤,一個 'createEntity'\/
-- 'addFragment' 都不呼叫。
checkRequiredFields :: Session -> ServiceM (Maybe WorkshopError)
checkRequiredFields session = do
  specs <- listEntityTypes
  pure $ case find ((== wsType session) . etsKey) specs of
    -- 找不到規格:交給 resolveOwner 的 UnknownType 分支處理,這裡不重複判斷
    Nothing -> Nothing
    Just spec ->
      let required = requiredFieldNames spec
          missing =
            nub
              ( concatMap
                  (\d -> [n | n <- required, not (stageFieldPresent n d)])
                  (wsPending session)
              )
       in if null missing then Nothing else Just (WsMissingRequiredField (wsType session) missing)

-- 主體 -------------------------------------------------------------------------

-- | 決定主體 id:'wsOwner' 已有值直接沿用(回傳 'Nothing' 的第二個欄位——這次
-- 沒有新建主體);'Nothing' 時用 @wsPending@ 的第一筆草稿建一份主題檔(回傳
-- 'Just' 那份新建的 'EntityView',供 'commitStage' 併進回傳的 @[EntityView]@
-- ——待確認假設 A4)。
resolveOwner :: Session -> ServiceM (Id, Maybe EntityView)
resolveOwner session = case wsOwner session of
  Just oid -> pure (oid, Nothing)
  Nothing -> do
    specs <- listEntityTypes
    spec <- case find ((== wsType session) . etsKey) specs of
      Just s -> pure s
      Nothing -> throwError (UnknownType (wsType session))
    -- 不用 'head':@wsPending@ 在這裡保證非空——'commitStage' 已在呼叫
    -- 'resolveOwner' 之前對 @null (wsPending session)@ 短路過一次。
    case wsPending session of
      [] ->
        error
          "StoryFlow.Workshop.Emit.resolveOwner: wsPending 是空的,\
          \這違反 commitStage 已經檢查過的前提"
      seed : _ -> do
        let ownerType = fromMaybe (wsType session) (etsOwnerType spec)
        view <-
          createEntity
            NewEntityReq
              { nerType = ownerType
              , nerTitle = sdTitle seed
              , nerSummary = sdSummary seed
              , nerBody = ""
              , nerTags = []
              , nerAliases = []
              , nerStatus = Draft
              , nerTimeline = fromMaybe emptyTimeline (sdTimeline seed)
              , nerLinks = []
              , nerSource = Workshop (wsType session)
              }
        pure (evId view, Just view)

-- 片段 -------------------------------------------------------------------------

-- | 把 @wsPending@ 逐筆寫成片段,每筆都掛 @partOf@ 指向主體。
commitDrafts :: Id -> Session -> ServiceM [EntityView]
commitDrafts ownerId session = mapM one (wsPending session)
  where
    one d =
      addFragment
        ownerId
        NewFragmentReq
          { nfrTitle = sdTitle d
          , nfrSummary = sdSummary d
          , nfrBody = sdBody d
          , nfrType = Just (wsType session)
          , nfrTags = sdTags d
          , nfrAliases = []
          , nfrStatus = Just Draft
          , nfrTimeline = sdTimeline d
          , nfrLinks = [Link PartOf (localRef ownerId) Nothing]
          , nfrSource = Just (Workshop (wsType session))
          }
