module AssetDB.Ingest.HandlerSpec (spec) where

import AssetDB.Ingest.Handler
import AssetDB.Types
import Codec.Picture qualified as P
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Test.Hspec

spec :: Spec
spec = do
  describe "extensionOf" $ do
    it "取小寫副檔名" $ do
      extensionOf "Sprites/UI_TravelBook_Frame01a.PNG" `shouldBe` ".png"
      extensionOf "a/b/c.tar.gz" `shouldBe` ".gz"

    it "沒有副檔名回空字串" $ do
      extensionOf "README" `shouldBe` ""
      extensionOf "dir/noext" `shouldBe` ""

    it "目錄名裡的點號不算" $
      -- 素材庫裡真的有 Complete_UI_Book_Styles_Pack_Full_v1.0/ 這種目錄
      extensionOf "Pack_v1.0/Sprites/frame" `shouldBe` ""

  describe "kindForPath" $ do
    it "依副檔名分類" $ do
      kindForPath "a.png" `shouldBe` KImage
      kindForPath "a.aseprite" `shouldBe` KSource
      kindForPath "a.psd" `shouldBe` KSource
      kindForPath "a.ttf" `shouldBe` KFont
      kindForPath "a.ldtk" `shouldBe` KLevel
      kindForPath "readme.txt" `shouldBe` KDoc
      kindForPath "a.zip" `shouldBe` KArchive

    it "不認得的副檔名歸為 KSource 而不是丟棄" $ do
      -- 廠商壓縮檔裡什麼都有。丟棄會讓「這包有幾個檔案」對不上,
      -- 之後查帳時無從解釋差額。
      kindForPath "Documentation.url" `shouldBe` KDoc
      kindForPath "weird.xyz" `shouldBe` KSource
      kindForPath "noext" `shouldBe` KSource

  describe "音效處理器" $ do
    -- 素材庫現在一個音效檔都沒有。這組測試證明音效進來時會被正確分類、
    -- 正確索引、正確出現在 facet 篩選裡,**不需要動任何資料表**。
    it "認得常見音訊格式" $
      mapM_
        (\e -> kindForPath ("sfx" <> e) `shouldBe` KAudio)
        [".wav", ".ogg", ".mp3", ".flac", ".aiff", ".m4a", ".opus"]

    it "音效與圖片走同一條索引路徑" $ do
      hKind audioHandlerStub `shouldBe` KAudio
      hKind pngHandler `shouldBe` KImage

    it "尚未實作解碼,所以沒有中繼資料 —— 但仍然入庫" $
      hProbe audioHandlerStub "任意位元組" `shouldBe` Nothing

  describe "PNG 中繼資料" $ do
    it "取出尺寸與 alpha" $ do
      let png = renderPng 7 3
      probeContent "a.png" png
        `shouldBe` Just (object ["width" .= (7 :: Int), "height" .= (3 :: Int), "hasAlpha" .= True, "colourCount" .= (1 :: Int)])

    it "色數是區分手繪與色盤像素風的訊號" $ do
      -- Cainos 的手繪素材有 2,700+ 色,像素圖示通常在 32 色以內。
      -- 這個數字會變成自動標記 pixel-art / hand-painted 的依據。
      let solid = renderPng 4 4
      fmap (KM.lookup "colourCount") (asObject <$> probeContent "a.png" solid)
        `shouldBe` Just (Just (Number 1))

    it "壞掉的 PNG 回 Nothing 而不是爆炸" $
      probeContent "a.png" "not a png at all" `shouldBe` Nothing

    it "副檔名不認得時不呼叫任何 probe" $
      probeContent "a.xyz" "whatever" `shouldBe` Nothing

--------------------------------------------------------------------------------

renderPng :: Int -> Int -> ByteString
renderPng w h =
  BL.toStrict (P.encodePng (P.generateImage (\_ _ -> P.PixelRGBA8 10 20 30 255) w h))

asObject :: Value -> KM.KeyMap Value
asObject = \case
  Object o -> o
  other -> error ("預期是 JSON 物件,收到 " <> show other)
