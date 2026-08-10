module AssetDB.Reorg.PackTomlSpec (spec) where

import AssetDB.Reorg.PackToml
import AssetDB.Reorg.Snapshot
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "renderPackToml" $ do
    let out = renderPackToml full

    it "含有識別欄位" $ do
      out `shouldSatisfy` T.isInfixOf "slug = \"complete-ui-book-styles\""
      out `shouldSatisfy` T.isInfixOf "vendor = \"Crusenho\""
      out `shouldSatisfy` T.isInfixOf "author = \"Crusenho Agus Hennihuno\""

    it "含有壓縮檔的雜湊與大小 —— 這是資料庫從磁碟重建的依據" $ do
      out `shouldSatisfy` T.isInfixOf "[archive]"
      out `shouldSatisfy` T.isInfixOf "sha256 = \"abc123\""
      out `shouldSatisfy` T.isInfixOf "entries = 1693"

    it "只寫壓縮檔的檔名,不寫路徑" $ do
      -- pack.toml 與壓縮檔放在同一個目錄裡,路徑會隨重構改變而檔名不會。
      out `shouldSatisfy` T.isInfixOf "file = \"pack.7z\""
      out `shouldNotSatisfy` T.isInfixOf "Raw/"

    it "AI 揭露有註解說明 unknown 與 none 的差別" $ do
      out `shouldSatisfy` T.isInfixOf "ai_disclosure = \"none\""
      out `shouldSatisfy` T.isInfixOf "Steam"

    it "缺欄位不會產生空白的 key" $ do
      -- `version = ""` 之類的東西看起來像「版本是空字串」,
      -- 而不是「沒有版本資訊」。兩者意義不同。
      let minimal = renderPackToml (full {prVendor = Nothing, prVersion = Nothing, prSourceUrl = Nothing})
      minimal `shouldNotSatisfy` T.isInfixOf "vendor ="
      minimal `shouldNotSatisfy` T.isInfixOf "version ="
      minimal `shouldNotSatisfy` T.isInfixOf "= \"\""

  describe "沒有授權時" $ do
    let out = renderPackToml (full {prLicense = Nothing, prStatus = "draft"})

    it "不產生 [license] 區塊,而是留下顯眼的說明" $ do
      out `shouldNotSatisfy` T.isInfixOf "[license]"
      out `shouldSatisfy` T.isInfixOf "⚠ 授權未填"

    it "status 是 draft" $
      out `shouldSatisfy` T.isInfixOf "status = \"draft\""

  describe "字串跳脫" $ do
    it "雙引號會跳脫" $
      renderPackToml (full {prName = "Shikashi\"s Pack"})
        `shouldSatisfy` T.isInfixOf "\\\""

    it "反斜線會跳脫" $
      renderPackToml (full {prName = "a\\b"})
        `shouldSatisfy` T.isInfixOf "\\\\"

    it "中文原樣保留 —— TOML 本來就是 UTF-8" $
      renderPackToml (full {prName = "1990 年代金門建築"})
        `shouldSatisfy` T.isInfixOf "name = \"1990 年代金門建築\""

--------------------------------------------------------------------------------

full :: PackRow
full =
  PackRow
    { prSlug = "complete-ui-book-styles"
    , prName = "Complete UI Book Styles Pack"
    , prVendor = Just "Crusenho"
    , prAuthor = Just "Crusenho Agus Hennihuno"
    , prLicense = Just "Crusenho Asset License"
    , prKind = "packs"
    , prStatus = "ready"
    , prAi = "none"
    , prSourceUrl = Just "https://crusenho.itch.io"
    , prVersion = Just "1.0"
    , prNotes = Nothing
    , prArchiveRel = "Raw/pack.7z"
    , prArchiveSha = "abc123"
    , prArchiveBytes = 5976883
    , prEntryCount = 1693
    }

