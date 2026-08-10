module AssetDB.Ingest.NotesSpec (spec) where

import AssetDB.Ingest.Notes
import AssetDB.Store
import AssetDB.Types (LinkRel (..), NoteKind (..))
import Control.Monad (void)
import Data.ByteString qualified as BS
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

  describe "importNotes" $ do
    it "匯入目錄裡的 Markdown" $ withNotes $ \(st, dir) -> do
      r <- importNotes st NkKnowledge dir
      length r `shouldBe` 2
      map fst r `shouldContain` ["技術棧清單"]

    it "重複匯入是更新而不是新增" $ withNotes $ \(st, dir) -> do
      -- 筆記會被反覆編輯。每次匯入都新增一筆會讓同一份文件散成好幾個版本。
      _ <- importNotes st NkKnowledge dir
      _ <- importNotes st NkKnowledge dir
      length <$> listNotes st Nothing `shouldReturn` 2

    it "非 Markdown 檔案不理會" $ withNotes $ \(st, dir) -> do
      writeFile (dir </> "note.txt") "不是 markdown"
      r <- importNotes st NkKnowledge dir
      length r `shouldBe` 2

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

  describe "links" $ do
    it "建立的邊雙向都查得到" $ withNotes $ \(st, dir) -> do
      -- 「改這張 tileset 會影響哪些關卡」是從目標端出發的查詢,
      -- 與正向一樣常見。只做單向等於做了一半。
      _ <- importNotes st NkKnowledge dir
      [(a, _, _, _), (b, _, _, _)] <- take 2 <$> listNotes st Nothing
      linkEntities st "note" a "note" b RelDocuments (Just "測試")
      outs <- entityLinks st "note" a
      ins <- entityLinks st "note" b
      map (\(d, r, _, _) -> (d, r)) outs `shouldBe` [("out", "documents")]
      map (\(d, r, _, _) -> (d, r)) ins `shouldBe` [("in", "documents")]

    it "重複建立同一條邊是無操作" $ withNotes $ \(st, dir) -> do
      _ <- importNotes st NkKnowledge dir
      [(a, _, _, _), (b, _, _, _)] <- take 2 <$> listNotes st Nothing
      linkEntities st "note" a "note" b RelDocuments Nothing
      linkEntities st "note" a "note" b RelDocuments Nothing
      length <$> entityLinks st "note" a `shouldReturn` 1

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
