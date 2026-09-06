-- | 節與檔案層 frontmatter 的__建構 DTO 與型別專屬條目載體__(graph-core\/F004)。
--
-- 一併收下 'MetaOverride'(@```meta@ 區塊的 'Aapms.Core.Meta.Meta' 那一半):
-- 它與 'MetaExtras' 是同一個區塊的兩半,而繼承\/覆寫\/展開的__規則__留在
-- "Aapms.Md.Inherit"(該模組原樣 re-export 它與 'emptyOverride')。
--
-- 本模組只有型別宣告、它們的 @FromJSON@ 實例與欄位選取器,__沒有任何轉換__:
-- 讀出 extras('Aapms.Md.Render.extrasOf' \/ 'Aapms.Md.Render.frontExtrasOf')、
-- 合併 extras('Aapms.Md.Render.mergeExtras' \/
-- 'Aapms.Md.Render.mergeFrontExtras')、把 payload 攤成行
-- ('Aapms.Md.Render.payloadOverride' \/ 'Aapms.Md.Render.payloadExtras' \/
-- 'Aapms.Md.Render.packFrontExtras')全部留在 "Aapms.Md.Render"。
--
-- 分家的判準是層次而不是主題:這些型別是 @aapms-store@ 的寫入路徑
-- ('Aapms.Store.Create.addSection' 等)與外殼的線上格式共同持有的__資料__,
-- 而 "Aapms.Md.Render" 是做位元組級推導的模組;型別層的消費端不該為了一個
-- DTO 去依賴整套編輯演算法。"Aapms.Md.Render" 原樣 re-export 本模組的全部
-- 名字,既有呼叫端與 'Aapms.Md' 門面都不受影響。
module Aapms.Md.Section
  ( -- * @```meta@ 區塊的 'Aapms.Core.Meta.Meta' 那一半
    MetaOverride (..)
  , emptyOverride

    -- * 節的建構 DTO(graph-core\/F004,payload 對節點種類做 sum)
  , NewSection (..)
  , NewSectionPayload (..)
  , NewAsset (..)
  , NewLicense (..)
  , NewNode (..)

    -- * meta 區塊的型別專屬那一半
  , MetaExtras (..)

    -- * 檔案層 frontmatter 的型別專屬那一半(graph-core\/F004 重跑,GAP-17)
  , FrontExtras (..)
  , NewPackFront (..)
  ) where

import Data.Aeson (FromJSON (..), Value (..), withObject, (.!=), (.:), (.:?))
import Data.Text (Text)
import Data.Time (Day)
import Aapms.Core.Asset (LogicalName, Sha256)
import Aapms.Core.Id (Id, Ref, VaultId)
import Aapms.Core.Json ()
import Aapms.Core.Level (NodeKind)
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Revision, Source, Status, Timeline, TypeKey)
import Aapms.Core.Pack (AiDisclosure, Author)

-- meta 區塊的 Meta 那一半 -----------------------------------------------------

-- | @```meta@ 區塊的內容:每個欄位都是 'Maybe',未寫的交給繼承規則填補
-- (規則本身住 "Aapms.Md.Inherit")。
--
-- @moKind@ 不在 entity-graph-core\/F003 原本的欄位表裡,是實作時補的(實作備註 1):
-- Level 檔的節一定有 @kind@,少了這一欄 'Aapms.Md.Render.updateSection'
-- 重新序列化時會把它整行刪掉。
--
-- @moType@ \/ @moVault@ \/ @moRevision@ 的型別是 graph-core\/F004 對齊 F001 統一
-- 'Aapms.Core.Meta.Meta' 之後修正的(原為 'Maybe' 'Text' \/ 'Text' \/ 'Int')。
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

-- meta 區塊的型別專屬那一半 ---------------------------------------------------

-- | @```meta@ 區塊裡__鍵不在 'Aapms.Md.Render.metaFieldOrder' 中__的頂層條目,
-- 以原始行保存。
--
-- 每個元素是一行,__不含行尾字元__(行尾由 'Aapms.Md.Render.renderMetaBlock'
-- 依 'Aapms.Md.Document.LineEnding' 補);一個「頂層條目」是「第 0 欄起的
-- @key:@ 那一行」加上其後所有縮排行與空行,因此 @meta:@ 這種區塊風格的巢狀值
-- 也整段留得住。
--
-- 為什麼是原始行而不是解過的 'Data.Aeson.Value':ADR-010 保護的是作者手寫的
-- 位元組,而解碼再編碼一定會動到引號、數字格式與縮排。這一半我們不需要理解
-- 它的語意,只需要不弄丟它。
newtype MetaExtras = MetaExtras
  { extraLines :: [Text]
  }
  deriving stock (Show, Eq)

