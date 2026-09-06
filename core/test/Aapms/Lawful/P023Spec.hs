-- | lawful 測試:P-023-manifest-codec(qa 填入)。
--
-- 十條 law 各一條 property test、十二個 example 各一條 example test,歸屬字串
-- 逐條寫成 @describe "P-023#LAW-n"@ \/ @describe "P-023#EX-n"@。
--
-- __執行預算__(rules\/roles.md「qa 的交付」:案例數與尺寸有上限、整個模組有
-- timeout):
--
-- * 每條 property 固定 100 個案例,經 @Test.Hspec.Hedgehog.'modifyMaxSuccess'@
--   宣告(hspec-hedgehog 的 @Example (PropertyT IO ())@ 實例本來就會拿 hspec 的
--   QuickCheck 參數覆寫掉 hedgehog 的 @withTests@,這裡不逆著它,直接用它唯一
--   認得的介面);shrink 上限 50、discard 上限 500(@maxDiscardRatio 5 * maxSuccess
--   100@)分別經 'modifyMaxShrinks' \/ 'modifyMaxDiscardRatio' 宣告,理由相同。
--   產生器的清單長度上限 5、文字長度上限 12、'Data.Aeson.Value' 巢狀深度上限 1,
--   沒有無界結構
-- * 每個 @it@(property 與 example 都算)經 'around_' 包在 'System.Timeout.timeout'
--   裡;超時視同紅。property 60 秒、example 10 秒,模組總預算因此有上界
--
-- __為什麼是 @Test.Hspec.Hedgehog.hedgehog@ 而不是自己呼叫 'Hedgehog.check'__:
-- lawful 的測試輸出解析器認的是 hspec 自己印的 @[✔]@\/@[✘]@ 那一列,緊接在
-- @describe "P-023#LAW-n"@ 之後。自己呼叫 'Hedgehog.check' 會讓 hedgehog 的
-- reporter 先印一行「✓ \<interactive\> passed 100 tests.」,把這一列插進中間,
-- 解析器就再也對不上。'hedgehog' 把 @PropertyT IO ()@ 交給 hspec-hedgehog 的
-- @Example@ 實例跑,hspec 這一側是唯一的 reporter,反例報告仍然完整印在失敗訊息裡,
-- 只是不會再多印一行「跑過了幾次」。
--
-- __產生器紀律__:每條 law 的 @given@ 一律用__直接建構__滿足前提的值(版本相符 \/
-- 版本不符 \/ key 不重複 \/ key 不存在),完全沒有用 'Hedgehog.Gen.filter' 過濾,
-- 因此不需要宣告覆蓋率下限。
module Aapms.Lawful.P023Spec (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM, forM_)
import Data.Aeson
  ( Result (..)
  , Value (..)
  , eitherDecodeStrict'
  , fromJSON
  , object
  , toJSON
  , (.=)
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.List (nub, sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog
  ( Gen
  , annotateShow
  , evalIO
  , forAll
  , hedgehog
  , modifyMaxDiscardRatio
  , modifyMaxShrinks
  , modifyMaxSuccess
  , (/==)
  , (===)
  )

import Aapms.Core.Asset (Sha256 (..))
import Aapms.Core.Id
  ( Id
  , IdPrefix (..)
  , Ref (..)
  , VaultId (..)
  , parseId
  , renderId
  , renderIdPrefix
  )
import Aapms.Core.Json ()
import Aapms.Core.Manifest
import Aapms.Core.Meta (Revision (..), TypeKey (..))

--------------------------------------------------------------------------------
-- 執行預算與 it 包裝

-- | 一條 property 的牆鐘上限(微秒)。
propTimeoutMicros :: Int
propTimeoutMicros = 60 * 1000 * 1000

-- | 一個 example 的牆鐘上限(微秒)。
exTimeoutMicros :: Int
exTimeoutMicros = 10 * 1000 * 1000

-- | 包住所有 law 的 'it':掛在 hspec 的 'around_' 這一層,不進 property 內部,
-- 所以 hspec-hedgehog 的 'hedgehog' 仍是唯一的 reporter。逾時視同紅。
withPropTimeout :: SpecWith a -> SpecWith a
withPropTimeout = around_ $ \act -> do
  r <- timeout propTimeoutMicros act
  case r of
    Just () -> pure ()
    Nothing ->
      expectationFailure
        ("law property 超過 " <> show (propTimeoutMicros `div` 1000000) <> " 秒未跑完,視同紅")

-- | 包住所有 example 的 'it'。逾時視同紅。
withExTimeout :: SpecWith a -> SpecWith a
withExTimeout = around_ $ \act -> do
  r <- timeout exTimeoutMicros act
  case r of
    Just () -> pure ()
    Nothing ->
      expectationFailure
        ("example 超過 " <> show (exTimeoutMicros `div` 1000000) <> " 秒未跑完,視同紅")

--------------------------------------------------------------------------------
-- 產生器(只用 types 層匯出的建構子與 smart constructor)

-- | 8 位小寫十六進位——'Aapms.Core.Id.Id' 的不變量。
genHex8 :: Gen Text
genHex8 = T.pack <$> Gen.list (Range.singleton 8) (Gen.element (['0' .. '9'] ++ ['a' .. 'f']))

-- | 'Id' 的建構子不外露,只能經 'parseId'。前綴 + 8 hex 一定合法,
-- 走不到 'Left' 分支。
genId :: IdPrefix -> Gen Id
genId p = do
  h <- genHex8
  case parseId (renderIdPrefix p <> "-" <> h) of
    Right (_, i) -> pure i
    Left e -> error ("P023Spec.genId:parseId 不該失敗:" <> show e)

-- | vault 的身分就是它自己的 @vlt-\<8 hex\>@ id(ADR-014)——'Aapms.Core.Id.parseRef'
-- 只認這個形狀的 vault 段,所以產生器不能給任意文字。
genVaultId :: Gen VaultId
genVaultId = VaultId . renderId <$> genId PVlt

genRef :: IdPrefix -> Gen Ref
genRef p = Ref <$> Gen.maybe genVaultId <*> genId p

-- | 混 ASCII \/ 符號 \/ CJK 的短文字。長度上限 12。
genText :: Gen Text
genText =
  Gen.text
    (Range.linear 0 12)
    (Gen.choice [Gen.alphaNum, Gen.element ("-_/. " :: String), Gen.enum '\x4E00' '\x9FFF'])

-- | 整秒的 'UTCTime':aeson 的 @toJSON@ \/ @fromJSON@ 對它是精確往返。
genUTCTime :: Gen UTCTime
genUTCTime = do
  d <-
    fromGregorian
      <$> Gen.integral (Range.linear 2000 2030)
      <*> Gen.int (Range.linear 1 12)
      <*> Gen.int (Range.linear 1 28)
  s <- Gen.int (Range.linear 0 86399)
  pure (UTCTime d (secondsToDiffTime (fromIntegral s)))

-- | 巢狀深度上限 1 的任意 'Value'(@maMeta@ 是自由 JSON)。
genValue :: Int -> Gen Value
genValue depth
  | depth <= 0 = leaf
  | otherwise = Gen.choice [leaf, container]
  where
    leaf =
      Gen.choice
        [ pure Null
        , toJSON <$> Gen.bool
        , toJSON <$> Gen.int (Range.linear (-1000) 1000)
        , toJSON <$> genText
        ]
    container =
      Gen.choice
        [ toJSON <$> Gen.list (Range.linear 0 3) (genValue (depth - 1))
        , toJSON . Map.fromList
            <$> Gen.list (Range.linear 0 3) ((,) <$> genFieldKey <*> genValue (depth - 1))
        ]
    genFieldKey :: Gen Text
    genFieldKey = Gen.text (Range.linear 1 6) Gen.alpha

genAssetKey :: Gen AssetKey
genAssetKey = AssetKey <$> genText

genManifestAsset :: Gen ManifestAsset
genManifestAsset =
  ManifestAsset
    <$> genId PAst
    <*> genAssetKey
    <*> genText
    <*> (TypeKey <$> genText)
    <*> (Sha256 <$> genText)
    <*> genVaultId
    <*> Gen.maybe (genRef PPck)
    <*> Gen.maybe (genRef PLic)
    <*> genValue 1

genManifestPack :: Gen ManifestPack
genManifestPack =
  ManifestPack
    <$> genRef PPck
    <*> genText
    <*> Gen.maybe genText
    <*> Gen.maybe genText
    <*> Gen.maybe (genRef PLic)

genManifestLicense :: Gen ManifestLicense
genManifestLicense =
  ManifestLicense
    <$> genRef PLic
    <*> genText
    <*> Gen.bool
    <*> Gen.bool
    <*> Gen.maybe genText
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe genText

-- | 由外部指定 @schemaVersion@ 與 asset 清單,其餘欄位隨機。
genManifestWith :: Int -> Gen [ManifestAsset] -> Gen Manifest
genManifestWith v genAssets =
  Manifest v
    <$> genText
    <*> genUTCTime
    <*> genAssets
    <*> Gen.list (Range.linear 0 3) genManifestPack
    <*> Gen.list (Range.linear 0 3) genManifestLicense

-- | 一般(可能有重複 key)的 asset 清單:key 從小池子抽,再刻意用一半的機率
-- 追加一筆同 key 的 asset,讓 LAW-6 的「有重複」子情形穩定出現。
genAssetsMaybeDup :: Gen [ManifestAsset]
genAssetsMaybeDup = do
  base <- Gen.list (Range.linear 0 4) genPooledAsset
  extra <-
    if null base
      then pure []
      else
        Gen.frequency
          [ (1, pure [])
          ,
            ( 1
            , do
                a <- Gen.element base
                b <- genPooledAsset
                pure [b {maKey = maKey a}]
            )
          ]
  Gen.shuffle (base ++ extra)
  where
    genPooledAsset = do
      a <- genManifestAsset
      k <- Gen.element keyPool
      pure a {maKey = k}

-- | key 保證兩兩相異的 asset 清單(LAW-5 的 @given@ 直接建構,不用過濾)。
genAssetsDistinctKeys :: Gen [ManifestAsset]
genAssetsDistinctKeys = do
  n <- Gen.int (Range.linear 0 5)
  ks <- take n <$> Gen.shuffle keyPool
  forM ks $ \k -> do
    a <- genManifestAsset
    pure a {maKey = k}

-- | 產生器用的 key 池;'absentKeyPool' 與它不相交。
keyPool :: [AssetKey]
keyPool = [AssetKey ("k-" <> T.pack (show i)) | i <- [1 .. 8 :: Int]]

-- | 保證不出現在 'keyPool' 裡的 key(LAW-7 的 @given@ 直接建構)。
absentKeyPool :: [AssetKey]
absentKeyPool = [AssetKey ("absent-" <> T.pack (show i)) | i <- [1 .. 5 :: Int]]

-- | 與 @cur@ 一定不相等的版本號(LAW-3 \/ LAW-4 的 @given@ 直接建構)。
genWrongVersion :: Int -> Gen Int
genWrongVersion cur = do
  d <- Gen.int (Range.linear 1 6)
  Gen.element [cur - d, cur + d]

genStoryManifestEntry :: Gen StoryManifestEntry
genStoryManifestEntry =
  StoryManifestEntry
    <$> genRef PEnt
    <*> genText
    <*> genText
    <*> genText
    <*> (Revision <$> Gen.int (Range.linear 1 50))

genStoryManifestWith :: Int -> Gen StoryManifest
genStoryManifestWith v =
  StoryManifest v
    <$> genText
    <*> genUTCTime
    <*> Gen.list (Range.linear 0 4) genStoryManifestEntry

genImageMeta :: Gen ImageMeta
genImageMeta =
  ImageMeta
    <$> Gen.int (Range.linear 0 8192)
    <*> Gen.int (Range.linear 0 8192)
    <*> Gen.bool
    <*> Gen.maybe (Gen.int (Range.linear 0 4096))

genAudioMeta :: Gen AudioMeta
genAudioMeta =
  AudioMeta
    <$> Gen.int (Range.linear 0 600000)
    <*> Gen.int (Range.linear 0 192000)
    <*> Gen.int (Range.linear 0 8)

-- | LAW-10 的定義域:任意 'Value',並刻意混入「長得像 image \/ audio meta 但欄位
-- 缺漏或型別不符」的近似物件,property 才不會只掃到明顯不相干的值。
genValueForTotality :: Gen Value
genValueForTotality =
  Gen.choice
    [ genValue 1
    , toJSON <$> genImageMeta
    , toJSON <$> genAudioMeta
    , nearMiss
    ]
  where
    nearMiss = do
      ks <- Gen.subsequence ["width", "height", "hasAlpha", "colorCount", "durationMs", "sampleRate", "channels"]
      vs <- forM ks $ \k -> (,) k <$> genValue 0
      pure (object [Key.fromText k .= v | (k, v) <- vs])

--------------------------------------------------------------------------------
-- total:把結果求值到正規形(deepseq 不在相依裡,逐欄手動 seq)

forceMaybeInt :: Maybe Int -> ()
forceMaybeInt Nothing = ()
forceMaybeInt (Just n) = n `seq` ()

forceImageMeta :: Maybe ImageMeta -> ()
forceImageMeta Nothing = ()
forceImageMeta (Just (ImageMeta w h a c)) = w `seq` h `seq` a `seq` forceMaybeInt c

forceAudioMeta :: Maybe AudioMeta -> ()
forceAudioMeta Nothing = ()
forceAudioMeta (Just (AudioMeta d r c)) = d `seq` r `seq` c `seq` ()

--------------------------------------------------------------------------------
-- golden 檔與 JSON 小工具

-- | 從 @core\/@(cabal test 的 cwd)看過去的相對路徑。
manifestGoldenPath :: FilePath
manifestGoldenPath = "test/golden/manifest.golden.json"

storyGoldenPath :: FilePath
storyGoldenPath = "test/golden/story-manifest.golden.json"

readGolden :: FilePath -> IO (Either String Value)
readGolden p = eitherDecodeStrict' <$> BS.readFile p

withGolden :: (HasCallStack) => FilePath -> Either String Value -> (Value -> Expectation) -> Expectation
withGolden p (Left e) _ = expectationFailure ("golden 檔讀不到或不是合法 JSON(" <> p <> "):" <> e)
withGolden _ (Right v) k = k v

lookupKey :: Text -> Value -> Maybe Value
lookupKey k (Object o) = KM.lookup (Key.fromText k) o
lookupKey _ _ = Nothing

setKey :: Text -> Value -> Value -> Value
setKey k nv (Object o) = Object (KM.insert (Key.fromText k) nv o)
setKey _ _ v = v

asList :: Value -> Maybe [Value]
asList v = case fromJSON v of
  Success xs -> Just xs
  Error _ -> Nothing

-- | 測試裡的 id 字面值;不合法代表 fixture 寫錯,直接爆。
idOrDie :: Text -> Id
idOrDie t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("P023Spec.idOrDie:" <> T.unpack t <> " 不是合法 id:" <> show e)

-- | 解出一個具體型別,失敗就把 aeson 的訊息當失敗理由。
decodedAs :: (HasCallStack) => String -> Result a -> (a -> Expectation) -> Expectation
decodedAs what (Error e) _ = expectationFailure (what <> " 解不出來:" <> e)
decodedAs _ (Success a) k = k a

--------------------------------------------------------------------------------
-- EX-7 的固定樣本

ex7Asset :: ManifestAsset
ex7Asset =
  ManifestAsset
    { maId = idOrDie "ast-7ad20c31"
    , maKey = AssetKey "sfx_ui_button-click_001"
    , maPath = "audio/sfx_ui_button-click_001.ogg"
    , maType = TypeKey "asset-audio"
    , maSha256 = Sha256 "3b241101707d52a324d3540c8bcffbca8ea0d1e1e2a3e1c3e1b6b6b3f7a2b0f"
    , maVault = VaultId "vlt-a0c4e1f8"
    , maPack = Nothing
    , maLicense = Nothing
    , maMeta = object ["durationMs" .= (240 :: Int), "sampleRate" .= (44100 :: Int), "channels" .= (2 :: Int)]
    }

-- | EX-9 的兩筆 pack:短 id 相同、vault 不同。
ex9PackA, ex9PackB :: ManifestPack
ex9PackA = ManifestPack (Ref (Just (VaultId "vlt-aaaaaaaa")) (idOrDie "pck-11223344")) "A 家的 UI Pack" Nothing Nothing Nothing
ex9PackB = ManifestPack (Ref (Just (VaultId "vlt-bbbbbbbb")) (idOrDie "pck-11223344")) "B 家的 UI Pack" Nothing Nothing Nothing

-- | EX-10 \/ EX-11 \/ EX-12 的四個固定 'Value'。
ex10ImageFull, ex10ImageNoColorCount, ex11Audio :: Value
ex10ImageFull =
  object
    [ "width" .= (512 :: Int)
    , "height" .= (512 :: Int)
    , "hasAlpha" .= True
    , "colorCount" .= (128 :: Int)
    ]
ex10ImageNoColorCount =
  object
    [ "width" .= (64 :: Int)
    , "height" .= (64 :: Int)
    , "hasAlpha" .= False
    ]
ex11Audio =
  object
    [ "durationMs" .= (240 :: Int)
    , "sampleRate" .= (44100 :: Int)
    , "channels" .= (2 :: Int)
    ]

--------------------------------------------------------------------------------

spec :: Spec
spec = do
  manifestGolden <- runIO (readGolden manifestGoldenPath)
  storyGolden <- runIO (readGolden storyGoldenPath)
  modifyMaxSuccess (const 100) $
    modifyMaxShrinks (const 50) $
      modifyMaxDiscardRatio (const 5) $ do
        withPropTimeout laws
        withExTimeout (examples manifestGolden storyGolden)

------------------------------------------------------------------ Laws

laws :: Spec
laws = do
  describe "P-023#LAW-1" $
    it "[roundtrip] 版本相符的 assets manifest 編成 JSON 再讀回來是同一個值" $
      hedgehog $ do
        m <- forAll (genManifestWith currentSchemaVersion genAssetsMaybeDup)
        fromJSON (toJSON m) === Success m

  describe "P-023#LAW-2" $
    it "[roundtrip] 版本相符的 story manifest 編成 JSON 再讀回來是同一個值" $
      hedgehog $ do
        sm <- forAll (genStoryManifestWith currentStoryManifestSchemaVersion)
        fromJSON (toJSON sm) === Success sm

  describe "P-023#LAW-3" $
    it "[invariant] schemaVersion 不是本工具支援的那一個就不解析,不靜默通過" $
      hedgehog $ do
        v <- forAll (genWrongVersion currentSchemaVersion)
        m <- forAll (genManifestWith v genAssetsMaybeDup)
        annotateShow (mSchemaVersion m)
        fromJSON (toJSON m) /== Success m

  describe "P-023#LAW-4" $
    it "[invariant] story manifest 的版本閘門獨立於 assets manifest,用自己的常數" $
      hedgehog $ do
        v <- forAll (genWrongVersion currentStoryManifestSchemaVersion)
        sm <- forAll (genStoryManifestWith v)
        annotateShow (smSchemaVersion sm)
        fromJSON (toJSON sm) /== Success sm

  describe "P-023#LAW-5" $
    it "[relation] key 不重複時,每一筆 asset 都能用自己的 key 從索引查回自己" $
      hedgehog $ do
        m <- forAll (genManifestWith currentSchemaVersion genAssetsDistinctKeys)
        -- given:產生器直接建構,這裡順帶把前提釘成斷言的一部分
        nub (map maKey (mAssets m)) === map maKey (mAssets m)
        forM_ (mAssets m) $ \a ->
          lookup (maKey a) (Map.toList (manifestIndex m)) === Just a

  describe "P-023#LAW-6" $
    it "[invariant] 索引的鍵集合就是 asset 的 key 集合,不多也不少" $
      hedgehog $ do
        m <- forAll (genManifestWith currentSchemaVersion genAssetsMaybeDup)
        sort (map fst (Map.toList (manifestIndex m))) === sort (nub (map maKey (mAssets m)))

  describe "P-023#LAW-7" $
    it "[relation] 沒出現在 manifest 裡的 key 查不到東西" $
      hedgehog $ do
        m <- forAll (genManifestWith currentSchemaVersion genAssetsMaybeDup)
        k <- forAll (Gen.element absentKeyPool)
        -- given:absentKeyPool 與 keyPool 不相交,前提由建構保證
        notElem k (map maKey (mAssets m)) === True
        lookup k (Map.toList (manifestIndex m)) === Nothing

  describe "P-023#LAW-8" $
    it "[roundtrip] ImageMeta 編成 JSON 再型別化讀回來是同一個值" $
      hedgehog $ do
        im <- forAll genImageMeta
        imageMeta (toJSON im) === Just im

  describe "P-023#LAW-9" $
    it "[roundtrip] AudioMeta 編成 JSON 再型別化讀回來是同一個值" $
      hedgehog $ do
        am <- forAll genAudioMeta
        audioMeta (toJSON am) === Just am

  describe "P-023#LAW-10" $
    it "[total] 任何 Value 丟給兩個型別化讀取都有值,不拋例外" $
      hedgehog $ do
        v <- forAll genValueForTotality
        -- total = 求值到正規形不拋例外;evalIO 會把例外變成這條 property 的紅燈
        _ <- evalIO (evaluate (forceImageMeta (imageMeta v)))
        _ <- evalIO (evaluate (forceAudioMeta (audioMeta v)))
        pure ()

------------------------------------------------------------------ Examples

examples :: Either String Value -> Either String Value -> Spec
examples manifestGolden storyGolden = do
  describe "P-023#EX-1" $
    it "golden manifest.golden.json 解得出 Manifest,再編碼與原檔語意相同" $
      withGolden manifestGoldenPath manifestGolden $ \gv ->
        decodedAs "manifest.golden.json" (fromJSON gv :: Result Manifest) $ \m -> do
          mSchemaVersion m `shouldBe` 2
          length (mAssets m) `shouldBe` 2
          length (mPacks m) `shouldBe` 1
          length (mLicenses m) `shouldBe` 1
          toJSON m `shouldBe` gv
          fromJSON (toJSON m) `shouldBe` Success m

  describe "P-023#EX-2" $
    it "golden story-manifest.golden.json 解得出 StoryManifest,schemaVersion 2,編回去語意相同" $
      withGolden storyGoldenPath storyGolden $ \gv ->
        decodedAs "story-manifest.golden.json" (fromJSON gv :: Result StoryManifest) $ \sm -> do
          smSchemaVersion sm `shouldBe` 2
          toJSON sm `shouldBe` gv
          fromJSON (toJSON sm) `shouldBe` Success sm

  describe "P-023#EX-3" $
    it "manifest 的 schemaVersion 換成 1 或 3 都解不出來,訊息含「請重新產生」" $
      withGolden manifestGoldenPath manifestGolden $ \gv ->
        forM_ [1 :: Int, 3] $ \bad ->
          case fromJSON (setKey "schemaVersion" (toJSON bad) gv) :: Result Manifest of
            Success m -> expectationFailure ("schemaVersion " <> show bad <> " 竟然解得出來:" <> show m)
            Error e -> do
              ("請重新產生" `T.isInfixOf` T.pack e) `shouldBe` True
              (T.pack (show bad) `T.isInfixOf` T.pack e) `shouldBe` True

  describe "P-023#EX-4" $
    it "story manifest 的 schemaVersion 換成 1 或 3 都解不出來,用自己的版本常數" $
      withGolden storyGoldenPath storyGolden $ \gv ->
        forM_ [1 :: Int, 3] $ \bad ->
          case fromJSON (setKey "schemaVersion" (toJSON bad) gv) :: Result StoryManifest of
            Success sm -> expectationFailure ("schemaVersion " <> show bad <> " 竟然解得出來:" <> show sm)
            Error e -> do
              ("story manifest" `T.isInfixOf` T.pack e) `shouldBe` True
              (T.pack (show currentStoryManifestSchemaVersion) `T.isInfixOf` T.pack e) `shouldBe` True

  describe "P-023#EX-5" $
    it "兩筆 asset 的 manifest:兩個 AssetKey 都回 Just,does-not-exist 回 Nothing" $
      withGolden manifestGoldenPath manifestGolden $ \gv ->
        decodedAs "manifest.golden.json" (fromJSON gv :: Result Manifest) $ \m -> do
          let ix = manifestIndex m
          fmap maKey (Map.lookup (AssetKey "ui_gui_travel-book-frame_001") ix)
            `shouldBe` Just (AssetKey "ui_gui_travel-book-frame_001")
          fmap maKey (Map.lookup (AssetKey "sfx_ui_button-click_001") ix)
            `shouldBe` Just (AssetKey "sfx_ui_button-click_001")
          Map.lookup (AssetKey "does-not-exist") ix `shouldBe` Nothing

  describe "P-023#EX-6" $
    it "mAssets 為 [] 的 manifest:manifestIndex 是空表,鍵集合為 []" $
      withGolden manifestGoldenPath manifestGolden $ \gv ->
        decodedAs "manifest.golden.json" (fromJSON gv :: Result Manifest) $ \m0 -> do
          let m = m0 {mAssets = []}
          manifestIndex m `shouldBe` Map.empty
          Map.keys (manifestIndex m) `shouldBe` []

  describe "P-023#EX-7" $
    it "maPack / maLicense 皆 Nothing:編碼後恰好九個鍵,兩者是 null 而不是省略鍵" $ do
      let v = toJSON ex7Asset
      case v of
        Object o -> KM.size o `shouldBe` 9
        _ -> expectationFailure ("ManifestAsset 應該編成物件,實際是:" <> show v)
      lookupKey "pack" v `shouldBe` Just Null
      lookupKey "license" v `shouldBe` Just Null
      decodedAs "EX-7 的 ManifestAsset" (fromJSON v :: Result ManifestAsset) $ \a -> do
        maPack a `shouldBe` Nothing
        maLicense a `shouldBe` Nothing
        a `shouldBe` ex7Asset

  describe "P-023#EX-8" $
    it "pack 寫成裸 id \"pck-11223344\" 讀成 Just (Ref Nothing ...),視為本 vault 參照" $
      withGolden manifestGoldenPath manifestGolden $ \gv ->
        case lookupKey "assets" gv >>= asList of
          Just (a0 : _) ->
            decodedAs "EX-8 的 ManifestAsset" (fromJSON (setKey "pack" (String "pck-11223344") a0) :: Result ManifestAsset) $ \a ->
              maPack a `shouldBe` Just (Ref Nothing (idOrDie "pck-11223344"))
          _ -> expectationFailure "golden manifest 的 assets 讀不出第一筆"

  describe "P-023#EX-9" $
    it "短 id 相同、vault 不同的兩筆 pack:mpId 不相等,各自能被完整 Ref 唯一查到" $ do
      mpId ex9PackA `shouldNotBe` mpId ex9PackB
      -- 剝掉 vault 前綴就會撞名——這正是整個引用圖 vault 化要擋的事
      refId (mpId ex9PackA) `shouldBe` refId (mpId ex9PackB)
      let table = [(mpId p, p) | p <- [ex9PackA, ex9PackB]]
      lookup (mpId ex9PackA) table `shouldBe` Just ex9PackA
      lookup (mpId ex9PackB) table `shouldBe` Just ex9PackB

  describe "P-023#EX-10" $
    it "imageMeta 讀出完整物件與缺 colorCount 的同形物件" $ do
      imageMeta ex10ImageFull `shouldBe` Just (ImageMeta 512 512 True (Just 128))
      imageMeta ex10ImageNoColorCount `shouldBe` Just (ImageMeta 64 64 False Nothing)

  describe "P-023#EX-11" $
    it "audioMeta 讀出 durationMs / sampleRate / channels" $
      audioMeta ex11Audio `shouldBe` Just (AudioMeta 240 44100 2)

  describe "P-023#EX-12" $
    it "image 的 Value 給 audioMeta、audio 的給 imageMeta,兩邊都是 Nothing 且不拋例外" $ do
      audioMeta ex10ImageFull `shouldBe` Nothing
      imageMeta ex11Audio `shouldBe` Nothing
      forceAudioMeta (audioMeta ex10ImageFull) `shouldBe` ()
      forceImageMeta (imageMeta ex11Audio) `shouldBe` ()
