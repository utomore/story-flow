{-# OPTIONS_GHC -Wno-orphans #-}

-- | 全部核心型別的 aeson 編解碼,__集中在這一個模組__。
--
-- 這是刻意的孤兒實例:@meta@ 區塊(entity-graph-core/F003)、SQLite 序列化(entity-graph-core/F004)、
-- REST API(P3)、CLI @--json@(P2)用的是同一套編碼規則,規則只該有一份。
-- 把實例散在各型別模組會讓「規則有一份」變成靠自律維持。
--
-- 編碼約定:
--
-- * 'Id' 與 'Ref' 是__字串__,不是物件。'Ref' 為 @"vault:id"@ 或 @"id"@
-- * 'Timeline' 兩欄皆 @Nothing@ 時整個 @timeline@ 鍵不出現
-- * 'Entity' / 'Level' / 'Node' 是__扁平__的——'Meta' 的欄位與專屬欄位同一層,
--   與 Markdown frontmatter 的形狀一致
module StoryFlow.Core.Json () where

import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Data.Text (Text)
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind, parseNodeKind, renderNodeKind)
import StoryFlow.Core.Link (Link (..), LinkKind, parseLinkKind, renderLinkKind)
import StoryFlow.Core.Meta
import StoryFlow.Core.Registry (EntityTypeSpec (..), FieldSpec (..))

-- 由 Either e a 產生解析錯誤時的統一訊息形狀
orFail :: (Show e) => Either e a -> Parser a
orFail = either (fail . show) pure

instance ToJSON Id where
  toJSON = String . renderId

instance FromJSON Id where
  parseJSON = withText "Id" (fmap snd . orFail . parseId)

instance ToJSON Ref where
  toJSON = String . renderRef

instance FromJSON Ref where
  parseJSON = withText "Ref" (orFail . parseRef)

instance ToJSON Status where
  toJSON = String . renderStatus

instance FromJSON Status where
  parseJSON = withText "Status" (orFail . parseStatus)

instance ToJSON Source where
  toJSON = String . renderSource

instance FromJSON Source where
  parseJSON = withText "Source" (orFail . parseSource)

instance ToJSON NodeKind where
  toJSON = String . renderNodeKind

instance FromJSON NodeKind where
  parseJSON = withText "NodeKind" (orFail . parseNodeKind)

instance ToJSON LinkKind where
  toJSON = String . renderLinkKind

instance FromJSON LinkKind where
  parseJSON = withText "LinkKind" (pure . parseLinkKind)

instance ToJSON Timeline where
  toJSON Timeline {..} =
    object $
      concat
        [ ["label" .= v | Just v <- [tlLabel]]
        , ["order" .= v | Just v <- [tlOrder]]
        ]

instance FromJSON Timeline where
  parseJSON = withObject "Timeline" $ \o ->
    Timeline <$> o .:? "label" <*> o .:? "order"

instance ToJSON Link where
  toJSON Link {..} =
    object $
      ["kind" .= linkKind, "target" .= linkTarget]
        ++ ["note" .= v | Just v <- [linkNote]]

instance FromJSON Link where
  parseJSON = withObject "Link" $ \o ->
    Link <$> o .: "kind" <*> o .: "target" <*> o .:? "note"

instance ToJSON Meta where
  toJSON = object . metaPairs

instance FromJSON Meta where
  parseJSON = withObject "Meta" parseMetaFields

-- | 'Meta' 的欄位對,供 'Entity' / 'Level' / 'Node' 扁平化時重用。
metaPairs :: Meta -> [Pair]
metaPairs Meta {..} =
  [ "id" .= metaId
  , "vault" .= metaVault
  , "type" .= metaType
  , "title" .= metaTitle
  , "summary" .= metaSummary
  , "tags" .= metaTags
  , "status" .= metaStatus
  , "aliases" .= metaAliases
  , "links" .= metaLinks
  , "source" .= metaSource
  , "revision" .= metaRevision
  , "created" .= metaCreated
  , "updated" .= metaUpdated
  ]
    ++ ["timeline" .= metaTimeline | not (isEmptyTimeline metaTimeline)]

