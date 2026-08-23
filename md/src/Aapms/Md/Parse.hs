-- | 兩階段解析的第二階段:把 'Document' 的原始切片解讀成核心型別。
--
-- 檔案層 frontmatter 的 @type: level@ 是判別依據('documentKind'):@level@ 走
-- Level 解析,否則走 Entity 解析。@level@ 因此是保留型別鍵,不可用於
-- @types\/registry\/@(由 entity-graph-core/F002 的 @validateRegistry@ 把關)。
--
-- 錯誤__盡量往下走完再一次回報全部__——作者手改一份檔案常一次壞好幾節,
-- 一次列完比修一個跑一次快得多。只有 frontmatter 層級的錯誤會中止解析,
-- 因為後面的內容失去了繼承來源,再解析下去只會產生一連串誤導的次生錯誤。
module Aapms.Md.Parse
  ( -- * 進入點
    parseDocument
  , documentKind
  , DocKind (..)

    -- * Entity 檔
  , EntityFile (..)
  , parseEntityFile

    -- * Level 檔
  , LevelFile (..)
  , parseLevelFile
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (..), Ref, idPrefix, parseId, renderIdPrefix)
import Aapms.Core.Json ()
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.Link (Link (..), LinkKind (Involves, References))
import Aapms.Core.Meta (Meta (..))
import Aapms.Md.Document
import Aapms.Md.Error
import Aapms.Md.Inherit
import Aapms.Md.Lexer (lexDocument, metaBlockYaml)
import Aapms.Md.Yaml

-- | 檔案的兩種身分。
data DocKind = DocEntity | DocLevel
  deriving stock (Show, Eq)

data EntityFile = EntityFile
  { efMain :: Entity
  -- ^ 檔案層主體
  , efFragments :: [Entity]
  -- ^ 各節
  }
  deriving stock (Show, Eq)

data LevelFile = LevelFile
  { lfLevel :: Level
  , lfNodes :: [Node]
  -- ^ @parent@ / @order@ 已由標題階層填好,直接餵給 core 的 @buildTree@ 即可
  }
  deriving stock (Show, Eq)

-- | 切塊(見 "Aapms.Md.Lexer")+ 節 id 唯一性檢查。
parseDocument :: FilePath -> Text -> Either [MdError] Document
parseDocument path src = do
  doc <- lexDocument path src
  case duplicateErrors doc of
    [] -> Right doc
    es -> Left es

-- | 同一個 id 的第二次(含)之後的出現各記一筆。
duplicateErrors :: Document -> [MdError]
duplicateErrors Document {..} = go [] docSections
  where
    go _ [] = []
    go seen (s : rest)
      | secId s `elem` seen = MdError docPath (secLine s) (DuplicateSectionId (secId s)) : go seen rest
      | otherwise = go (secId s : seen) rest

documentKind :: Document -> Either [MdError] DocKind
documentKind doc = do
  v <- frontValue doc
  case v of
    Object o -> case KM.lookup "type" o of
      Just (String "level") -> Right DocLevel
      Just (String _) -> Right DocEntity
      _ -> Left [MdError (docPath doc) 1 (RequiredFieldMissing "type")]
    _ -> Left [MdError (docPath doc) 1 (RequiredFieldMissing "type")]

-- | frontmatter 的 aeson 'Value'。
--
-- 'docFrontRaw' 以開頭界線的行尾字元起始,所以 YAML 的第 n 行剛好就是檔案的
-- 第 n 行,行號不需要換算。
frontValue :: Document -> Either [MdError] Value
frontValue Document {..} = case decodeValue docFrontRaw of
  Left (l, m) -> Left [MdError docPath l (FrontmatterYaml m)]
  Right v -> Right v

-- | frontmatter 的 'Value' 與檔案層 'Meta'。缺必填欄位一次列完。
frontMeta :: Document -> Either [MdError] (Value, Meta)
frontMeta doc = do
  v <- frontValue doc
  case missingFields requiredFrontFields v of
    [] -> case fromValue v of
      Left m -> Left [MdError (docPath doc) 1 (FrontmatterYaml m)]
      Right meta -> Right (v, meta)
    missing -> Left [MdError (docPath doc) 1 (RequiredFieldMissing f) | f <- missing]

