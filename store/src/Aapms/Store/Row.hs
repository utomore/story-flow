-- | 核心型別 ↔ SQLite 資料列的轉換裡__純函式__的那一半(graph-core\/F006)。
-- 內部模組,不對外承諾介面,不經 "Aapms.Store" 門面 re-export。
--
-- 集中在一處的理由與 "Aapms.Core.Json" 相同:寫入與讀出必須是同一套規則,
-- 分散在 "Aapms.Store.Index" 與 "Aapms.Store.Query" 兩邊就會慢慢長歪,而
-- 「刪掉 index.db 重建後等價」這條保證正好完全建立在兩邊一致上。
--
-- __碰 sqlite 的那一半住 "Aapms.Store.Row.Sql"__:@nodeFields@ 與六個 @s*@
-- 建構子回的是 @SQLData@、@insertSql@ 回的是 @Query@、@hydrateMeta@ 要一個
-- @Connection@,六個 @FromRow@ 實例更是 sqlite-simple 自己的類別 —— 它們一律
-- 需要 @Database.SQLite.Simple@ 在場,而本模組是純的、不 import 任何 IO 模組。
-- 欄位清單常數、列 → 值的轉換、DocKind \/ JSON \/ 日期的文字編碼與兩個字串拼裝
-- 輔助都不需要那個相依,因此留在這裡。
--
-- __待確認假設 A10__:design.md「索引結構」的 @nodes@ 表 15 欄裡沒有 @vault@
-- 欄——'Aapms.Core.Meta.Meta' 的 @metaVault@ 因此不是逐欄存進 @nodes@,而是
-- 'Aapms.Store.Row.Sql.hydrateMeta' 用呼叫端傳入的 'Aapms.Core.Id.VaultId'
-- (來自 'Aapms.Store.Marker.VaultHandle'
-- 自己的 'Aapms.Store.Marker.vhMarker' \/ 'Aapms.Store.Marker.vmId',永遠可得、
-- 零額外 IO)__原樣填回__。這與 md fixture 展示的「frontmatter 的 @vault:@
-- 只是自由文字標籤,不強制等於 vault 自己的 @vlt-@ id」一致:同一個 vault 內
-- 重建兩次、或 @rm index.db@ 前後,@hydrateMeta@ 永遠用同一個來源填,S0 契約
-- 測試(F006 驗收標準)因此仍然成立,只是 hydrate 出來的 @metaVault@ 不保證
-- 逐位元組等於檔案 frontmatter 當初寫的那個字串。**影響**:若之後某個 feature
-- 需要「這個節點檔案宣告的 vault 標籤」而非「它實際所在的 vault」,要幫
-- @nodes@ 表加回一欄,是純 schema 擴充,不影響本模組其餘介面。
module Aapms.Store.Row
  ( -- * nodes 欄位
    nodeColumnList
  , nodeColumns
  , NodeRow (..)
  , rowToMeta

    -- * 六個專屬表
  , assetColumnList
  , assetColumns
  , AssetRow (..)
  , assetFromRow
  , packColumnList
  , packColumns
  , PackRow (..)
  , packFromRow
  , licenseColumnList
  , licenseColumns
  , LicenseRow (..)
  , licenseFromRow
  , levelColumnList
  , levelColumns
  , LevelRow (..)
  , treeNodeColumnList
  , treeNodeColumns
  , TreeNodeRow (..)

    -- * links
  , LinkRow (..)
  , toLink

    -- * DocKind 文字編碼
  , renderDocKind
  , parseDocKind

    -- * JSON 輔助(kind meta / author / ai_disclosure)
  , encodeJsonText
  , decodeJsonText
  , encodeAuthorJson
  , decodeAuthorJson
  , aiDisclosureText
  , parseAiDisclosureText

    -- * 日期文字
  , dayText

    -- * SQL 拼裝輔助(純字串)
  , inList
  , groupPairs
  ) where

import Data.Aeson
  ( FromJSON
  , Result (..)
  , ToJSON
  , Value (..)
  , decodeStrict
  , encode
  , fromJSON
  , toJSON
  )
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Time (Day, defaultTimeLocale, formatTime, parseTimeM)
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Id (Id, Ref (..), VaultId (..), parseId, parseRef)
import Aapms.Core.Json ()
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), parseLinkKind)
import Aapms.Core.Meta
import Aapms.Core.Pack (AiDisclosure (..), Author, Pack (..))
import Aapms.Md.Document (DocKind (..))

--------------------------------------------------------------------------------
-- nodes

-- | 對照 @nodes@ 表的 15 欄,順序固定。
nodeColumnList :: [Text]
nodeColumnList =
  [ "id"
  , "prefix"
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
  , "file_path"
  , "section_anchor"
  , "owner"
  ]

nodeColumns :: Text
nodeColumns = T.intercalate ", " nodeColumnList

