-- | 節層繼承檔案層的合併規則(graph-core/F004:四種文件共用)。
--
-- design.md「節層繼承規則」表格是「等」的精確定義,逐欄的理由見
-- entity-graph-core/F003 的表格與 graph-core/design.md。
--
-- 重點的幾條:
--
-- * @tags@ 是__聯集去重__而非覆寫——檔案層放共通標籤、節層放專屬標籤是最自然的
--   用法,純覆寫會逼作者重寫共通標籤
-- * @summary@ __不繼承__——片段的一句話總結是衝突偵測撈 context 的主要輸入,
--   繼承主體的總結等於製造假資訊。graph-core/F004 移除了 'MdWarning' 通道
--   (待確認假設 ASM-1),缺 summary 因此__不再產生警告__,只是空字串
-- * @revision@ __不繼承__,未寫時為 @1@——繼承會讓多個片段共用同一個 revision,
--   樂觀鎖(entity-graph-core/F004)就失去意義
-- * @type@ 是否繼承__依文件種類而定__(design.md「節層繼承規則」表格):主題檔 /
--   Level 檔 / licenses.md 繼承,pack.md 不繼承且缺漏是錯誤——由呼叫端傳入
--   'typeInherits' 旗標決定
module Aapms.Md.Inherit
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
import Aapms.Core.Id (Id, VaultId)
import Aapms.Core.Json ()
import Aapms.Core.Level (NodeKind)
import Aapms.Core.Link (Link (..))
import Aapms.Core.Meta
import Aapms.Md.Error (MdErrorKind (..))

-- | @```meta@ 區塊的內容:每個欄位都是 'Maybe',未寫的交給繼承規則填補。
--
-- @moKind@ 不在 entity-graph-core/F003 原本的欄位表裡,是實作時補的(實作備註 1):
-- Level 檔的節一定有 @kind@,少了這一欄 'Aapms.Md.Render.updateSection'
-- 重新序列化時會把它整行刪掉。
--
-- @moType@ / @moVault@ / @moRevision@ 的型別是 graph-core/F004 對齊 F001 統一
-- 'Meta' 之後修正的(原為 'Maybe' 'Text' \/ 'Text' \/ 'Int')。
data MetaOverride = MetaOverride
  { moKind :: Maybe NodeKind
  , moType :: Maybe TypeKey
  , moVault :: Maybe VaultId
  , moSummary :: Maybe Text
  , moTags :: Maybe [Text]
  , moStatus :: Maybe Status
  , moTimeline :: Maybe Timeline
  , moAliases :: Maybe [Text]
  , moLinks :: Maybe [Link]
  , moSource :: Maybe Source
  , moRevision :: Maybe Revision
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
--
-- 型別隨欄位改變(@TypeKey@ \/ @VaultId@ \/ @Revision@)自動吃到
-- "Aapms.Core.Json" 對應的 @FromJSON@ 實例,實例本身不用改。
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
-- @Aapms.Store.Write.writeEntityMeta@ 的介面吃的是
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
    , moTimeline = metaTimeline
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
    , metaTimeline = keepMaybe moTimeline (metaTimeline m)
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

    -- metaTimeline 本身已經是 Maybe,寫了就整個換掉(含寫成 Nothing 的情形
    -- 表達不出來——覆寫沒寫這一欄與覆寫成「清空」用同一個 Nothing,這是
    -- MetaOverride 對 Maybe 欄位的既有限制,entity-graph-core/F003 就是這個形狀)。
    keepMaybe :: Maybe Timeline -> Maybe Timeline -> Maybe Timeline
    keepMaybe mv get = maybe get Just mv

-- | 檔案層 'Meta' + 節 id + 節標題 + 節層覆寫 → 節的 'Meta'。
--
-- @typeInherits@(graph-core/F004 新增,design.md「節層繼承規則」表格):
-- 'True' 時節層未寫 @type@ 就繼承檔案層(主題檔 / Level 檔 / licenses.md);
-- 'False' 時節層__必須__自己寫 @type@,缺漏回 'Left' ('SectionFieldMissing'
-- 這個 'MdErrorKind',由呼叫端補上行號組成完整 'MdError')——pack.md 的節一定
-- 是某種 asset 型別,不可能跟容器的 @asset-pack@ 相同。
inheritMeta :: Bool -> Meta -> Id -> Text -> MetaOverride -> Either MdErrorKind Meta
inheritMeta typeInherits file i title MetaOverride {..} = do
  ty <- case (moType, typeInherits) of
    (Just t, _) -> Right t
    (Nothing, True) -> Right (metaType file)
    (Nothing, False) -> Left (SectionFieldMissing i "type")
  Right
    Meta
      { metaId = i
      , metaVault = orInherit moVault metaVault
      , metaType = ty
      , metaTitle = title
      , metaSummary = maybe "" id moSummary
      , metaTags = nub (metaTags file ++ maybe [] id moTags)
      , metaStatus = orInherit moStatus metaStatus
      , metaTimeline = maybe (metaTimeline file) Just moTimeline
      , metaAliases = maybe [] id moAliases
      , metaLinks = maybe [] id moLinks
      , metaSource = orInherit moSource metaSource
      , metaRevision = maybe (Revision 1) id moRevision
      , metaCreated = orInherit moCreated metaCreated
      , metaUpdated = orInherit moUpdated metaUpdated
      }
  where
    orInherit :: Maybe a -> (Meta -> a) -> a
    orInherit mv get = maybe (get file) id mv