-- | 節的 @```meta@ 區塊。沒有區塊視為全部欄位未寫。
sectionOverride :: FilePath -> Section -> Either [MdError] MetaOverride
sectionOverride path Section {..} = case secMetaRaw of
  Nothing -> Right emptyOverride
  Just raw ->
    let (off, yaml) = metaBlockYaml raw
     in case decodeMetaAt yaml of
          Left (l, m) -> Left [MdError path (secLine + off + l) (SectionYaml secId m)]
          Right ov -> Right ov

-- | 節 id 的前綴必須與檔案的身分相符。
prefixErrors :: FilePath -> IdPrefix -> Section -> [MdError]
prefixErrors path want Section {..} =
  [ MdError path secLine (IdPrefixMismatch secId (renderIdPrefix want))
  | idPrefix secId /= want
  ]

-- | 檔案層 frontmatter 描述主體 Entity,'docPreamble' 是它的 @body@;
-- 每個節是一個片段 Entity。
parseEntityFile :: Document -> Either [MdError] (EntityFile, [MdWarning])
parseEntityFile doc@Document {..} = do
  (_, front) <- frontMeta doc
  let results = map (fragment front) docSections
      errs = concat [e | Left e <- results]
      oks = [x | Right x <- results]
  if null errs
    then
      Right
        ( EntityFile
            { efMain = Entity front (T.strip docPreamble)
            , efFragments = map fst oks
            }
        , concatMap snd oks
        )
    else Left errs
  where
    fragment :: Meta -> Section -> Either [MdError] (Entity, [MdWarning])
    fragment front s@Section {..} =
      case (prefixErrors docPath PEnt s, sectionOverride docPath s) of
        (pe, Left ye) -> Left (pe ++ ye)
        (pe@(_ : _), Right _) -> Left pe
        ([], Right ov) ->
          let (meta, ws) = inheritMeta front secId secTitle ov
              body = T.strip secBodyRaw
           in Right (Entity meta body, ws ++ [EmptyBody secId | T.null body])

-- | 標題階層即樹(ADR-009):層級決定 @parent@,文件順序決定 @order@。
--
-- 本函式__不呼叫__ @buildTree@——結構合法性是 core 的職責,這裡只負責把文字
-- 變成 Node 清單。
parseLevelFile :: Document -> Either [MdError] (LevelFile, [MdWarning])
parseLevelFile doc@Document {..} = do
  (v, front) <- frontMeta doc
  let (structErrs, placed) = structure docPath docSections
      results = map (node front) placed
      errs = structErrs ++ concat [e | Left e <- results]
      oks = [x | Right x <- results]
  root <- rootId doc v
  if null errs
    then
      Right
        ( LevelFile
            { lfLevel = Level front root
            , lfNodes = map fst oks
            }
        , concatMap snd oks
        )
    else Left errs
  where
    node :: Meta -> (Section, Maybe Id, Int) -> Either [MdError] (Node, [MdWarning])
    node front (s@Section {..}, parent, order) =
      case (prefixErrors docPath PNod s, sectionOverride docPath s) of
        (pe, Left ye) -> Left (pe ++ ye)
        (pe@(_ : _), Right _) -> Left pe
        ([], Right ov) -> case moKind ov of
          Nothing -> Left [MdError docPath secLine (MissingNodeKind secId)]
          Just k ->
            let (meta, ws) = inheritMeta front secId secTitle ov
             in Right
                  ( Node
                      { nodMeta = meta
                      , nodLevel = metaId front
                      , nodParent = parent
                      , nodOrder = order
                      , nodKind = k
                      , nodEntities = entitiesOf meta
                      }
                  , ws
                  )

    -- Node 指向的 Entity 由 involves / references 推導,不另設 entities 欄位
    entitiesOf :: Meta -> [Ref]
    entitiesOf meta =
      nub [linkTarget l | l <- metaLinks meta, linkKind l `elem` [Involves, References]]

-- | frontmatter 的 @root@:寫了就要與第一個節相符,沒寫就以第一個節填入。
rootId :: Document -> Value -> Either [MdError] Id
rootId Document {..} v = case (declared, docSections) of
  (Nothing, s : _) -> Right (secId s)
  (Nothing, []) -> Left [MdError docPath 1 (RequiredFieldMissing "root")]
  (Just d, s : _)
    | d /= secId s -> Left [MdError docPath 1 (RootMismatch d (secId s))]
    | otherwise -> Right d
  (Just d, []) -> Right d
  where
    declared = case v of
      Object o -> case KM.lookup "root" o of
        Just (String s) -> either (const Nothing) (Just . snd) (parseId s)
        _ -> Nothing
      _ -> Nothing

-- | 由標題層級算出每個節的 @parent@ 與 @order@,並回報跳級/越級。
structure :: FilePath -> [Section] -> ([MdError], [(Section, Maybe Id, Int)])
structure _ [] = ([], [])
structure path (s0 : rest) = go [] M.empty rootLevel (s0 : rest)
  where
    rootLevel = secLevel s0

    go :: [(Int, Id)] -> M.Map (Maybe Id) Int -> Int -> [Section] -> ([MdError], [(Section, Maybe Id, Int)])
    go _ _ _ [] = ([], [])
    go stack orders prev (s : more) =
      let lvl = secLevel s
          errsHere
            | lvl < rootLevel = [MdError path (secLine s) (HeadingAboveRoot rootLevel lvl)]
            | lvl > prev + 1 = [MdError path (secLine s) (HeadingSkip prev lvl)]
            | otherwise = []
          stack' = dropWhile ((>= lvl) . fst) stack
          parent = case stack' of
            ((_, p) : _) -> Just p
            [] -> Nothing
          order = M.findWithDefault 0 parent orders + 1
          (es, ps) = go ((lvl, secId s) : stack') (M.insert parent order orders) lvl more
       in (errsHere ++ es, (s, parent, order) : ps)
