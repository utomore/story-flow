-- | API 測試的樣本值。
--
-- 每個樣本都__把選配欄位填滿__。理由是 T3 要比對「@toJSON@ 的鍵集合」與
-- 「schema 的 @properties@ 鍵集合」__相等__,而 core 與 service 的 aeson 實例對
-- @Maybe@ 欄位的約定是「沒值就整個鍵不出現」——樣本留空的話,兩邊會因為鍵少了
-- 而看似不一致,測試就變成在測樣本而不是測 schema。
module StoryFlow.Api.Fixtures
  ( sampleMeta
  , sampleEntity
  , sampleLevel
  , sampleNode
  , sampleTree
  , sampleLink
  , sampleTimeline
  , sampleFieldSpec
  , sampleTypeSpec
  , sampleEntityView
  , sampleLevelView
  , sampleVaultView
  , sampleSearchHit
  , sampleLinkReport
  , sampleIndexReport
  , sampleDeleteReport
  , sampleNewEntityReq
  , sampleNewFragmentReq
  , sampleNewLevelReq
  , sampleNewNodeReq
  , sampleEntityPatch

    -- * 衝突偵測(conflict-detection/F004)
  , sampleDraft
  , sampleConflictOpts
  , sampleGraphEvidence
  , sampleGraphLayer
  , sampleRetrievalLayer
  , sampleJudgeLayer
  , sampleContextHit
  , sampleContextReq
  , idOf
  , refOf
  ) where

import Data.Text (Text)
import Data.Time (fromGregorian)
import StoryFlow.Api (ContextReq (..))
import StoryFlow.Conflict.Types
  ( ConflictOpts (..)
  , ContextHit (..)
  , Draft (..)
  , GraphEvidence (..)
  , HitLayer (..)
  )
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind (KCast, KScene))
import StoryFlow.Core.Link (Link (..), LinkKind (Contradicts, PartOf))
import StoryFlow.Core.Meta (Meta (..), Source (Human), Status (Canon), Timeline (..))
import StoryFlow.Core.Registry (EntityTypeSpec (..), FieldSpec (..))
import StoryFlow.Core.Tree (NodeTree (..))
import StoryFlow.Service

sampleTimeline :: Timeline
sampleTimeline = Timeline (Just "埃提亞崩塌前") (Just 3)

sampleLink :: Link
sampleLink = Link Contradicts (refOf "ent-91cc") (Just "對雙親死因的敘述不一致")

sampleMeta :: Meta
sampleMeta =
  Meta
    { metaId = idOf "ent-7f3a"
    , metaVault = "liftgame"
    , metaType = "character"
    , metaTitle = "琳達"
    , metaSummary = "埃提亞的第七織手"
    , metaTags = ["動機", "仇恨"]
    , metaStatus = Canon
    , metaTimeline = sampleTimeline
    , metaAliases = ["小琳", "第七織手"]
    , metaLinks = [Link PartOf (refOf "ent-7f3b") Nothing, sampleLink]
    , metaSource = Human
    , metaRevision = 3
    , metaCreated = fromGregorian 2026 8 16
    , metaUpdated = fromGregorian 2026 8 17
    }

sampleEntity :: Entity
sampleEntity = Entity sampleMeta "那年她十四歲……"

sampleLevel :: Level
sampleLevel = Level sampleMeta {metaId = idOf "lvl-3a01", metaType = "level"} (idOf "nod-0001")

-- | @parent@ 有值:根節點的 @parent@ 鍵不出現,而樣本要能覆蓋到那一欄。
sampleNode :: Node
sampleNode =
  Node
    { nodMeta = sampleMeta {metaId = idOf "nod-0002", metaType = "node"}
    , nodLevel = idOf "lvl-3a01"
    , nodParent = Just (idOf "nod-0001")
    , nodOrder = 1
    , nodKind = KCast
    , nodEntities = [refOf "ent-7f3a"]
    }

sampleTree :: NodeTree
sampleTree =
  NodeTree
    sampleNode {nodParent = Nothing, nodKind = KScene, nodMeta = (nodMeta sampleNode) {metaId = idOf "nod-0001"}}
    [NodeTree sampleNode []]

sampleFieldSpec :: FieldSpec
sampleFieldSpec = FieldSpec "summary" True "一句話說明這個片段講角色的哪一面"

sampleTypeSpec :: EntityTypeSpec
sampleTypeSpec =
  EntityTypeSpec
    { etsKey = "character-fragment"
    , etsName = "角色片段"
    , etsFields = [sampleFieldSpec]
    , etsAllowedLinks = [PartOf, Contradicts]
    , etsStages = ["定位", "外貌與舉止"]
    , etsDir = Just "characters"
    , etsOwnerType = Just "character"
    }

