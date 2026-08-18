-- | 輸出。兩種模式共用同一組資料,分開 render。
--
-- __@--json@ 是統一信封__:成功與失敗都是合法 JSON、都印到 stdout。
--
-- @
-- {"ok": true,  "data": \<資料本體\>}
-- {"ok": false, "error": {"code": "entity_not_found", "message": "…"}}
-- @
--
-- 信封化(而不是「成功印本體、失敗印 stderr」)的理由是 AI Agent 只要 parse
-- 一種形狀。代價是 @jq@ 要多一層 @.data@,對人來說是小事——人本來就不會加
-- @--json@。
--
-- @data@ 是 service 的 View 型別經 "StoryFlow.Service.Json" 序列化的結果,
-- __CLI 不重新編碼__;@code@ \/ @message@ 同樣來自 service 的 'errorCode' \/
-- 'renderServiceError'。三種介面(CLI、server、MCP)因此講同一套話。
module StoryFlow.Cli.Render
  ( -- * 信封
    Envelope (..)
  , encodeEnvelope

    -- * 人類可讀
  , renderEntity
  , renderMetaTable
  , renderSearch
  , renderLinks
  , renderLevelTree
  , renderVaults
  , renderVaultInfo
  , renderTypes
  , renderIndexReport
  , renderDelete
  , renderCreated

    -- * 排版工具
  , displayWidth
  , padTo
  , table
  ) where

