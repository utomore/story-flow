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

    it "commercial 只接受 0 或 1" $ \st -> do
      r <- tryDB $ execute_ (storeConn st) "INSERT INTO licenses (name,commercial) VALUES ('weird',2)"
      r `shouldSatisfy` failed

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
