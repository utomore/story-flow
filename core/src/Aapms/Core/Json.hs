{-# OPTIONS_GHC -Wno-orphans #-}

-- | 全部核心型別的 aeson 編解碼,__集中在這一個模組__。
--
-- 這是刻意的孤兒實例:@meta@ 區塊(aapms-md)、SQLite 序列化(aapms-store)、
-- REST API、CLI @--json@ 用的是同一套編碼規則,規則只該有一份。把實例散在
-- 各型別模組會讓「規則有一份」變成靠自律維持。
--
-- 編碼約定:
--
-- * 'Id' / 'VaultId' / 'TypeKey' / 'Sha256' / 'LogicalName' 是__字串__,不是物件。
--   'Ref' 為 @"vault-id:id"@ 或 @"id"@
-- * 'Timeline' 兩欄皆 @Nothing@ 時整個物件是 @{}@;'Meta' 的 @metaTimeline@ 是
--   @Nothing@ 時整個 @timeline@ 鍵不出現
-- * 'Entity' \/ 'Asset' \/ 'Pack' \/ 'License' \/ 'Level' \/ 'Node' 是__扁平__的
--   ——'Meta' 的欄位與專屬欄位同一層,與 Markdown frontmatter 的形狀一致
-- * 'AnyNode' 沒有額外的判別鍵——解碼時讀 @id@ 欄位的前綴決定要用哪個節點型別
--   的 'FromJSON',id 的前綴本來就唯一對應節點種類('Aapms.Core.AnyNode.prefixOf')
module Aapms.Core.Json () where

import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Data.Text (Text)
import Aapms.Core.AnyNode (AnyNode (..))
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id
import Aapms.Core.Level (Level (..), Node (..), NodeKind, parseNodeKind, renderNodeKind)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), LinkKind, parseLinkKind, renderLinkKind)
import Aapms.Core.Meta
import Aapms.Core.Pack (AiDisclosure (..), Author (..), Pack (..))

-- 由 Either e a 產生解析錯誤時的統一訊息形狀
orFail :: (Show e) => Either e a -> Parser a
orFail = either (fail . show) pure

instance ToJSON Id where
  toJSON = String . renderId

instance FromJSON Id where
  parseJSON = withText "Id" (fmap snd . orFail . parseId)

instance ToJSON VaultId where
  toJSON (VaultId t) = String t

instance FromJSON VaultId where
  parseJSON = withText "VaultId" (pure . VaultId)

instance ToJSON Ref where
  toJSON = String . renderRef

instance FromJSON Ref where
  parseJSON = withText "Ref" (orFail . parseRef)

instance ToJSON TypeKey where
  toJSON (TypeKey t) = String t

instance FromJSON TypeKey where
  parseJSON = withText "TypeKey" (pure . TypeKey)

instance ToJSON Revision where
  toJSON (Revision n) = toJSON n

instance FromJSON Revision where
  parseJSON v = Revision <$> parseJSON v

instance ToJSON Sha256 where
  toJSON (Sha256 t) = String t

instance FromJSON Sha256 where
  parseJSON = withText "Sha256" (pure . Sha256)

instance ToJSON LogicalName where
  toJSON (LogicalName t) = String t

instance FromJSON LogicalName where
  parseJSON = withText "LogicalName" (pure . LogicalName)

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

instance ToJSON AiDisclosure where
  toJSON = String . renderAiDisclosure

instance FromJSON AiDisclosure where
  parseJSON = withText "AiDisclosure" (orFail . parseAiDisclosure)

renderAiDisclosure :: AiDisclosure -> Text
renderAiDisclosure = \case
  AiUnknown -> "unknown"
  AiNone -> "none"
  AiAssisted -> "assisted"
  AiGenerated -> "generated"

-- | 缺漏視為 'AiUnknown' 由呼叫端的 @.:? .!= AiUnknown@ 處理;這裡只認四個
-- 合法字面值,打錯字直接失敗,不悄悄吞成 unknown。
parseAiDisclosure :: Text -> Either Text AiDisclosure
parseAiDisclosure t = case t of
  "unknown" -> Right AiUnknown
  "none" -> Right AiNone
  "assisted" -> Right AiAssisted
  "generated" -> Right AiGenerated
  _ -> Left t

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

-- | 'Meta' 的欄位對,供六種節點扁平化時重用。
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
    ++ ["timeline" .= v | Just v <- [metaTimeline]]

-- | 從同一層物件解出 'Meta',供扁平化的六種節點重用。
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
    <*> o .:? "timeline"
    <*> o .:? "aliases" .!= []
    <*> o .:? "links" .!= []
    <*> o .:? "source" .!= Human
    <*> o .:? "revision" .!= Revision 1
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

