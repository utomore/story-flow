{-# OPTIONS_GHC -Wno-orphans #-}

-- | 業務型別的 aeson 編解碼,__集中在這一個模組__。
--
-- 與 "Aapms.Core.Json" 同一個理由的孤兒實例:CLI 的 @--json@(service-and-interfaces/F002)、
-- REST API 與 OpenAPI(service-and-interfaces/F003)、未來的 MCP 用的是同一套編碼規則,規則只該有
-- 一份。把實例散在各型別模組會讓「規則有一份」變成靠自律維持。
--
-- 編碼約定(延續 core):
--
-- * 欄位名去掉 Haskell 的前綴,多字用 snake_case
-- * @Maybe@ 欄位沒值時__整個鍵不出現__,不是 @null@
-- * @(Id, Link)@ 這種來源\/關聯配對編成 @{\"source\": …, \"link\": …}@ 物件,
--   不是二元陣列——Agent 讀得懂鍵名,讀不懂位置
module Aapms.Service.Json () where

import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Aapms.Core.Id (Id)
import Aapms.Core.Json ()
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Source (Human), Status (Draft), emptyTimeline)
import Aapms.Core.Tree (NodeTree (..))
import Aapms.Service.Types

-- | @{"source": id, "link": {...}}@ ——反向關聯與被打斷的關聯共用這個形狀。
linkPair :: (Id, Link) -> Value
linkPair (i, l) = object ["source" .= i, "link" .= l]

parseLinkPair :: Value -> Parser (Id, Link)
parseLinkPair = withObject "SourcedLink" $ \o -> (,) <$> o .: "source" <*> o .: "link"

-- | 有值才出現的鍵。
optional :: (ToJSON a) => Key -> Maybe a -> [Pair]
optional k mv = [k .= v | Just v <- [mv]]

-- View ------------------------------------------------------------------------

instance ToJSON NodeTree where
  toJSON NodeTree {..} = object ["node" .= ntNode, "children" .= ntChildren]

instance FromJSON NodeTree where
  parseJSON = withObject "NodeTree" $ \o ->
    NodeTree <$> o .: "node" <*> o .:? "children" .!= []

instance ToJSON EntityView where
  toJSON EntityView {..} =
    object $
      ["entity" .= evEntity, "path" .= evPath, "warnings" .= evWarnings]
        ++ optional "anchor" evAnchor

instance FromJSON EntityView where
  parseJSON = withObject "EntityView" $ \o ->
    EntityView
      <$> o .: "entity"
      <*> o .: "path"
      <*> o .:? "anchor"
      <*> o .:? "warnings" .!= []

instance ToJSON LevelView where
  toJSON LevelView {..} =
    object ["level" .= lvLevel, "tree" .= lvTree, "path" .= lvPath]

instance FromJSON LevelView where
  parseJSON = withObject "LevelView" $ \o ->
    LevelView <$> o .: "level" <*> o .: "tree" <*> o .: "path"

instance ToJSON VaultView where
  toJSON VaultView {..} =
    object $
      ["name" .= vvName, "root" .= vvRoot] ++ optional "entity_count" vvEntityCount

instance FromJSON VaultView where
  parseJSON = withObject "VaultView" $ \o ->
    VaultView <$> o .: "name" <*> o .: "root" <*> o .:? "entity_count"

instance ToJSON SearchHit where
  toJSON SearchHit {..} =
    object $
      ["meta" .= shMeta, "snippet" .= shSnippet] ++ optional "score" shScore

instance FromJSON SearchHit where
  parseJSON = withObject "SearchHit" $ \o ->
    SearchHit <$> o .: "meta" <*> o .: "snippet" <*> o .:? "score"

instance ToJSON LinkReport where
  toJSON LinkReport {..} =
    object
      [ "outgoing" .= lrOutgoing
      , "incoming" .= map linkPair lrIncoming
      ]

instance FromJSON LinkReport where
  parseJSON = withObject "LinkReport" $ \o ->
    LinkReport
      <$> o .:? "outgoing" .!= []
      <*> (o .:? "incoming" .!= [] >>= traverse parseLinkPair)

instance ToJSON IndexReport where
  toJSON IndexReport {..} = object ["files" .= irFiles, "issues" .= irIssues]

instance FromJSON IndexReport where
  parseJSON = withObject "IndexReport" $ \o ->
    IndexReport <$> o .: "files" <*> o .:? "issues" .!= []

instance ToJSON DeleteReport where
  toJSON DeleteReport {..} =
    object
      [ "path" .= delPath
      , "removed" .= delRemoved
      , "broken_links" .= map linkPair delBrokenLinks
      ]

instance FromJSON DeleteReport where
  parseJSON = withObject "DeleteReport" $ \o ->
    DeleteReport
      <$> o .: "path"
      <*> o .:? "removed" .!= []
      <*> (o .:? "broken_links" .!= [] >>= traverse parseLinkPair)

-- 請求 -------------------------------------------------------------------------

instance ToJSON NewEntityReq where
  toJSON NewEntityReq {..} =
    object
      [ "type" .= nerType
      , "title" .= nerTitle
      , "summary" .= nerSummary
      , "body" .= nerBody
      , "tags" .= nerTags
      , "aliases" .= nerAliases
      , "status" .= nerStatus
      , "timeline" .= nerTimeline
      , "links" .= nerLinks
      , "source" .= nerSource
      ]

instance FromJSON NewEntityReq where
  parseJSON = withObject "NewEntityReq" $ \o ->
    NewEntityReq
      <$> o .: "type"
      <*> o .: "title"
      <*> o .:? "summary" .!= ""
      <*> o .:? "body" .!= ""
      <*> o .:? "tags" .!= []
      <*> o .:? "aliases" .!= []
      <*> o .:? "status" .!= Draft
      <*> o .:? "timeline" .!= emptyTimeline
      <*> o .:? "links" .!= []
      <*> o .:? "source" .!= Human

instance ToJSON NewFragmentReq where
  toJSON NewFragmentReq {..} =
    object $
      [ "title" .= nfrTitle
      , "summary" .= nfrSummary
      , "body" .= nfrBody
      , "tags" .= nfrTags
      , "aliases" .= nfrAliases
      , "links" .= nfrLinks
      ]
        ++ optional "type" nfrType
        ++ optional "status" nfrStatus
        ++ optional "timeline" nfrTimeline
        ++ optional "source" nfrSource

instance FromJSON NewFragmentReq where
  parseJSON = withObject "NewFragmentReq" $ \o ->
    NewFragmentReq
      <$> o .: "title"
      <*> o .:? "summary" .!= ""
      <*> o .:? "body" .!= ""
      <*> o .:? "type"
      <*> o .:? "tags" .!= []
      <*> o .:? "aliases" .!= []
      <*> o .:? "status"
      <*> o .:? "timeline"
      <*> o .:? "links" .!= []
      <*> o .:? "source"

instance ToJSON NewLevelReq where
  toJSON NewLevelReq {..} =
    object
      [ "title" .= nlrTitle
      , "summary" .= nlrSummary
      , "body" .= nlrBody
      , "root_title" .= nlrRootTitle
      , "root_kind" .= nlrRootKind
      , "status" .= nlrStatus
      ]

instance FromJSON NewLevelReq where
  parseJSON = withObject "NewLevelReq" $ \o ->
    NewLevelReq
      <$> o .: "title"
      <*> o .:? "summary" .!= ""
      <*> o .:? "body" .!= ""
      <*> o .: "root_title"
      <*> o .: "root_kind"
      <*> o .:? "status" .!= Draft

instance ToJSON NewNodeReq where
  toJSON NewNodeReq {..} =
    object
      [ "title" .= nnrTitle
      , "kind" .= nnrKind
      , "summary" .= nnrSummary
      , "body" .= nnrBody
      , "links" .= nnrLinks
      ]

instance FromJSON NewNodeReq where
  parseJSON = withObject "NewNodeReq" $ \o ->
    NewNodeReq
      <$> o .: "title"
      <*> o .: "kind"
      <*> o .:? "summary" .!= ""
      <*> o .:? "body" .!= ""
      <*> o .:? "links" .!= []

instance ToJSON EntityPatch where
  toJSON EntityPatch {..} =
    object . concat $
      [ optional "title" epTitle
      , optional "summary" epSummary
      , optional "tags" epTags
      , optional "status" epStatus
      , optional "timeline" epTimeline
      , optional "aliases" epAliases
      , optional "source" epSource
      ]

instance FromJSON EntityPatch where
  parseJSON = withObject "EntityPatch" $ \o ->
    EntityPatch
      <$> o .:? "title"
      <*> o .:? "summary"
      <*> o .:? "tags"
      <*> o .:? "status"
      <*> o .:? "timeline"
      <*> o .:? "aliases"
      <*> o .:? "source"