-- 新節的建構 DTO --------------------------------------------------------------

-- | 新節的建構 DTO(graph-core\/F004,取代舊 @insertSection@ 直接吃
-- 'Aapms.Md.Document.Section')。
--
-- @nsId@ 由呼叫端(@aapms-store@ 的 @allocateId@)先配好再傳進來——本套件不
-- 知道怎麼配 id。
data NewSection = NewSection
  { nsId :: Id
  , nsLevel :: Int
  , nsTitle :: Text
  , nsBody :: Text
  , nsPayload :: NewSectionPayload
  }
  deriving stock (Show, Eq)

-- | 節的內容,__對節點種類做 sum__(design.md 契約 D,2026-08-24 GAP-1 裁決)。
--
-- 每個建構子都帶一個 'MetaOverride'(四種文件共用的 'Aapms.Core.Meta.Meta'
-- 那一半),外加該種節點自己的專屬欄位。
--
-- __不採__「把 asset \/ license 欄位塞進 'MetaOverride'」:那個型別是 md 與
-- store 共用的節層繼承 DTO,污染它會動到 ADR-010 位元組保留所依賴的繼承規則。
-- 封閉 sum 的好處與契約 A 的 @AnyNode@ 相同:新增節點種類時編譯器會列出所有
-- 待處理處,而 'Aapms.Md.Render.appendSection' 維持單一入口。
data NewSectionPayload
  = -- | 主題檔的片段:沒有專屬欄位
    NSFragment MetaOverride
  | -- | @pack.md@ 的一筆 asset
    NSAsset MetaOverride NewAsset
  | -- | @licenses.md@ 的一種授權
    NSLicense MetaOverride NewLicense
  | -- | Level 檔的一個節點
    NSNode MetaOverride NewNode
  deriving stock (Show, Eq)

