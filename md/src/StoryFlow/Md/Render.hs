-- | 寫回與單節編輯(ADR-0010)。
--
-- 'renderDocument' 只是把每一段原始切片依序接起來,因此__位元組相等是結構上
-- 保證的__,不是靠測試碰運氣。編輯函式集中在本模組一處,是為了讓「只重寫被修改
-- 的那一段」這條保證有一個守得住的邊界。
--
-- @```meta@ 區塊的序列化__自己寫,不用 YAML 編碼器__:只有被修改的節需要重寫,
-- 格式完全由我們決定(欄位順序固定、@links@ 用流式風格、字串只在必要時加引號);
-- 引入編碼器反而要對抗它的排版偏好。
module StoryFlow.Md.Render
  ( -- * 寫回
    renderDocument
  , renderSection

    -- * 編輯
  , updateSection
  , insertSection
  , removeSection
  , mkSection

    -- * meta 區塊序列化
  , renderMetaBlock
  , metaFieldOrder
  ) where

import Data.Char (isDigit, isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)
import StoryFlow.Core.Id (Id, renderId, renderRef)
import StoryFlow.Core.Level (renderNodeKind)
import StoryFlow.Core.Link (Link (..), renderLinkKind)
import StoryFlow.Core.Meta
import StoryFlow.Md.Document
import StoryFlow.Md.Error
import StoryFlow.Md.Inherit
import StoryFlow.Md.Lexer (lineTerm, metaBlockYaml, splitLinesKeep)
import StoryFlow.Md.Yaml (decodeMeta)

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
  Nothing -> Right doc {docSections = new : docSections}
  Just i
    | not (any ((== i) . secId) docSections) -> Left (MdError docPath 1 (UnknownSectionId i))
    | otherwise -> Right doc {docSections = go docSections}
    where
      go [] = []
      go (s : rest)
        | secId s == i = (if null rest && not docFinalNL then padNL s else s) : new : rest
        | otherwise = s : go rest
      -- 檔尾沒有換行時先補上,否則新節的標題會黏在原本的最後一行後面
      padNL s = s {secBodyRaw = secBodyRaw s <> renderLineEnding docEnding}

-- | 刪除節,連同它的 meta 區塊與正文。
removeSection :: Id -> Document -> Either MdError Document
removeSection i doc@Document {..}
  | not (any ((== i) . secId) docSections) = Left (MdError docPath 1 (UnknownSectionId i))
  | otherwise = Right doc {docSections = filter ((/= i) . secId) docSections}

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

-- | 固定的欄位順序。func-0003 給的九個欄位順序原樣保留為子序列,
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