-- | 對照 'nodeColumnList' 的 15 欄。
data NodeRow = NodeRow
  { nrId :: Text
  , nrPrefix :: Text
  , nrType :: Text
  , nrTitle :: Text
  , nrSummary :: Text
  , nrStatus :: Text
  , nrTimeline :: Maybe Text
  , nrTimelineOrder :: Maybe Int
  , nrSource :: Text
  , nrRevision :: Int
  , nrCreated :: Text
  , nrUpdated :: Text
  , nrFilePath :: Text
  , nrSectionAnchor :: Maybe Text
  , nrOwner :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | 純函式版本:'NodeRow' + 已查回的 aliases\/tags\/links → 'Meta'。索引裡的
-- 值都是本套件自己寫進去的,理論上不會壞;真的壞了就回 'Nothing' 而不是讓
-- 查詢整個炸掉——索引是可重建的衍生物,一列壞掉不該讓作者連查都查不了。
rowToMeta :: VaultId -> NodeRow -> [Text] -> [Text] -> [Link] -> Maybe Meta
rowToMeta vid NodeRow {..} aliases tags links = do
  (_, i) <- ok (parseId nrId)
  st <- ok (parseStatus nrStatus)
  src <- ok (parseSource nrSource)
  created <- day nrCreated
  updated <- day nrUpdated
  pure
    Meta
      { metaId = i
      , metaVault = vid
      , metaType = TypeKey nrType
      , metaTitle = nrTitle
      , metaSummary = nrSummary
      , metaTags = tags
      , metaStatus = st
      , metaTimeline = case (nrTimeline, nrTimelineOrder) of
          (Nothing, Nothing) -> Nothing
          (lbl, ord) -> Just (Timeline lbl ord)
      , metaAliases = aliases
      , metaLinks = links
      , metaSource = src
      , metaRevision = Revision nrRevision
      , metaCreated = created
      , metaUpdated = updated
      }
  where
    ok = either (const Nothing) Just
    day t = parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack t)

--------------------------------------------------------------------------------
-- assets

assetColumnList :: [Text]
assetColumnList = ["name", "sha256", "entry", "ext", "meta_json", "license", "author"]

assetColumns :: Text
assetColumns = T.intercalate ", " assetColumnList

