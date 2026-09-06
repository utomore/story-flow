-- | lawful 測試:P-020-core-identity(qa 填入)。
--
-- 每條 law 一個 @describe "P-020#LAW-n"@ 包住的 property,每個 example 一個
-- @describe "P-020#EX-n"@。歸屬字串只出現在這個模組。
--
-- 產生器只用 @Aapms.Core.Id@(types 層)匯出的建構途徑組合法值:
-- 'Id' 的建構子不外露,所以合法的 'Id' 只能來自 'newId'(一律 8 位十六進位)
-- 或 'parseId'(放寬到 1–8 位);'Ref' 與 'VaultId' 的建構子有匯出,但 vault
-- 段落一律用 @vlt-\<hex\>@ 組出來,才是文檔說的合法參照。
module Aapms.Lawful.P020Spec (spec) where

import Control.Exception (evaluate)
import qualified Data.ByteString as BS
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), addDays, fromGregorian, secondsToDiffTime)
import System.Timeout (timeout)

import Test.Hspec
import Test.Hspec.Hedgehog

import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Aapms.Core.Id

--------------------------------------------------------------------------------
-- 產生器
--------------------------------------------------------------------------------

-- | 八種前綴的封閉列舉。
genIdPrefix :: Gen IdPrefix
genIdPrefix = Gen.enumBounded

-- | 小寫十六進位字元。
genHexDigit :: Gen Char
genHexDigit = Gen.element (['0' .. '9'] ++ ['a' .. 'f'])

-- | 1–8 位小寫十六進位,parseId 接受的範圍。
genHexBody :: Gen Text
genHexBody = T.pack <$> Gen.list (Range.linear 1 8) genHexDigit

-- | 要雜湊的內容:ASCII 與中日文字混排,長度有上限。
genContent :: Gen Text
genContent = Gen.text (Range.linear 0 32) genContentChar

genContentChar :: Gen Char
genContentChar =
  Gen.frequency
    [ (3, Gen.alphaNum)
    , (2, Gen.element ['琳', '達', '埃', '提', '亞', '崩', '塌', '前', '的', '織', '紋', '刀'])
    , (1, Gen.element [' ', '-', '_', ':', '.'])
    ]

-- | 時間由呼叫端給,範圍限在 2020-01-01 之後十年內。
genTime :: Gen UTCTime
genTime = do
  d <- Gen.integral (Range.linear 0 3650)
  s <- Gen.integral (Range.linear 0 86399)
  pure (UTCTime (addDays d (fromGregorian 2020 1 1)) (secondsToDiffTime s))

-- | 碰撞重試用的 salt,有上限。
genSalt :: Gen Int
genSalt = Gen.int (Range.linear 0 1000)

-- | 合法的 id 文字:@\<prefix\>-\<1..8 hex\>@。
genIdText :: Gen Text
genIdText = do
  p <- genIdPrefix
  h <- genHexBody
  pure (renderIdPrefix p <> "-" <> h)

-- | 合法的 vault 文字:vault 段落自己也是一個 @vlt-\<hex\>@ id。
genVaultIdText :: Gen Text
genVaultIdText = ("vlt-" <>) <$> genHexBody

genVaultId :: Gen VaultId
genVaultId = VaultId <$> genVaultIdText

-- | 合法的參照文字,兩種寫法各半。
genRefText :: Gen Text
genRefText = do
  mv <- Gen.maybe genVaultIdText
  i <- genIdText
  pure (maybe "" (<> ":") mv <> i)

-- | newId 產生的 id(一律八位)。
genNewId :: Gen Id
genNewId = newId <$> genIdPrefix <*> genContent <*> genTime <*> genSalt

-- | parseId 解析出來的 id(涵蓋 1–7 位的短寫)。
genParsedId :: Gen Id
genParsedId = Gen.mapMaybe (either (const Nothing) (Just . snd) . parseId) genIdText

-- | 兩種合法來源各半。
genId :: Gen Id
genId = Gen.choice [genNewId, genParsedId]

genRef :: Gen Ref
genRef = Ref <$> Gen.maybe genVaultId <*> genId

-- | 任意文字,偏向會打到解析器邊界的形狀。
genAnyText :: Gen Text
genAnyText =
  Gen.choice
    [ Gen.text (Range.linear 0 24) Gen.unicode
    , Gen.text (Range.linear 0 16) (Gen.element (['a' .. 'g'] ++ ['0' .. '9'] ++ ['-', ':']))
    , genRefText
    , genIdText
    , renderIdPrefix <$> genIdPrefix
    , (<> "-") . renderIdPrefix <$> genIdPrefix
    ]

