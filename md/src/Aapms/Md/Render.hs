-- | 寫回與單節編輯(ADR-010)。
--
-- 'renderDocument' 只是把每一段原始切片依序接起來,因此__位元組相等是結構上
-- 保證的__,不是靠測試碰運氣。編輯函式集中在本模組一處,是為了讓「只重寫被修改
-- 的那一段」這條保證有一個守得住的邊界。
--
-- @```meta@ 區塊的序列化__自己寫,不用 YAML 編碼器__:只有被修改的節需要重寫,
-- 格式完全由我們決定(欄位順序固定、@links@ 用流式風格、字串只在必要時加引號);
-- 引入編碼器反而要對抗它的排版偏好。
module Aapms.Md.Render
  ( -- * 寫回
    renderDocument
  , renderSection

    -- * 編輯
  , updateSection
  , insertSection
  , removeSection
  , mkSection
  , replaceSectionBody
  , replacePreamble
  , renameSection
  , overrideAt

    -- * 檔案層 frontmatter
  , updateFrontmatter
  , renderFrontmatter
  , frontmatterFieldOrder
  , mkDocument

    -- * meta 區塊序列化
  , renderMetaBlock
  , metaFieldOrder
  ) where

import Data.Char (isDigit, isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)
import Aapms.Core.Id (Id, renderId, renderRef)
import Aapms.Core.Level (renderNodeKind)
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta
import Aapms.Md.Document
import Aapms.Md.Error
import Aapms.Md.Inherit
import Aapms.Md.Lexer (lineTerm, metaBlockYaml, splitLinesKeep)
import Aapms.Md.Yaml (decodeFrontmatter, decodeMeta)

-- | 逐字重組。未經修改的 'Document' 保證
-- @renderDocument (parseDocument p t) == t@。
renderDocument :: Document -> Text
renderDocument Document {..} =
  "---" <> docFrontRaw <> "---" <> docPreamble <> T.concat (map renderSection docSections)

renderSection :: Section -> Text
renderSection Section {..} = secHeadingRaw <> fromMaybe "" secMetaRaw <> secBodyRaw

-- | 修改單一節的 meta:__只有該節的 meta 區塊__被重新序列化,其餘逐字不動。
--
-- 節原本沒有 meta 區塊時補一個(前面隔一個空行)。節不存在、或該節原本的
-- meta 區塊 YAML 壞掉(改不動不存在的東西)時回 'Left'。
updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document
updateSection i f doc@Document {..} = case sectionById i doc of
  Nothing -> Left (MdError docPath 1 (UnknownSectionId i))
  Just s -> do
    old <- currentOverride docPath s
    let s' = s {secMetaRaw = Just (reserialize docEnding s (f old))}
    Right doc {docSections = map (\x -> if secId x == i then s' else x) docSections}

-- | 某一節目前的 @```meta@ 區塊解出來的覆寫;沒有區塊時是 'emptyOverride'。
--
-- 'updateSection' 內部已經做了同一件事,但呼叫端有時需要__先看過目前的值再
-- 決定要不要改__('Aapms.Store.Write.removeEntityLink' 一筆都沒命中時要
-- 中止而不是寫一份沒變的檔案)。把它公開出來,好過讓呼叫端自己去 decode
-- 'secMetaRaw' ——那等於把 meta 區塊的解讀規則複製一份出去。
overrideAt :: Id -> Document -> Either MdError MetaOverride
overrideAt i doc@Document {..} = case sectionById i doc of
  Nothing -> Left (MdError docPath 1 (UnknownSectionId i))
  Just s -> currentOverride docPath s

currentOverride :: FilePath -> Section -> Either MdError MetaOverride
currentOverride path Section {..} = case secMetaRaw of
  Nothing -> Right emptyOverride
  Just raw -> case decodeMeta (snd (metaBlockYaml raw)) of
    Left msg -> Left (MdError path secLine (SectionYaml secId msg))
    Right ov -> Right ov

-- | 保留原本 meta 區塊之前的空行,只換掉 fence 之間的內容。
reserialize :: LineEnding -> Section -> MetaOverride -> Text
reserialize le Section {..} ov = lead <> trimTail (renderMetaBlock ov le)
  where
    lead = case secMetaRaw of
      Just raw -> T.concat (takeWhile isBlank (splitLinesKeep raw))
      Nothing -> renderLineEnding le
    -- 原本的 meta 區塊在檔尾且沒有行尾時,重寫後也不補
    trimTail t = case secMetaRaw of
      Just raw | T.null (lineTerm raw) -> T.dropWhileEnd (`elem` ['\r', '\n']) t
      _ -> t
    isBlank l = T.all isSpace l

-- | 在指定節之後插入新節;@Nothing@ 表示插在最前面(preamble 之後)。
--
-- 「之後」是__該節本身__之後,不是它整棵子樹之後——Level 檔要插進子樹尾端時
-- 指定該子樹的最後一節即可。
insertSection :: Maybe Id -> Section -> Document -> Either MdError Document
insertSection mAfter new doc@Document {..} = case mAfter of
  Nothing -> Right doc {docPreamble = blankTail docEnding docPreamble, docSections = new : docSections}
  Just i
    | not (any ((== i) . secId) docSections) -> Left (MdError docPath 1 (UnknownSectionId i))
    | otherwise -> Right doc {docSections = go docSections}
    where
      go [] = []
      go (s : rest)
        | secId s == i = pad s : new : rest
        | otherwise = s : go rest
      pad s = s {secBodyRaw = blankTail docEnding (secBodyRaw s)}

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
  | not (any ((== i) . secId) docSections) = Left (MdError docPath 1 (UnknownSectionId i))
  | otherwise = Right doc {docSections = filter ((/= i) . secId) docSections}

