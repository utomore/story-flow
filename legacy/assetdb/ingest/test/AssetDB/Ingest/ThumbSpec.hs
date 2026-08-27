-- | 縮圖縮放的測試。
--
-- 重點是**放大時不能糊掉**:素材庫絕大多數是 32×32 的像素圖示,
-- 而網格顯示 128px —— 那是放大。雙線性內插會讓像素風完全消失。
module AssetDB.Ingest.ThumbSpec (spec) where

import AssetDB.Ingest.Thumb
import Codec.Picture qualified as P
import Data.ByteString.Lazy qualified as BL
import System.FilePath (splitDirectories, takeFileName)
import Test.Hspec

spec :: Spec
spec = do
  describe "renderThumb" $ do
    it "輸出永遠是正方形" $ do
      -- 前端的虛擬化網格需要固定格子高度才能算對捲動位置。
      let out = renderThumb 128 (checker 32 8)
      (P.imageWidth out, P.imageHeight out) `shouldBe` (128, 128)

    it "非正方形的來源會置中,不會被拉伸" $ do
      let out = renderThumb 64 (solid 32 8 red)
      -- 上下應該是透明的留白
      P.pixelAt out 32 0 `shouldBe` transparent
      P.pixelAt out 32 32 `shouldBe` red

    it "放大用最近鄰:原始像素變成乾淨方塊,不產生中間色" $ do
      -- 這是整個模組存在的理由。8×8 放到 64×64 是 8 倍,
      -- 每個原始像素應該是 8×8 的純色方塊。
      let src = checker 8 1
          out = renderThumb 64 src
          colours = [P.pixelAt out x y | x <- [0 .. 63], y <- [0 .. 63]]
      length (nub' colours) `shouldBe` 2

    it "放大取整數倍,不會產生半個像素" $ do
      -- 100 / 8 = 12.5。取 12 倍得 96,兩側各留 2px。
      let out = renderThumb 100 (solid 8 8 red)
      P.pixelAt out 1 50 `shouldBe` transparent
      P.pixelAt out 50 50 `shouldBe` red

    it "縮小用面積平均:細節不會整片消失" $ do
      -- 最近鄰縮小會直接丟掉大部分像素,棋盤格會變成單色。
      let src = checker 64 1
          out = renderThumb 8 src
          colours = [P.pixelAt out x y | x <- [0 .. 7], y <- [0 .. 7]]
      -- 平均之後應該是介於黑白之間的灰,而不是純黑或純白
      length (nub' colours) `shouldSatisfy` (>= 1)
      all (\(P.PixelRGBA8 r _ _ _) -> r > 40 && r < 215) colours `shouldBe` True

  describe "makeThumb" $ do
    it "吃得下真的 PNG,吐得出真的 PNG" $ do
      let png = BL.toStrict (P.encodePng (checker 32 4))
      case makeThumb Thumb128 png of
        Left e -> expectationFailure (show e)
        Right out -> case P.decodePng out of
          Left e -> expectationFailure e
          Right img -> P.dynamicMap P.imageWidth img `shouldBe` 128

    it "壞掉的輸入回報錯誤而不是爆炸" $
      makeThumb Thumb128 "not an image" `shouldSatisfy` either (const True) (const False)

  describe "thumbPath" $ do
    it "以雜湊前兩碼分層,避免單一目錄塞六千個檔案" $ do
      -- 分隔符是平台原生的,所以比對路徑分段而不是整串。
      let p = thumbPath "/cache" "abcdef0123" Thumb128
      splitDirectories p `shouldContain` ["ab"]
      takeFileName p `shouldBe` "abcdef0123_128.png"

    it "不同尺寸不同檔名" $
      thumbPath "/c" "aa" Thumb128 `shouldNotBe` thumbPath "/c" "aa" Thumb512

--------------------------------------------------------------------------------

red, transparent :: P.PixelRGBA8
red = P.PixelRGBA8 255 0 0 255
transparent = P.PixelRGBA8 0 0 0 0

solid :: Int -> Int -> P.PixelRGBA8 -> P.Image P.PixelRGBA8
solid w h p = P.generateImage (\_ _ -> p) w h

-- | 棋盤格,格子大小 n。
checker :: Int -> Int -> P.Image P.PixelRGBA8
checker size n =
  P.generateImage
    ( \x y ->
        if even ((x `div` n) + (y `div` n))
          then P.PixelRGBA8 0 0 0 255
          else P.PixelRGBA8 255 255 255 255
    )
    size
    size

nub' :: Eq a => [a] -> [a]
nub' = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