--------------------------------------------------------------------------------
-- 輔助
--------------------------------------------------------------------------------

-- | total 的斷言:把結果求值到正規形(靠 Show 走遍整個結構)不拋例外。
evalTotal :: Show a => a -> PropertyT IO ()
evalTotal x = do
  n <- evalIO (evaluate (length (show x)))
  assert (n >= 0)

isHexLowerChar :: Char -> Bool
isHexLowerChar c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

-- | EX 用的固定時間。
time0 :: UTCTime
time0 = UTCTime (fromGregorian 2026 9 6) 0

-- | 整個模組的 per-test timeout,跑爆機器視同紅。
withPerTestTimeout :: IO () -> IO ()
withPerTestTimeout act = do
  r <- timeout 30000000 act
  case r of
    Just () -> pure ()
    Nothing -> expectationFailure "P-020 測試超過 30 秒 timeout"

--------------------------------------------------------------------------------
-- spec
--------------------------------------------------------------------------------

spec :: Spec
spec = modifyMaxSuccess (const 100) . around_ withPerTestTimeout $ do
  laws
  examples

laws :: Spec
laws = do
  describe "P-020#LAW-1" $
    it "[roundtrip] 參照渲染成文字再解析,拿回同一個參照" $
      hedgehog $ do
        r <- forAll genRef
        parseRef (renderRef r) === Right r

  describe "P-020#LAW-2" $
    it "[roundtrip] 合法的參照字串解析後渲染回來逐字相同,兩種寫法都是" $
      hedgehog $ do
        t <- forAll genRefText
        fmap renderRef (parseRef t) === Right t

  describe "P-020#LAW-3" $
    it "[roundtrip] 八種前綴的文字表示與解析互為反函式" $
      hedgehog $ do
        p <- forAll genIdPrefix
        parseIdPrefix (renderIdPrefix p) === Right p

  describe "P-020#LAW-4" $
    it "[roundtrip] id 渲染成文字再解析,拿回同一個 id" $
      hedgehog $ do
        i <- forAll genId
        fmap snd (parseId (renderId i)) === Right i

  describe "P-020#LAW-5" $
    it "[relation] 生出來的 id,前綴就是給它的那一個" $
      hedgehog $ do
        p <- forAll genIdPrefix
        c <- forAll genContent
        tm <- forAll genTime
        s <- forAll genSalt
        idPrefix (newId p c tm s) === p

  describe "P-020#LAW-6" $
    it "[invariant] newId 一律產生三字母前綴加八位十六進位,全長固定 12" $
      hedgehog $ do
        p <- forAll genIdPrefix
        c <- forAll genContent
        tm <- forAll genTime
        s <- forAll genSalt
        let t = renderId (newId p c tm s)
        T.length t === 12
        assert (T.isPrefixOf (renderIdPrefix p) t)

  describe "P-020#LAW-7" $
    it "[relation] 同一組輸入換一個 salt 就得到不同的 id" $
      hedgehog $ do
        p <- forAll genIdPrefix
        c <- forAll genContent
        tm <- forAll genTime
        s1 <- forAll genSalt
        d <- forAll (Gen.int (Range.linear 1 1000))
        let s2 = s1 + d
        assert (s1 /= s2)
        newId p c tm s1 /== newId p c tm s2

  describe "P-020#LAW-8" $
    it "[relation] localRef 只換包裝:vault 段落是空的,id 原封不動" $
      hedgehog $ do
        i <- forAll genId
        refVault (localRef i) === Nothing
        refId (localRef i) === i

  describe "P-020#LAW-9" $
    it "[total] 任何文字丟給 parseId 都有值,不拋例外" $
      hedgehog $ do
        t <- forAll genAnyText
        evalTotal (parseId t)

  describe "P-020#LAW-10" $
    it "[total] 任何文字丟給 parseRef 都有值,不拋例外" $
      hedgehog $ do
        t <- forAll genAnyText
        evalTotal (parseRef t)

  describe "P-020#LAW-11" $
    it "[identity] 空的位元組序列不折疊任何東西,雜湊值就是 FNV-1a 的 offset basis" $
      hedgehog $ do
        bs <- forAll (Gen.bytes (Range.singleton 0))
        assert (BS.null bs)
        fnv1a64 bs === 0xcbf29ce484222325

