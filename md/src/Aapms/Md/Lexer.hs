-- | 逐行切塊 —— 兩階段解析的第一階段(ADR-010)。
--
-- 本模組只認得四件事:哪幾行是 frontmatter、哪一行是節標題、哪一段是
-- @```meta@ 區塊、其餘是正文。每一塊的__原始文字原封不動保留__,解讀是
-- "Aapms.Md.Parse" 的事。
--
-- == 分節界線(entity-graph-core/F003 實作備註 2)
--
-- __第一個帶 @{#id}@ 的標題才開始分節__。system.md 的琳達範例裡
-- @# 琳達@ 因此留在 'Aapms.Md.Document.docPreamble';第一個節之後的標題
-- 一律必須帶 @{#id}@,否則是 'HeadingWithoutId'。副作用是片段正文裡不能再用
-- Markdown 子標題——對「節即片段」的格式來說這是想要的行為。
--
-- 圍籬區塊(@```@ / @~~~@)內的行一律不當標題也不當 meta 區塊,因此正文裡
-- 貼一段含 @#@ 或 @```meta@ 的程式碼不會被誤判。
--
-- == 單一錯誤契約(graph-core/F004 待確認假設 A2)
--
-- 契約 D 的 'lexDocument' 只回一個 'MdError'。內部仍然照舊蒐集__全部__結構
-- 錯誤(標題缺 id、id 重複、meta 區塊未關閉……)——這是實作細節,不影響對外
-- 型別——只是最後依 'errLine' 取最小的一筆對外回報。'DuplicateSectionId' 因此
-- 併進同一個蒐集池:若某份文件同時有一個缺 id 的標題(較早的行)與一組重複
-- id(較晚的行),回報的是行號較早的那一個。
module Aapms.Md.Lexer
  ( -- * 進入點
    lexDocument

    -- * 行的處理
  , splitLinesKeep
  , lineTerm
  , lineContent

    -- * 標題
  , Heading (..)
  , parseHeadingLine

    -- * meta 區塊
  , metaBlockYaml
  , fenceInfo
  ) where

import Data.Char (isSpace)
import Data.Either (partitionEithers)
import Data.List (minimumBy)
import Data.Maybe (isJust)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id, parseId)
import Aapms.Md.Document
import Aapms.Md.Error

-- | 一行(含行尾)在原檔的位置與標題判定結果。
data Line = Line
  { lnNo :: Int
  , lnRaw :: Text
  , lnHeading :: Maybe Heading
  -- ^ @Nothing@ = 不是標題,或位於圍籬區塊內
  }

