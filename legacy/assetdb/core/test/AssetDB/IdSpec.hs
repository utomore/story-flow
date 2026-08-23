module AssetDB.IdSpec (spec) where

import AssetDB.Id
import Data.Bits (shiftL)
import Data.Either (isLeft)
import Data.List (sort)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "編碼" $ do
    it "永遠是 26 個字元" $
      property $
        forAll genULID $ \u -> T.length (renderULID u) === 26

    it "只使用 Crockford 字母表(不含 I / L / O / U)" $
      property $
        forAll genULID $ \u ->
          T.all (`elem` ("0123456789ABCDEFGHJKMNPQRSTVWXYZ" :: String)) (renderULID u)

    it "render / parse 來回一致" $
      property $
        forAll genULID $ \u -> parseULID (renderULID u) === Right u

    it "全零與最大值都能表示" $ do
      let zero = either (error . T.unpack) id (mkULID 0 0)
          maxv = either (error . T.unpack) id (mkULID (bit48 - 1) (bit80 - 1))
      renderULID zero `shouldBe` T.replicate 26 "0"
      parseULID (renderULID maxv) `shouldBe` Right maxv

  describe "字典序 == 時間序" $ do
    -- 這是選 ULID 而不是 UUIDv4 的全部理由:ORDER BY ulid 免費得到建檔順序,
    -- 而且 B-tree 索引是尾端追加而不是隨機插入。
    it "時間戳較大的 ULID,文字排序也較大" $
      property $
        forAll ((,) <$> genTs <*> genTs) $ \(a, b) ->
          a /= b ==>
            let ua = mk a 0
                ub = mk b 0
             in compare a b === compare (renderULID ua) (renderULID ub)

    it "同一批 ULID 依文字排序與依值排序結果相同" $
      property $
        forAll (listOf genULID) $ \us ->
          map renderULID (sort us) === sort (map renderULID us)

  describe "解碼的寬鬆處理" $ do
    -- Crockford 的建議。人從截圖轉抄 ID 時最常打錯的就是這幾個字元,
    -- 而放寬不會造成歧義 —— I / L / O 本來就不在字母表裡。
    it "接受小寫" $ do
      let u = mk 1234567 999
          up = renderULID u
      parseULID (T.toLower up) `shouldBe` Right u

    it "I 與 L 視為 1、O 視為 0" $ do
      let canonical = T.replicate 25 "0" <> "1"
      parseULID (T.replicate 25 "O" <> "I") `shouldBe` parseULID canonical
      parseULID (T.replicate 25 "0" <> "L") `shouldBe` parseULID canonical

  describe "解碼的嚴格處理" $ do
    it "拒絕長度不對的字串" $ do
      parseULID "" `shouldSatisfy` isLeft
      parseULID (T.replicate 25 "0") `shouldSatisfy` isLeft
      parseULID (T.replicate 27 "0") `shouldSatisfy` isLeft

    it "拒絕字母表外的字元" $
      parseULID (T.replicate 25 "0" <> "U") `shouldSatisfy` isLeft

    it "拒絕超過 128 位元的值(首字元大於 7)" $ do
      -- 26 × 5 = 130 bits,比 128 多出兩位。首字元最大只能是 '7'。
      parseULID ("8" <> T.replicate 25 "0") `shouldSatisfy` isLeft
      parseULID ("Z" <> T.replicate 25 "Z") `shouldSatisfy` isLeft
      parseULID ("7" <> T.replicate 25 "Z") `shouldSatisfy` (not . isLeft)

  describe "建構的範圍檢查" $ do
    it "拒絕超出 48 位元的時間戳" $
      mkULID bit48 0 `shouldSatisfy` isLeft

    it "拒絕超出 80 位元的亂數" $
      mkULID 0 bit80 `shouldSatisfy` isLeft

    it "拒絕負值" $ do
      mkULID (-1) 0 `shouldSatisfy` isLeft
      mkULID 0 (-1) `shouldSatisfy` isLeft

  describe "取值" $ do
    it "亂數部分取得回來" $
      property $
        forAll ((,) <$> genTs <*> genRnd) $ \(ts, r) ->
          ulidRandomness (mk ts r) === r

    it "時間戳解讀為毫秒" $ do
      -- 1970-01-01T00:00:01Z
      show (ulidTimestamp (mk 1000 0)) `shouldBe` "1970-01-01 00:00:01 UTC"

  describe "newULID" $ do
    it "連續產生的 ID 不重複" $ do
      us <- mapM (const newULID) [1 .. 200 :: Int]
      length (nubOrdish (map renderULID us)) `shouldBe` 200
  where
    nubOrdish = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

--------------------------------------------------------------------------------

bit48, bit80 :: Integer
bit48 = 1 `shiftL` 48
bit80 = 1 `shiftL` 80

mk :: Integer -> Integer -> ULID
mk ts r = either (error . T.unpack) id (mkULID ts r)

genTs :: Gen Integer
genTs = choose (0, bit48 - 1)

genRnd :: Gen Integer
genRnd = choose (0, bit80 - 1)

genULID :: Gen ULID
genULID = mk <$> genTs <*> genRnd
