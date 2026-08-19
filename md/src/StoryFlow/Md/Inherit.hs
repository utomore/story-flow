-- | 節層繼承檔案層的合併規則。
--
-- system.md 只寫了「節層未寫的欄位繼承檔案層(@vault@/@type@/@timeline@/
-- @status@ 等)」;「等」的精確定義在這裡,逐欄的理由見 entity-graph-core/F003 的表格。
--
-- 重點的三條:
--
-- * @tags@ 是__聯集去重__而非覆寫——檔案層放共通標籤、節層放專屬標籤是最自然的
--   用法,純覆寫會逼作者重寫共通標籤
-- * @summary@ __不繼承__,缺漏產生 'MissingSummary' 警告——片段的一句話總結是
--   衝突偵測撈 context 的主要輸入,繼承主體的總結等於製造假資訊
-- * @revision@ __不繼承__,未寫時為 @1@——繼承會讓多個片段共用同一個 revision,
--   樂觀鎖(entity-graph-core/F004)就失去意義
module StoryFlow.Md.Inherit
  ( MetaOverride (..)
  , emptyOverride
  , inheritMeta
  , overrideOf
  , applyOverride
  ) where

import Data.Aeson
import Data.List (nub)
import Data.Text (Text)
import Data.Time (Day)
import StoryFlow.Core.Id (Id)
import StoryFlow.Core.Json ()
import StoryFlow.Core.Level (NodeKind)
import StoryFlow.Core.Link (Link (..), LinkKind (Custom))
import StoryFlow.Core.Meta
import StoryFlow.Md.Error

-- | @```meta@ 區塊的內容:每個欄位都是 'Maybe',未寫的交給繼承規則填補。
--
-- @moKind@ 不在 entity-graph-core/F003 原本的欄位表裡,是實作時補的(實作備註 1):
-- Level 檔的節一定有 @kind@,少了這一欄 'StoryFlow.Md.Render.updateSection'
-- 重新序列化時會把它整行刪掉。
data MetaOverride = MetaOverride
  { moKind :: Maybe NodeKind
  , moType :: Maybe Text
  , moVault :: Maybe Text
  , moSummary :: Maybe Text
  , moTags :: Maybe [Text]
  , moStatus :: Maybe Status
  , moTimeline :: Maybe Timeline
  , moAliases :: Maybe [Text]
  , moLinks :: Maybe [Link]
  , moSource :: Maybe Source
  , moRevision :: Maybe Int
  , moCreated :: Maybe Day
  , moUpdated :: Maybe Day
  }
  deriving stock (Show, Eq)

emptyOverride :: MetaOverride
emptyOverride =
  MetaOverride
    { moKind = Nothing
    , moType = Nothing
    , moVault = Nothing
    , moSummary = Nothing
    , moTags = Nothing
    , moStatus = Nothing
    , moTimeline = Nothing
    , moAliases = Nothing
    , moLinks = Nothing
    , moSource = Nothing
    , moRevision = Nothing
    , moCreated = Nothing
    , moUpdated = Nothing
    }

-- | 未知欄位一律忽略不報錯:註冊表可以宣告任何欄位,md 這一層不該替它把關。
instance FromJSON MetaOverride where
  parseJSON = withObject "MetaOverride" $ \o ->
    MetaOverride
      <$> o .:? "kind"
      <*> o .:? "type"
      <*> o .:? "vault"
      <*> o .:? "summary"
      <*> o .:? "tags"
      <*> o .:? "status"
      <*> o .:? "timeline"
      <*> o .:? "aliases"
      <*> o .:? "links"
      <*> o .:? "source"
      <*> o .:? "revision"
      <*> o .:? "created"
      <*> o .:? "updated"

-- | 完整 'Meta' → 每一欄都是 @Just@ 的覆寫。
--
-- 檔案層主體沒有「節層 meta 區塊」可以當作目前的覆寫,但
-- 'StoryFlow.Store.Write.writeEntityMeta' 的介面吃的是
-- @'MetaOverride' -> 'MetaOverride'@ ——節層與主體共用同一個修改函式,
-- 靠的就是這一對展開/套回。@moKind@ 一律 'Nothing':'Meta' 沒有這一欄。
overrideOf :: Meta -> MetaOverride
overrideOf Meta {..} =
  MetaOverride
    { moKind = Nothing
    , moType = Just metaType
    , moVault = Just metaVault
    , moSummary = Just metaSummary
    , moTags = Just metaTags
    , moStatus = Just metaStatus
    , moTimeline = Just metaTimeline
    , moAliases = Just metaAliases
    , moLinks = Just metaLinks
    , moSource = Just metaSource
    , moRevision = Just metaRevision
    , moCreated = Just metaCreated
    , moUpdated = Just metaUpdated
    }

-- | 把覆寫疊回一份完整的 'Meta':@Nothing@ 的欄位保留原值。
--
-- 與 'inheritMeta' 的規則__不同__且不該相同:那裡是「節繼承檔案層」,
-- @tags@ 聯集、@summary@ 不繼承;這裡是「同一份 'Meta' 的部分修改」,
-- 每一欄都是單純的覆蓋。@id@ 與 @title@ 'MetaOverride' 表達不了,原樣保留。
applyOverride :: MetaOverride -> Meta -> Meta
applyOverride MetaOverride {..} m =
  m
    { metaType = keep moType metaType
    , metaVault = keep moVault metaVault
    , metaSummary = keep moSummary metaSummary
    , metaTags = keep moTags metaTags
    , metaStatus = keep moStatus metaStatus
    , metaTimeline = keep moTimeline metaTimeline
    , metaAliases = keep moAliases metaAliases
    , metaLinks = keep moLinks metaLinks
    , metaSource = keep moSource metaSource
    , metaRevision = keep moRevision metaRevision
    , metaCreated = keep moCreated metaCreated
    , metaUpdated = keep moUpdated metaUpdated
    }
  where
    keep :: Maybe a -> (Meta -> a) -> a
    keep mv get = maybe (get m) id mv

-- | 檔案層 'Meta' + 節 id + 節標題 + 節層覆寫 → 節的 'Meta'。
inheritMeta :: Meta -> Id -> Text -> MetaOverride -> (Meta, [MdWarning])
inheritMeta file i title MetaOverride {..} = (meta, warnings)
  where
    meta =
      Meta
        { metaId = i
        , metaVault = orInherit moVault metaVault
        , metaType = orInherit moType metaType
        , metaTitle = title
        , metaSummary = maybe "" id moSummary
        , metaTags = nub (metaTags file ++ maybe [] id moTags)
        , metaStatus = orInherit moStatus metaStatus
        , metaTimeline = orInherit moTimeline metaTimeline
        , metaAliases = maybe [] id moAliases
        , metaLinks = links
        , metaSource = orInherit moSource metaSource
        , metaRevision = maybe 1 id moRevision
        , metaCreated = orInherit moCreated metaCreated
        , metaUpdated = orInherit moUpdated metaUpdated
        }

    orInherit :: Maybe a -> (Meta -> a) -> a
    orInherit mv get = maybe (get file) id mv

    links = maybe [] id moLinks

    warnings =
      [MissingSummary i | maybe True (== "") moSummary]
        ++ [CustomLinkKind i k | Link {linkKind = Custom k} <- links]
