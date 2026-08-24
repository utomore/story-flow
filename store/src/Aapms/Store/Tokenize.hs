-- | 中日韓文字的 n-gram 預切、FTS 六欄投影與查詢路由(graph-core\/F007;ADR-016)。
--
-- == 為什麼需要這個模組
--
-- FTS5 給的兩個 tokenizer 各自都處理不了中文:
--
-- * @trigram@ 把文字切成三字元窗格,中文因此可以子字串搜尋——但 FTS5 規定
--   @MATCH@ 的查詢__至少三個字元__。而「藥水」「琳達」「金門」這類二字詞
--   正是中文專有名詞的主要形態。
-- * @unicode61@ 把一整段中文當成__一個__ token,搜「藥水」對不上「魔法藥水瓶」。
--
-- 解法是自己控制 token 流:把中日韓序列展開成 unigram + bigram、以空白分隔後
-- 寫進一張 @unicode61@ 索引(@fts_cjk@),原文則照樣寫進 @trigram@ 索引
-- (@fts_tri@)。unicode61 遇空白斷詞,而中日韓字元本身不是分隔符,所以
-- 「藥 水 藥水」正好被切成三個 token,二字詞變成精確比對。
--
-- __本模組是純的__:不碰 SQLite、不碰檔案。寫入端(@Aapms.Store.Index@)呼叫
-- 'ftsRowOf' 取得一個節點的兩份六欄內容,再交給
-- 'Aapms.Store.Schema.insertFtsRows' 落地;查詢端(@Aapms.Store.Query@)呼叫
-- 'routeOf' 決定查哪張表、'triMatchExpr' \/ 'cjkMatchExpr' 產生 @MATCH@ 運算式。
--
-- __ADR-016 第四條__:索引是衍生物,本模組的切詞規則('cjkSegment' \/
-- 'ftsRowOf')只要行為改變,就必須 bump 'Aapms.Store.Schema.schemaVersion' 讓
-- 索引整庫重建,__不寫任何遷移程式__。寫入與查詢共用同一段切詞程式碼,是這個
-- 作法唯一要守住的不變量。
module Aapms.Store.Tokenize
  ( -- * 字元判定
    isCjk
  , hasCjk
  , cjkRuns

    -- * 索引側:六欄投影與預切
  , FtsText (..)
  , FtsRow (..)
  , rawFtsText
  , segmentFtsText
  , ftsRowOf
  , cjkSegment
  , desegmentCjk

    -- * 查詢側:路由與 MATCH 運算式
  , SearchRoute (..)
  , usesTrigram
  , usesCjk
  , routeOf
  , triMatchExpr
  , cjkMatchExpr

    -- * FTS5 字面字串
  , ftsQuoted
  , ftsPhrase
  ) where

import Aapms.Core.AnyNode (AnyNode)
import Aapms.Core.Id (Id)
import Data.Text (Text)

--------------------------------------------------------------------------------
-- 字元判定

-- | 中日韓字元。判斷錯的代價不對稱:多收一個字元只是多幾個 token,漏掉一個
-- 字元就是永遠搜不到,所以假名與諺文也算進來。
isCjk :: Char -> Bool
isCjk = undefined

-- | 這段文字裡有沒有任何中日韓字元。
hasCjk :: Text -> Bool
hasCjk = undefined

-- | 極大的中日韓連續段,依出現順序。非中日韓字元是分段點,空段不回傳。
--
-- 分段是為了不讓 bigram 跨越非中日韓字元:「台灣 日本」若產生「灣日」,
-- 搜「灣日」會誤中一筆語意上不存在的結果。
cjkRuns :: Text -> [Text]
cjkRuns = undefined

--------------------------------------------------------------------------------
-- 索引側

-- | 一個節點進 FTS 的六個欄位,對應 @fts_tri@ \/ @fts_cjk@ 的欄位順序。
--
-- 同一個型別同時表示「原文」(給 @fts_tri@)與「預切後的 n-gram 串」
-- (給 @fts_cjk@)——兩者形狀相同,差別只在內容,由 'FtsRow' 的欄位區分。
data FtsText = FtsText
  { ftTitle :: Text
  , ftSummary :: Text
  , ftBody :: Text
  -- ^ 節點正文。@body@ 進 FTS 但不進 @nodes@(design.md):正文只有檔案有。
  -- 'Aapms.Core.Level.Level' 與 'Aapms.Core.Level.Node' 沒有正文,為空字串。
  , ftAliases :: Text
  , ftTags :: Text
  , ftName :: Text
  -- ^ asset 的邏輯名稱;其他節點種類為空字串。
  }
  deriving stock (Show, Eq)

