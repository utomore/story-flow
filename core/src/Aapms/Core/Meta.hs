-- | 統一 Meta:'Entity' / 'Level' / 'Node' 共用同一組欄位(ADR-003)。
--
-- 統一的用意是抽象與管理成本只付一次——索引表、API 序列化、CLI 輸出、
-- 衝突偵測全部對同一組欄位工作。
module Aapms.Core.Meta
  ( -- * 狀態
    Status (..)
  , renderStatus
  , parseStatus

    -- * 來源
  , Source (..)
  , renderSource
  , parseSource

    -- * 時間軸
  , Timeline (..)
  , emptyTimeline
  , isEmptyTimeline

    -- * Meta
  , Meta (..)
  , metaFieldNames
  , bumpRevision
  , isCanon

    -- * 錯誤
  , MetaError (..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)
import Aapms.Core.Id (Id)
import Aapms.Core.Link (Link)

-- | 只有 'Canon' 參與衝突偵測的比對基準。草稿不該被拿來當「過去的設定」比對,
-- 否則每個未定案的想法都會製造假衝突(ADR-003)。
data Status
  = Draft
  | Canon
  | Deprecated
  deriving stock (Show, Eq, Ord, Enum, Bounded)

renderStatus :: Status -> Text
renderStatus = \case
  Draft -> "draft"
  Canon -> "canon"
  Deprecated -> "deprecated"

parseStatus :: Text -> Either MetaError Status
parseStatus t = case t of
  "draft" -> Right Draft
  "canon" -> Right Canon
  "deprecated" -> Right Deprecated
  _ -> Left (UnknownStatus t)

-- | 誰寫的。追溯用,也是工作坊與 AI Agent 產出的區分依據。
data Source
  = Human
  | -- | @agent:claude-code@ / @agent:codex@
    Agent Text
  | -- | @workshop:character@
    Workshop Text
  deriving stock (Show, Eq, Ord)

renderSource :: Source -> Text
renderSource = \case
  Human -> "human"
  Agent t -> "agent:" <> t
  Workshop t -> "workshop:" <> t

parseSource :: Text -> Either MetaError Source
parseSource t
  | t == "human" = Right Human
  | Just rest <- T.stripPrefix "agent:" t, not (T.null rest) = Right (Agent rest)
  | Just rest <- T.stripPrefix "workshop:" t, not (T.null rest) = Right (Workshop rest)
  | otherwise = Left (BadSource t)

-- | 故事內時間點。字串可模糊(「崩塌前後」),選配的整數供排序與時序過濾。
data Timeline = Timeline
  { tlLabel :: Maybe Text
  , tlOrder :: Maybe Int
  }
  deriving stock (Show, Eq, Ord)

emptyTimeline :: Timeline
emptyTimeline = Timeline Nothing Nothing

isEmptyTimeline :: Timeline -> Bool
isEmptyTimeline t = t == emptyTimeline

-- | 逐欄對應 system.md 的欄位表。
--
-- 'metaType' 刻意是 'Text' 而非封閉 enum:ADR-005 的宣告式註冊表要求 core
-- 不認識任何具體型別。合法性由 "Aapms.Core.Registry" 在載入後檢查,
-- 不由編譯器檢查——這是明確買下的取捨。
data Meta = Meta
  { metaId :: Id
  , metaVault :: Text
  , metaType :: Text
  , metaTitle :: Text
  , metaSummary :: Text
  , metaTags :: [Text]
  , metaStatus :: Status
  , metaTimeline :: Timeline
  , metaAliases :: [Text]
  , metaLinks :: [Link]
  , metaSource :: Source
  , metaRevision :: Int
  , metaCreated :: Day
  , metaUpdated :: Day
  }
  deriving stock (Show, Eq)

-- | 'Meta' 的全部欄位名(序列化與型別註冊表使用的名稱,非 Haskell 欄位名)。
--
-- "Aapms.Core.Registry" 以這份清單判斷型別宣告裡的 @fields@ 是否寫錯欄位名。
-- 新增 'Meta' 欄位時這裡也要加——順序與 system.md 的欄位表一致。
metaFieldNames :: [Text]
metaFieldNames =
  [ "id"
  , "vault"
  , "type"
  , "title"
  , "summary"
  , "tags"
  , "status"
  , "timeline"
  , "aliases"
  , "links"
  , "source"
  , "revision"
  , "created"
  , "updated"
  ]

-- | revision + 1 且把 @updated@ 換成傳入的日期。樂觀鎖的唯一遞增點。
bumpRevision :: Day -> Meta -> Meta
bumpRevision today m =
  m
    { metaRevision = metaRevision m + 1
    , metaUpdated = today
    }

-- | 衝突偵測的比對基準過濾器。
isCanon :: Meta -> Bool
isCanon m = metaStatus m == Canon

data MetaError
  = UnknownStatus Text
  | BadSource Text
  deriving stock (Show, Eq)
