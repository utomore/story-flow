-- | 寫回與單節編輯(ADR-010)。
--
-- 'renderDocument' 只是把每一段原始切片依序接起來,因此__位元組相等是結構上
-- 保證的__,不是靠測試碰運氣。編輯函式集中在本模組一處,是為了讓「只重寫被修改
-- 的那一段」這條保證有一個守得住的邊界。
--
-- @```meta@ 區塊的序列化__自己寫,不用 YAML 編碼器__:只有被修改的節需要重寫,
-- 格式完全由我們決定(欄位順序固定、@links@ 用流式風格、字串只在必要時加引號);
-- 引入編碼器反而要對抗它的排版偏好。
--
-- == meta 區塊的兩半(graph-core/F004 重跑,G2)
--
-- 一個 @```meta@ 區塊裡有兩種頂層條目:
--
-- * 鍵落在 'metaFieldOrder' 裡的,是 'MetaOverride' 表達得出來的 'Aapms.Core.Meta.Meta' 欄位
-- * 其餘的,是__型別專屬條目__('MetaExtras'):asset 的 @sha256@ \/ @entry@ \/
--   @ext@ \/ @meta@ \/ @license@ \/ @author@、license 的八個授權維度,以及型別
--   註冊表宣告的任何自訂欄位
--
-- 舊版把整塊由 'MetaOverride' 重寫,第二種條目因此在任何一次 'updateSection'
-- 之後__靜默消失__(spec-gaps G2:依 ADR-013,@pack.md@ 是素材中繼資料的真相,
-- 這是永久資料破壞)。現在 'renderMetaBlock' 必須同時吃兩半,少一半在型別上就
-- 寫不出來。
module Aapms.Md.Render
  ( -- * 寫回
    renderDocument
  , renderSection

    -- * 編輯(Meta 半邊)
  , updateSection
  , updateSectionBody
  , removeSection
  , renameSection
  , replacePreamble
  , overrideAt

    -- * 編輯(型別專屬半邊,graph-core/F004 重跑)
  , updateSectionExtras
  , extrasAt

    -- * 新節
  , appendSection
  , mkSection

    -- * 節的建構 DTO(graph-core/F004,payload 對節點種類做 sum)
  , NewSection (..)
  , NewSectionPayload (..)
  , NewAsset (..)
  , NewLicense (..)
  , NewNode (..)
  , payloadOverride
  , payloadExtras

    -- * 檔案層 frontmatter
  , updateFrontmatter
  , renderFrontmatter
  , frontmatterFieldOrder
  , newDocument

    -- * meta 區塊序列化
  , renderMetaBlock
  , metaFieldOrder
  , MetaExtras (..)
  , extrasOf
  , mergeExtras
  ) where

import Data.Aeson (FromJSON (..), Value (..), withObject, (.!=), (.:), (.:?))
import Data.Char (isDigit, isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)
import Aapms.Core.Asset (LogicalName, Sha256)
import Aapms.Core.Id (Id, Ref, VaultId (..), renderId, renderRef)
import Aapms.Core.Level (NodeKind, renderNodeKind)
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta
import Aapms.Md.Document
import Aapms.Md.Error
import Aapms.Md.Inherit
import Aapms.Md.Lexer (lineTerm, metaBlockYaml, splitLinesKeep)
import Aapms.Md.Yaml (decodeFrontmatter, decodeMeta)

-- | 逐字重組。未經修改的 'Document' 保證
-- @renderDocument (parseDocument t) == t@。
renderDocument :: Document -> Text
renderDocument Document {..} =
  "---" <> docFrontRaw <> "---" <> docPreamble <> T.concat (map renderSection docSections)

renderSection :: Section -> Text
renderSection Section {..} = secHeadingRaw <> fromMaybe "" secMetaRaw <> secBodyRaw

