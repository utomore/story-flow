-- | 搜尋的測試。
--
-- fixture 重現真實素材庫的三種情況:英文素材、中文參考資料、被排除的宣傳圖。
-- 兩條全文路徑(trigram 與 bigram)都必須各自驗證 —— 它們處理的查詢不重疊。
module AssetDB.Store.SearchSpec (spec) where

import AssetDB.Store
import AssetDB.Store.Index
import AssetDB.Store.Search
import Control.Monad (forM_, void)
import Data.Text (Text)
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = around withSeeded $ do
  describe "全文" $ do
    it "以邏輯名稱搜尋" $ \st ->
      names st emptyQuery {sqText = Just "travel-book"} `shouldReturn` ["ui_gui_travel-book-alert_01a"]

    it "以廠商原始檔名搜尋" $ \st ->
      -- 使用者記得的常常是舊檔名,那是他們當初下載時看到的東西。
      names st emptyQuery {sqText = Just "TravelBook"} `shouldReturn` ["ui_gui_travel-book-alert_01a"]

    it "以作者搜尋" $ \st ->
      length <$> hits st emptyQuery {sqText = Just "Crusenho"} `shouldReturn` 1

    it "ASCII 子字串 —— trigram 索引的價值所在" $ \st ->
      -- unicode61 會把 blue-potion 切成 blue / potion,搜 otion 完全落空。
      names st emptyQuery {sqText = Just "otion"} `shouldReturn` ["spr_item_blue-potion_02"]

    it "查詢裡的減號不會被當成 NOT 運算子" $ \st ->
      names st emptyQuery {sqText = Just "blue-potion"} `shouldReturn` ["spr_item_blue-potion_02"]

    it "搜不到就是空,不是全部" $ \st ->
      hits st emptyQuery {sqText = Just "nonexistent"} `shouldReturn` []

  describe "中文全文" $ do
    it "兩字詞走 bigram 索引" $ \st ->
      -- trigram 的 MATCH 下限是三個字元,兩字中文詞在那條路徑上永遠是空結果。
      length <$> hits st emptyQuery {sqText = Just "金門", sqIncludeReference = True}
        `shouldReturn` 1

    it "長詞同樣找得到" $ \st ->
      length <$> hits st emptyQuery {sqText = Just "金門建築", sqIncludeReference = True}
        `shouldReturn` 1

    it "參考資料預設不出現 —— 找 GUI 框時不該跳出廟宇照片" $ \st ->
      hits st emptyQuery {sqText = Just "金門"} `shouldReturn` []

  describe "facet 篩選" $ do
    it "依廠商" $ \st ->
      names st emptyQuery {sqVendors = ["Crusenho"]} `shouldReturn` ["ui_gui_travel-book-alert_01a"]

    it "依素材包" $ \st ->
      length <$> hits st emptyQuery {sqPacks = ["potions"]} `shouldReturn` 1

    it "多個條件是交集" $ \st ->
      hits st emptyQuery {sqVendors = ["Crusenho"], sqPacks = ["potions"]} `shouldReturn` []

    it "只要已命名的" $ \st -> do
      -- 需要納入參考資料才有未命名的項目可比 —— 預設查詢剛好只剩已命名的兩筆。
      let base = emptyQuery {sqIncludeReference = True}
      total <- length <$> hits st base
      named <- length <$> hits st base {sqNamedOnly = True}
      total `shouldBe` 3
      named `shouldBe` 2

    it "被排除的項目預設不出現" $ \st -> do
      without <- length <$> hits st emptyQuery
      with <- length <$> hits st emptyQuery {sqIncludeExcluded = True}
      with `shouldSatisfy` (> without)

  describe "facet 計數" $ do
    it "算某個 facet 時排除該 facet 自己的條件" $ \st -> do
      -- 否則選了「廠商 = Crusenho」之後,廠商側欄只剩 Crusenho 一筆,
      -- 使用者就沒辦法改選別人。
      fc <- facetCounts (storeConn st) emptyQuery {sqVendors = ["Crusenho"]}
      map fst (fcVendors fc) `shouldContain` ["Cainos"]

    it "其他 facet 仍受目前條件約束" $ \st -> do
      fc <- facetCounts (storeConn st) emptyQuery {sqVendors = ["Crusenho"]}
      map fst (fcPacks fc) `shouldBe` ["ui-book"]

  describe "索引維護" $ do
    it "重建後筆數與資源相符" $ \st -> do
      n <- reindexFts (storeConn st)
      (fts, _) <- ftsRowCount (storeConn st)
      fts `shouldBe` n

    it "只有含中日韓字元的資源才進 bigram 索引" $ \st -> do
      _ <- reindexFts (storeConn st)
      (_, cjk) <- ftsRowCount (storeConn st)
      -- fixture 裡只有一筆是中文的
      cjk `shouldBe` 1

    it "偵測得出索引落後" $ \st -> do
      _ <- reindexFts (storeConn st)
      ftsStale (storeConn st) `shouldReturn` False
      execute_
        (storeConn st)
        "INSERT INTO assets (ulid,kind,root_id,rel_path,original_name,status,created_at,updated_at) \
        \VALUES ('01ZZ','image',1,'new.png','new.png','active','t','t')"
      ftsStale (storeConn st) `shouldReturn` True