data AssetRow = AssetRow
  { asrName :: Maybe Text
  , asrSha256 :: Text
  , asrEntry :: Text
  , asrExt :: Maybe Text
  , asrMetaJson :: Text
  , asrLicense :: Maybe Text
  , asrAuthor :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | 'AssetRow' + 已查回的 'Meta' + 回讀檔案取得的 body → 'Asset'。
assetFromRow :: Meta -> AssetRow -> Text -> Asset
assetFromRow meta AssetRow {..} body =
  Asset
    { astMeta = meta
    , astName = LogicalName <$> asrName
    , astSha256 = Sha256 asrSha256
    , astEntry = asrEntry
    , astExt = asrExt
    , astKindMeta = decodeJsonText asrMetaJson
    , astLicense = asrLicense >>= refOf
    , astAuthor = asrAuthor
    , astBody = body
    }

--------------------------------------------------------------------------------
-- packs

packColumnList :: [Text]
packColumnList =
  [ "vendor"
  , "archive"
  , "sha256"
  , "license"
  , "author_json"
  , "source_url"
  , "ai_disclosure"
  , "is_reference"
  ]

packColumns :: Text
packColumns = T.intercalate ", " packColumnList

data PackRow = PackRow
  { pkrVendor :: Maybe Text
  , pkrArchive :: Maybe Text
  , pkrSha256 :: Maybe Text
  , pkrLicense :: Maybe Text
  , pkrAuthorJson :: Maybe Text
  , pkrSourceUrl :: Maybe Text
  , pkrAiDisclosure :: Text
  , pkrIsReference :: Bool
  }
  deriving stock (Show, Eq)

packFromRow :: Meta -> PackRow -> Text -> Pack
packFromRow meta PackRow {..} body =
  Pack
    { pckMeta = meta
    , pckVendor = pkrVendor
    , pckArchive = T.unpack <$> pkrArchive
    , pckSha256 = Sha256 <$> pkrSha256
    , pckLicense = pkrLicense >>= refOf
    , pckAuthor = pkrAuthorJson >>= decodeAuthorJson
    , pckSourceUrl = pkrSourceUrl
    , pckAiDisclosure = maybe AiUnknown id (parseAiDisclosureText pkrAiDisclosure)
    , pckBody = body
    }

--------------------------------------------------------------------------------
-- licenses

licenseColumnList :: [Text]
licenseColumnList =
  [ "commercial"
  , "attribution_required"
  , "credit_text"
  , "modification_allowed"
  , "redistribution_allowed"
  , "resale_allowed"
  , "nft_allowed"
  , "source_url"
  ]

licenseColumns :: Text
licenseColumns = T.intercalate ", " licenseColumnList

data LicenseRow = LicenseRow
  { lcrCommercial :: Bool
  , lcrAttributionRequired :: Bool
  , lcrCreditText :: Maybe Text
  , lcrModificationAllowed :: Maybe Bool
  , lcrRedistributionAllowed :: Maybe Bool
  , lcrResaleAllowed :: Maybe Bool
  , lcrNftAllowed :: Maybe Bool
  , lcrSourceUrl :: Maybe Text
  }
  deriving stock (Show, Eq)

licenseFromRow :: Meta -> LicenseRow -> License
licenseFromRow meta LicenseRow {..} =
  License
    { licMeta = meta
    , licCommercial = lcrCommercial
    , licAttributionRequired = lcrAttributionRequired
    , licCreditText = lcrCreditText
    , licModificationAllowed = lcrModificationAllowed
    , licRedistributionAllowed = lcrRedistributionAllowed
    , licResaleAllowed = lcrResaleAllowed
    , licNftAllowed = lcrNftAllowed
    , licSourceUrl = lcrSourceUrl
    , licFullText = Nothing
    }

--------------------------------------------------------------------------------
-- levels

levelColumnList :: [Text]
levelColumnList = ["root"]

levelColumns :: Text
levelColumns = T.intercalate ", " levelColumnList

newtype LevelRow = LevelRow {lvrRoot :: Text}
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- tree_nodes

treeNodeColumnList :: [Text]
treeNodeColumnList = ["level_id", "parent_id", "order_idx", "kind"]

treeNodeColumns :: Text
treeNodeColumns = T.intercalate ", " treeNodeColumnList

data TreeNodeRow = TreeNodeRow
  { tnrLevelId :: Text
  , tnrParentId :: Maybe Text
  , tnrOrderIdx :: Int
  , tnrKind :: Text
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- links

-- | @src, dst_vault, dst, kind, note@。
data LinkRow = LinkRow Text (Maybe Text) Text Text (Maybe Text)
  deriving stock (Show, Eq)

toLink :: LinkRow -> Maybe (Id, Link)
toLink (LinkRow src dstVault dst kind note) = do
  (_, s) <- either (const Nothing) Just (parseId src)
  (_, d) <- either (const Nothing) Just (parseId dst)
  pure (s, Link (parseLinkKind kind) (Ref (VaultId <$> dstVault) d) note)

refOf :: Text -> Maybe Ref
refOf t = either (const Nothing) Just (parseRef t)

--------------------------------------------------------------------------------
-- DocKind 文字編碼(待確認假設 ASM-6:store 自訂,不用 DocKind 的 Show 實例)

renderDocKind :: DocKind -> Text
renderDocKind = \case
  TopicDoc -> "topic"
  LevelDoc -> "level"
  PackDoc -> "pack"
  LicenseDoc -> "license"

parseDocKind :: Text -> Maybe DocKind
parseDocKind = \case
  "topic" -> Just TopicDoc
  "level" -> Just LevelDoc
  "pack" -> Just PackDoc
  "license" -> Just LicenseDoc
  _ -> Nothing

--------------------------------------------------------------------------------
-- JSON 輔助

-- | 一般 aeson 'Value' → 儲存用文字。
encodeJsonText :: Value -> Text
encodeJsonText = TL.toStrict . TLE.decodeUtf8 . encode

-- | 儲存用文字 → 'Value'。壞掉(不該發生,是本套件自己寫的)時回 'Null' 而不是
-- 讓查詢炸掉。
decodeJsonText :: Text -> Value
decodeJsonText t = maybe Null id (decodeStrict (TE.encodeUtf8 t))

encodeAuthorJson :: Author -> Text
encodeAuthorJson = encodeJsonText . toJSON

decodeAuthorJson :: Text -> Maybe Author
decodeAuthorJson t = decodeStrict (TE.encodeUtf8 t)

-- | 借道 "Aapms.Core.Json" 的 orphan 'ToJSON'\/'FromJSON' 'Aapms.Core.Pack.AiDisclosure'
-- 實例(該模組沒有匯出 @renderAiDisclosure@\/@parseAiDisclosure@ 兩個純函式,
-- 只有 instance 是公開的)。
aiDisclosureText :: (ToJSON a) => a -> Text
aiDisclosureText v = case toJSON v of
  String t -> t
  other -> encodeJsonText other

parseAiDisclosureText :: (FromJSON a) => Text -> Maybe a
parseAiDisclosureText t = case fromJSON (String t) of
  Success v -> Just v
  Error _ -> Nothing

--------------------------------------------------------------------------------
-- 日期文字

-- | @YYYY-MM-DD@,與 Markdown frontmatter 同一種寫法。
dayText :: Day -> Text
dayText = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"

--------------------------------------------------------------------------------
-- SQL 拼裝輔助(純字串)

inList :: Int -> Text
inList n = "(" <> T.intercalate ", " (replicate n "?") <> ")"

groupPairs :: [(Text, [a])] -> M.Map Text [a]
groupPairs = foldr (\(k, v) m -> M.insertWith (flip (++)) k v m) M.empty
