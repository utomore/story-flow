-- | 共用路徑/文字小工具的測試(G-E002)。
--
-- 案例合併自各套件原本各自持有的測試與實際使用情境 ——
-- 這裡鎖住的行為,是五個套件共同的假設。
module AssetDB.PathTextSpec (spec) where

import AssetDB.PathText
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "leafOf" $ do
    it "取路徑最後一段" $ do
      leafOf "a/b/c.png" `shouldBe` "c.png"
      leafOf "c.png" `shouldBe` "c.png"

    it "空字串與尾隨分隔符" $ do
      leafOf "" `shouldBe` ""
      leafOf "a/b/" `shouldBe` ""

  describe "extensionOf" $ do
    it "取小寫副檔名(含點號)" $ do
      extensionOf "Sprites/UI_TravelBook_Frame01a.PNG" `shouldBe` ".png"
      extensionOf "a/b/c.tar.gz" `shouldBe` ".gz"

    it "沒有副檔名回空字串" $ do
      extensionOf "README" `shouldBe` ""
      extensionOf "dir/noext" `shouldBe` ""

    it "目錄名裡的點號不算" $
      extensionOf "Pack_v1.0/Sprites/frame" `shouldBe` ""

    it "點號後沒有東西視為沒有副檔名" $
      extensionOf "weird." `shouldBe` ""

  describe "slugify" $ do
    it "空格、方括號、& 與撇號都變成連字號並收斂" $ do
      slugify "Complete UI Book Styles Pack" `shouldBe` "complete-ui-book-styles-pack"
      slugify "[GUI] Pixel Art & Frames" `shouldBe` "gui-pixel-art-frames"

    it "大寫與數字保留(小寫化)" $
      slugify "BDragon1727" `shouldBe` "bdragon1727"

    it "純中文產生空字串 —— 呼叫端必須自己處理退路" $
      slugify "金門建築" `shouldBe` ""

  describe "thumbPath" $ do
    it "以內容雜湊前兩碼分層" $
      thumbPath "cache" "abcdef" Thumb128
        `shouldBe` ("cache" </> "ab" </> "abcdef_128.png")

    it "不同尺寸不同檔名" $
      thumbPath "cache" "abcdef" Thumb512
        `shouldBe` ("cache" </> "ab" </> "abcdef_512.png")

  describe "ThumbSize" $
    it "thumbSizes 覆蓋全部尺寸,px 與 tag 對應" $ do
      thumbSizes `shouldBe` [Thumb128, Thumb512]
      map thumbSizePx thumbSizes `shouldBe` [128, 512]
      map thumbSizeTag thumbSizes `shouldBe` ["128", "512"]
