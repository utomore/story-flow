-- | 中日韓文字的 n-gram 前處理。
--
-- == 為什麼需要這個模組
--
-- SQLite 的 FTS5 給我們兩個 tokenizer,兩個都無法單獨處理中文:
--
-- * @unicode61@(預設)把整段中文當成**一個** token。
--   「金門建築」是一個詞,搜「金門」得不到任何結果。
--
-- * @trigram@ 把文字切成三字元窗格,中文因此可以子字串搜尋 ——
--   但 FTS5 規定 @MATCH@ 的查詢**至少要三個字元**。
--   而中文的雙字詞(金門、行銷、廟宇、素材、建築)極其常見。
--
-- 解法是自己控制 token 流:把中日韓序列展開成 n-gram,以空白分隔後寫進
-- 一張 @unicode61@ 索引。unicode61 遇空白斷詞,而中日韓字元本身不是分隔符,
-- 所以「金門 門建 建築」正好被切成三個 token,雙字詞變成精確比對。
--
-- == 為什麼 unigram 與 bigram 要分成兩欄
--
-- 直覺上會想把兩者串在同一欄。實際上會壞掉,因為 bigram 比對倚賴**片語查詢**
-- (要求 token 連續出現),而混入 unigram 會打亂相對位置:
--
-- @
-- 索引「台灣金門建築」→ 台 灣 金 門 建 築 台灣 灣金 金門 門建 建築
-- 查詢「金門建築」    → 金 門 建 築 金門 門建 建築
-- @
--
-- 查詢要求「築」後面緊接「金門」,但索引裡「築」後面是「台灣」—— 比對失敗。
-- 分成兩欄之後,單字查詢走 unigram 欄,雙字以上走 bigram 欄,各自乾淨。
--
-- 寫入與查詢共用同一段程式碼,是這個作法唯一需要守住的不變量。
module AssetDB.Store.Tokenize
  ( -- * 索引側
    CjkIndex (..)
  , cjkIndex
  , cjkUnigrams
  , cjkBigrams

    -- * 查詢側
  , cjkMatchExpr

    -- * 判定
  , hasCJK
  , isCJK

    -- * FTS5 字串跳脫
  , ftsPhrase
  , ftsQuoted
  ) where

import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T

-- | 中日韓字元。範圍取自 Unicode 區塊定義。
--
-- 包含假名與諺文,因為素材包作者遍布東亞,而且判斷錯的代價不對稱:
-- 多收一個字元只是多幾個 token,漏掉一個字元就是永遠搜不到。
isCJK :: Char -> Bool
isCJK c =
  let o = ord c
   in (o >= 0x3040 && o <= 0x30FF) -- 平假名、片假名
        || (o >= 0x3400 && o <= 0x4DBF) -- 統一表意文字擴充 A
        || (o >= 0x4E00 && o <= 0x9FFF) -- 統一表意文字
        || (o >= 0xF900 && o <= 0xFAFF) -- 相容表意文字
        || (o >= 0xAC00 && o <= 0xD7AF) -- 諺文音節
        || (o >= 0x20000 && o <= 0x2FA1F) -- 擴充 B–F

hasCJK :: Text -> Bool
hasCJK = T.any isCJK

--------------------------------------------------------------------------------
-- 索引側

-- | 一筆文件的中日韓索引內容,對應 @assets_cjk@ 的兩個欄位。
data CjkIndex = CjkIndex
  { cjkUni :: Text
  -- ^ 空白分隔的單字元,支援單字查詢。
  , cjkBi :: Text
  -- ^ 空白分隔的重疊雙字元,支援雙字以上的片語查詢。
  }
  deriving stock (Eq, Show)

cjkIndex :: Text -> CjkIndex
cjkIndex t = CjkIndex {cjkUni = cjkUnigrams t, cjkBi = cjkBigrams t}

-- | 取出所有中日韓字元,以空白分隔。
--
-- @"1990 年代金門" -> "年 代 金 門"@
cjkUnigrams :: Text -> Text
cjkUnigrams = T.unwords . map T.singleton . T.unpack . T.filter isCJK

-- | 每段中日韓序列展開成重疊雙字元。**長度 1 的序列不產生任何 bigram**
-- —— 那種情況由 'cjkUnigrams' 負責。
--
-- @
-- "金門建築"      -> "金門 門建 建築"
-- "金門"          -> "金門"
-- "金"            -> ""
-- "台灣 日本"      -> "台灣 日本"   -- 不會跨越空白產生「灣日」
-- "hello world"   -> ""
-- @
cjkBigrams :: Text -> Text
cjkBigrams = T.unwords . concatMap bigramsOf . cjkRuns

-- | 極大的中日韓連續段。分段是為了不讓 bigram 跨越非中日韓字元 ——
-- 「台灣 日本」若產生「灣日」,搜尋「灣日」會誤中一筆語意上不存在的結果。
cjkRuns :: Text -> [Text]
cjkRuns = filter (not . T.null) . go
  where
    go t
      | T.null t = []
      | otherwise =
          let rest = T.dropWhile (not . isCJK) t
              (run, after) = T.span isCJK rest
           in if T.null run then [] else run : go after

bigramsOf :: Text -> [Text]
bigramsOf run
  | T.length run < 2 = []
  | otherwise = [T.take 2 (T.drop i run) | i <- [0 .. T.length run - 2]]

--------------------------------------------------------------------------------
-- 查詢側

-- | 把使用者輸入轉成 @assets_cjk@ 的 @MATCH@ 運算式。
-- 輸入不含中日韓字元時回傳 'Nothing' —— 那種查詢該走 trigram 索引。
--
-- @
-- "金"        -> Just "uni : \\"金\\""
-- "金門"      -> Just "bi : \\"金門\\""
-- "金門建築"  -> Just "bi : \\"金門 門建 建築\\""
-- "potion"    -> Nothing
-- @
--
-- 多段中日韓的輸入(如「台灣 建築」)取全部 bigram 做片語比對會過度嚴格,
-- 所以各段之間以 AND 連接,段內才用片語。
cjkMatchExpr :: Text -> Maybe Text
cjkMatchExpr term =
  case cjkRuns term of
    [] -> Nothing
    runs ->
      let clauses = map clauseFor runs
       in Just (T.intercalate " AND " clauses)
  where
    clauseFor run
      | T.length run < 2 = "uni : " <> ftsQuoted run
      | otherwise = "bi : " <> ftsPhrase (T.unwords (bigramsOf run))

--------------------------------------------------------------------------------
-- FTS5 字串跳脫

-- | 把使用者輸入包成 FTS5 的字面字串。
--
-- FTS5 的 @MATCH@ 語法會把 @*@ @:@ @^@ @-@ @(@ @)@ @"@ 當成運算子,
-- 使用者搜「blue-potion」時那個減號會被解讀成 NOT。加雙引號可以全部關掉,
-- 內部的雙引號則以重複兩次跳脫。
ftsQuoted :: Text -> Text
ftsQuoted t = "\"" <> T.replace "\"" "\"\"" t <> "\""

-- | 把已經是空白分隔的 token 串包成片語查詢。
--
-- 片語查詢要求這些 token 在文件中**連續出現**,所以「金門建築」不會誤中
-- 只含有「金門」與不相鄰的「建築」的文件。
ftsPhrase :: Text -> Text
ftsPhrase = ftsQuoted . T.unwords . T.words
