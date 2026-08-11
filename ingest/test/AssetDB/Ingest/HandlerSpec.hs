module AssetDB.Ingest.HandlerSpec (spec) where

import AssetDB.Ingest.Handler
import AssetDB.Types
import Codec.Picture qualified as P
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
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

    it "讀得懂 WAV 的取樣率、聲道數與長度" $ do
      -- 1 秒 44.1kHz 立體聲 16-bit = 44100 × 2 × 2 = 176,400 位元組
      probeContent "sfx.wav" (renderWav 44100 2 16 176400)
        `shouldBe` Just
          ( object
              [ "channels" .= (2 :: Int)
              , "sampleRate" .= (44100 :: Int)
              , "bitsPerSample" .= (16 :: Int)
              , "durationMs" .= (1000 :: Int)
              ]
          )

    it "chunk 之間夾雜 LIST 時仍然讀得到 fmt 與 data" $ do
      -- 真實世界的 WAV 常常在 fmt 與 data 之間放 LIST/INFO(製作軟體的署名)。
      -- 假設固定位移的解析器會在這裡讀到垃圾。
      let wav = renderWavWith [("LIST", BS.replicate 26 0x20)] 22050 1 8 11025
      fmap (KM.lookup "durationMs" . asObject) (probeContent "sfx.wav" wav)
        `shouldBe` Just (Just (Number 500))

    it "奇數長度的 chunk 後面有 padding byte" $ do
      -- RIFF 規定 chunk 以偶數位元組對齊。漏掉 padding 會讓後續所有 chunk 位移錯一格。
      let wav = renderWavWith [("id3 ", BS.replicate 7 0x41)] 8000 1 8 8000
      fmap (KM.lookup "sampleRate" . asObject) (probeContent "sfx.wav" wav)
        `shouldBe` Just (Just (Number 8000))

    it "不是 WAV 的音訊格式只分類不解碼 —— 仍然入庫" $ do
      -- ogg / mp3 / flac 目前只認副檔名。它們照樣是 KAudio、照樣進搜尋,
      -- 只是沒有時長。加入解碼時改的還是同一個 hProbe。
      kindForPath "bgm.ogg" `shouldBe` KAudio
      probeContent "bgm.ogg" "OggS\0\2\0\0\0" `shouldBe` Nothing

    it "壞掉的 WAV 回 Nothing 而不是爆炸" $ do
      hProbe audioHandlerStub "任意位元組" `shouldBe` Nothing
      -- 檔頭宣稱是 RIFF 但沒有 fmt chunk
      probeContent "sfx.wav" (BS.concat ["RIFF", le32b 40, "WAVE", BS.replicate 32 0]) `shouldBe` Nothing

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

-- | 產生一個最小但合法的 RIFF\/WAVE 檔。
--
-- 手寫而不是放二進位測試檔:這樣才能任意調整取樣率與 chunk 排列,
-- 而測試讀的人也看得到「為什麼這個位元組在這裡」。
renderWav :: Int -> Int -> Int -> Int -> ByteString
renderWav = renderWavWith []

-- | 同上,但在 @fmt @ 與 @data@ 之間插入額外的 chunk。
renderWavWith :: [(ByteString, ByteString)] -> Int -> Int -> Int -> Int -> ByteString
renderWavWith extra sampleRate channels bits dataBytes =
  BS.concat ["RIFF", le32b (4 + BS.length body), "WAVE", body]
  where
    body = BS.concat ([chunk "fmt " fmtBody] <> map (uncurry chunk) extra <> [chunk "data" (BS.replicate dataBytes 0)])
    blockAlign = channels * (bits `div` 8)
    byteRate = sampleRate * blockAlign
    fmtBody =
      BS.concat
        [ le16b 1 -- PCM
        , le16b channels
        , le32b sampleRate
        , le32b byteRate
        , le16b blockAlign
        , le16b bits
        ]

-- | chunk = 4 位元組 id + 4 位元組長度 + 內容 + 奇數長度時補一個位元組。
chunk :: ByteString -> ByteString -> ByteString
chunk cid b = BS.concat [cid, le32b (BS.length b), b, BS.replicate (BS.length b `mod` 2) 0]

le16b, le32b :: Int -> ByteString
le16b n = BS.pack [fromIntegral (n `div` (256 ^ i)) | i <- [0 :: Int, 1]]
le32b n = BS.pack [fromIntegral (n `div` (256 ^ i)) | i <- [0 :: Int .. 3]]

asObject :: Value -> KM.KeyMap Value
asObject = \case
  Object o -> o
  other -> error ("預期是 JSON 物件,收到 " <> show other)
