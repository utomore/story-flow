-- | Schema 的約束測試。
--
-- 重點不在「表建得出來」,而在**寫不進去的東西真的寫不進去**。
-- 一個沒有被測過的 CHECK 約束跟註解沒兩樣。
module AssetDB.Store.SchemaSpec (spec) where

import AssetDB.Store
import Control.Exception (try)
import Control.Monad (void)
import Data.List (sort)
import Data.Text qualified as T
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = around withMigrated $ do
  describe "資料表" $ do
    it "建出預期的表" $ \st -> do
      ts <- tableNames st
      let expected =
            [ "archives", "asset_categories", "asset_tags", "assets", "authors"
            , "blobs", "categories", "collection_items", "collections", "events"
            , "licenses", "links", "moves", "name_clusters", "naming_vocab"
            , "notes", "packs", "project_assets", "projects", "roots"
            , "schema_migrations", "tags"
            ]
      -- FTS5 會另外產生一堆 *_data / *_idx 影子表,只檢查我們自己宣告的
      filter (`elem` expected) ts `shouldBe` sort expected

  describe "assets 的位置約束" $ do
    -- 一筆資源要嘛在壓縮檔裡,要嘛是散檔。這個 CHECK 讓「兩者都填」
    -- 或「兩者都空」在資料庫層就寫不進去,不必靠應用層自律。
    it "接受壓縮檔內的項目" $ \st -> do
      seedArchive st
      insertAsset st archiveShaped `shouldReturn` ()

    it "接受散檔" $ \st -> do
      seedRoot st
      insertAsset st looseShaped `shouldReturn` ()

    it "拒絕兩種位置同時填寫" $ \st -> do
      seedArchive st
      seedRoot st
      r <-
        tryDB $
          execute_
            (storeConn st)
            "INSERT INTO assets (ulid,kind,original_name,archive_id,entry_path,root_id,rel_path,created_at,updated_at) \
            \VALUES ('01H0','image','x.png',1,'a/x.png',1,'b/x.png','t','t')"
      r `shouldSatisfy` failed

    it "拒絕兩種位置都不填" $ \st -> do
      r <-
        tryDB $
          execute_
            (storeConn st)
            "INSERT INTO assets (ulid,kind,original_name,created_at,updated_at) \
            \VALUES ('01H1','image','x.png','t','t')"
      r `shouldSatisfy` failed

  describe "外鍵約束" $ do
    it "拒絕指向不存在的 pack" $ \st -> do
      seedRoot st
      r <-
        tryDB $
          execute_
            (storeConn st)
            "INSERT INTO assets (ulid,kind,original_name,root_id,rel_path,pack_id,created_at,updated_at) \
            \VALUES ('01H2','image','x.png',1,'x.png',999,'t','t')"
      r `shouldSatisfy` failed

    it "刪除 pack 時連帶刪除其 archives" $ \st -> do
      seedArchive st
      execute_ (storeConn st) "DELETE FROM packs WHERE id=1"
      n <- countOf st "archives"
      n `shouldBe` 0

  describe "授權欄位" $ do
    -- 建專案的授權閘門讀 commercial。漏填時寧可寫入失敗,
    -- 也不要預設成允許而放行 Non-Commercial 素材。
    it "commercial 沒有預設值,漏填就寫不進去" $ \st -> do
      r <- tryDB $ execute_ (storeConn st) "INSERT INTO licenses (name) VALUES ('unknown')"
      r `shouldSatisfy` failed

    it "attribution_required 同樣沒有預設值" $ \st -> do
      -- 猜錯的方向都有代價:預設不需署名會漏掉 Crusenho 那種必須署名的授權;
      -- 預設需要署名則會產生一堆多餘的致謝。兩邊都不猜,強迫填。
      r <- tryDB $ execute_ (storeConn st) "INSERT INTO licenses (name,commercial) VALUES ('half',1)"
      r `shouldSatisfy` failed

    it "commercial 只接受 0 或 1" $ \st -> do
      r <- tryDB $ execute_ (storeConn st) "INSERT INTO licenses (name,commercial) VALUES ('weird',2)"
      r `shouldSatisfy` failed

    it "未知的維度可以是 NULL,而且 NULL 與 0 意義不同" $ \st -> do
      -- NULL = 授權條款沒寫;0 = 明確禁止。把未知當禁止會讓素材無故不可用,
      -- 當允許則是法律風險。
      execute_
        (storeConn st)
        "INSERT INTO licenses (name,commercial,attribution_required,nft_allowed) \
        \VALUES ('partial',1,0,NULL)"
      r <- query_ (storeConn st) "SELECT nft_allowed IS NULL FROM licenses WHERE name='partial'"
      map fromOnly r `shouldBe` [1 :: Int]

  describe "素材包完備狀態" $ do
    -- 使用者匯入時必須填授權與作者。強制方式不是靠應用層自律,
    -- 而是「ready 狀態的 pack 必須兩者皆備」這條 CHECK。
    it "draft 允許授權與作者留空 —— 否則匯入會卡住" $ \st -> do
      seedRoot st
      insertPack st "draft" "NULL" "NULL" `shouldReturn` ()

    it "ready 但沒有授權時寫不進去" $ \st -> do
      seedRoot st
      seedAuthor st
      r <- tryDB $ insertPack st "ready" "NULL" "1"
      r `shouldSatisfy` failed

    it "ready 但沒有作者時寫不進去" $ \st -> do
      seedRoot st
      seedLicense st
      r <- tryDB $ insertPack st "ready" "1" "NULL"
      r `shouldSatisfy` failed

    it "兩者皆備才能是 ready" $ \st -> do
      seedRoot st
      seedAuthor st
      seedLicense st
      insertPack st "ready" "1" "1" `shouldReturn` ()

    it "draft 升級為 ready 時同樣受檢查" $ \st -> do
      seedRoot st
      insertPack st "draft" "NULL" "NULL"
      r <- tryDB $ execute_ (storeConn st) "UPDATE packs SET status='ready' WHERE id=1"
      r `shouldSatisfy` failed

  describe "AI 使用揭露" $ do
    it "預設是 unknown,不是 none" $ \st -> do
      -- 「還沒查」與「作者聲明未使用」是不同的事。發行前稽核只接受後者。
      seedRoot st
      insertPack st "draft" "NULL" "NULL"
      r <- query_ (storeConn st) "SELECT ai_disclosure FROM packs WHERE id=1"
      map fromOnly r `shouldBe` (["unknown"] :: [String])

    it "只接受已知的揭露值" $ \st -> do
      seedRoot st
      r <-
        tryDB $
          execute_
            (storeConn st)
            "INSERT INTO packs (id,ulid,slug,name,root_id,rel_dir,ai_disclosure,created_at,updated_at) \
            \VALUES (2,'01P9','x','X',1,'v/x','maybe','t','t')"
      r `shouldSatisfy` failed

  describe "已查證的授權種子資料" $ do
    it "只收錄有授權全文可查的" $ \st -> do
      names <- query_ (storeConn st) "SELECT name FROM licenses ORDER BY name" :: IO [Only String]
      map fromOnly names
        `shouldBe` [ "Adventurer 2D Pixel Art"
                   , "BDragon1727 Full License"
                   , "Cainos Asset License"
                   , "Crusenho Asset License"
                   , "Idylwild Runic Codex"
                   , "Kibyra Asset License"
                   , "Shikashi Fantasy Icons"
                   ]

    it "Crusenho 是唯一要求署名的,且帶有致謝字句" $ \st -> do
      r <-
        query_
          (storeConn st)
          "SELECT name FROM licenses WHERE attribution_required=1 AND credit_text IS NOT NULL ORDER BY name"
      map fromOnly r `shouldBe` (["Crusenho Asset License", "Shikashi Fantasy Icons"] :: [String])

    it "Idylwild 是唯一允許再散布的" $ \st -> do
      r <- query_ (storeConn st) "SELECT name FROM licenses WHERE redistribution_allowed=1"
      map fromOnly r `shouldBe` (["Idylwild Runic Codex"] :: [String])

    it "全部允許商用 —— 未查證的授權刻意不收錄" $ \st -> do
      n <- countWhere st "licenses" "commercial=0"
      n `shouldBe` 0

  describe "列舉欄位" $ do
    it "status 只接受已知值" $ \st -> do
      seedRoot st
      r <-
        tryDB $
          execute_
            (storeConn st)
            "INSERT INTO assets (ulid,kind,original_name,root_id,rel_path,status,created_at,updated_at) \
            \VALUES ('01H3','image','x.png',1,'x.png','bogus','t','t')"
      r `shouldSatisfy` failed

    it "archive format 只接受支援的格式" $ \st -> do
      seedPack st
      r <-
        tryDB $
          execute_
            (storeConn st)
            "INSERT INTO archives (ulid,pack_id,rel_path,format,sha256,bytes) \
            \VALUES ('01H4',1,'a.tar','tar','sha',1)"
      r `shouldSatisfy` failed

  describe "初始資料" $ do
    it "命名詞彙表已填入" $ \st -> do
      domains <- countWhere st "naming_vocab" "facet='domain'"
      states <- countWhere st "naming_vocab" "facet='state'"
      variants <- countWhere st "naming_vocab" "facet='variant'"
      domains `shouldSatisfy` (>= 10)
      states `shouldSatisfy` (>= 30)
      variants `shouldSatisfy` (>= 20)

    it "頂層分類已建立" $ \st -> do
      rows <- query_ (storeConn st) "SELECT slug FROM categories WHERE parent_id IS NULL ORDER BY slug"
      map fromOnly rows
        `shouldBe` (["audio", "character", "font", "fx", "ground", "gui", "level", "prop", "reference"] :: [String])