-- | 節標題的三個成分。
data Heading = Heading
  { hLevel :: Int
  , hTitle :: Text
  , hId :: Maybe Text
  -- ^ @{#id}@ 的內容,尚未 'parseId'
  }
  deriving stock (Show, Eq)

-- | 切行但__保留行尾__。最後一行沒有行尾時原樣回傳。
splitLinesKeep :: Text -> [Text]
splitLinesKeep t
  | T.null t = []
  | otherwise = case T.breakOn "\n" t of
      (pre, rest)
        | T.null rest -> [pre]
        | otherwise -> (pre <> "\n") : splitLinesKeep (T.drop 1 rest)

-- | 一行的行尾字元(@"\\r\\n"@ / @"\\n"@ / 檔尾無行尾的 @""@)。
lineTerm :: Text -> Text
lineTerm l
  | "\r\n" `T.isSuffixOf` l = "\r\n"
  | "\n" `T.isSuffixOf` l = "\n"
  | otherwise = ""

-- | 去掉行尾後的內容。
lineContent :: Text -> Text
lineContent l = T.dropEnd (T.length (lineTerm l)) l

isBlankLine :: Text -> Bool
isBlankLine = T.all isSpace . lineContent

-- | ATX 標題行。@## 外貌 {#ent-7f3b}@ 得 @(2, "外貌", Just "ent-7f3b")@。
--
-- 標題文字含 @#@ 時不誤切:切 id 用的是__最後一個__ @{#@,而 @#@ 的計數只在
-- 行首連續段落上。
parseHeadingLine :: Text -> Maybe Heading
parseHeadingLine raw
  | level < 1 || level > 6 = Nothing
  | not (T.null rest) && not (isSpace (T.head rest)) = Nothing
  | otherwise = Just (Heading level title mid)
  where
    content = lineContent raw
    (marks, rest) = T.span (== '#') content
    level = T.length marks
    text = T.strip rest
    (title, mid) = splitIdAttr text

-- | 由標題文字尾端切出 @{#id}@。
splitIdAttr :: Text -> (Text, Maybe Text)
splitIdAttr text = case T.stripSuffix "}" text of
  Nothing -> (text, Nothing)
  Just before -> case T.breakOnEnd "{#" before of
    (pre, idt)
      | T.null pre -> (text, Nothing)
      | T.null idt -> (text, Nothing)
      | T.any isSpace idt -> (text, Nothing)
      | otherwise -> (T.stripEnd (T.dropEnd 2 pre), Just idt)

-- | 圍籬行的 @(字元, 長度, info string)@。縮排超過 3 個空白不算圍籬。
fenceInfo :: Text -> Maybe (Char, Int, Text)
fenceInfo raw
  | indent > 3 = Nothing
  | otherwise = case T.uncons stripped of
      Just (ch, _)
        | ch == '`' || ch == '~'
        , let (marks, rest) = T.span (== ch) stripped
        , T.length marks >= 3 ->
            Just (ch, T.length marks, T.strip rest)
      _ -> Nothing
  where
    content = lineContent raw
    stripped = T.dropWhile (== ' ') content
    indent = T.length content - T.length stripped

isMetaFence :: Text -> Bool
isMetaFence raw = case fenceInfo raw of
  Just (_, _, info) -> info == "meta"
  Nothing -> False

-- | 是否為關閉 @(ch, n)@ 圍籬的行:同字元、長度不短於開啟、且沒有 info string。
closesFence :: Char -> Int -> Text -> Bool
closesFence ch n raw = case fenceInfo raw of
  Just (ch', n', info) -> ch' == ch && n' >= n && T.null info
  Nothing -> False

-- | 切出 'Document'。結構錯誤只回報行號最小的一筆(graph-core/F004,見本模組
-- 頂端說明);frontmatter 層級的錯誤中止解析(後面的內容失去了繼承來源,
-- 再解析下去只會產生一連串誤導的次生錯誤)。
--
-- 'docKind' 欄位在這裡只填佔位值 'TopicDoc'——本模組不解讀 frontmatter 的
-- YAML,真正的身分由 'Aapms.Md.Parse.parseDocument' 讀出 @type@ 後覆寫。
lexDocument :: Text -> Either MdError Document
lexDocument src = do
  (frontRaw, closeIdx) <- frontmatter
  let closeLine = ls !! closeIdx
      afterRaw = drop (closeIdx + 1) ls
      tagged = tagLines (closeIdx + 2) afterRaw
      -- 第一個「帶 id 的標題」才開始分節;在它之前的標題屬於 preamble
      (preLines, secLines) = break startsSection tagged
      preamble = lineTerm closeLine <> T.concat (map lnRaw preLines)
      (chunkErrs, secs) = partitionEithers (concatMap chunkToSection (splitChunks secLines))
      allErrs = chunkErrs ++ duplicateErrors secs
  case allErrs of
    (e : es) -> Left (minimumBy (comparing errLine) (e : es))
    [] ->
      Right
        Document
          { docFrontRaw = frontRaw
          , docPreamble = preamble
          , docSections = secs
          , docEnding = detectLineEnding src
          , docFinalNL = "\n" `T.isSuffixOf` src
          , docKind = TopicDoc
          }
  where
    ls = splitLinesKeep src

    startsSection l = case lnHeading l of
      Just h -> isJust (hId h)
      Nothing -> False

    frontmatter :: Either MdError (Text, Int)
    frontmatter = case ls of
      [] -> Left (mdError 1 NoFrontmatter)
      (l0 : rest)
        | lineContent l0 /= "---" -> Left (mdError 1 NoFrontmatter)
        | otherwise -> case break ((== "---") . lineContent) rest of
            (_, []) -> Left (mdError 1 UnterminatedFrontmatter)
            (inside, _) ->
              Right (lineTerm l0 <> T.concat inside, length inside + 1)

    -- 逐行標記,並追蹤圍籬狀態
    tagLines :: Int -> [Text] -> [Line]
    tagLines = go Nothing
      where
        go _ _ [] = []
        go fence n (l : rest) = case fence of
          Just (ch, k)
            | closesFence ch k l -> Line n l Nothing : go Nothing (n + 1) rest
            | otherwise -> Line n l Nothing : go fence (n + 1) rest
          Nothing -> case fenceInfo l of
            Just (ch, k, _) -> Line n l Nothing : go (Just (ch, k)) (n + 1) rest
            Nothing -> Line n l (parseHeadingLine l) : go Nothing (n + 1) rest

    -- 由第一個節開始,每遇到標題就切一塊
    splitChunks :: [Line] -> [[Line]]
    splitChunks [] = []
    splitChunks (x : xs) =
      let (body, more) = break (isJust . lnHeading) xs
       in (x : body) : splitChunks more

    chunkToSection :: [Line] -> [Either MdError Section]
    chunkToSection [] = []
    chunkToSection (h : body) = case lnHeading h of
      Nothing -> [] -- splitChunks 保證第一行是標題
      Just Heading {..} -> case hId >>= toId of
        Nothing -> [Left (mdError (lnNo h) (HeadingWithoutId hTitle))]
        Just i -> case takeMetaBlock body of
          Left e -> [Left e]
          Right (metaRaw, rest) ->
            [ Right
                Section
                  { secLevel = hLevel
                  , secHeadingRaw = lnRaw h
                  , secTitle = hTitle
                  , secId = i
                  , secMetaRaw = metaRaw
                  , secBodyRaw = T.concat (map lnRaw rest)
                  , secLine = lnNo h
                  }
            ]

    toId :: Text -> Maybe Id
    toId t = either (const Nothing) (Just . snd) (parseId t)

    -- 標題之後只隔空行就出現的 ```meta 才算 meta 區塊
    takeMetaBlock :: [Line] -> Either MdError (Maybe Text, [Line])
    takeMetaBlock body =
      let (blanks, rest) = span (isBlankLine . lnRaw) body
       in case rest of
            (f : afterFence)
              | isMetaFence (lnRaw f)
              , Just (ch, k, _) <- fenceInfo (lnRaw f) ->
                  case break (closesFence ch k . lnRaw) afterFence of
                    (_, []) -> Left (mdError (lnNo f) UnterminatedMetaBlock)
                    (inside, close : after) ->
                      Right
                        ( Just (T.concat (map lnRaw (blanks ++ [f] ++ inside ++ [close])))
                        , after
                        )
            _ -> Right (Nothing, body)

    -- 同一個 id 的第二次(含)之後的出現各記一筆(graph-core/F004:併進同一個
    -- 蒐集池,與 chunkErrs 一起依 errLine 取最小)。
    duplicateErrors :: [Section] -> [MdError]
    duplicateErrors = go []
      where
        go _ [] = []
        go seen (s : rest)
          | secId s `elem` seen = mdError (secLine s) (DuplicateSectionId (secId s)) : go seen rest
          | otherwise = go (secId s : seen) rest

-- | 由 'Aapms.Md.Document.secMetaRaw' 取出 YAML 內容,
-- 以及它相對於該切片第一行的行位移(0 起算)。
--
-- 位移供錯誤行號換算:@YAML 第 p 行@ 的檔案行號 =
-- @secLine + 位移 + p@。
metaBlockYaml :: Text -> (Int, Text)
metaBlockYaml raw =
  let ls = splitLinesKeep raw
      (blanks, rest) = span isBlankLine ls
   in case rest of
        (f : afterFence) -> case fenceInfo f of
          Just (ch, k, _) ->
            let inside = takeWhile (not . closesFence ch k) afterFence
             in (length blanks + 1, T.concat inside)
          Nothing -> (length blanks, T.concat rest)
        [] -> (length blanks, "")