examples :: Spec
examples = do
  describe "P-020#EX-1" $
    it "parseRef \"vlt-a0c4e1f8:ent-7f3b2a91\" 帶 vault 段落,renderRef 逐字回來" $
      case parseRef "vlt-a0c4e1f8:ent-7f3b2a91" of
        Left e -> expectationFailure ("預期 Right,得到 " ++ show e)
        Right r -> do
          refVault r `shouldBe` Just (VaultId "vlt-a0c4e1f8")
          renderRef r `shouldBe` "vlt-a0c4e1f8:ent-7f3b2a91"

  describe "P-020#EX-2" $
    it "parseRef \"ent-7f3b2a91\" 是裸 id,vault 段落為 Nothing" $
      case parseRef "ent-7f3b2a91" of
        Left e -> expectationFailure ("預期 Right,得到 " ++ show e)
        Right r -> do
          refVault r `shouldBe` Nothing
          renderRef r `shouldBe` "ent-7f3b2a91"

  describe "P-020#EX-3" $
    it "parseRef \":ent-7f3a\" 的 vault 段落為空,是 BadRefFormat" $
      parseRef ":ent-7f3a" `shouldBe` Left (BadRefFormat ":ent-7f3a")

  describe "P-020#EX-4" $
    it "vault 段落的前綴不是 vlt、或多於一個冒號,都是 BadRefFormat" $ do
      parseRef "ent-00000000:ent-7f3a" `shouldBe` Left (BadRefFormat "ent-00000000:ent-7f3a")
      parseRef "a:b:ent-7f3a" `shouldBe` Left (BadRefFormat "a:b:ent-7f3a")

  describe "P-020#EX-5" $
    it "八種前綴的文字表示,逐一 parseIdPrefix 回原值" $ do
      let ps = [PEnt, PAst, PPck, PLic, PLvl, PNod, PVlt, PPrj]
      map renderIdPrefix ps `shouldBe` ["ent", "ast", "pck", "lic", "lvl", "nod", "vlt", "prj"]
      traverse (parseIdPrefix . renderIdPrefix) ps `shouldBe` Right ps

  describe "P-020#EX-6" $
    it "parseId \"nod-0001\" 收下四位十六進位的短寫,renderId 逐字回來" $
      case parseId "nod-0001" of
        Left e -> expectationFailure ("預期 Right,得到 " ++ show e)
        Right (p, i) -> do
          p `shouldBe` PNod
          renderId i `shouldBe` "nod-0001"

  describe "P-020#EX-7" $
    it "沒有連字號、空的十六進位段、非法字元、超過八位,都是 BadIdFormat" $ do
      let badFormat t = case parseId t of
            Left (BadIdFormat _) -> pure ()
            other -> expectationFailure ("預期 BadIdFormat,得到 " ++ show other)
      badFormat "ent7f3a"
      badFormat "ent-"
      badFormat "ent-7g3a"
      badFormat "ent-7f3a1c92f"

  describe "P-020#EX-8" $
    it "parseId \"xyz-7f3a\" 的前綴不是八種之一" $
      parseId "xyz-7f3a" `shouldBe` Left (UnknownIdPrefix "xyz")

  describe "P-020#EX-9" $
    it "同輸入換 salt 得到不同 id;salt 0..9 得到十個互不相同的 id" $ do
      newId PEnt "琳達" time0 0 `shouldNotBe` newId PEnt "琳達" time0 1
      let ids = [newId PEnt "琳達" time0 s | s <- [0 .. 9]]
      length (nub ids) `shouldBe` 10

  describe "P-020#EX-10" $
    it "newId 的文字:ent 起頭、連字號之後恰好八位小寫十六進位、全長 12" $ do
      let i = newId PEnt "埃提亞崩塌前的織紋刀" time0 0
          t = renderId i
          body = T.drop 4 t
      T.length t `shouldBe` 12
      T.take 4 t `shouldBe` "ent-"
      T.length body `shouldBe` 8
      T.all isHexLowerChar body `shouldBe` True
      idPrefix i `shouldBe` PEnt

  describe "P-020#EX-11" $
    it "fnv1a64 的 offset basis 與單字元對照值" $ do
      fnv1a64 "" `shouldBe` 0xcbf29ce484222325
      fnv1a64 "a" `shouldBe` 0xaf63dc4c8601ec8c