sampleEntityView :: EntityView
sampleEntityView = EntityView sampleEntity "characters/琳達.md" (Just "ent-7f3c") ["型別警告一則"]

sampleLevelView :: LevelView
sampleLevelView = LevelView sampleLevel sampleTree "levels/教室.md"

sampleVaultView :: VaultView
sampleVaultView = VaultView "liftgame" "/home/u/story-vaults/liftgame" (Just 42)

-- | @score@ 刻意給 'Just':'StoryFlow.Api.SchemaSpec' 的樣本要把選配欄位填滿,
-- 否則「@Maybe@ 沒值就整個鍵不出現」的約定會讓鍵集合比對假性不一致。
sampleSearchHit :: SearchHit
sampleSearchHit = SearchHit sampleMeta "……埃提亞的第七織手……" (Just 0.87)

sampleLinkReport :: LinkReport
sampleLinkReport = LinkReport [sampleLink] [(idOf "ent-7f3b", sampleLink)]

sampleIndexReport :: IndexReport
sampleIndexReport = IndexReport 12 ["characters/壞掉.md: 解析失敗"]

sampleDeleteReport :: DeleteReport
sampleDeleteReport =
  DeleteReport "characters/琳達.md" [idOf "ent-7f3a", idOf "ent-7f3b"] [(idOf "ent-9000", sampleLink)]

sampleNewEntityReq :: NewEntityReq
sampleNewEntityReq =
  NewEntityReq
    { nerType = "character"
    , nerTitle = "琳達"
    , nerSummary = "埃提亞的第七織手"
    , nerBody = "那年她十四歲……"
    , nerTags = ["動機"]
    , nerAliases = ["小琳"]
    , nerStatus = Canon
    , nerTimeline = sampleTimeline
    , nerLinks = [sampleLink]
    , nerSource = Human
    }

sampleNewFragmentReq :: NewFragmentReq
sampleNewFragmentReq =
  NewFragmentReq
    { nfrTitle = "外貌"
    , nfrSummary = "銀灰短髮"
    , nfrBody = "銀灰短髮剪到耳際……"
    , nfrType = Just "character-fragment"
    , nfrTags = ["外觀"]
    , nfrAliases = ["刺青的那個"]
    , nfrStatus = Just Canon
    , nfrTimeline = Just sampleTimeline
    , nfrLinks = [sampleLink]
    , nfrSource = Just Human
    }

sampleNewLevelReq :: NewLevelReq
sampleNewLevelReq = NewLevelReq "教室" "崩塌後的午後教室" "場景說明" "午後的教室" KScene Canon

sampleNewNodeReq :: NewNodeReq
sampleNewNodeReq = NewNodeReq "出場人物" KCast "這一場有誰" "節點正文" [sampleLink]

sampleEntityPatch :: EntityPatch
sampleEntityPatch =
  EntityPatch
    { epTitle = Just "琳達(改)"
    , epSummary = Just "改過的一句話"
    , epTags = Just ["動機"]
    , epStatus = Just Canon
    , epTimeline = Just sampleTimeline
    , epAliases = Just ["小琳"]
    , epSource = Just Human
    }

-- 衝突偵測(conflict-detection/F004) -----------------------------------------------

sampleDraft :: Draft
sampleDraft = Draft "琳達在埃提亞崩塌那年失去雙親" [idOf "ent-7f3a"]

-- | @timeline_window@ 刻意給 'Just':選配欄位沒值時整個鍵不出現,樣本留空的話
-- 'StoryFlow.Api.SchemaSpec' 的鍵集合比對會假性不一致。
sampleConflictOpts :: ConflictOpts
sampleConflictOpts =
  ConflictOpts
    { coTopN = 5
    , coJudgeN = 3
    , coExpandBody = True
    , coTimelineWindow = Just 2
    , coGraphDepth = 3
    }

sampleGraphEvidence :: GraphEvidence
sampleGraphEvidence = GraphEvidence (idOf "ent-7f3c") Contradicts (refOf "ent-91cc")

-- | 'HitLayer' 的三個建構子各一個樣本。
--
-- 它是和積型別,一個樣本只走得到一個建構子 —— 所以 schema 那一側是聯集物件,
-- 而測試比對的是__子集__而不是相等(見 'StoryFlow.Api.SchemaSpec')。
sampleGraphLayer, sampleRetrievalLayer, sampleJudgeLayer :: HitLayer
sampleGraphLayer = ByGraph sampleGraphEvidence
sampleRetrievalLayer = ByRetrieval 0.82
sampleJudgeLayer = ByJudge 0.91

sampleContextHit :: ContextHit
sampleContextHit = ContextHit sampleMeta "……埃提亞的第七織手……" sampleRetrievalLayer

sampleContextReq :: ContextReq
sampleContextReq = ContextReq sampleDraft sampleConflictOpts

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("測試裡的 ref 不合法:" <> show e)
