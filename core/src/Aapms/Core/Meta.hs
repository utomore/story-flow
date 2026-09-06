-- | 統一 Meta:'Entity' / 'Asset' / 'Pack' / 'License' / 'Level' / 'Node' 共用同一組
-- 欄位(ADR-012)。
--
-- 統一的用意是抽象與管理成本只付一次——索引表、API 序列化、CLI 輸出、
-- 檢索、衝突偵測、專案產出對同一組欄位工作。
module Aapms.Core.Meta
  ( -- * 型別鍵與版本
    TypeKey (..)
  , Revision (..)

    -- * 狀態
  , Status (..)
  , renderStatus
  , parseStatus

    -- * 來源
  , Source (..)
  , SourceName
  , mkSourceName
  , sourceNameText
  , renderSource
  , parseSource

    -- * 時間軸
  , Timeline (..)

    -- * Meta
  , Meta (..)
  , metaFieldNames
  , bumpRevision
  , isCanon

    -- * 待接手的型別骨架(#2 checkMeta 的回傳型別)
  , MetaWarning (..)

    -- * 錯誤
  , MetaError (..)
  ) where

import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)
import Aapms.Core.Id (Id, VaultId)
import Aapms.Core.Link (Link)

-- | 註冊表鍵,如 @character-fragment@ / @asset-image@。@level@ / @asset-pack@ /
-- @asset-license@ 是引擎保留鍵(registry-family-and-naming/#2 的載入層負責擋)。
newtype TypeKey = TypeKey Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | 樂觀鎖用的版本號,從 1 起算,只透過 'bumpRevision' 遞增。
newtype Revision = Revision Int
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | 只有 'Canon' 參與衝突偵測的比對基準。草稿不該被拿來當「過去的設定」比對,
-- 否則每個未定案的想法都會製造假衝突。'Missing' 是 asset 專屬狀態(ADR-012):
-- pack.md 條目仍在,但掃描器找不到對應檔案。
data Status
  = Draft
  | Canon
  | Deprecated
  | Missing
  deriving stock (Show, Eq, Ord, Enum, Bounded)

renderStatus :: Status -> Text
renderStatus = \case
  Draft -> "draft"
  Canon -> "canon"
  Deprecated -> "deprecated"
  Missing -> "missing"

parseStatus :: Text -> Either MetaError Status
parseStatus t = case t of
  "draft" -> Right Draft
  "canon" -> Right Canon
  "deprecated" -> Right Deprecated
  "missing" -> Right Missing
  _ -> Left (UnknownStatus t)

-- | 帶 payload 的 'Source' 的名字部分:__非空__的文字。
--
-- 建構子不匯出,唯一的檢查入口是 'mkSourceName'(字面值另有 'IsString')。
-- 空名字寫出去是 @source: \"agent:\"@,而 'parseSource' 不接受它——非法狀態
-- 由型別擋掉,不留給序列化往返(P-025-md-document 的 REV-1)。
--
-- 判定與 'parseSource' 一致:只拒絕空字串,不拒絕全空白。
newtype SourceName = SourceName Text
  deriving stock (Show, Eq, Ord)

-- | 非空才是 'Just'。
mkSourceName :: Text -> Maybe SourceName
mkSourceName t
  | T.null t = Nothing
  | otherwise = Just (SourceName t)

sourceNameText :: SourceName -> Text
sourceNameText (SourceName t) = t

-- | __只給字面值用__。@fromString ""@ 會 'error'——編譯期寫得出來的常數不該
-- 逼呼叫端拆 'Maybe';執行期來的文字一律走 'mkSourceName'。
instance IsString SourceName where
  fromString s = case mkSourceName (T.pack s) of
    Just n -> n
    Nothing -> error "Aapms.Core.Meta.SourceName: 空字串不是合法的 source 名字"

-- | 誰寫的。追溯用,也是工作坊、AI Agent 與掃描器產出的區分依據。
data Source
  = Human
  | -- | @agent:claude-code@ / @agent:codex@
    Agent SourceName
  | -- | @workshop:character@
    Workshop SourceName
  | -- | 由掃描器發現(assetdb 匯入的素材大多是這個)
    Scan
  | -- | @ai:\<model\>@,AI 直接產出而非經 Agent 工具鏈
    Ai SourceName
  deriving stock (Show, Eq, Ord)

renderSource :: Source -> Text
renderSource = \case
  Human -> "human"
  Agent t -> "agent:" <> sourceNameText t
  Workshop t -> "workshop:" <> sourceNameText t
  Scan -> "scan"
  Ai t -> "ai:" <> sourceNameText t

parseSource :: Text -> Either MetaError Source
parseSource t
  | t == "human" = Right Human
  | t == "scan" = Right Scan
  | Just rest <- T.stripPrefix "agent:" t, Just n <- mkSourceName rest = Right (Agent n)
  | Just rest <- T.stripPrefix "workshop:" t, Just n <- mkSourceName rest = Right (Workshop n)
  | Just rest <- T.stripPrefix "ai:" t, Just n <- mkSourceName rest = Right (Ai n)
  | otherwise = Left (BadSource t)

-- | 故事內時間點。字串可模糊(「崩塌前後」),選配的整數供排序與時序過濾。
-- 「這個節點根本沒有時間軸」由 'Meta' 的 @Maybe Timeline@ 表達,本型別內部
-- 不再需要一個「兩欄皆空」的哨兵值。
data Timeline = Timeline
  { tlLabel :: Maybe Text
  , tlOrder :: Maybe Int
  }
  deriving stock (Show, Eq, Ord)

-- | 逐欄對應 system.md 的欄位表,六種節點共用(ADR-012)。
--
-- 'metaType' 刻意是 'TypeKey' 而非封閉 enum:ADR-005 的宣告式註冊表要求 core
-- 不認識任何具體型別。合法性由註冊表純驗證(registry-family-and-naming/#2)在
-- 載入後檢查,不由編譯器檢查——這是明確買下的取捨。
data Meta = Meta
  { metaId :: Id
  , metaVault :: VaultId
  , metaType :: TypeKey
  , metaTitle :: Text
  , metaSummary :: Text
  , metaTags :: [Text]
  , metaStatus :: Status
  , metaTimeline :: Maybe Timeline
  , metaAliases :: [Text]
  , metaLinks :: [Link]
  , metaSource :: Source
  , metaRevision :: Revision
  , metaCreated :: Day
  , metaUpdated :: Day
  }
  deriving stock (Show, Eq)

-- | 'Meta' 的全部欄位名(序列化與型別註冊表使用的名稱,非 Haskell 欄位名)。
--
-- 型別純驗證(registry-family-and-naming/#2)以這份清單判斷型別宣告裡的
-- @fields@ 是否寫錯欄位名。新增 'Meta' 欄位時這裡也要加——順序與 system.md
-- 的欄位表一致。
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
    { metaRevision = bump (metaRevision m)
    , metaUpdated = today
    }
  where
    bump (Revision n) = Revision (n + 1)

-- | 衝突偵測的比對基準過濾器。
isCanon :: Meta -> Bool
isCanon m = metaStatus m == Canon

-- | 型別純驗證(registry-family-and-naming/#2)的警告種類。
--
-- __待確認假設 A1__:本型別的確切建構子清單由 F001 依 #2 契約卡驗收標準文字
-- (「'checkMeta' 對 asset 檢查 @name@ 第一段在該型別的 @name_kinds@ 內、關聯在
-- @allowed_links@ 內」)反推的最小合理形狀;'checkMeta' 本身的呼叫邏輯留給 #2。
data MetaWarning
  = -- | 型別鍵、缺少的必填欄位名
    MissingRequiredField TypeKey Text
  | -- | 型別鍵、不在 @allowed_links@ 內的關聯名
    LinkNotAllowed TypeKey Text
  | -- | 節點的 type 不在註冊表內
    UnknownNodeType TypeKey
  | -- | 型別鍵、不在 @name_kinds@ 內的命名第一段
    NameKindNotAllowed TypeKey Text
  deriving stock (Show, Eq)

data MetaError
  = UnknownStatus Text
  | BadSource Text
  deriving stock (Show, Eq)