--------------------------------------------------------------------------------

withMigrated :: (Store -> IO ()) -> IO ()
withMigrated f = do
  st <- openStoreInMemory
  void (initSchema st)
  f st
  close (storeConn st)

tableNames :: Store -> IO [String]
tableNames st =
  map fromOnly
    <$> query_ (storeConn st) "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"

countOf :: Store -> String -> IO Int
countOf st t = countWhere st t "1=1"

countWhere :: Store -> String -> String -> IO Int
countWhere st t w = do
  rows <- query_ (storeConn st) (Query (T.pack ("SELECT COUNT(*) FROM " <> t <> " WHERE " <> w)))
  pure (case rows of [Only n] -> n; _ -> -1)

tryDB :: IO a -> IO (Either SQLError a)
tryDB = try

failed :: Either SQLError a -> Bool
failed = either (const True) (const False)

seedRoot :: Store -> IO ()
seedRoot st =
  execute_
    (storeConn st)
    "INSERT OR IGNORE INTO roots (id,path,label,kind) VALUES (1,'C:/lib','lib','packs')"

seedPack :: Store -> IO ()
seedPack st = do
  seedRoot st
  execute_
    (storeConn st)
    "INSERT OR IGNORE INTO packs (id,ulid,slug,name,root_id,rel_dir,created_at,updated_at) \
    \VALUES (1,'01P0','demo','Demo Pack',1,'vendor/demo','t','t')"

