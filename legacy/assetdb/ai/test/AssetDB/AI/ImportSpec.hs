-- | 外部建議匯入(F007)。
--
-- 最後一組是驗收點:第二個入口匯進來的中文標籤,走同一道閘門之後中文搜尋要命中。
-- 它證明的不是匯入本身,而是「匯入接得上既有的管線 C」。
module AssetDB.AI.ImportSpec (spec) where

import AssetDB.AI.Import
import AssetDB.AI.Suggest
import AssetDB.Store
import AssetDB.Store.Index (reindexFts)
import AssetDB.Store.Search
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = around withSeeded $ do
  describe "T1 解碼與切行" $ do
    it "空檔與只有空白行:irLines 0、無問題、不寫" $ \st -> do
      let conn = storeConn st
      r0 <- importSuggestions conn defaultImportOptions ""
      r0 `shouldBe` ImportReport 0 0 []
      r1 <- importSuggestions conn defaultImportOptions (jsonl ["", "   ", "\t"])
      r1 `shouldBe` ImportReport 0 0 []
      countRows conn "ai_suggestions" `shouldReturn` 0

    it "非 UTF-8 位元組:行號 0 問題,不拋例外" $ \st -> do
      r <- importSuggestions (storeConn st) defaultImportOptions (BS.pack [0xff, 0xfe, 0x41])
      map fst (irProblems r) `shouldBe` [0]
      irWritten r `shouldBe` 0

    it "行號是原始行號,跳過的空白行也算" $ \st -> do
      -- 第 1 行合法、第 2 行空白、第 3 行壞掉:使用者在編輯器裡看到的就是第 3 行。
      r <- importSuggestions (storeConn st) defaultImportOptions (jsonl [blobTag "藥水", "", "{not json"])
      irLines r `shouldBe` 2
      map fst (irProblems r) `shouldBe` [3]

  describe "T2 第 1 層:形狀" $ do
    it "七種違規各自列出行號與原因" $ \st -> do
      let bad =
            [ "{not json"
            , obj [("target_type", "\"thing\""), ("target_key", q sha), ("field", "\"tag\""), ("value", "\"x\""), ("facet", "\"free\""), ("lang", "\"zh\"")]
            , obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"colour\""), ("value", "\"x\""), ("lang", "\"zh\"")]
            , obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"subject\""), ("value", "\"x\""), ("lang", "\"fr\"")]
            , obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"tag\""), ("value", "\"x\""), ("lang", "\"zh\"")]
            , obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"subject\""), ("value", "\"x\""), ("facet", "\"free\""), ("lang", "\"zh\"")]
            , obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"tag\""), ("value", "\"x\""), ("facet", "\"free\""), ("lang", "\"zh\""), ("confidence", "1.5")]
            , obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"tag\""), ("value", "\"   \""), ("facet", "\"free\""), ("lang", "\"zh\"")]
            ]
      r <- importSuggestions (storeConn st) defaultImportOptions (jsonl bad)
      map fst (irProblems r) `shouldBe` [1 .. 8]
      let reasons = map snd (irProblems r)
      reasons !! 0 `shouldSatisfy` T.isInfixOf "JSON"
      reasons !! 1 `shouldSatisfy` T.isInfixOf "target_type"
      reasons !! 2 `shouldSatisfy` T.isInfixOf "field"
      reasons !! 3 `shouldSatisfy` T.isInfixOf "lang"
      reasons !! 4 `shouldSatisfy` T.isInfixOf "facet 必填"
      reasons !! 5 `shouldSatisfy` T.isInfixOf "不可帶 facet"
      reasons !! 6 `shouldSatisfy` T.isInfixOf "confidence"
      reasons !! 7 `shouldSatisfy` T.isInfixOf "value"
      irWritten r `shouldBe` 0

    it "一行多個問題全部列出" $ \st -> do
      let line = obj [("target_type", "\"thing\""), ("target_key", "\"\""), ("field", "\"tag\""), ("value", "\"\""), ("lang", "\"fr\"")]
      r <- importSuggestions (storeConn st) defaultImportOptions (jsonl [line])
      length (irProblems r) `shouldSatisfy` (>= 4)
      map fst (irProblems r) `shouldSatisfy` all (== 1)

  describe "T3 第 2 層:詞彙表" $ do
    it "分類不在詞彙表時擋下,理由含「不在詞彙表」" $ \st -> do
      r <- importSuggestions (storeConn st) defaultImportOptions (jsonl [blobCategory "icon/dragon"])
      irProblems r `shouldSatisfy` any (\(n, why) -> n == 1 && "不在詞彙表" `T.isInfixOf` why)

    it "詞彙表裡的葉節點與頂層都通過" $ \st -> do
      r <- importSuggestions (storeConn st) defaultImportOptions (jsonl [blobCategory "icon/potion", blobCategory "icon"])
      r `shouldBe` ImportReport 2 2 []

  describe "T4 第 3 層:目標存在" $ do
    it "不存在的 blob / asset / pack 被擋下" $ \st -> do
      let rows =
            [ tagOn "blob" "deadbeef"
            , tagOn "asset" "01ZZZZ"
            , tagOn "pack" "no-such-pack"
            , tagOn "blob" sha
            , tagOn "asset" "01B1"
            , tagOn "pack" "magic-potions"
            ]
      r <- importSuggestions (storeConn st) defaultImportOptions (jsonl rows)
      map fst (irProblems r) `shouldBe` [1, 2, 3]
      map snd (irProblems r) `shouldSatisfy` all (T.isInfixOf "不存在")

    it "cluster 鍵不驗、照收" $ \st -> do
      r <- importSuggestions (storeConn st) defaultImportOptions (jsonl [tagOn "cluster" "nope|other|w|.png"])
      r `shouldBe` ImportReport 1 1 []

  describe "T5 閘門與寫入" $ do
    it "任一行有問題則一筆都不寫" $ \st -> do
      let conn = storeConn st
      r <- importSuggestions conn defaultImportOptions (jsonl [blobTag "藥水", blobTag "圖示", "{broken"])
      irWritten r `shouldBe` 0
      countRows conn "ai_suggestions" `shouldReturn` 0

    it "dry-run 回報筆數但不寫" $ \st -> do
      let conn = storeConn st
      r <- importSuggestions conn defaultImportOptions {ioDryRun = True} (jsonl [blobTag "藥水", blobTag "圖示"])
      r `shouldBe` ImportReport 2 0 []
      countRows conn "ai_suggestions" `shouldReturn` 0

    it "合法匯入後 listSuggestions 看得到 pending 且 run_id NULL" $ \st -> do
      let conn = storeConn st
      r <- importSuggestions conn defaultImportOptions (jsonl [blobTag "藥水"])
      r `shouldBe` ImportReport 1 1 []
      rows <- listSuggestions conn emptyFilter
      map ssValue rows `shouldBe` ["藥水"]
      map ssStatus rows `shouldBe` ["pending"]
      map ssLang rows `shouldBe` ["zh"]
      nulls <- query_ conn "SELECT COUNT(*) FROM ai_suggestions WHERE run_id IS NULL" :: IO [Only Int]
      nulls `shouldBe` [Only 1]

    it "irWritten 是實際寫入數:已決定的列不計入不洗回" $ \st -> do
      let conn = storeConn st
      void (importSuggestions conn defaultImportOptions (jsonl [blobTag "藥水"]))
      [s] <- listSuggestions conn emptyFilter
      void (decideSuggestions conn [ssId s] "rejected" "test")
      r <- importSuggestions conn defaultImportOptions (jsonl [blobTag "藥水", blobTag "血瓶"])
      irWritten r `shouldBe` 1
      rows <- listSuggestions conn emptyFilter
      [(ssValue x, ssStatus x) | x <- rows] `shouldMatchList` [("藥水", "rejected"), ("血瓶", "pending")]

  describe "T7 驗收:第二個入口接得上管線 C" $
    it "匯入 → confirm → apply → reindexFts 後中文搜尋命中" $ \st -> do
      let conn = storeConn st
      none <- search conn emptyQuery {sqText = Just "藥水"}
      none `shouldBe` []
      void (importSuggestions conn defaultImportOptions (jsonl [blobTag "藥水"]))
      rows <- listSuggestions conn emptyFilter
      void (decideSuggestions conn (map ssId rows) "confirmed" "test")
      void (applySuggestions conn defaultApplyOptions {aoDryRun = False})
      void (reindexFts conn)
      hits <- search conn emptyQuery {sqText = Just "藥水"}
      map hitOriginal hits `shouldMatchList` ["potion01.png", "potion01.png"]