-- | 只換某一節的正文:'secHeadingRaw' 與 'secMetaRaw' __一個位元組都不動__。
--
-- 新正文不以行尾結尾、而它後面還有下一節時自動補一個——否則下一節的標題會
-- 黏在正文最後一行後面(與 'insertSection' 的 @padNL@ 同一個坑)。
replaceSectionBody :: Id -> Text -> Document -> Either MdError Document
replaceSectionBody i body doc@Document {..}
  | not (any ((== i) . secId) docSections) = Left (MdError docPath 1 (UnknownSectionId i))
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
  Nothing -> Left (MdError docPath 1 (UnknownSectionId i))
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

-- | 由零件組一個新的 'Section'(給 'insertSection' 用)。
--
-- @secLine@ 填 0:新節還不屬於任何檔案,行號要等重新 parse 才有意義。
mkSection :: LineEnding -> Int -> Id -> Text -> Maybe MetaOverride -> Text -> Section
mkSection le level i title mOv body =
  Section
    { secLevel = level
    , secHeadingRaw =
        T.replicate level "#" <> " " <> title <> " {#" <> renderId i <> "}" <> nl
    , secTitle = title
    , secId = i
    , secMetaRaw = fmap (\ov -> nl <> renderMetaBlock ov le) mOv
    , secBodyRaw = body
    , secLine = 0
    }
  where
    nl = renderLineEnding le

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
  Left msg -> Left (MdError docPath 1 (FrontmatterYaml msg))
  Right meta -> Right doc {docFrontRaw = lead <> renderFrontmatter (f meta) docEnding}
  where
    -- docFrontRaw 由開頭界線的行尾字元起算,那個字元要原樣留著
    lead = case splitLinesKeep docFrontRaw of
      (l : _) | not (T.null (lineTerm l)) -> lineTerm l
      _ -> renderLineEnding docEnding

-- | 從零產生一份只有 frontmatter 與正文、還沒有任何節的 'Document'。
--
-- 三段切片依 'renderDocument' 的重組規則填:@---@ 兩條界線由它重生,
-- 因此 'docFrontRaw' 以行尾開頭、'docPreamble' 以「界線的行尾 + 一行空白」開頭。
--
-- Entity 檔與 Level 檔共用同一個函式:Level 的 @root@ 由標題階層推導
-- (ADR-009)不寫進 frontmatter,兩者的差別只在 'metaType' 是不是 @level@。
--
-- @docPath@ 留空——新文件還不屬於任何檔案,要用於錯誤訊息時由呼叫端填。
mkDocument :: LineEnding -> Meta -> Text -> Document
mkDocument le meta body =
  Document
    { docPath = ""
    , docFrontRaw = nl <> renderFrontmatter meta le
    , docPreamble = nl <> nl <> body
    , docSections = []
    , docEnding = le
    , docFinalNL = not (T.null (lineTerm body))
    }
  where
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
renderFrontmatter :: Meta -> LineEnding -> Text
renderFrontmatter m le = T.concat [l <> nl | l <- concatMap field frontmatterFieldOrder]
  where
    nl = renderLineEnding le

    field :: Text -> [Text]
    field = \case
      "id" -> ["id: " <> renderId (metaId m)]
      "type" -> ["type: " <> scalar (metaType m)]
      "vault" -> ["vault: " <> scalar (metaVault m)]
      "title" -> ["title: " <> scalar (metaTitle m)]
      "summary" -> ["summary: " <> scalar (metaSummary m)]
      "tags" -> ["tags: " <> flowList (metaTags m)]
      "status" -> ["status: " <> renderStatus (metaStatus m)]
      "timeline" -> [timelineLine (metaTimeline m)]
      "aliases" -> ["aliases: " <> flowList (metaAliases m)]
      "source" -> ["source: " <> scalar (renderSource (metaSource m))]
      "revision" -> ["revision: " <> T.pack (show (metaRevision m))]
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

-- | 序列化成完整的 @```meta@ 區塊(含前後 fence 行與結尾行尾)。
-- 值為 @Nothing@ 的欄位不輸出。
renderMetaBlock :: MetaOverride -> LineEnding -> Text
renderMetaBlock MetaOverride {..} le =
  "```meta" <> nl <> T.concat [l <> nl | l <- concatMap field metaFieldOrder] <> "```" <> nl
  where
    nl = renderLineEnding le

    field :: Text -> [Text]
    field = \case
      "kind" -> ["kind: " <> renderNodeKind k | Just k <- [moKind]]
      "type" -> ["type: " <> scalar t | Just t <- [moType]]
      "vault" -> ["vault: " <> scalar t | Just t <- [moVault]]
      "summary" -> ["summary: " <> scalar t | Just t <- [moSummary]]
      "tags" -> ["tags: " <> flowList ts | Just ts <- [moTags]]
      "status" -> ["status: " <> renderStatus s | Just s <- [moStatus]]
      "timeline" -> [timelineLine tl | Just tl <- [moTimeline]]
      "aliases" -> ["aliases: " <> flowList as | Just as <- [moAliases]]
      "source" -> ["source: " <> scalar (renderSource s) | Just s <- [moSource]]
      "revision" -> ["revision: " <> T.pack (show r) | Just r <- [moRevision]]
      "created" -> ["created: " <> day d | Just d <- [moCreated]]
      "updated" -> ["updated: " <> day d | Just d <- [moUpdated]]
      "links" -> linkLines
      _ -> []

    linkLines = case moLinks of
      Nothing -> []
      Just [] -> ["links: []"]
      Just ls -> "links:" : map linkLine ls

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