-- | 從同一層物件解出 'Meta',供扁平化的三種實體重用。
parseMetaFields :: Object -> Parser Meta
parseMetaFields o =
  Meta
    <$> o .: "id"
    <*> o .: "vault"
    <*> o .: "type"
    <*> o .: "title"
    <*> o .:? "summary" .!= ""
    <*> o .:? "tags" .!= []
    <*> o .:? "status" .!= Draft
    <*> o .:? "timeline" .!= emptyTimeline
    <*> o .:? "aliases" .!= []
    <*> o .:? "links" .!= []
    <*> o .:? "source" .!= Human
    <*> o .:? "revision" .!= 1
    <*> o .: "created"
    <*> o .: "updated"

instance ToJSON Entity where
  toJSON Entity {..} = object (metaPairs entMeta ++ ["body" .= entBody])

instance FromJSON Entity where
  parseJSON = withObject "Entity" $ \o ->
    Entity <$> parseMetaFields o <*> (o .:? "body" .!= (mempty :: Text))

instance ToJSON Level where
  toJSON Level {..} = object (metaPairs lvlMeta ++ ["root" .= lvlRoot])

instance FromJSON Level where
  parseJSON = withObject "Level" $ \o ->
    Level <$> parseMetaFields o <*> o .: "root"

instance ToJSON Node where
  toJSON Node {..} =
    object $
      metaPairs nodMeta
        ++ [ "level" .= nodLevel
           , "order" .= nodOrder
           , "kind" .= nodKind
           , "entities" .= nodEntities
           ]
        ++ ["parent" .= v | Just v <- [nodParent]]

instance FromJSON Node where
  parseJSON = withObject "Node" $ \o ->
    Node
      <$> parseMetaFields o
      <*> o .: "level"
      <*> o .:? "parent"
      <*> o .:? "order" .!= 0
      <*> o .: "kind"
      <*> o .:? "entities" .!= []

-- 型別註冊表 --------------------------------------------------------------------

-- | 'EntityTypeSpec' 的編碼在 P2 才需要(CLI 的 @story-flow type list --json@),
-- 但它的家仍然是這裡:@--json@、REST 的型別清單與未來 MCP 的能力宣告用的是同一份
-- 宣告,規則散成三份就會漂移。
--
-- 鍵名沿用 @types\/registry\/*.toml@ 的欄位名(@allowed_links@ \/ @owner_type@),
-- 讓讀 JSON 的人與寫 TOML 的人看到同一組字。
instance ToJSON FieldSpec where
  toJSON FieldSpec {..} =
    object ["name" .= fsName, "required" .= fsRequired, "hint" .= fsHint]

instance FromJSON FieldSpec where
  parseJSON = withObject "FieldSpec" $ \o ->
    FieldSpec <$> o .: "name" <*> o .:? "required" .!= False <*> o .:? "hint" .!= ""

instance ToJSON EntityTypeSpec where
  toJSON EntityTypeSpec {..} =
    object $
      [ "key" .= etsKey
      , "name" .= etsName
      , "fields" .= etsFields
      , "allowed_links" .= etsAllowedLinks
      , "stages" .= etsStages
      ]
        ++ ["dir" .= v | Just v <- [etsDir]]
        ++ ["owner_type" .= v | Just v <- [etsOwnerType]]

instance FromJSON EntityTypeSpec where
  parseJSON = withObject "EntityTypeSpec" $ \o ->
    EntityTypeSpec
      <$> o .: "key"
      <*> o .:? "name" .!= ""
      <*> o .:? "fields" .!= []
      <*> o .:? "allowed_links" .!= []
      <*> o .:? "stages" .!= []
      <*> o .:? "dir"
      <*> o .:? "owner_type"
