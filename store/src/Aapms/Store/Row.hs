-- | 核心型別 ↔ SQLite 資料列的轉換。內部模組,不對外承諾介面。
--
-- 集中在一處的理由與 "Aapms.Core.Json" 相同:寫入與讀出必須是同一套規則,
-- 分散在 @Index@ 與 @Query@ 兩邊就會慢慢長歪,而「刪掉 index.db 重建後等價」
-- 這條保證正好完全建立在兩邊一致上。
module Aapms.Store.Row
  ( -- * 欄位清單
    metaColumns
  , metaColumnList
  , metaFields
  , linkFields

    -- * SQLData 輔助
  , sText
  , sInt
  , sMaybeText
  , sMaybeInt
  , dayText

    -- * 讀出
  , MetaRow (..)
  , EntityRow (..)
  , LevelRow (..)
  , NodeRow (..)
  , LinkRow (..)
  , toMeta
  , toLink
  , toRef
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, defaultTimeLocale, formatTime, parseTimeM)
import Database.SQLite.Simple (FromRow (..), SQLData (..), field)
import Aapms.Core.Id (Id, Ref (..), parseId, parseRef, renderId)
import Aapms.Core.Link (Link (..), parseLinkKind, renderLinkKind)
import Aapms.Core.Meta

-- | 'Meta' 在 @entities@ \/ @levels@ \/ @nodes@ 三張表裡共用的欄位,順序固定。
--
-- INSERT 的欄位順序可以自己指定,所以三張表都能直接把這 12 欄擺在最前面,
-- 各自的專屬欄位接在後面。
metaColumnList :: [Text]
metaColumnList =
  [ "id"
  , "vault"
  , "type"
  , "title"
  , "summary"
  , "status"
  , "timeline"
  , "timeline_order"
  , "source"
  , "revision"
  , "created"
  , "updated"
  ]

-- | 'metaColumnList' 的 @SELECT@ 寫法。
metaColumns :: Text
metaColumns = T.intercalate ", " metaColumnList

metaFields :: Meta -> [SQLData]
metaFields Meta {..} =
  [ sText (renderId metaId)
  , sText metaVault
  , sText metaType
  , sText metaTitle
  , sText metaSummary
  , sText (renderStatus metaStatus)
  , sMaybeText (tlLabel metaTimeline)
  , sMaybeInt (tlOrder metaTimeline)
  , sText (renderSource metaSource)
  , sInt metaRevision
  , sText (dayText metaCreated)
  , sText (dayText metaUpdated)
  ]

-- | @links@ 一列:@src, dst_vault, dst, kind, note, file_path@。
--
-- @dst_vault@ 由呼叫端正規化——指向本 Vault 的參照一律存 @NULL@,否則
-- @liftgame:ent-7f3a@ 與 @ent-7f3a@ 會變成兩個查不到彼此的東西。
linkFields :: Id -> Link -> FilePath -> [SQLData]
linkFields src Link {..} file =
  [ sText (renderId src)
  , sMaybeText (refVault linkTarget)
  , sText (renderId (refId linkTarget))
  , sText (renderLinkKind linkKind)
  , sMaybeText linkNote
  , sText (T.pack file)
  ]

sText :: Text -> SQLData
sText = SQLText

sInt :: Int -> SQLData
sInt = SQLInteger . fromIntegral

sMaybeText :: Maybe Text -> SQLData
sMaybeText = maybe SQLNull SQLText

sMaybeInt :: Maybe Int -> SQLData
sMaybeInt = maybe SQLNull sInt

-- | @YYYY-MM-DD@,與 Markdown frontmatter 同一種寫法。
dayText :: Day -> Text
dayText = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"

-- 讀出 ------------------------------------------------------------------------

-- | 對應 'metaColumns' 的 12 欄。
data MetaRow = MetaRow
  { mrId :: Text
  , mrVault :: Text
  , mrType :: Text
  , mrTitle :: Text
  , mrSummary :: Text
  , mrStatus :: Text
  , mrTimeline :: Maybe Text
  , mrOrder :: Maybe Int
  , mrSource :: Text
  , mrRevision :: Int
  , mrCreated :: Text
  , mrUpdated :: Text
  }
  deriving stock (Show, Eq)

instance FromRow MetaRow where
  fromRow =
    MetaRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | 'metaColumns' + @file_path@ + @section_anchor@。
data EntityRow = EntityRow MetaRow FilePath (Maybe Text)
  deriving stock (Show, Eq)

instance FromRow EntityRow where
  fromRow = EntityRow <$> fromRow <*> field <*> field

-- | 'metaColumns' + @root@ + @file_path@。
data LevelRow = LevelRow MetaRow Text FilePath
  deriving stock (Show, Eq)

instance FromRow LevelRow where
  fromRow = LevelRow <$> fromRow <*> field <*> field

-- | 'metaColumns' + @level_id@ + @parent_id@ + @order_idx@ + @kind@
-- + @file_path@ + @section_anchor@。
data NodeRow = NodeRow MetaRow Text (Maybe Text) Int Text FilePath (Maybe Text)
  deriving stock (Show, Eq)

instance FromRow NodeRow where
  fromRow =
    NodeRow
      <$> fromRow
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | @src, dst_vault, dst, kind, note@。
data LinkRow = LinkRow Text (Maybe Text) Text Text (Maybe Text)
  deriving stock (Show, Eq)

instance FromRow LinkRow where
  fromRow = LinkRow <$> field <*> field <*> field <*> field <*> field

-- | 組回 'Meta'。索引裡的值都是本套件自己寫進去的,理論上不會壞;
-- 真的壞了就當這一列不存在(回 'Nothing')而不是讓查詢整個炸掉——
-- 索引是可重建的衍生物,一列壞掉不該讓作者連查都查不了。
toMeta :: MetaRow -> [Text] -> [Text] -> [Link] -> Maybe Meta
toMeta MetaRow {..} tags aliases links = do
  (_, i) <- ok (parseId mrId)
  st <- ok (parseStatus mrStatus)
  src <- ok (parseSource mrSource)
  created <- day mrCreated
  updated <- day mrUpdated
  pure
    Meta
      { metaId = i
      , metaVault = mrVault
      , metaType = mrType
      , metaTitle = mrTitle
      , metaSummary = mrSummary
      , metaTags = tags
      , metaStatus = st
      , metaTimeline = Timeline mrTimeline mrOrder
      , metaAliases = aliases
      , metaLinks = links
      , metaSource = src
      , metaRevision = mrRevision
      , metaCreated = created
      , metaUpdated = updated
      }
  where
    ok = either (const Nothing) Just
    day t = parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack t)

toLink :: LinkRow -> Maybe (Id, Link)
toLink (LinkRow src dstVault dst kind note) = do
  (_, s) <- either (const Nothing) Just (parseId src)
  (_, d) <- either (const Nothing) Just (parseId dst)
  pure (s, Link (parseLinkKind kind) (Ref dstVault d) note)

-- | @links.dst_vault@ \/ @links.dst@ 兩欄 → 'Ref'。
toRef :: Maybe Text -> Text -> Maybe Ref
toRef v d = case parseRef (maybe "" (<> ":") v <> d) of
  Right r -> Just r
  Left _ -> Nothing
