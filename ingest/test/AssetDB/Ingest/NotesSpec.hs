module AssetDB.Ingest.NotesSpec (spec) where

import AssetDB.Ingest.Notes
import AssetDB.Store
import AssetDB.Types (LinkRel (..), NoteKind (..))
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "parseFrontMatter" $ do
    it "讀 front matter 的 title" $
      ndTitle (parseFrontMatter "x.md" "---\ntitle: 我的筆記\ntags: a\n---\n\n內文") `shouldBe` "我的筆記"

    it "沒有 front matter 時取第一個 Markdown 標題" $
      ndTitle (parseFrontMatter "x.md" "# 遊戲企畫書\n\n內文") `shouldBe` "遊戲企畫書"

    it "兩者都沒有時退回檔名" $
      ndTitle (parseFrontMatter "readme.md" "只有內文") `shouldBe` "readme.md"

    it "title 的引號會脫掉" $
      ndTitle (parseFrontMatter "x.md" "---\ntitle: \"帶引號\"\n---\n內文") `shouldBe` "帶引號"

    it "front matter 不會混進內文" $
      ndBody (parseFrontMatter "x.md" "---\ntitle: T\n---\n\n真正的內文")
        `shouldSatisfy` (not . T.isInfixOf "title:")

    it "解析所有 key: value" $
      lookup "tags" (ndFront (parseFrontMatter "x.md" "---\ntitle: T\ntags: a, b\n---\nx"))
        `shouldBe` Just "a, b"

    -- ingest/E002 T4:收尾的 --- 直接頂著檔案結尾,是真實會出現的
    -- 邊界(編輯器不補結尾換行)。
    it "對 --- 後直接 EOF 的內容正確解析" $ do
      let doc = parseFrontMatter "x.md" "---\ntitle: T\n---"
      ndTitle doc `shouldBe` "T"
      ndFront doc `shouldBe` [("title", "T")]
      ndBody doc `shouldBe` ""

    it "對 --- 加換行即 EOF 的內容正確解析" $ do
      let doc = parseFrontMatter "x.md" "---\ntitle: T\n---\n"
      ndTitle doc `shouldBe` "T"
      ndBody doc `shouldBe` ""

  -- ingest/E002 T1:front matter 值裡的反斜線與控制字元(Windows 路徑、
  -- tab)以前會被手刻拼接寫成不合法的 JSON。
  describe "frontJson" $ do
    it "對含反斜線與控制字元的值產生合法 JSON" $ do
      let kvs = [("path", "C:\\assets\\gui"), ("note", "tab\there\nnewline")]
      Aeson.decode (BL.fromStrict (encodeUtf8 (frontJson kvs)))
        `shouldBe` Just (Map.fromList kvs :: Map.Map Text Text)

    it "空 front matter 是空物件" $
      frontJson [] `shouldBe` "{}"

  describe "importNotes" $ do
    it "匯入目錄裡的 Markdown" $ withNotes $ \(st, dir) -> do
      (r, problems) <- importNotes st NkKnowledge dir
      length r `shouldBe` 2
      problems `shouldBe` []
      map fst r `shouldContain` ["技術棧清單"]

    it "重複匯入是更新而不是新增" $ withNotes $ \(st, dir) -> do
      -- 筆記會被反覆編輯。每次匯入都新增一筆會讓同一份文件散成好幾個版本。
      _ <- importNotes st NkKnowledge dir
      _ <- importNotes st NkKnowledge dir
      length <$> listNotes st Nothing `shouldReturn` 2

    it "非 Markdown 檔案不理會" $ withNotes $ \(st, dir) -> do
      writeFile (dir </> "note.txt") "不是 markdown"
      (r, problems) <- importNotes st NkKnowledge dir
      length r `shouldBe` 2
      problems `shouldBe` []

    -- G-E003 T8。同一個模組裡的 linkEntities 早就寫著「打錯不該是例外或
    -- 崩潰」並回 Either,而同一個檔案裡的 I/O 卻沒比照 —— 一個讀不到的
    -- 檔案會讓整次匯入崩掉,已經解析好的也一起沒了。
    it "讀不到的檔案跳過並回報,其餘照樣匯入" $ withNotes $ \(st, dir) -> do
      -- 目錄不是檔案:BS.readFile 對它必定失敗,而且每個平台都一樣。
      -- 副檔名仍是 .md,所以它會進入待匯入清單。
      createDirectoryIfMissing True (dir </> "broken.md")
      (r, problems) <- importNotes st NkKnowledge dir
      length r `shouldBe` 2
      map fst r `shouldContain` ["技術棧清單"]
      -- 回報說得出是哪一個檔案。
      problems `shouldSatisfy` any (T.isInfixOf "broken.md")
      length problems `shouldBe` 1
      -- 成功的那兩篇真的進了資料庫。
      length <$> listNotes st Nothing `shouldReturn` 2

    it "目錄不存在時是空結果,不是錯誤" $ withNotes $ \(st, dir) -> do
      (r, problems) <- importNotes st NkKnowledge (dir </> "nope")
      r `shouldBe` []
      problems `shouldBe` []

    it "依 kind 篩選" $ withNotes $ \(st, dir) -> do
      _ <- importNotes st NkKnowledge dir
      length <$> listNotes st (Just NkKnowledge) `shouldReturn` 2
      length <$> listNotes st (Just NkMarketing) `shouldReturn` 0

  describe "reindexNotes" $
    it "中文筆記進 bigram 索引 —— 那是主力而非備援" $ withNotes $ \(st, dir) -> do
      _ <- importNotes st NkKnowledge dir
      n <- reindexNotes st
      n `shouldBe` 2
      rows <-
        query_ (storeConn st) "SELECT COUNT(*) FROM notes_cjk" :: IO [Only Int]
      map fromOnly rows `shouldBe` [2]

  -- ingest/E002 T2:實體型別字串是使用者在 CLI 打的,打錯不該崩潰。
  describe "tableOf" $ do
    it "對未知實體型別回傳 Left 而非崩潰" $ do
      tableOf "foo" `shouldSatisfy` isLeft
      tableOf "" `shouldSatisfy` isLeft

    it "五種已知型別對應到資料表" $ do
      tableOf "asset" `shouldBe` Right "assets"
      tableOf "note" `shouldBe` Right "notes"

  describe "links" $ do
    it "建立的邊雙向都查得到" $ withNotes $ \(st, dir) -> do
      -- 「改這張 tileset 會影響哪些關卡」是從目標端出發的查詢,
      -- 與正向一樣常見。只做單向等於做了一半。
      _ <- importNotes st NkKnowledge dir
      [(a, _, _, _), (b, _, _, _)] <- take 2 <$> listNotes st Nothing
      linkEntities st "note" a "note" b RelDocuments (Just "測試") `shouldReturn` Right ()
      Right outs <- entityLinks st "note" a
      Right ins <- entityLinks st "note" b
      map (\(d, r, _, _) -> (d, r)) outs `shouldBe` [("out", "documents")]
      map (\(d, r, _, _) -> (d, r)) ins `shouldBe` [("in", "documents")]

    it "重複建立同一條邊是無操作" $ withNotes $ \(st, dir) -> do
      _ <- importNotes st NkKnowledge dir
      [(a, _, _, _), (b, _, _, _)] <- take 2 <$> listNotes st Nothing
      _ <- linkEntities st "note" a "note" b RelDocuments Nothing
      _ <- linkEntities st "note" a "note" b RelDocuments Nothing
      fmap length <$> entityLinks st "note" a `shouldReturn` Right 1

    -- ingest/E002 T3:對外一律 ULID(ADR-003),內部整數 id 不出模組。
    it "entityLinks 回傳的對端識別是 ULID 而非內部整數 id" $ withNotes $ \(st, dir) -> do
      _ <- importNotes st NkKnowledge dir
      [(a, _, _, _), (b, _, _, _)] <- take 2 <$> listNotes st Nothing
      _ <- linkEntities st "note" a "note" b RelDocuments Nothing
      Right [(_, _, _, dst)] <- entityLinks st "note" a
      dst `shouldBe` b
      T.length dst `shouldBe` 26

    it "未知實體型別回 Left 帶友善訊息" $ withNotes $ \(st, _) -> do
      r <- linkEntities st "foo" "01X" "note" "01Y" RelDocuments Nothing
      r `shouldSatisfy` isLeft
      ls <- entityLinks st "foo" "01X"
      ls `shouldSatisfy` isLeft

--------------------------------------------------------------------------------

withNotes :: ((Store, FilePath) -> IO ()) -> IO ()
withNotes f =
  withSystemTempDirectory "assetdb-notes" $ \root -> do
    let dir = root </> "docs"
    createDirectoryIfMissing True dir
    writeUtf8 (dir </> "tech.md") "---\ntitle: 技術棧清單\n---\n\n用 h-raylib 與 apecs。"
    writeUtf8 (dir </> "gdd.md") "# 遊戲企畫書\n\n島嶼村莊魔法陣模擬,無戰鬥。"
    st <- openStore (root </> "db.sqlite")
    void (initSchema st)
    f (st, dir)
    close (storeConn st)
  where
    -- 明確以 UTF-8 位元組寫。writeFile 用 locale 編碼,
    -- Windows 上會把中文寫壞或直接拋例外。
    writeUtf8 p = BS.writeFile p . encodeUtf8 . T.pack