seedAuthor :: Store -> IO ()
seedAuthor st =
  execute_
    (storeConn st)
    "INSERT OR IGNORE INTO authors (id,name,url,contact) \
    \VALUES (1,'Demo Author','https://demo.itch.io','demo@example.com')"

seedLicense :: Store -> IO ()
seedLicense st =
  execute_
    (storeConn st)
    "INSERT OR IGNORE INTO licenses (id,name,commercial,attribution_required) \
    \VALUES (1,'Demo License',1,0)"

-- | 以指定的 status / license_id / author_id 建立素材包。
-- 後兩者以 SQL 字面字串傳入,才能表達 NULL。
insertPack :: Store -> String -> String -> String -> IO ()
insertPack st status licenseId authorId =
  execute_ (storeConn st) $
    Query $
      T.pack $
        "INSERT INTO packs (id,ulid,slug,name,root_id,rel_dir,status,license_id,author_id,created_at,updated_at) \
        \VALUES (1,'01P1','demo','Demo Pack',1,'vendor/demo','"
          <> status
          <> "',"
          <> licenseId
          <> ","
          <> authorId
          <> ",'t','t')"

seedArchive :: Store -> IO ()
seedArchive st = do
  seedPack st
  execute_
    (storeConn st)
    "INSERT OR IGNORE INTO archives (id,ulid,pack_id,rel_path,format,sha256,bytes) \
    \VALUES (1,'01A0',1,'demo.zip','zip','deadbeef',1024)"

insertAsset :: Store -> [SQLData] -> IO ()
insertAsset st vals =
  execute
    (storeConn st)
    "INSERT INTO assets (ulid,kind,original_name,archive_id,entry_path,root_id,rel_path,created_at,updated_at) \
    \VALUES (?,?,?,?,?,?,?,'t','t')"
    vals

archiveShaped :: [SQLData]
archiveShaped =
  [ SQLText "01B0", SQLText "image", SQLText "x.png"
  , SQLInteger 1, SQLText "Sprites/x.png"
  , SQLNull, SQLNull
  ]

looseShaped :: [SQLData]
looseShaped =
  [ SQLText "01B1", SQLText "image", SQLText "y.png"
  , SQLNull, SQLNull
  , SQLInteger 1, SQLText "studio/y.png"
  ]
