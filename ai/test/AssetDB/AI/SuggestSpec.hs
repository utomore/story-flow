-- | 這個檔案裡有一個測試是整個 AI 功能的驗收點:
-- 「套用一個中文標籤之後,中文搜尋找得到那筆素材」。
--
-- 它之所以關鍵,是因為失敗的樣子與成功的樣子在外觀上一模一樣。
-- @assets_fts.tags@ 現在就是空字串;扇出若漏掉,它還是空字串,
-- 所有指令照樣回報成功,而中文搜尋照樣零筆。
module AssetDB.AI.SuggestSpec (spec) where

import AssetDB.AI.Suggest
import AssetDB.Store
import AssetDB.Store.Index (reindexFts)
import AssetDB.Store.Search
import Control.Monad (void)
import Data.Text (Text)
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = around withSeeded $ do
  describe "upsertSuggestions" $ do
    it "寫入後看得到" $ \st -> do
      let conn = storeConn st
      void (upsertSuggestions conn Nothing [zhTag "藥水"])
      rows <- listSuggestions conn emptyFilter
      map ssValue rows `shouldBe` ["藥水"]
      map ssStatus rows `shouldBe` ["pending"]

    it "重跑是更新而不是堆疊" $ \st -> do
      let conn = storeConn st
      void (upsertSuggestions conn Nothing [zhTag "藥水"])
      void (upsertSuggestions conn Nothing [zhTag "藥水"])
      rows <- listSuggestions conn emptyFilter
      length rows `shouldBe` 1

    it "不會把已決定的建議洗回 pending" $ \st -> do
      -- 人的判斷不該被下一次批次覆蓋掉。
      let conn = storeConn st
      void (upsertSuggestions conn Nothing [zhTag "藥水"])
      [s] <- listSuggestions conn emptyFilter
      void (decideSuggestions conn [ssId s] "rejected" "test")
      void (upsertSuggestions conn Nothing [zhTag "藥水"])
      rows <- listSuggestions conn emptyFilter
      map ssStatus rows `shouldBe` ["rejected"]

  describe "hasSuggestionsFor" $
    it "叢集層續跑靠它判斷做過沒有" $ \st -> do
      let conn = storeConn st
      hasSuggestionsFor conn "cluster" "p|shape" `shouldReturn` False
      void (upsertSuggestions conn Nothing [categorySuggestion "cluster" "p|shape" "icon" Nothing Nothing])
      hasSuggestionsFor conn "cluster" "p|shape" `shouldReturn` True

  describe "applySuggestions" $ do
    it "只套用 confirmed 的" $ \st -> do
      let conn = storeConn st
      void (upsertSuggestions conn Nothing [zhTag "藥水"])
      r <- applySuggestions conn defaultApplyOptions {aoDryRun = False}
      arTags r `shouldBe` 0

    it "以 sha256 為鍵的建議會扇出到所有指向該內容的素材" $ \st -> do
      -- 內容定址的後果:同一份內容被兩筆 asset 指向(不同素材包裡的同一
      -- 個檔案),兩筆都必須拿到標籤。漏掉扇出,索引就餵不飽。
      let conn = storeConn st
      confirmAll conn [zhTag "藥水"]
      r <- applySuggestions conn defaultApplyOptions {aoDryRun = False}
      arTags r `shouldBe` 2

    it "dry-run 不寫入" $ \st -> do
      let conn = storeConn st
      confirmAll conn [zhTag "藥水"]
      void (applySuggestions conn defaultApplyOptions {aoDryRun = True})
      n <- countRows conn "asset_tags"
      n `shouldBe` 0

    it "重跑不會覆蓋人工標籤" $ \st -> do
      -- source 的強弱是 manual > rule > inferred(見 Schema.hs)。
      -- 用 INSERT OR IGNORE 而不是 REPLACE,人工修正才留得住。
      let conn = storeConn st
      execute_ conn "INSERT INTO tags (id,name,facet) VALUES (99,'藥水','free')"
      execute_ conn "INSERT INTO asset_tags (asset_id,tag_id,source) VALUES (1,99,'manual')"
      confirmAll conn [zhTag "藥水"]
      void (applySuggestions conn defaultApplyOptions {aoDryRun = False})
      rows <- query_ conn "SELECT source FROM asset_tags WHERE asset_id = 1" :: IO [Only Text]
      map fromOnly rows `shouldBe` ["manual"]

    it "分類寫進 asset_categories" $ \st -> do
      let conn = storeConn st
      confirmAll conn [categorySuggestion "blob" sha "icon/potion" (Just 0.9) Nothing]
      r <- applySuggestions conn defaultApplyOptions {aoDryRun = False}
      arCategories r `shouldBe` 2
      n <- countRows conn "asset_categories"
      n `shouldBe` 2

    it "叢集目標需要呼叫端注入解析器" $ \st -> do
      let conn = storeConn st
      confirmAll conn [tagSuggestion "cluster" "p|shape" "style" "en" "pixel-art" Nothing]
      -- 預設解析器回傳空清單,建議因此被計入 unresolved 而不是靜靜消失。
      r0 <- applySuggestions conn defaultApplyOptions {aoDryRun = False}
      arUnresolved r0 `shouldBe` 1
      r1 <-
        applySuggestions
          conn
          defaultApplyOptions {aoDryRun = False, aoResolveCluster = \_ -> pure [1]}
      arTags r1 `shouldBe` 1

  describe "驗收:中文標籤讓中文搜尋活起來" $ do
    it "套用前搜不到" $ \st -> do
      -- 這是這個素材庫今天的處境:CJK 索引是好的,但語料裡沒有中文。
      hits <- search (storeConn st) emptyQuery {sqText = Just "藥水"}
      hits `shouldBe` []

    it "套用 + reindexFts 之後搜得到" $ \st -> do
      let conn = storeConn st
      confirmAll conn [zhTag "藥水"]
      void (applySuggestions conn defaultApplyOptions {aoDryRun = False})
      -- reindexFts 這一步漏掉的話,上面全部照樣「成功」,而搜尋照樣零筆。
      void (reindexFts conn)
      hits <- search conn emptyQuery {sqText = Just "藥水"}
      map hitOriginal hits `shouldMatchList` ["potion01.png", "potion01.png"]

    it "英文標籤同樣進得了索引" $ \st -> do
      let conn = storeConn st
      confirmAll conn [tagSuggestion "blob" sha "free" "en" "health potion" Nothing]
      void (applySuggestions conn defaultApplyOptions {aoDryRun = False})
      void (reindexFts conn)
      hits <- search conn emptyQuery {sqText = Just "health"}
      length hits `shouldBe` 2