-- | 修改單一節的 meta:__只有該節的 meta 區塊__被重新序列化,其餘逐字不動。
--
-- 節原本沒有 meta 區塊時補一個(前面隔一個空行)。節不存在、或該節原本的
-- meta 區塊 YAML 壞掉(改不動不存在的東西)時回 'Left'。
--
-- __型別專屬條目原封不動__(graph-core/F004 重跑,G2):@f@ 只碰得到
-- 'MetaOverride' 那一半,'extrasOf' 取出的那一半以原始行逐字帶過去。舊版少了
-- 這一步,對 @pack.md@ 的 asset 節做任何一次 'updateSection' 都會吃掉
-- @sha256@ \/ @entry@ —— 依 ADR-013 那是素材中繼資料的真相。
updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document
updateSection = undefined

-- | 某一節目前的 @```meta@ 區塊解出來的覆寫;沒有區塊時是 'emptyOverride'。
--
-- 'updateSection' 內部已經做了同一件事,但呼叫端有時需要__先看過目前的值再
-- 決定要不要改__(@Aapms.Store.Write.removeEntityLink@ 一筆都沒命中時要
-- 中止而不是寫一份沒變的檔案)。把它公開出來,好過讓呼叫端自己去 decode
-- 'secMetaRaw' ——那等於把 meta 區塊的解讀規則複製一份出去。
--
-- 沿用既有實作,不在契約 D 的逐字清單裡(F004 待確認假設 A5):
-- @aapms-store@ 的 @Edit.hs@ 依賴它先看目前值再決定要不要改。
overrideAt :: Id -> Document -> Either MdError MetaOverride
overrideAt i doc = case sectionById i doc of
  Nothing -> Left (mdError 1 (UnknownSectionId i))
  Just s -> currentOverride s

currentOverride :: Section -> Either MdError MetaOverride
currentOverride Section {..} = case secMetaRaw of
  Nothing -> Right emptyOverride
  Just raw -> case decodeMeta (snd (metaBlockYaml raw)) of
    Left msg -> Left (mdError secLine (SectionYaml secId msg))
    Right ov -> Right ov

-- | 保留原本 meta 區塊之前的空行,只換掉 fence 之間的內容。
--
-- graph-core/F004 重跑:多吃一個 'MetaExtras' —— 少了它,重寫等於刪掉節的
-- 型別專屬條目(G2)。
reserialize :: LineEnding -> Section -> MetaOverride -> MetaExtras -> Text
reserialize = undefined

-- meta 區塊的型別專屬那一半 ---------------------------------------------------

-- | @```meta@ 區塊裡__鍵不在 'metaFieldOrder' 中__的頂層條目,以原始行保存。
--
-- 每個元素是一行,__不含行尾字元__(行尾由 'renderMetaBlock' 依 'LineEnding'
-- 補);一個「頂層條目」是「第 0 欄起的 @key:@ 那一行」加上其後所有縮排行與
-- 空行,因此 @meta:@ 這種區塊風格的巢狀值也整段留得住。
--
-- 為什麼是原始行而不是解過的 'Data.Aeson.Value':ADR-010 保護的是作者手寫的
-- 位元組,而解碼再編碼一定會動到引號、數字格式與縮排。這一半我們不需要理解
-- 它的語意,只需要不弄丟它。
newtype MetaExtras = MetaExtras
  { extraLines :: [Text]
  }
  deriving stock (Show, Eq)

