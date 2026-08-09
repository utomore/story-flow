module AssetDB.Ingest.CatalogueSpec (spec) where

import AssetDB.Ingest.Catalogue
import AssetDB.Store
import Control.Monad (void)
import Data.Either (isLeft)
import Data.Text (Text)
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = do
  describe "parseCatalogue" $ do
    it "讀出所有欄位" $
      case parseCatalogue sample of
        Left e -> expectationFailure (show e)
        Right (Catalogue [p]) -> do
          peArchive p `shouldBe` "demo.zip"
          peName p `shouldBe` "Demo Pack"
          peSlug p `shouldBe` "demo-pack"
          peVendor p `shouldBe` Just "DemoVendor"
          peAuthor p `shouldBe` Just "Demo Author"
          peLicense p `shouldBe` Just "Demo License"
          peAi p `shouldBe` Just "assisted"
          pePrice p `shouldBe` Just 2.5
        Right other -> expectationFailure ("預期一個 pack,收到 " <> show (length (catPacks other)))

    it "可選欄位缺席不影響解析" $
      case parseCatalogue "schema = 1\n[[pack]]\narchive=\"a.zip\"\nname=\"A\"\nslug=\"a\"\n" of
        Right (Catalogue [p]) -> do
          peLicense p `shouldBe` Nothing
          peAuthor p `shouldBe` Nothing
        other -> expectationFailure (show (fmap (length . catPacks) other))

    it "缺少必填欄位就失敗" $ do
      -- archive / name / slug 三者缺一就無法對應到資料庫,寧可解析失敗
      parseCatalogue "[[pack]]\nname=\"A\"\nslug=\"a\"\n" `shouldSatisfy` isLeft
      parseCatalogue "[[pack]]\narchive=\"a.zip\"\n" `shouldSatisfy` isLeft

    it "語法錯誤就失敗" $
      parseCatalogue "這不是 TOML [[[" `shouldSatisfy` isLeft

  describe "applyCatalogue" $ around withSeeded $ do
    it "以基本檔名比對,不是完整路徑" $ \st -> do
      -- 重構會改變目錄結構,但廠商的壓縮檔檔名不會變
      r <- apply st sample
      map fst (arMatched r) `shouldBe` ["demo.zip"]
      arMissingArchive r `shouldBe` []

    it "授權與作者齊備時升級為 ready" $ \st -> do
      r <- apply st sample
      map snd (arMatched r) `shouldBe` [True]
      countWhere st "packs WHERE status='ready'" `shouldReturn` 1

    it "缺作者時維持 draft" $ \st -> do
      r <- apply st noAuthor
      map snd (arMatched r) `shouldBe` [False]
      countWhere st "packs WHERE status='draft'" `shouldReturn` 1

    it "引用不存在的授權時回報,而不是靜靜忽略" $ \st -> do
      r <- apply st badLicense
      arMissingLicense r `shouldBe` ["No Such License"]
      -- 沒有套用任何東西,素材包維持 draft
      countWhere st "packs WHERE status='draft'" `shouldReturn` 1

    it "資料庫裡沒有的壓縮檔會被回報" $ \st -> do
      r <- apply st missingArchive
      arMissingArchive r `shouldBe` ["never-scanned.zip"]

    it "作者只建立一次" $ \st -> do
      void (apply st sample)
      void (apply st sample)
      countWhere st "authors" `shouldReturn` 1

    it "重複套用不會產生變化" $ \st -> do
      void (apply st sample)
      r <- apply st sample
      map snd (arMatched r) `shouldBe` [True]
      countWhere st "packs" `shouldReturn` 1

--------------------------------------------------------------------------------

apply :: Store -> Text -> IO ApplyResult
apply st src =
  case parseCatalogue src of
    Left e -> ioError (userError (show e))
    Right c -> applyCatalogue st c

sample :: Text
sample =
  "schema = 1\n\
  \[[pack]]\n\
  \archive = \"demo.zip\"\n\
  \name = \"Demo Pack\"\n\
  \slug = \"demo-pack\"\n\
  \vendor = \"DemoVendor\"\n\
  \author = \"Demo Author\"\n\
  \author_url = \"https://demo.itch.io\"\n\
  \license = \"Demo License\"\n\
  \ai = \"assisted\"\n\
  \price_usd = 2.5\n"

noAuthor :: Text
noAuthor =
  "[[pack]]\narchive=\"demo.zip\"\nname=\"Demo\"\nslug=\"demo\"\nlicense=\"Demo License\"\n"

badLicense :: Text
badLicense =
  "[[pack]]\narchive=\"demo.zip\"\nname=\"Demo\"\nslug=\"demo\"\n\
  \author=\"A\"\nlicense=\"No Such License\"\n"

missingArchive :: Text
missingArchive =
  "[[pack]]\narchive=\"never-scanned.zip\"\nname=\"X\"\nslug=\"x\"\n"

withSeeded :: (Store -> IO ()) -> IO ()
withSeeded f = do
  st <- openStoreInMemory
  void (initSchema st)
  let conn = storeConn st
  execute_ conn "INSERT INTO licenses (name,commercial,attribution_required) VALUES ('Demo License',1,0)"
  execute_ conn "INSERT INTO roots (id,path,label,kind) VALUES (1,'C:/lib','lib','packs')"
  execute_
    conn
    "INSERT INTO packs (id,ulid,slug,name,root_id,rel_dir,created_at,updated_at) \
    \VALUES (1,'01P0','demo','Demo',1,'vendor/demo.zip','t','t')"
  execute_
    conn
    "INSERT INTO archives (id,ulid,pack_id,rel_path,format,sha256,bytes) \
    \VALUES (1,'01A0',1,'vendor/demo.zip','zip','deadbeef',1)"
  f st
  close conn

countWhere :: Store -> Text -> IO Int
countWhere st what = do
  rows <- query_ (storeConn st) (Query ("SELECT COUNT(*) FROM " <> what))
  pure (case rows of (Only n : _) -> n; _ -> -1)