--------------------------------------------------------------------------------

sha :: Text
sha = "aa11bb22cc33"

zhTag :: Text -> Suggestion
zhTag t = tagSuggestion "blob" sha "free" "zh" t (Just 0.8)

confirmAll :: Connection -> [Suggestion] -> IO ()
confirmAll conn sgs = do
  void (upsertSuggestions conn Nothing sgs)
  rows <- listSuggestions conn emptyFilter
  void (decideSuggestions conn (map ssId rows) "confirmed" "test")

countRows :: Connection -> Query -> IO Int
countRows conn t = do
  r <- query_ conn ("SELECT COUNT(*) FROM " <> t) :: IO [Only Int]
  pure (case r of (Only n : _) -> n; _ -> 0)

-- | 兩筆 asset 指向同一份內容 —— 這正是扇出必須存在的理由。
withSeeded :: (Store -> IO ()) -> IO ()
withSeeded f = do
  st <- openStoreInMemory
  void (initSchema st)
  let conn = storeConn st
  execute_ conn "INSERT INTO roots (id,path,label,kind) VALUES (1,'/lib','lib','packs')"
  execute_ conn "INSERT INTO authors (id,name) VALUES (1,'Kibyra')"
  -- status='ready' 的素材包必須同時有授權與作者(schema 的 CHECK)。
  -- 授權沿用種子資料,不硬寫 id —— 種子已經佔用了前幾個。
  execute_
    conn
    "INSERT INTO packs (id,ulid,slug,name,vendor,author_id,license_id,root_id,rel_dir,kind,status,created_at,updated_at) \
    \VALUES (1,'01P1','magic-potions','Magic Potions','Kibyra',1, \
    \        (SELECT id FROM licenses WHERE name='Kibyra Asset License'),1,'magic-potions','packs','ready','t','t'), \
    \       (2,'01P2','rpg-icons','RPG Icons','Kibyra',1, \
    \        (SELECT id FROM licenses WHERE name='Kibyra Asset License'),1,'rpg-icons','packs','ready','t','t')"
  execute_ conn "INSERT INTO blobs (sha256,bytes,kind,first_seen) VALUES ('aa11bb22cc33',100,'image','t')"
  execute_
    conn
    "INSERT INTO assets (id,ulid,kind,root_id,rel_path,original_name,sha256,pack_id,status,created_at,updated_at) \
    \VALUES (1,'01B1','image',1,'a/potion01.png','potion01.png','aa11bb22cc33',1,'active','t','t'), \
    \       (2,'01B2','image',1,'b/potion01.png','potion01.png','aa11bb22cc33',2,'active','t','t')"
  void (reindexFts conn)
  f st
  close conn