--------------------------------------------------------------------------------

hits :: Store -> SearchQuery -> IO [SearchHit]
hits st = search (storeConn st)

names :: Store -> SearchQuery -> IO [Text]
names st q = map (maybe "(未命名)" id . hitLogical) <$> hits st q

withSeeded :: (Store -> IO ()) -> IO ()
withSeeded f = do
  st <- openStoreInMemory
  void (initSchema st)
  let conn = storeConn st
  execute_ conn "INSERT INTO roots (id,path,label,kind) VALUES (1,'/lib','lib','packs')"
  execute_ conn "INSERT INTO authors (id,name) VALUES (1,'Crusenho Agus Hennihuno'),(2,'Cainos'),(3,'Alchbees Studio')"
  -- 授權沿用 schema 種子資料裡已經有的那幾份,不要硬寫 id ——
  -- 種子已經佔用了 1..7,測試再插一次會撞主鍵。
  forM_ packs $ \(pid, slug, name, vendor, aid, kind) ->
    execute
      conn
      "INSERT INTO packs (id,ulid,slug,name,vendor,author_id,license_id,root_id,rel_dir,kind,status,created_at,updated_at) \
      \VALUES (?,?,?,?,?,?,(SELECT id FROM licenses WHERE name='Cainos Asset License'),1,?,?,'ready','t','t')"
      (pid, "01P" <> show pid, slug, name, vendor, aid, slug, kind)
  forM_ (zip [1 :: Int ..] assets) $ \(i, (pid, logical, orig, path, status)) ->
    execute
      conn
      "INSERT INTO assets (ulid,kind,root_id,rel_path,original_name,logical_name,pack_id,status,created_at,updated_at) \
      \VALUES (?,'image',1,?,?,?,?,?,'t','t')"
      ("01B" <> show i, path, orig, logical, pid, status)
  void (reindexFts conn)
  f st
  close conn

packs :: [(Int, Text, Text, Text, Int, Text)]
packs =
  [ (1, "ui-book", "Complete UI Book Styles Pack", "Crusenho", 1, "packs")
  , (2, "potions", "Pixel Art Icon Pack - RPG", "Cainos", 2, "packs")
  , (3, "jinmen", "1990 年代金門建築", "Alchbees", 3, "reference")
  ]

assets :: [(Int, Maybe Text, Text, Text, Text)]
assets =
  [ (1, Just "ui_gui_travel-book-alert_01a", "UI_TravelBook_Alert01a.png", "Sprites/UI_TravelBook_Alert01a.png", "active")
  , (2, Just "spr_item_blue-potion_02", "Blue Potion 2.png", "Potion/Blue Potion 2.png", "active")
  , (3, Nothing, "IMG_1342.HEIC", "金門建築/IMG_1342.HEIC", "active")
  , (1, Nothing, "Promo.png", "Preview/Promo.png", "excluded")
  ]