-- | 一個節點要寫進兩張 FTS 表的完整內容。
data FtsRow = FtsRow
  { frNode :: Id
  -- ^ 節點 id;落地時經 @fts_map@ 換成兩張 FTS 表共用的 rowid。
  , frTri :: FtsText
  -- ^ @fts_tri@ 的內容:原文,不做任何切詞。
  , frCjk :: FtsText
  -- ^ @fts_cjk@ 的內容:每一欄都已經是 'cjkSegment' 的輸出。
  }
  deriving stock (Show, Eq)

-- | 節點 → 六欄原文。純投影,不做切詞。
rawFtsText :: AnyNode -> FtsText
rawFtsText = undefined

-- | 逐欄套用 'cjkSegment'。
segmentFtsText :: FtsText -> FtsText
segmentFtsText = undefined

-- | 寫入端的單一入口(「模組間公開介面」的 Index → Tokenize)。
ftsRowOf :: AnyNode -> FtsRow
ftsRowOf = undefined

-- | 把一段文字預切成 @fts_cjk@ 用的 token 串:先所有 unigram、再所有 bigram,
-- 以單一空白分隔。非中日韓字元一律丟棄。
--
-- @
-- "金門建築"      -> "金 門 建 築 金門 門建 建築"
-- "藥水"          -> "藥 水 藥水"
-- "金"            -> "金"
-- "台灣 日本"      -> "台 灣 日 本 台灣 日本"   -- 不產生「灣日」
-- "hello world"   -> ""
-- @
--
-- unigram 與 bigram 放同一欄不會互相干擾:unicode61 對空白分隔的內容產生的
-- token 就是這些字串本身,長度 1 的 token 永遠不等於長度 2 的 token,而查詢
-- 端('cjkMatchExpr')對同一段輸入只會產生其中一種,片語比對因此不會跨過
-- unigram\/bigram 的交界。
cjkSegment :: Text -> Text
cjkSegment = undefined

-- | 'cjkSegment' 的還原:把 token 串併回連續文字,重疊的 bigram 只保留一次。
-- 供 @fts_cjk@ 的 @snippet()@ 輸出還原成人看得懂的片段。
--
-- @
-- "金 門 建 築 金門 門建 建築" -> "金門建築"
-- @
desegmentCjk :: Text -> Text
desegmentCjk = undefined

--------------------------------------------------------------------------------
-- 查詢側

-- | 一次查詢要走哪張(或哪兩張)FTS 表。
data SearchRoute
  = -- | 只查 @fts_tri@:查詢字串不含中日韓字元
    TrigramOnly
  | -- | 只查 @fts_cjk@:含中日韓字元,且整串長度不到三個字元
    -- (trigram 對三字元以下的查詢必定空結果,不值得多一次子查詢)
    CjkOnly
  | -- | 兩張都查,結果以分數合併去重:含中日韓字元且長度三個字元以上
    BothIndexes
  deriving stock (Show, Eq)

-- | 這條路由要不要查 @fts_tri@。
usesTrigram :: SearchRoute -> Bool
usesTrigram = undefined

-- | 這條路由要不要查 @fts_cjk@。
usesCjk :: SearchRoute -> Bool
usesCjk = undefined

-- | 依查詢字串的長度與字元類別決定路由(「模組間公開介面」的 Query → Tokenize)。
-- 判斷對象是去掉頭尾空白之後的字串。
routeOf :: Text -> SearchRoute
routeOf = undefined

-- | @fts_tri@ 的 @MATCH@ 運算式。去掉頭尾空白後為空字串時回 'Nothing'。
triMatchExpr :: Text -> Maybe Text
triMatchExpr = undefined

-- | @fts_cjk@ 的 @MATCH@ 運算式。查詢字串不含中日韓字元時回 'Nothing'
-- ——那種查詢該走 @fts_tri@。
--
-- 多段中日韓的輸入(如「台灣 建築」)取全部 bigram 做單一片語比對會過度嚴格,
-- 所以各段之間以 @AND@ 連接,段內才用片語。
cjkMatchExpr :: Text -> Maybe Text
cjkMatchExpr = undefined

--------------------------------------------------------------------------------
-- FTS5 字面字串

-- | 把使用者輸入包成 FTS5 的字面字串。
--
-- FTS5 的 @MATCH@ 語法會把 @*@ @:@ @^@ @-@ @(@ @)@ @"@ 當成運算子,使用者搜
-- 「blue-potion」時那個減號會被解讀成 NOT。加雙引號可以全部關掉,內部的雙引號
-- 則以重複兩次跳脫。
ftsQuoted :: Text -> Text
ftsQuoted = undefined

-- | 把已經是空白分隔的 token 串包成片語查詢:要求這些 token 在文件中__連續
-- 出現__,所以「金門建築」不會誤中只含「金門」與不相鄰的「建築」的文件。
ftsPhrase :: Text -> Text
ftsPhrase = undefined