--------------------------------------------------------------------------------

sha :: Text
sha = "aa11bb22cc33"

q :: Text -> Text
q t = "\"" <> t <> "\""

obj :: [(Text, Text)] -> Text
obj kvs = "{" <> T.intercalate "," [q k <> ":" <> v | (k, v) <- kvs] <> "}"

tagOn :: Text -> Text -> Text
tagOn tt key =
  obj [("target_type", q tt), ("target_key", q key), ("field", "\"tag\""), ("value", "\"pixel\""), ("facet", "\"style\""), ("lang", "\"en\"")]

blobTag :: Text -> Text
blobTag v =
  obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"tag\""), ("value", q v), ("facet", "\"free\""), ("lang", "\"zh\""), ("confidence", "0.9")]

blobCategory :: Text -> Text
blobCategory path =
  obj [("target_type", "\"blob\""), ("target_key", q sha), ("field", "\"category\""), ("value", q path), ("lang", "\"en\"")]

jsonl :: [Text] -> ByteString
jsonl = encodeUtf8 . T.unlines

countRows :: Connection -> Query -> IO Int
countRows conn t = do
  r <- query_ conn ("SELECT COUNT(*) FROM " <> t) :: IO [Only Int]
  pure (case r of (Only n : _) -> n; _ -> 0)

-- | 與 SuggestSpec 同一份種子:兩筆 asset 指向同一份內容。
withSeeded :: (Store -> IO ()) -> IO ()
withSeeded f = do
  st <- openStoreInMemory
  void (initSchema st)
  let conn = storeConn st
  execute_ conn "INSERT INTO roots (id,path,label,kind) VALUES (1,'/lib','lib','packs')"
  execute_ conn "INSERT INTO authors (id,name) VALUES (1,'Kibyra')"
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