-- | asset 的專屬欄位,與 'Aapms.Core.Asset.Asset' 逐欄對應(扣掉
-- 'Aapms.Core.Meta.Meta' 與正文)。
--
-- @sha256@ \/ @entry@ 是必填而非 'Maybe':'Aapms.Core.Asset.Asset' 的對應欄位
-- 就不是 'Maybe',寫不出這兩欄的節 'Aapms.Md.Parse.toPack' 一定解不回來。
data NewAsset = NewAsset
  { naName :: Maybe LogicalName
  , naSha256 :: Sha256
  , naEntry :: Text
  , naExt :: Maybe Text
  , naKindMeta :: Value
  -- ^ kind 專屬 JSON(@image@ 的寬高、@audio@ 的長度……)。'Null' = 不寫這一欄
  , naLicense :: Maybe Ref
  , naAuthor :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | 節層 meta 直接管的授權維度,與 'Aapms.Core.License.License' 對應(扣掉
-- 'Aapms.Core.Meta.Meta' 與 @full_text@ —— @licenses.md@ 的節不重複貼授權全文)。
--
-- @commercial@ 與 @attribution_required@ 是 'Bool' 而非 @'Maybe' 'Bool'@:
-- 它們缺漏是錯誤(design.md 契約卡),其餘六項缺漏為 'Nothing'。
data NewLicense = NewLicense
  { nlcCommercial :: Bool
  , nlcAttributionRequired :: Bool
  , nlcCreditText :: Maybe Text
  , nlcModificationAllowed :: Maybe Bool
  , nlcRedistributionAllowed :: Maybe Bool
  , nlcResaleAllowed :: Maybe Bool
  , nlcNftAllowed :: Maybe Bool
  , nlcSourceUrl :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | Level 檔的一個節點的專屬欄位。
--
-- 只有 @kind@ 一欄:@parent@ 與 @order@ 由標題階層推導(ADR-009),
-- 'Aapms.Core.Level.nodEntities' 由 @involves@ \/ @references@ 兩種關聯推導,
-- 兩者都不該由呼叫端重複指定 —— 指定了就會有兩個真相來源。
newtype NewNode = NewNode
  { nnKind :: NodeKind
  }
  deriving stock (Show, Eq)

-- | 解碼規則與舊 @AssetFields@ 完全相同(原樣搬過來):@sha256@ \/ @entry@ 用
-- @.:@,其餘用 @.:?@,與 "Aapms.Core.Json" 的 @FromJSON Asset@ 一致。
instance FromJSON NewAsset where
  parseJSON = withObject "NewAsset" $ \o ->
    NewAsset
      <$> o .:? "name"
      <*> o .: "sha256"
      <*> o .: "entry"
      <*> o .:? "ext"
      <*> o .:? "meta" .!= Null
      <*> o .:? "license"
      <*> o .:? "author"

-- | 解碼規則與舊 @LicenseFields@ 完全相同(原樣搬過來)。
instance FromJSON NewLicense where
  parseJSON = withObject "NewLicense" $ \o ->
    NewLicense
      <$> o .: "commercial"
      <*> o .: "attribution_required"
      <*> o .:? "credit_text"
      <*> o .:? "modification_allowed"
      <*> o .:? "redistribution_allowed"
      <*> o .:? "resale_allowed"
      <*> o .:? "nft_allowed"
      <*> o .:? "source_url"

-- 檔案層 frontmatter 的型別專屬那一半 -----------------------------------------

-- | 檔案層的型別專屬條目。__'MetaExtras' 的 newtype,不是別名__
-- (2026-08-25 開發者裁決 ASM-11)。
--
-- 底層表示與節層__完全相同__(就是「一組原始行」),所以
-- 'Aapms.Md.Render.mergeExtras' 那一組機制__一份就夠__,本型別只在邊界拆包
-- ('unFrontExtras',或 @Data.Coerce.coerce@)——__不得__另寫第二份切段與取鍵
-- 的邏輯,那條規則正是 GAP-2 \/ GAP-17 的判準本身,兩份實作遲早分歧。
--
-- 那為什麼還要包一層:兩層的__鍵清單不同__(節層是
-- 'Aapms.Md.Render.metaFieldOrder'、檔案層是
-- 'Aapms.Md.Render.frontmatterFieldOrder'),混用時 'Aapms.Md.Parse.toPack' 照樣
-- 解得回來(多餘的鍵一律忽略),症狀是__安靜的髒資料而不是編譯錯誤__。本子系統
-- 已經被「安靜的資料遺失」咬過兩次(GAP-2 在節層、GAP-17 在檔案層),
-- __兩次都不是測試抓到的,是人讀出來的__;能用型別擋掉的第三次就不該留給人讀。
newtype FrontExtras = FrontExtras
  { unFrontExtras :: MetaExtras
  }
  deriving stock (Show, Eq)

-- | @pack.md@ 檔案層 frontmatter 的 pack 專屬欄位(graph-core\/F004 重跑,GAP-17)。
--
-- __只有寫方向__:讀方向是 "Aapms.Core.Json" 的 @FromJSON Pack@,那是全系統
-- 唯一的解碼規則(F001),md 不得再定義第二份。兩者對得上不靠型別,靠 F004 的
-- __往返 law__ LAW-44 —— GAP-17 之所以能潛伏,正是因為以前沒有任何 law 測這個往返。
--
-- 欄位名前綴用 @npf@ 而不是 @aapms-store@ 的 @NewPack@ 那組 @np@:兩者是
-- __不同的 DTO__(store 的 'NewPack' 還帶 @npDir@ \/ @npTitle@ \/ @npTags@ 等
-- 建 'Aapms.Core.Meta.Meta' 與路徑要用的欄位),同名欄位選擇器會在 store 一旦
-- @import Aapms.Md@ 時互相衝突。
data NewPackFront = NewPackFront
  { npfVendor :: Maybe Text
  , npfArchive :: Maybe FilePath
  -- ^ @'Nothing'@ = 散檔目錄,此時各 asset 的 @entry@ 是相對該目錄的路徑
  , npfSha256 :: Maybe Sha256
  , npfLicense :: Maybe Ref
  , npfAuthor :: Maybe Author
  , npfSourceUrl :: Maybe Text
  , npfAiDisclosure :: AiDisclosure
  -- ^ @'Aapms.Core.Pack.AiUnknown'@ = 不寫這一欄(@FromJSON Pack@ 的
  -- @.:? \"ai_disclosure\" .!= AiUnknown@ 會解回同一個值)
  }
  deriving stock (Show, Eq)
