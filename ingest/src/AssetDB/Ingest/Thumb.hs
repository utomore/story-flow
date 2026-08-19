-- | 縮圖產生。
--
-- == 為什麼縮放演算法要分方向
--
-- 素材庫絕大多數是 32×32 的像素圖示,而網格要顯示 128px —— 那是**放大**,不是縮小。
-- 雙線性內插會把像素邊緣糊成一片,像素風完全消失。放大一律用最近鄰,
-- 而且**取整數倍**再置中,這樣每個原始像素在縮圖上都是一個乾淨的方塊。
--
-- 真正需要縮小的只有少數大圖(spritesheet、參考照片),那時才用面積平均。
--
-- == 內容定址
--
-- 快取以 blob 的 SHA-256 為鍵,不是以資源為鍵。多家廠商附上同一份免費字型時
-- 只算一次;而且素材重新命名、搬家、重新匯入都不會讓快取失效 ——
-- 內容沒變,縮圖就沒變。
module AssetDB.Ingest.Thumb
  ( ThumbSize (..)
  , thumbSizes
  , thumbPath
  , renderThumb
  , makeThumb
  ) where

-- ThumbSize 與 thumbPath 的唯一實作在 core 的 AssetDB.PathText
-- (enhance-0012):產生端(這裡)與讀取端(ai、server)必須是同一套
-- 定址規則,否則縮圖找不到卻不報錯。此處 re-export 維持既有 API。
import AssetDB.PathText (ThumbSize (..), thumbPath, thumbSizePx, thumbSizes)
import Codec.Picture qualified as P
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T

--------------------------------------------------------------------------------

-- | 解碼、縮放、編碼成 PNG。
--
-- 輸出 PNG 而非 WebP:WebP 需要外部編碼器,而縮圖總量只有兩百多 MB,
-- 省下的頻寬不值得多一個 sidecar 相依。
makeThumb :: ThumbSize -> ByteString -> Either Text ByteString
makeThumb size bs = do
  img <- either (Left . T.pack) Right (P.decodeImage bs)
  let rgba = P.convertRGBA8 img
  pure (BL.toStrict (P.encodePng (renderThumb (thumbSizePx size) rgba)))

-- | 把圖片放進 n×n 的正方形畫布,維持長寬比並置中。
--
-- 畫布是正方形而不是貼合原圖比例,因為前端的虛擬化網格需要**固定的格子高度**
-- 才能正確計算捲動位置。讓每張縮圖自己決定高度會讓捲動條在載入過程中跳動。
renderThumb :: Int -> P.Image P.PixelRGBA8 -> P.Image P.PixelRGBA8
renderThumb n src =
  P.generateImage pick n n
  where
    sw = P.imageWidth src
    sh = P.imageHeight src

    -- 放大時取整數倍,縮小時取實際比例。
    upscaling = sw <= n && sh <= n
    factor :: Int
    factor = max 1 (min (n `div` max 1 sw) (n `div` max 1 sh))

    (dw, dh)
      | upscaling = (sw * factor, sh * factor)
      | otherwise =
          let r = min (fromIntegral n / fromIntegral sw) (fromIntegral n / fromIntegral sh) :: Double
           in (max 1 (round (fromIntegral sw * r)), max 1 (round (fromIntegral sh * r)))

    offX = (n - dw) `div` 2
    offY = (n - dh) `div` 2

    pick x y
      | x < offX || y < offY || x >= offX + dw || y >= offY + dh = transparent
      | upscaling =
          -- 最近鄰:每個原始像素變成 factor×factor 的乾淨方塊,像素風完好。
          P.pixelAt src ((x - offX) `div` factor) ((y - offY) `div` factor)
      | otherwise = areaAverage src sw sh dw dh (x - offX) (y - offY)

    transparent = P.PixelRGBA8 0 0 0 0

-- | 面積平均。縮小時比最近鄰好得多 —— 最近鄰縮小會直接丟掉大部分像素,
-- 細線條與文字會斷斷續續。
areaAverage :: P.Image P.PixelRGBA8 -> Int -> Int -> Int -> Int -> Int -> Int -> P.PixelRGBA8
areaAverage src sw sh dw dh dx dy =
  let x0 = (dx * sw) `div` dw
      x1 = max (x0 + 1) (((dx + 1) * sw) `div` dw)
      y0 = (dy * sh) `div` dh
      y1 = max (y0 + 1) (((dy + 1) * sh) `div` dh)
      pixels =
        [ P.pixelAt src x y
        | y <- [y0 .. min (sh - 1) (y1 - 1)]
        , x <- [x0 .. min (sw - 1) (x1 - 1)]
        ]
      n = max 1 (length pixels)
      sums = foldr addP (0, 0, 0, 0) pixels
      (r, g, b, a) = sums
   in P.PixelRGBA8
        (fromIntegral (r `div` n))
        (fromIntegral (g `div` n))
        (fromIntegral (b `div` n))
        (fromIntegral (a `div` n))
  where
    addP (P.PixelRGBA8 r g b a) (ar, ag, ab, aa) =
      ( ar + fromIntegral r :: Int
      , ag + fromIntegral g :: Int
      , ab + fromIntegral b :: Int
      , aa + fromIntegral a :: Int
      )