-- | 從一個節現有的 @```meta@ 區塊取出型別專屬條目。
--
-- 沒有 meta 區塊、或區塊裡每個頂層條目的鍵都在 'metaFieldOrder' 裡時,回
-- @'MetaExtras' []@。__不解 YAML__:壞掉的區塊照樣抽得出行,壞不壞是
-- 'updateSection' 走 'MetaOverride' 那一半時才會發現的事。
extrasOf :: Section -> MetaExtras
extrasOf = undefined

-- | 'extrasOf' 的 'Id' 版本,與 'overrideAt' 對稱:@aapms-store@ 的寫入路徑
-- 需要__先看目前的專屬欄位__再決定要不要改。節不存在時回 'Left'。
extrasAt :: Id -> Document -> Either MdError MetaExtras
extrasAt = undefined

-- | 兩份專屬條目合併:__第一個參數為新__,同鍵時它贏。
--
-- 結果的順序是「第一個參數的條目依原序在前,第二個參數中鍵未被覆蓋的條目
-- 依原序在後」。這是 'updateSectionExtras' 的「只改我指名的那幾欄、其餘逐字
-- 留著」語意的唯一定義處。
mergeExtras :: MetaExtras -> MetaExtras -> MetaExtras
mergeExtras = undefined

-- | 只改某一節的型別專屬條目:'MetaOverride' 那一半、標題行與正文
-- __一個位元組都不動__。
--
-- 契約 E 的 @writeAssetFields@ \/ @upsertLicense@ 要改的正是這一半
-- (@license@ \/ @author@ \/ @name@、八個授權維度),而
-- @'MetaOverride' -> 'MetaOverride'@ 表達不了它們。節不存在時回 'Left'。
updateSectionExtras :: Id -> (MetaExtras -> MetaExtras) -> Document -> Either MdError Document
updateSectionExtras = undefined

-- 新節的建構 DTO --------------------------------------------------------------

-- | 新節的建構 DTO(graph-core/F004,取代舊 @insertSection@ 直接吃 'Section')。
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

-- | 節的內容,__對節點種類做 sum__(design.md 契約 D,2026-08-24 G1 裁決)。
--
-- 每個建構子都帶一個 'MetaOverride'(四種文件共用的 'Aapms.Core.Meta.Meta'
-- 那一半),外加該種節點自己的專屬欄位。
--
-- __不採__「把 asset \/ license 欄位塞進 'MetaOverride'」:那個型別是 md 與
-- store 共用的節層繼承 DTO,污染它會動到 ADR-010 位元組保留所依賴的繼承規則。
-- 封閉 sum 的好處與契約 A 的 @AnyNode@ 相同:新增節點種類時編譯器會列出所有
-- 待處理處,而 'appendSection' 維持單一入口。
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

-- | payload 的 'Aapms.Core.Meta.Meta' 那一半。
--
-- 'NSNode' 是唯一會動到傳入的 'MetaOverride' 的:@kind@ 落在 'metaFieldOrder'
-- 裡,而 'NewNode' 才是它的真相來源,所以結果的 @moKind@ 一律是
-- @'Just' ('nnKind' n)@,__不管__原本的 @moKind@ 是什麼。其餘三個建構子原樣
-- 回傳自己帶的 'MetaOverride'。
payloadOverride :: NewSectionPayload -> MetaOverride
payloadOverride = undefined

-- | payload 的型別專屬那一半,序列化成 'MetaExtras' 的行。
--
-- 每個建構子產生的鍵是固定的一組,且__與 'metaFieldOrder' 不相交__:
--
-- * 'NSFragment' \/ 'NSNode':無(@kind@ 走 'payloadOverride')
-- * 'NSAsset':@name@ @sha256@ @entry@ @ext@ @meta@ @license@ @author@,依此順序
-- * 'NSLicense':@commercial@ @attribution_required@ @credit_text@
--   @modification_allowed@ @redistribution_allowed@ @resale_allowed@
--   @nft_allowed@ @source_url@,依此順序
--
-- 值為 'Nothing'(以及 'NewAsset' 的 @naKindMeta = 'Null'@)的欄位不輸出——
-- 與 @FromJSON@ 的 @.:?@ 對「鍵不存在」的處置一致,寫出去再解回來是同一份值。
payloadExtras :: NewSectionPayload -> MetaExtras
payloadExtras = undefined

-- | 在文件__最後一節之後__插入新節,沒有任何節時插在最前面(preamble 之後)。
-- 「1,693 節的文件末尾追加一節,前面 1,693 節位元組不變」——這是
-- @insertSection@(entity-graph-core/F003)邏輯的一個特化,語意窄化成固定
-- 「插在最後」以直接對上這條驗收標準。
--
-- 新節的 meta 區塊由 'payloadOverride' 與 'payloadExtras' 兩半組出來,所以
-- 追加一筆 asset \/ 一種授權時寫得出能通過 'Aapms.Md.Parse.toPack' \/
-- 'Aapms.Md.Parse.toLicenses' 驗證的完整新節(G1)。
--
-- __不驗證__節的業務欄位是否與檔案身分相符(把 'NSAsset' 加進主題檔不會在
-- 這裡被擋下來):那是呼叫端與 'Aapms.Md.Parse' 的職責,與本函式不驗證標題
-- 階層是同一個理由。
appendSection :: NewSection -> Document -> Either MdError Document
appendSection = undefined

-- | 插入點之前那一段的結尾:__補到剛好隔一個空行__。
--
-- 兩個坑合在這一個函式裡:原檔尾沒有換行時新節的標題會黏在最後一行後面
-- (entity-graph-core/F003 就已經在防的那個);有換行但沒有空行時檔案雖然解析得回來,
-- 卻長得不像人寫的——而 Vault 是給人看的 git repo,工具產生的段落要與作者
-- 手寫的分不出來。
--
-- 這一個行尾是插入__必然__帶來的改動,不違反 ADR-010:被動到的是插入點,
-- 不是「未經修改的區塊」。
blankTail :: LineEnding -> Text -> Text
blankTail le t
  | T.null t = nl
  | (nl <> nl) `T.isSuffixOf` t = t
  | nl `T.isSuffixOf` t = t <> nl
  | otherwise = t <> nl <> nl
  where
    nl = renderLineEnding le

-- | 刪除節,連同它的 meta 區塊與正文。
removeSection :: Id -> Document -> Either MdError Document
removeSection i doc@Document {..}
  | not (any ((== i) . secId) docSections) = Left (mdError 1 (UnknownSectionId i))
  | otherwise = Right doc {docSections = filter ((/= i) . secId) docSections}

-- | 只換某一節的正文:'secHeadingRaw' 與 'secMetaRaw' __一個位元組都不動__。
-- 改名自 @replaceSectionBody@(entity-graph-core/F005 T3),邏輯不變。
--
-- 新正文不以行尾結尾、而它後面還有下一節時自動補一個——否則下一節的標題會
-- 黏在正文最後一行後面(與 'appendSection' 的 'blankTail' 同一個坑)。
updateSectionBody :: Id -> Text -> Document -> Either MdError Document
updateSectionBody i body doc@Document {..}
  | not (any ((== i) . secId) docSections) = Left (mdError 1 (UnknownSectionId i))
  | otherwise = Right doc {docSections = go docSections}
  where
    go [] = []
    go (s : rest)
      | secId s == i = s {secBodyRaw = pad (null rest) body} : rest
      | otherwise = s : go rest

    pad isLast t
      | isLast = t
      | T.null t = t
      | T.null (lineTerm t) = t <> renderLineEnding docEnding
      | otherwise = t

-- | 只換某一節的標題文字:層級、@{#id}@ 與該行原本的行尾__原樣保留__。
--
-- 片段的標題不在 @```meta@ 區塊裡,而是標題行本身,所以
-- 'Aapms.Md.Inherit.MetaOverride' 表達不了它——檔案層主體改標題走
-- 'updateFrontmatter',節層改標題只能走這裡(service-and-interfaces/F001 補)。
--
-- 只重寫標題那一行,'secMetaRaw' 與 'secBodyRaw' 一個位元組都不動。
renameSection :: Id -> Text -> Document -> Either MdError Document
renameSection i title doc@Document {..} = case sectionById i doc of
  Nothing -> Left (mdError 1 (UnknownSectionId i))
  Just s ->
    let s' =
          s
            { secTitle = title
            , secHeadingRaw =
                T.replicate (secLevel s) "#"
                  <> " "
                  <> title
                  <> " {#"
                  <> renderId i
                  <> "}"
                  <> lineTerm (secHeadingRaw s)
            }
     in Right doc {docSections = map (\x -> if secId x == i then s' else x) docSections}

-- | 只換 frontmatter 與第一個節之間的正文(檔案層主體的 @body@)。
--
-- 'docPreamble' 的第一個字元起算是__結尾界線 @---@ 的行尾__(見
-- "Aapms.Md.Document" 的切片界線),那一段必須留著,否則
-- 'renderDocument' 重組出來的 @---@ 會與正文黏成一行。
replacePreamble :: Text -> Document -> Document
replacePreamble body doc@Document {..} = doc {docPreamble = lead <> nl <> core}
  where
    nl = renderLineEnding docEnding
    lead = case splitLinesKeep docPreamble of
      (l : _) | not (T.null (lineTerm l)) -> lineTerm l
      _ -> nl
    stripped = T.dropWhileEnd (`elem` ['\r', '\n']) body
    core
      | T.null stripped = ""
      | null docSections = stripped <> nl
      | otherwise = stripped <> nl <> nl

-- | 由零件組一個新的 'Section'(給 'appendSection' 用)。
--
-- @secLine@ 填 0:新節還不屬於任何檔案,行號要等重新 parse 才有意義。
--
-- @'Nothing'@ = 完全不產生 @```meta@ 區塊;@'Just' p@ 的區塊內容由
-- 'payloadOverride' 與 'payloadExtras' 兩半組成(graph-core/F004 重跑:原本
-- 吃 @'Maybe' 'MetaOverride'@,只寫得出一半)。
mkSection :: LineEnding -> Int -> Id -> Text -> Maybe NewSectionPayload -> Text -> Section
mkSection = undefined

-- 檔案層 frontmatter --------------------------------------------------------

-- | 改寫檔案層 frontmatter。
--
-- 與節層不同,這是__整段重新序列化__而不是逐欄改寫:frontmatter 是一整塊
-- YAML,沒有像節那樣「只有 meta 區塊要換」的細界線可切。代價是作者寫在
-- frontmatter 裡的 YAML 註解會被抹掉;節層的位元組保留不受影響,而那才是
-- ADR-010 真正在保護的東西——片段是被工具高頻改寫的那一種。
--
-- 吃 @'Meta' -> 'Meta'@ 而不是 @'MetaOverride' -> 'MetaOverride'@:frontmatter
-- 一定是__完整的__ 'Meta',而 'MetaOverride' 連 @id@ 與 @title@ 都沒有——改標題
-- 正是檔案層主體最常見的修改。
--
-- frontmatter 的 YAML 壞掉時回 'Left' 且__不覆蓋__:改不動一份讀不懂的東西。
updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document
updateFrontmatter f doc@Document {..} = case decodeFrontmatter docFrontRaw of
  Left msg -> Left (mdError 1 (FrontmatterYaml msg))
  Right meta -> Right doc {docFrontRaw = lead <> renderFrontmatter (f meta) docEnding}
  where
    -- docFrontRaw 由開頭界線的行尾字元起算,那個字元要原樣留著
    lead = case splitLinesKeep docFrontRaw of
      (l : _) | not (T.null (lineTerm l)) -> lineTerm l
      _ -> renderLineEnding docEnding

-- | 從零產生一份只有 frontmatter 與正文、還沒有任何節的 'Document'
-- (graph-core/F004,取代 @mkDocument@)。
--
-- 三段切片依 'renderDocument' 的重組規則填:@---@ 兩條界線由它重生,
-- 因此 'docFrontRaw' 以行尾開頭、'docPreamble' 以「界線的行尾 + 一行空白」開頭。
--
-- 一律固定用 'LF'——呼叫端要 'CRLF' 的情境(沿用既有檔案的風格)本來就是走
-- 'updateFrontmatter' \/ 'updateSection' 之類的編輯路徑,不會呼叫本函式。
--
-- @kind@ 存進 'Document' 的內部快取欄位,讓新建的 'Document' 呼叫
-- 'Aapms.Md.Document.docKind' 立刻拿得到正確答案,不必先 'renderDocument' 再
-- 'Aapms.Md.Parse.parseDocument' 繞一圈。
newDocument :: DocKind -> Meta -> Text -> Document
newDocument kind meta body =
  Document
    { docFrontRaw = nl <> renderFrontmatter meta le
    , docPreamble = nl <> nl <> body
    , docSections = []
    , docEnding = le
    , docFinalNL = not (T.null (lineTerm body))
    , docKind = kind
    }
  where
    le = LF
    nl = renderLineEnding le

-- | frontmatter 的固定欄位順序。
--
-- 'metaFieldOrder' 的相對順序原樣保留為子序列,只把 @id@ \/ @title@ 插進去、
-- 拿掉 @kind@(frontmatter 描述的是 Entity 或 Level,不是 Node)。
frontmatterFieldOrder :: [Text]
frontmatterFieldOrder =
  [ "id"
  , "type"
  , "vault"
  , "title"
  , "summary"
  , "tags"
  , "status"
  , "timeline"
  , "aliases"
  , "source"
  , "revision"
  , "created"
  , "updated"
  , "links"
  ]

-- | 完整 'Meta' → frontmatter 內容(__不含__ @---@ 界線,含結尾行尾)。
--
-- 與 'renderMetaBlock' 不同,'Meta' 的欄位沒有 'Maybe',所以__每個欄位都會
-- 輸出__。空值(@summary: ""@、@tags: []@)照樣寫出來,讓 frontmatter 自我
-- 說明有哪些欄位。純量的引號規則與 @links@ \/ @timeline@ 的風格與
-- 'renderMetaBlock' 共用同一組輔助函式,不複製一份——複製了兩處的跳脫規則
-- 遲早分歧。
--
-- @type@ \/ @vault@ \/ @revision@(graph-core/F004)先解開 newtype
-- ('TypeKey' \/ 'VaultId' \/ 'Revision') 再交給 'scalar' \/ 'show'——直接對
-- newtype 呼叫衍生的 'Show' 會印成 @TypeKey "asset-pack"@,不是純量文字。
renderFrontmatter :: Meta -> LineEnding -> Text
renderFrontmatter m le = T.concat [l <> nl | l <- concatMap field frontmatterFieldOrder]
  where
    nl = renderLineEnding le

    field :: Text -> [Text]
    field = \case
      "id" -> ["id: " <> renderId (metaId m)]
      "type" -> let TypeKey t = metaType m in ["type: " <> scalar t]
      "vault" -> let VaultId t = metaVault m in ["vault: " <> scalar t]
      "title" -> ["title: " <> scalar (metaTitle m)]
      "summary" -> ["summary: " <> scalar (metaSummary m)]
      "tags" -> ["tags: " <> flowList (metaTags m)]
      "status" -> ["status: " <> renderStatus (metaStatus m)]
      "timeline" ->
        [ case metaTimeline m of
            Nothing -> "timeline: null"
            Just tl -> timelineLine tl
        ]
      "aliases" -> ["aliases: " <> flowList (metaAliases m)]
      "source" -> ["source: " <> scalar (renderSource (metaSource m))]
      "revision" -> let Revision r = metaRevision m in ["revision: " <> T.pack (show r)]
      "created" -> ["created: " <> T.pack (show (metaCreated m))]
      "updated" -> ["updated: " <> T.pack (show (metaUpdated m))]
      "links" -> case metaLinks m of
        [] -> ["links: []"]
        ls -> "links:" : map linkLine ls
      _ -> []

-- | 固定的欄位順序。entity-graph-core/F003 給的九個欄位順序原樣保留為子序列,
-- @kind@ / @vault@ / @created@ / @updated@ 是實作補上的(實作備註 1)。
--
-- 固定順序讓同一份資料每次寫出都一樣,@git diff@ 才乾淨。
metaFieldOrder :: [Text]
metaFieldOrder =
  [ "kind"
  , "type"
  , "vault"
  , "summary"
  , "tags"
  , "status"
  , "timeline"
  , "aliases"
  , "source"
  , "revision"
  , "created"
  , "updated"
  , "links"
  ]

-- | @timeline@ 兩欄皆 'Nothing' 表示「未寫」的 sentinel 值,只有全域 'Just'
-- 才是「這一欄有值」。序列化成完整的 @```meta@ 區塊(含前後 fence 行與結尾
-- 行尾)。值為 'Nothing' 的欄位不輸出。
--
-- 輸出的行序列固定是:@```meta@、'metaFieldOrder' 依序產生的行、
-- @'extraLines'@ 逐字、@```@。型別專屬條目排在 'Aapms.Core.Meta.Meta' 欄位
-- __之後__而不是回到原位:固定順序是「同一份資料每次寫出都一樣、@git diff@
-- 才乾淨」這條規則的延伸,回原位要多存一份位置資訊,而位置本身不是資料
-- (graph-core/F004 重跑,G2)。
renderMetaBlock :: MetaOverride -> MetaExtras -> LineEnding -> Text
renderMetaBlock = undefined

-- | 'metaFieldOrder' 的每一欄怎麼寫成一行。'renderMetaBlock' 的 'MetaOverride'
-- 那一半;值為 'Nothing' 的欄位回空清單。
metaFieldLines :: MetaOverride -> Text -> [Text]
metaFieldLines MetaOverride {..} = \case
  "kind" -> ["kind: " <> renderNodeKind k | Just k <- [moKind]]
  "type" -> ["type: " <> scalar t | Just (TypeKey t) <- [moType]]
  "vault" -> ["vault: " <> scalar t | Just (VaultId t) <- [moVault]]
  "summary" -> ["summary: " <> scalar t | Just t <- [moSummary]]
  "tags" -> ["tags: " <> flowList ts | Just ts <- [moTags]]
  "status" -> ["status: " <> renderStatus s | Just s <- [moStatus]]
  "timeline" -> [timelineLine tl | Just tl <- [moTimeline]]
  "aliases" -> ["aliases: " <> flowList as | Just as <- [moAliases]]
  "source" -> ["source: " <> scalar (renderSource s) | Just s <- [moSource]]
  "revision" -> ["revision: " <> T.pack (show r) | Just (Revision r) <- [moRevision]]
  "created" -> ["created: " <> day d | Just d <- [moCreated]]
  "updated" -> ["updated: " <> day d | Just d <- [moUpdated]]
  "links" -> case moLinks of
    Nothing -> []
    Just [] -> ["links: []"]
    Just ls -> "links:" : map linkLine ls
  _ -> []
  where
    day :: Day -> Text
    day = T.pack . show

-- | @timeline: 埃提亞崩塌前@(僅 label)或 @timeline: {label: ..., order: 3}@。
timelineLine :: Timeline -> Text
timelineLine Timeline {..} = case (tlLabel, tlOrder) of
  (Just l, Nothing) -> "timeline: " <> scalar l
  (Nothing, Nothing) -> "timeline: {}"
  (Nothing, Just n) -> "timeline: {order: " <> T.pack (show n) <> "}"
  (Just l, Just n) ->
    "timeline: {label: " <> flowScalar l <> ", order: " <> T.pack (show n) <> "}"

-- | @  - {kind: partOf, target: ent-7f3a}@
linkLine :: Link -> Text
linkLine Link {..} =
  "  - {kind: "
    <> flowScalar (renderLinkKind linkKind)
    <> ", target: "
    <> flowScalar (renderRef linkTarget)
    <> maybe "" (\n -> ", note: " <> flowScalar n) linkNote
    <> "}"

flowList :: [Text] -> Text
flowList xs = "[" <> T.intercalate ", " (map flowScalar xs) <> "]"

-- | 區塊上下文的純量:必要時才加引號。
scalar :: Text -> Text
scalar t
  | needsQuote t = quote t
  | otherwise = t

-- | 流式上下文(@{}@ 與 @[]@ 之內)另外要避開 @,@ @{@ @}@ @[@ @]@。
flowScalar :: Text -> Text
flowScalar t
  | needsQuote t || T.any (`elem` (",{}[]" :: String)) t = quote t
  | otherwise = t

needsQuote :: Text -> Bool
needsQuote t =
  T.null t
    || T.strip t /= t
    || maybe False (`elem` ("-?:,[]{}#&*!|>'\"%@`" :: String)) (fst <$> T.uncons t)
    || T.isInfixOf ": " t
    || T.isInfixOf " #" t
    || T.any (`elem` ("\n\t\r" :: String)) t
    || T.toLower t `elem` ["true", "false", "null", "yes", "no", "on", "off", "~"]
    || looksNumeric t

looksNumeric :: Text -> Bool
looksNumeric t = case T.uncons t of
  Nothing -> False
  Just (c, _) ->
    (isDigit c || c == '+' || c == '-' || c == '.')
      && T.all (\x -> isDigit x || x `elem` ("+-.eExXaAbBcCdDfF_" :: String)) t

-- | 雙引號字串。YAML 的雙引號風格支援反斜線跳脫。
quote :: Text -> Text
quote t = "\"" <> foldl' esc "" (T.unpack t) <> "\""
  where
    esc acc c = acc <> case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _ -> T.singleton c