instance ToJSON Asset where
  toJSON Asset {..} =
    object $
      metaPairs astMeta
        ++ [ "sha256" .= astSha256
           , "entry" .= astEntry
           , "meta" .= astKindMeta
           , "body" .= astBody
           ]
        ++ ["name" .= v | Just v <- [astName]]
        ++ ["ext" .= v | Just v <- [astExt]]
        ++ ["license" .= v | Just v <- [astLicense]]
        ++ ["author" .= v | Just v <- [astAuthor]]

instance FromJSON Asset where
  parseJSON = withObject "Asset" $ \o ->
    Asset
      <$> parseMetaFields o
      <*> o .:? "name"
      <*> o .: "sha256"
      <*> o .: "entry"
      <*> o .:? "ext"
      <*> o .:? "meta" .!= Null
      <*> o .:? "license"
      <*> o .:? "author"
      <*> o .:? "body" .!= (mempty :: Text)

instance ToJSON Author where
  toJSON Author {..} =
    object $
      ["name" .= authorName]
        ++ ["url" .= v | Just v <- [authorUrl]]
        ++ ["contact" .= v | Just v <- [authorContact]]

instance FromJSON Author where
  parseJSON = withObject "Author" $ \o ->
    Author <$> o .: "name" <*> o .:? "url" <*> o .:? "contact"

instance ToJSON Pack where
  toJSON Pack {..} =
    object $
      metaPairs pckMeta
        ++ [ "ai_disclosure" .= pckAiDisclosure
           , "body" .= pckBody
           ]
        ++ ["vendor" .= v | Just v <- [pckVendor]]
        ++ ["archive" .= v | Just v <- [pckArchive]]
        ++ ["sha256" .= v | Just v <- [pckSha256]]
        ++ ["license" .= v | Just v <- [pckLicense]]
        ++ ["author" .= v | Just v <- [pckAuthor]]
        ++ ["source_url" .= v | Just v <- [pckSourceUrl]]

instance FromJSON Pack where
  parseJSON = withObject "Pack" $ \o ->
    Pack
      <$> parseMetaFields o
      <*> o .:? "vendor"
      <*> o .:? "archive"
      <*> o .:? "sha256"
      <*> o .:? "license"
      <*> o .:? "author"
      <*> o .:? "source_url"
      <*> o .:? "ai_disclosure" .!= AiUnknown
      <*> o .:? "body" .!= (mempty :: Text)

instance ToJSON License where
  toJSON License {..} =
    object $
      metaPairs licMeta
        ++ [ "commercial" .= licCommercial
           , "attribution_required" .= licAttributionRequired
           ]
        ++ ["credit_text" .= v | Just v <- [licCreditText]]
        ++ ["modification_allowed" .= v | Just v <- [licModificationAllowed]]
        ++ ["redistribution_allowed" .= v | Just v <- [licRedistributionAllowed]]
        ++ ["resale_allowed" .= v | Just v <- [licResaleAllowed]]
        ++ ["nft_allowed" .= v | Just v <- [licNftAllowed]]
        ++ ["source_url" .= v | Just v <- [licSourceUrl]]
        ++ ["full_text" .= v | Just v <- [licFullText]]

instance FromJSON License where
  parseJSON = withObject "License" $ \o ->
    License
      <$> parseMetaFields o
      <*> o .: "commercial"
      <*> o .: "attribution_required"
      <*> o .:? "credit_text"
      <*> o .:? "modification_allowed"
      <*> o .:? "redistribution_allowed"
      <*> o .:? "resale_allowed"
      <*> o .:? "nft_allowed"
      <*> o .:? "source_url"
      <*> o .:? "full_text"

instance ToJSON AnyNode where
  toJSON = \case
    NEntity e -> toJSON e
    NAsset a -> toJSON a
    NPack p -> toJSON p
    NLicense l -> toJSON l
    NLevel lvl -> toJSON lvl
    NNode n -> toJSON n

-- | 沒有額外的判別鍵:'Aapms.Core.Id.parseId' 解出 @id@ 欄位的前綴,前綴唯一
-- 對應一種節點('Aapms.Core.AnyNode.prefixOf' 的反函式),據此挑對應的
-- 'FromJSON' 實例解碼。@vlt@ \/ @prj@ 前綴不對應任何 'AnyNode' 建構子。
instance FromJSON AnyNode where
  parseJSON v = withObject "AnyNode" dispatch v
    where
      dispatch o = do
        idText <- o .: "id"
        (prefix, _) <- orFail (parseId idText)
        case prefix of
          PEnt -> NEntity <$> parseJSON v
          PAst -> NAsset <$> parseJSON v
          PPck -> NPack <$> parseJSON v
          PLic -> NLicense <$> parseJSON v
          PLvl -> NLevel <$> parseJSON v
          PNod -> NNode <$> parseJSON v
          PVlt -> fail "AnyNode: vlt id 不對應任何節點型別"
          PPrj -> fail "AnyNode: prj id 不對應任何節點型別"
