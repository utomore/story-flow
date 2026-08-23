-- | 全文搜尋的可用性驗證。
--
-- 這是整個 schema 裡最不確定的部分,所以測試寫得比較細:
--
-- 1. @sqlite-simple@ 綁的 SQLite 到底有沒有編進 FTS5?
-- 2. @trigram@ tokenizer 在不在?(需要 SQLite >= 3.34)
-- 3. **中文搜得到嗎?** 這是整個搜尋設計成敗的關鍵。
--
-- 第 3 題的答案分兩半:三字以上靠 trigram,雙字以下靠自己前處理的
-- bigram / unigram 索引。兩條路徑都必須測到。
module AssetDB.Store.FtsSpec (spec) where

import AssetDB.Store
import AssetDB.Store.Tokenize
import Control.Monad (void)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = do
  describe "SQLite 能力探測" $ do
    it "編進了 FTS5" $ inMemory $ \st -> do
      opts <- query_ (storeConn st) "PRAGMA compile_options" :: IO [Only Text]
      map fromOnly opts `shouldSatisfy` any (T.isInfixOf "FTS5")

    it "trigram tokenizer 可用" $ inMemory $ \st -> do
      execute_ (storeConn st) "CREATE VIRTUAL TABLE probe USING fts5(x, tokenize='trigram')"
      execute_ (storeConn st) "INSERT INTO probe(x) VALUES ('hello world')"
      hits <- query_ (storeConn st) "SELECT x FROM probe WHERE probe MATCH 'ell'" :: IO [Only Text]
      length hits `shouldBe` 1

  describe "assets_fts(trigram)" $ around withSeeded $ do
    it "以完整詞搜尋" $ \st ->
      search st "travel" `shouldReturn` [1]

    it "以子字串搜尋 —— 這是 trigram 相對於 unicode61 的主要好處" $ \st ->
      -- unicode61 會把 blue-potion 切成 blue / potion,搜 "otion" 完全落空
      search st "otion" `shouldReturn` [2]

    it "跨欄位:打作者名找得到素材" $ \st ->
      search st "Crusenho" `shouldReturn` [1]

    it "打廠商原始檔名也找得到" $ \st ->
      search st "TravelBook" `shouldReturn` [1]

    it "查詢裡的減號不會被當成 NOT 運算子" $ \st ->
      search st "blue-potion" `shouldReturn` [2]

    it "搜不到的東西回空" $ \st ->
      search st "nonexistent" `shouldReturn` []

  describe "中文搜尋" $ around withSeeded $ do
    it "三字以上:trigram 就夠了" $ \st ->
      search st "金門建築" `shouldReturn` [3]

    it "中文子字串:trigram" $ \st ->
      search st "門建築" `shouldReturn` [3]

    it "兩字詞:trigram 搜不到 —— 這是它的硬限制" $ \st ->
      -- 記錄實際行為而不是假裝它可以。FTS5 規定 trigram 的 MATCH
      -- 至少三個字元,兩字詞永遠是空結果。assets_cjk 就是為此存在。
      search st "金門" `shouldReturn` []

    it "兩字詞:bigram 索引找得到" $ \st ->
      searchCJK st "金門" `shouldReturn` [3]

    it "bigram 索引也吃得下長詞" $ \st ->
      searchCJK st "金門建築" `shouldReturn` [3]

    it "單字查詢走 unigram 欄" $ \st ->
      searchCJK st "書" `shouldReturn` [1]

    it "片語查詢不會誤中不相鄰的組合" $ \st ->
      -- 第 1 筆含「書本樣式」與「圖示」,但沒有「式圖」這個相鄰組合
      searchCJK st "式圖" `shouldReturn` []

    it "多段查詢以 AND 連接" $ \st ->
      searchCJK st "年代 建築" `shouldReturn` [3]

    it "中日韓查詢不會誤中純 ASCII 資料" $ \st ->
      searchCJK st "建築" `shouldReturn` [3]

--------------------------------------------------------------------------------

inMemory :: (Store -> IO a) -> IO a
inMemory f = do
  st <- openStoreInMemory
  r <- f st
  close (storeConn st)
  pure r

-- | 三筆代表性資料:一筆英文 GUI 素材、一筆英文道具、一筆中文參考資料。
data Row = Row
  { rId :: Int
  , rLogical :: Text
  , rOriginal :: Text
  , rEntry :: Text
  , rTags :: Text
  , rPack :: Text
  , rAuthor :: Text
  , rNotes :: Text
  }

rows :: [Row]
rows =
  [ Row 1 "ui_gui_travel-book-frame_01a" "UI_TravelBook_Frame01a.png"
      "Sprites/UI_TravelBook_Frame01a.png" "book pixel-art"
      "Complete UI Book Styles" "Crusenho" "書本樣式的圖示框"
  , Row 2 "spr_item_blue-potion_02" "Blue Potion 2.png"
      "Magic Potions/Blue Potion 2.png" "potion item"
      "Kibyra Magic Potions" "Kibyra" ""
  , Row 3 "doc_ref_jinmen-architecture" "金門建築.rar"
      "reference/1990s-taiwan-jinmen/金門建築.rar" "參考 建築"
      "1990 年代金門建築" "" "1990 年代台灣金門的建築風格參考照片"
  ]

withSeeded :: (Store -> IO ()) -> IO ()
withSeeded f = do
  st <- openStoreInMemory
  void (initSchema st)
  mapM_ (insertRow st) rows
  f st
  close (storeConn st)

insertRow :: Store -> Row -> IO ()
insertRow st Row {..} = do
  execute
    (storeConn st)
    "INSERT INTO assets_fts(rowid, logical_name, original_name, entry_path, tags, pack, author, notes) \
    \VALUES (?,?,?,?,?,?,?,?)"
    (rId, rLogical, rOriginal, rEntry, rTags, rPack, rAuthor, rNotes)

  -- 中日韓索引吃的是同一批文字的 n-gram 展開。寫入與查詢共用
  -- AssetDB.Store.Tokenize,這是這個設計唯一需要守住的不變量。
  let blob = T.unwords [rLogical, rOriginal, rEntry, rTags, rPack, rAuthor, rNotes]
      CjkIndex {..} = cjkIndex blob
  execute
    (storeConn st)
    "INSERT INTO assets_cjk(rowid, uni, bi) VALUES (?,?,?)"
    (rId, cjkUni, cjkBi)

search :: Store -> Text -> IO [Int]
search st term = do
  r <-
    query
      (storeConn st)
      "SELECT rowid FROM assets_fts WHERE assets_fts MATCH ? ORDER BY rowid"
      (Only (ftsQuoted term))
  pure (map fromOnly r)

searchCJK :: Store -> Text -> IO [Int]
searchCJK st term =
  case cjkMatchExpr term of
    Nothing -> pure []
    Just expr -> do
      r <-
        query
          (storeConn st)
          "SELECT rowid FROM assets_cjk WHERE assets_cjk MATCH ? ORDER BY rowid"
          (Only expr)
      pure (map fromOnly r)
