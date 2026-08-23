module AssetDB.Archive.TypesSpec (spec) where

import AssetDB.Archive.Types
import AssetDB.Types (TextEnum (..))
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "detectFormat" $ do
    it "認得三種格式" $ do
      detectFormat "a.zip" `shouldBe` Just FmtZip
      detectFormat "a.rar" `shouldBe` Just FmtRar
      detectFormat "a.7z" `shouldBe` Just Fmt7z

    it "副檔名比對不分大小寫" $ do
      -- 素材庫裡有 .HEIC 這種全大寫的副檔名,壓縮檔遲早也會遇到
      detectFormat "A.ZIP" `shouldBe` Just FmtZip
      detectFormat "A.Rar" `shouldBe` Just FmtRar

    it "路徑含空格與特殊字元不影響判斷" $ do
      -- 現有素材庫的真實檔名
      detectFormat "[GUI] Shikashi's Fantasy Icons Pack v2.zip" `shouldBe` Just FmtZip
      detectFormat "herbs&medicinal-plants.zip" `shouldBe` Just FmtZip
      detectFormat "C:\\Raw壓縮檔\\金門建築.rar" `shouldBe` Just FmtRar

    it "不認得的副檔名回 Nothing" $ do
      detectFormat "a.tar" `shouldBe` Nothing
      detectFormat "a.tar.gz" `shouldBe` Nothing
      detectFormat "noext" `shouldBe` Nothing

  describe "needsSidecar" $
    it "只有 ZIP 不需要外部工具" $ do
      needsSidecar FmtZip `shouldBe` False
      needsSidecar FmtRar `shouldBe` True
      needsSidecar Fmt7z `shouldBe` True

  describe "normalizeEntryPath" $ do
    -- 7-Zip 在 Windows 上輸出反斜線,ZIP 規格用正斜線。資料庫只能存一種,
    -- 否則同一個項目會因為來源不同產生兩筆不同的 entry_path。
    it "反斜線統一成正斜線" $
      normalizeEntryPath "Books\\Books\\book1.png" `shouldBe` "Books/Books/book1.png"

    it "正斜線原樣保留" $
      normalizeEntryPath "Sprites/UI_TravelBook_Frame01a.png"
        `shouldBe` "Sprites/UI_TravelBook_Frame01a.png"

    it "去掉開頭的 ./" $ do
      normalizeEntryPath "./a.png" `shouldBe` "a.png"
      normalizeEntryPath "././a.png" `shouldBe` "a.png"

    it "是冪等的" $ do
      let p = normalizeEntryPath "a\\b\\c.png"
      normalizeEntryPath p `shouldBe` p

    it "中文路徑不受影響" $
      normalizeEntryPath "金門建築\\IMG_1342.HEIC" `shouldBe` "金門建築/IMG_1342.HEIC"

  describe "錯誤訊息" $ do
    it "找不到 sidecar 時要說出找過哪裡與怎麼安裝" $ do
      -- 「找不到 7z」對使用者沒有幫助。開發這套系統的機器上 7-Zip 裝在
      -- C:\Program Files\7-Zip\ 但不在 PATH,訊息必須說清楚找過哪些位置。
      let msg = renderArchiveError (SidecarNotFound FmtRar ["C:\\a\\7z.exe", "/usr/bin/7z"])
      msg `shouldSatisfy` T.isInfixOf "C:\\a\\7z.exe"
      msg `shouldSatisfy` T.isInfixOf "/usr/bin/7z"
      msg `shouldSatisfy` T.isInfixOf "winget install"

    it "不支援的格式要列出支援哪些" $ do
      let msg = renderArchiveError (UnsupportedExtension "a.tar")
      mapM_ (\f -> msg `shouldSatisfy` T.isInfixOf (toTextEnum f)) [FmtZip, FmtRar, Fmt7z]