import Data.Aeson (ToJSON (..), encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (renderId, renderRef)
import StoryFlow.Core.Level (Level (..), Node (..), renderNodeKind)
import StoryFlow.Core.Link (Link (..), renderLinkKind)
import StoryFlow.Core.Meta (Meta (..), Timeline (..), renderSource, renderStatus)
import StoryFlow.Core.Registry (EntityTypeSpec (..), FieldSpec (..))
import StoryFlow.Core.Tree (NodeTree (..))
import StoryFlow.Service

-- 信封 -------------------------------------------------------------------------

-- | 成功與失敗都是合法 JSON。@Err@ 的兩個欄位依序是 @code@ 與 @message@。
data Envelope a
  = Ok a
  | Err Text Text
  deriving stock (Show, Eq)

instance (ToJSON a) => ToJSON (Envelope a) where
  toJSON (Ok a) = object ["ok" .= True, "data" .= a]
  toJSON (Err c m) = object ["ok" .= False, "error" .= object ["code" .= c, "message" .= m]]

-- | 編成一行 UTF-8 文字。
--
-- 走 'TE.decodeUtf8' 回 'Text' 而不是直接把 'BL.ByteString' 寫進 handle:
-- 同一個 handle 上其他輸出都是 'Text',混用位元組寫入會在 Windows 上與換行
-- 轉換打架。aeson 的 @encode@ 不會把非 ASCII 逃逸成 @\\uXXXX@,繁中原樣出來。
encodeEnvelope :: (ToJSON a) => Envelope a -> Text
encodeEnvelope = TE.decodeUtf8 . BL.toStrict . encode

-- 人類可讀:Entity ---------------------------------------------------------------

-- | frontmatter 風格的欄位清單 + 正文。
renderEntity :: EntityView -> Text
renderEntity v =
  T.intercalate "\n" $
    fields
      ++ ["path:      " <> T.pack (evPath v) <> anchor]
      ++ linkBlock
      ++ bodyBlock
  where
    e = evEntity v
    m = entMeta e
    anchor = maybe "" ("#" <>) (evAnchor v)
    fields =
      [ "id:        " <> renderId (metaId m)
      , "vault:     " <> metaVault m
      , "type:      " <> metaType m
      , "title:     " <> metaTitle m
      , "summary:   " <> metaSummary m
      , "tags:      " <> commas (metaTags m)
      , "status:    " <> renderStatus (metaStatus m)
      , "timeline:  " <> renderTimeline (metaTimeline m)
      , "aliases:   " <> commas (metaAliases m)
      , "source:    " <> renderSource (metaSource m)
      , "revision:  " <> tshow (metaRevision m)
      , "created:   " <> T.pack (show (metaCreated m))
      , "updated:   " <> T.pack (show (metaUpdated m))
      ]
    linkBlock
      | null (metaLinks m) = ["links:     (無)"]
      | otherwise = "links:" : map (("  " <>) . renderLink) (metaLinks m)
    bodyBlock
      | T.null (T.strip (entBody e)) = []
      | otherwise = ["", entBody e]

renderTimeline :: Timeline -> Text
renderTimeline (Timeline lbl ord') = case (lbl, ord') of
  (Nothing, Nothing) -> "(無)"
  (Just l, Nothing) -> l
  (Nothing, Just o) -> "(無標籤,order " <> tshow o <> ")"
  (Just l, Just o) -> l <> "(order " <> tshow o <> ")"

-- | @kind → target(說明)@。一行一條,不對齊——關聯的數量通常個位數,
-- 對齊帶來的閱讀增益抵不過欄寬跳動。
renderLink :: Link -> Text
renderLink (Link k t n) =
  renderLinkKind k <> " → " <> renderRef t <> maybe "" (\x -> "(" <> x <> ")") n

-- | @id | type | status | title | summary@ 的對齊表格。
--
-- 欄寬以__顯示寬度__計算而非字元數:繁中一個字佔兩格,用 'T.length' 對齊的表格
-- 在有中文標題時會整排歪掉。
renderMetaTable :: [Meta] -> Text
renderMetaTable [] = "(沒有符合的項目)"
renderMetaTable ms = table ["id", "type", "status", "title", "summary"] (map row ms)
  where
    row m =
      [ renderId (metaId m)
      , metaType m
      , renderStatus (metaStatus m)
      , metaTitle m
      , metaSummary m
      ]

renderSearch :: [SearchHit] -> Text
renderSearch [] = "(沒有命中)"
renderSearch hs = table ["id", "type", "status", "title", "summary", "snippet"] (map row hs)
  where
    row (SearchHit m s) =
      [ renderId (metaId m)
      , metaType m
      , renderStatus (metaStatus m)
      , metaTitle m
      , metaSummary m
      , oneLine s
      ]

-- | 正向與反向一次印完:「這個片段跟什麼有關」在作者心裡是一個問題,不是兩個。
renderLinks :: LinkReport -> Text
renderLinks (LinkReport out inc) =
  T.intercalate "\n" $
    ("正向(從這裡指出去):" : block (map renderLink out))
      ++ ("反向(指到這裡來):" : block (map incoming inc))
  where
    block [] = ["  (無)"]
    block xs = map ("  " <>) xs
    incoming (src, l) = renderId src <> " ─" <> renderLinkKind (linkKind l) <> "→ 這裡"

-- 人類可讀:Level 樹 -------------------------------------------------------------

-- | ASCII 樹,形狀與 architecture.md 的場景樹圖一致。
--
-- 吃的是 'lvTree'(已經是 'NodeTree'),__不自己從扁平清單重建__ ——
-- 'StoryFlow.Core.Tree.buildTree' 已經驗證過合法性,再重建一次就是第二份樹邏輯。
renderLevelTree :: LevelView -> Text
renderLevelTree v =
  T.intercalate "\n" $
    (renderId (lvId v) <> " " <> metaTitle (lvlMeta (lvLevel v)))
      : go "" True (lvTree v)
  where
    go indent isLast t =
      line indent isLast (ntNode t)
        : concat
          [ go (indent <> childIndent isLast) (i == length kids - 1) c
          | (i, c) <- zip [0 ..] kids
          ]
      where
        kids = ntChildren t
    childIndent True = "   "
    childIndent False = "│  "
    line indent isLast n =
      let head' = indent <> (if isLast then "└─ " else "├─ ")
          label = head' <> renderId (metaId (nodMeta n)) <> " " <> renderNodeKind (nodKind n)
       in padTo summaryColumn label <> nodeText n
    -- 摘要一律從第 25 欄開始;標籤已經超過就退讓成兩個空格(architecture.md 的
    -- 圖裡 interaction 那一行就是這種情形)
    summaryColumn = 25
    nodeText n =
      let m = nodMeta n
       in if T.null (metaSummary m) then metaTitle m else metaSummary m

-- 人類可讀:其餘 -----------------------------------------------------------------

renderVaults :: [VaultView] -> Text
renderVaults [] = "(全域註冊表裡還沒有 Vault;用 story-flow vault init 建一個)"
renderVaults vs = table ["name", "root"] [[vvName v, T.pack (vvRoot v)] | v <- vs]

renderVaultInfo :: VaultView -> Text
renderVaultInfo v =
  T.intercalate
    "\n"
    [ "name:     " <> vvName v
    , "root:     " <> T.pack (vvRoot v)
    , "entities: " <> maybe "(未計算)" tshow (vvEntityCount v)
    ]

renderTypes :: [EntityTypeSpec] -> Text
renderTypes [] = "(型別註冊表是空的)"
renderTypes ts = table ["key", "name", "dir", "required", "allowed_links"] (map row ts)
  where
    row t =
      [ etsKey t
      , etsName t
      , fromMaybe "-" (etsDir t)
      , commas [fsName f | f <- etsFields t, fsRequired f]
      , commas (map renderLinkKind (etsAllowedLinks t))
      ]

renderIndexReport :: IndexReport -> Text
renderIndexReport r = "已索引 " <> tshow (irFiles r) <> " 個檔案"

renderDelete :: DeleteReport -> Text
renderDelete r =
  "已刪除 "
    <> T.intercalate "、" (map renderId (delRemoved r))
    <> "("
    <> T.pack (delPath r)
    <> ")"
    <> broken
  where
    broken
      | null (delBrokenLinks r) = ""
      | otherwise =
          ";打斷了 " <> tshow (length (delBrokenLinks r)) <> " 條指進來的關聯"

-- | 寫入類指令的一行結果。
renderCreated :: Text -> EntityView -> Text
renderCreated verb v =
  verb <> " " <> renderId (evId v) <> "(" <> T.pack (evPath v) <> anchor <> ")"
  where
    anchor = maybe "" ("#" <>) (evAnchor v)

-- 排版工具 ---------------------------------------------------------------------

-- | 終端上的顯示寬度。CJK 全形字佔兩格。
displayWidth :: Text -> Int
displayWidth = T.foldl' (\acc c -> acc + charWidth c) 0

charWidth :: Char -> Int
charWidth c = if isWide (ord c) then 2 else 1

-- | 全形範圍。取 East Asian Wide / Fullwidth 的主要區段——CJK、假名、諺文與
-- 全形標點。精確到每個 codepoint 需要一整份 Unicode 表,而這一層只是為了讓
-- 表格不歪。
isWide :: Int -> Bool
isWide o =
  (o >= 0x1100 && o <= 0x115F)
    || (o >= 0x2E80 && o <= 0x303E)
    || (o >= 0x3041 && o <= 0x33FF)
    || (o >= 0x3400 && o <= 0x4DBF)
    || (o >= 0x4E00 && o <= 0x9FFF)
    || (o >= 0xA000 && o <= 0xA4CF)
    || (o >= 0xAC00 && o <= 0xD7A3)
    || (o >= 0xF900 && o <= 0xFAFF)
    || (o >= 0xFE30 && o <= 0xFE4F)
    || (o >= 0xFF00 && o <= 0xFF60)
    || (o >= 0xFFE0 && o <= 0xFFE6)
    || (o >= 0x20000 && o <= 0x3FFFD)

-- | 補空格到指定的顯示寬度;已經超過就原樣回、後面至少留兩格。
padTo :: Int -> Text -> Text
padTo n t
  | w >= n = t <> "  "
  | otherwise = t <> T.replicate (n - w) " "
  where
    w = displayWidth t

-- | 表頭 + 資料列,欄與欄之間以 @ | @ 分隔。
--
-- 每一列的欄數都與表頭相同——@--json@ 之外的輸出也該是可以用 @cut@ 切的。
table :: [Text] -> [[Text]] -> Text
table headers rows = T.intercalate "\n" (map line (headers : rows))
  where
    widths = [maximum (map displayWidth col) | col <- transpose' (headers : rows)]
    line cells =
      T.stripEnd (T.intercalate " | " [pad w c | (w, c) <- zip widths cells])
    pad w c = c <> T.replicate (max 0 (w - displayWidth c)) " "

-- | 'Data.List.transpose' 對齊到最長列——這裡的列長一定相同,但自己寫一份
-- 就不必為了一個函式把 @containers@ 的相依理由講成別的。
transpose' :: [[Text]] -> [[Text]]
transpose' xss
  | all null xss = []
  | otherwise = map headOr xss : transpose' (map (drop 1) xss)
  where
    headOr (x : _) = x
    headOr [] = ""

commas :: [Text] -> Text
commas [] = "(無)"
commas xs = T.intercalate ", " xs

oneLine :: Text -> Text
oneLine = T.unwords . T.words

tshow :: (Show a) => a -> Text
tshow = T.pack . show
