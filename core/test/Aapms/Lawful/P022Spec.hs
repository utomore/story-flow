-- | lawful 測試:P-022-logical-name(qa 填入)。
--
-- 每條 law 一個 @describe "P-022#LAW-n"@ 包住的 property test,每個 example 一個
-- @describe "P-022#EX-n"@。產生器只用 types 層 "Aapms.Core.Name" 的 smart
-- constructor('mkSegment' / 'indexSegment')組合法值,尺寸全部有上限。
module Aapms.Lawful.P022Spec (spec) where

import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Name
import Aapms.Core.Naming
  ( mkLogicalName
  , parseLogicalName
  , renderParts
  , validateLogicalName
  )
import Control.Exception (SomeException, evaluate, try)
import Control.Monad.IO.Class (liftIO)
import Data.Either (isLeft, isRight)
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog

--------------------------------------------------------------------------------
-- 測試支架

-- | 測試用的分段建構;只吃已知合法的字面值,踩到就是 fixture 寫錯。
seg :: Text -> Segment
seg t = case mkSegment t of
  Right s -> s
  Left e -> error ("P-022 test fixture: " <> show t <> " -> " <> show e)

-- | 整個模組的上限:任何一條 property 或 example 超過就算紅。
withTimeoutSecs :: Int -> SpecWith a -> SpecWith a
withTimeoutSecs n = around_ $ \act -> do
  r <- timeout (n * 1000000) act
  case r of
    Just () -> pure ()
    Nothing -> expectationFailure ("P-022 測試超過 " <> show n <> " 秒未結束")

isBadSegmentErr :: Either NameError a -> Bool
isBadSegmentErr (Left (BadSegment _)) = True
isBadSegmentErr _ = False

isTooLongErr :: Either NameError a -> Bool
isTooLongErr (Left (TooLong _ _)) = True
isTooLongErr _ = False

--------------------------------------------------------------------------------
-- 詞彙表的候選池
--
-- 「外來」池與正規池刻意不相交,有 given 前提的 law 因此可以直接建構滿足前提的
-- 值,不必靠過濾。

kindPool :: [Text]
kindPool = ["ui", "spr", "tex", "sfx"]

foreignKindPool :: [Text]
foreignKindPool = ["zzz", "qqq", "wxy"]

domainPool :: [Text]
domainPool = ["gui", "char", "ground"]

statePool :: [Text]
statePool = ["up", "down", "idle", "hover", "pressed"]

foreignStatePool :: [Text]
foreignStatePool = ["zzz", "qqq", "wxy"]

--------------------------------------------------------------------------------
-- 產生器

segChars :: [Char]
segChars = ['a' .. 'z'] ++ ['0' .. '9']

genSegChar :: Gen Char
genSegChar = Gen.element segChars

-- | 合法分段的文字:1~2 個 @[a-z0-9]+@ 片段以 @-@ 相接,最長 11 個字元。
genSegmentText :: Gen Text
genSegmentText = do
  n <- Gen.int (Range.linear 1 2)
  parts <- Gen.list (Range.singleton n) (Gen.text (Range.linear 1 5) genSegChar)
  pure (T.intercalate "-" parts)

genSegment :: Gen Segment
genSegment = do
  t <- genSegmentText
  either (const Gen.discard) pure (mkSegment t)

-- | 詞彙表。三張表都從候選池抽子序列;'nvKinds' 與 'nvStates' 保證非空,後續的
-- 產生器才抽得到「表內」的值。
genVocab :: Gen NamingVocab
genVocab = do
  k0 <- Gen.element kindPool
  ks <- Gen.subsequence kindPool
  ds <- Gen.subsequence domainPool
  s0 <- Gen.element statePool
  ss <- Gen.subsequence statePool
  pure
    NamingVocab
      { nvKinds = map seg (nub (k0 : ks))
      , nvDomains = map seg ds
      , nvStates = map seg (nub (s0 : ss))
      }

-- | 依文法組出的合法候選名稱,長度必定遠低於 'maxLogicalNameLength'。
genNameText :: NamingVocab -> Gen Text
genNameText v = do
  k <- Gen.element (map segmentText (nvKinds v))
  d <- Gen.element domainPool
  s <- genSegmentText
  mvar <- Gen.maybe genSegmentText
  mst <- Gen.maybe (Gen.element (map segmentText (nvStates v)))
  mix <- Gen.maybe (Gen.int (Range.linear 0 999))
  let ixTxt = fmap (T.justifyRight 3 '0' . T.pack . show) mix
  pure (T.intercalate "_" ([k, d, s] ++ catMaybes [mvar, mst, ixTxt]))

-- | 任意文字:名稱狀的、ASCII 垃圾、非 ASCII、空字串都有。
genAnyText :: NamingVocab -> Gen Text
genAnyText v =
  Gen.frequency
    [ (4, genNameText v)
    , (2, Gen.text (Range.linear 0 24) (Gen.element (segChars ++ "_-. ABZ")))
    , (2, Gen.text (Range.linear 0 12) Gen.unicode)
    , (1, pure "")
    ]

-- | 長度必定超過上限的合法字元名稱。
genOverlongText :: NamingVocab -> Gen Text
genOverlongText v = do
  k <- Gen.element (map segmentText (nvKinds v))
  d <- Gen.element domainPool
  n <- Gen.int (Range.linear (maxLogicalNameLength + 1) 90)
  s <- Gen.text (Range.singleton n) genSegChar
  Gen.element [T.intercalate "_" [k, d, s], s, T.intercalate "_" [k, d, s, "up"]]

-- | 手工建構的部位,kind 在表內、其餘欄位隨機。
genPartsInVocab :: NamingVocab -> Gen NameParts
genPartsInVocab v = do
  k <- Gen.element (nvKinds v)
  d <- seg <$> Gen.element domainPool
  s <- genSegment
  mvar <- Gen.maybe genSegment
  mst <- Gen.maybe (Gen.element (nvStates v))
  mix <- Gen.maybe (Gen.int (Range.linear 0 999))
  pure
    NameParts
      { npKind = k
      , npDomain = d
      , npSubject = s
      , npVariant = mvar
      , npState = mst
      , npIndex = mix
      }

--------------------------------------------------------------------------------

spec :: Spec
spec = withTimeoutSecs 120 $ modifyMaxSuccess (const 100) $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-022#LAW-1" $
    it "拆解得開的名稱,依序拼回來就是原字串" $
      hedgehog $ do
        v <- forAll genVocab
        t <- forAll (genNameText v)
        let r = parseLogicalName v t
        cover 60 "parsed" (isRight r)
        case r of
          Left _ -> success
          Right parts -> renderParts parts === Right t

  describe "P-022#LAW-2" $
    it "拆得開又在詞彙表內的名稱,建回去是同一個邏輯名稱" $
      hedgehog $ do
        v <- forAll genVocab
        t <- forAll (genNameText v)
        let r = parseLogicalName v t
        cover 60 "parsed with known kind" $
          case r of
            Right parts -> npKind parts `elem` nvKinds v
            Left _ -> False
        case r of
          Left _ -> success
          Right parts
            | npKind parts `elem` nvKinds v ->
                mkLogicalName v parts === Right (LogicalName t)
            | otherwise -> success

  describe "P-022#LAW-3" $
    it "kind 是封閉的:不在 nvKinds 內一律拒絕" $
      hedgehog $ do
        v <- forAll genVocab
        k <- forAll (seg <$> Gen.element foreignKindPool)
        d <- forAll (seg <$> Gen.element domainPool)
        s <- forAll genSegment
        mvar <- forAll (Gen.maybe genSegment)
        mst <-
          forAll $
            Gen.choice
              [ pure Nothing
              , Just <$> Gen.element (nvStates v)
              , Just . seg <$> Gen.element foreignStatePool
              ]
        mix <- forAll (Gen.maybe (Gen.int (Range.linear 0 999)))
        let parts =
              NameParts
                { npKind = k
                , npDomain = d
                , npSubject = s
                , npVariant = mvar
                , npState = mst
                , npIndex = mix
                }
        mkLogicalName v parts
          === Left (UnknownKindPrefix (segmentText (npKind parts)))

  describe "P-022#LAW-4" $
    it "state 也是封閉的:手工建構的 state 不在 nvStates 內一律拒絕" $
      hedgehog $ do
        v <- forAll genVocab
        parts0 <- forAll (genPartsInVocab v)
        st <- forAll (seg <$> Gen.element foreignStatePool)
        let parts = parts0 {npState = Just st}
        mkLogicalName v parts === Left (UnknownState (segmentText st))

  describe "P-022#LAW-5" $
    it "拼出來超過上限的組合一律拒絕,錯誤帶得出實際長度" $
      hedgehog $ do
        v <- forAll genVocab
        k <- forAll (Gen.element (nvKinds v))
        d <- forAll (seg <$> Gen.element domainPool)
        n <- forAll (Gen.int (Range.linear 60 90))
        s <- forAll (seg <$> Gen.text (Range.singleton n) genSegChar)
        mvar <- forAll (Gen.maybe genSegment)
        mix <- forAll (Gen.maybe (Gen.int (Range.linear 0 999)))
        let parts =
              NameParts
                { npKind = k
                , npDomain = d
                , npSubject = s
                , npVariant = mvar
                , npState = Nothing
                , npIndex = mix
                }
        let rendered = renderParts parts
        cover 80 "rendered and overlong" $
          case rendered of
            Right txt -> T.length txt > maxLogicalNameLength
            Left _ -> False
        case rendered of
          Left _ -> success
          Right txt
            | T.length txt > maxLogicalNameLength ->
                mkLogicalName v parts === Left (TooLong (T.length txt) txt)
            | otherwise -> success

  describe "P-022#LAW-6" $
    it "超過上限的輸入拆不出部位" $
      hedgehog $ do
        v <- forAll genVocab
        t <- forAll (genOverlongText v)
        assert (T.length t > maxLogicalNameLength)
        assert (isLeft (parseLogicalName v t))

  describe "P-022#LAW-7" $
    it "任何文字丟給 parseLogicalName 都有值,不拋例外" $
      hedgehog $ do
        v <- forAll genVocab
        t <- forAll (genAnyText v)
        -- 求值到正規形:show 會走遍整個結構的每一個欄位。
        r <-
          liftIO
            ( try (evaluate (length (show (parseLogicalName v t))))
                :: IO (Either SomeException Int)
            )
        case r of
          Right _ -> success
          Left e -> do
            annotate (show e)
            failure

  describe "P-022#LAW-8" $
    it "主體不會被當成 state 剝掉,即使它剛好是一個 state 詞" $
      hedgehog $ do
        v <- forAll genVocab
        k <- forAll (Gen.element (nvKinds v))
        d <- forAll (seg <$> Gen.element domainPool)
        s <-
          forAll $
            Gen.choice [seg <$> Gen.element statePool, genSegment]
        let parts =
              NameParts
                { npKind = k
                , npDomain = d
                , npSubject = s
                , npVariant = Nothing
                , npState = Nothing
                , npIndex = Nothing
                }
        case renderParts parts of
          Left _ -> do
            cover 60 "rendered and parsed" False
            success
          Right t -> do
            let r2 = parseLogicalName v t
            cover 60 "rendered and parsed" (isRight r2)
            case r2 of
              Left _ -> success
              Right p2 -> npSubject p2 === npSubject parts

  describe "P-022#LAW-9" $
    it "validateLogicalName 不看 TypeKey:型別專屬的檢查不在這裡" $
      hedgehog $ do
        v <- forAll genVocab
        k1 <- forAll genTypeKey
        k2 <- forAll genTypeKey
        nm <- forAll (genLogicalNameFor v)
        validateLogicalName v k1 nm === validateLogicalName v k2 nm

  describe "P-022#LAW-10" $
    it "segmentText 是 mkSegment 的左逆函式" $
      hedgehog $ do
        t <-
          forAll $
            Gen.frequency
              [ (3, genSegmentText)
              , (1, Gen.text (Range.linear 0 10) (Gen.element (segChars ++ "_-. ABZ")))
              , (1, Gen.text (Range.linear 0 6) Gen.unicode)
              ]
        let r = mkSegment t
        cover 40 "valid segment" (isRight r)
        cover 10 "rejected" (isLeft r)
        case r of
          Left _ -> success
          Right s -> segmentText s === t

  describe "P-022#LAW-11" $
    it "序號的定義域恰好是 0 到 999" $
      hedgehog $ do
        n <-
          forAll $
            Gen.choice
              [ Gen.int (Range.linear 0 999)
              , Gen.int (Range.linear 1000 5000)
              , Gen.int (Range.linear (-5000) (-1))
              ]
        cover 20 "in range" (n >= 0 && n <= 999)
        cover 20 "out of range" (n < 0 || n > 999)
        isRight (indexSegment n) === (n >= 0 && n <= 999)

  describe "P-022#LAW-12" $
    it "indexSegment 產出的分段一定長得像序號" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 0 999))
        case indexSegment n of
          Left _ -> success
          Right s -> assert (isIndexShaped (segmentText s))

genTypeKey :: Gen TypeKey
genTypeKey =
  TypeKey
    <$> Gen.element
      ["asset-image", "asset-audio", "character-fragment", "level", "asset-pack"]

genLogicalNameFor :: NamingVocab -> Gen LogicalName
genLogicalNameFor v =
  LogicalName
    <$> Gen.frequency
      [ (3, genNameText v)
      , (1, Gen.text (Range.linear 0 16) (Gen.element (segChars ++ "_-. ABZ")))
      , (1, Gen.text (Range.linear 0 8) Gen.unicode)
      ]

--------------------------------------------------------------------------------
-- Examples

-- | Examples 用的固定詞彙表。
vocab :: NamingVocab
vocab =
  NamingVocab
    { nvKinds = map seg kindPool
    , nvDomains = map seg domainPool
    , nvStates = map seg statePool
    }

examples :: Spec
examples = do
  describe "P-022#EX-1" $
    it "ui_gui_travel-book-frame_001" $
      case parseLogicalName vocab "ui_gui_travel-book-frame_001" of
        Left e -> expectationFailure (show e)
        Right p -> do
          segmentText (npSubject p) `shouldBe` "travel-book-frame"
          npVariant p `shouldBe` Nothing
          npState p `shouldBe` Nothing
          npIndex p `shouldBe` Just 1
          renderParts p `shouldBe` Right "ui_gui_travel-book-frame_001"

  describe "P-022#EX-2" $
    it "spr_char_hero_attack-01_up" $
      case parseLogicalName vocab "spr_char_hero_attack-01_up" of
        Left e -> expectationFailure (show e)
        Right p -> do
          fmap segmentText (npVariant p) `shouldBe` Just "attack-01"
          fmap segmentText (npState p) `shouldBe` Just "up"
          npIndex p `shouldBe` Nothing
          mkLogicalName vocab p
            `shouldBe` Right (LogicalName "spr_char_hero_attack-01_up")

  describe "P-022#EX-3" $
    it "spr_char_up:單段主體剛好撞上 state 詞" $
      case parseLogicalName vocab "spr_char_up" of
        Left e -> expectationFailure (show e)
        Right p -> do
          segmentText (npSubject p) `shouldBe` "up"
          npState p `shouldBe` Nothing

  describe "P-022#EX-4" $
    it "ui_gui_holo-book-alert_01a_000:序號的下界" $
      case parseLogicalName vocab "ui_gui_holo-book-alert_01a_000" of
        Left e -> expectationFailure (show e)
        Right p -> do
          fmap segmentText (npVariant p) `shouldBe` Just "01a"
          npIndex p `shouldBe` Just 0
          renderParts p `shouldBe` Right "ui_gui_holo-book-alert_01a_000"

  describe "P-022#EX-5" $
    it "tex_ground_tileset-grass:剛好三段" $
      case parseLogicalName vocab "tex_ground_tileset-grass" of
        Left e -> expectationFailure (show e)
        Right p -> do
          segmentText (npSubject p) `shouldBe` "tileset-grass"
          npVariant p `shouldBe` Nothing
          npState p `shouldBe` Nothing
          npIndex p `shouldBe` Nothing

  describe "P-022#EX-6" $
    it "ui_gui" $
      parseLogicalName vocab "ui_gui"
        `shouldBe` Left (TooFewSegments 2 "ui_gui")

  describe "P-022#EX-7" $
    it "福岡廟宇:不自作主張音譯" $
      parseLogicalName vocab "福岡廟宇"
        `shouldBe` Left (NoAsciiContent "福岡廟宇")

  describe "P-022#EX-8" $
    it "65 個 a 是 Left;64 個 a 的錯誤不是 TooLong" $ do
      parseLogicalName vocab (T.replicate 65 "a") `shouldSatisfy` isLeft
      parseLogicalName vocab (T.replicate 64 "a") `shouldSatisfy` isLeft
      parseLogicalName vocab (T.replicate 64 "a")
        `shouldSatisfy` (not . isTooLongErr)

  describe "P-022#EX-9" $
    it "空分段、大寫、空白" $ do
      parseLogicalName vocab "ui__gui_frame" `shouldBe` Left EmptySegment
      parseLogicalName vocab "UI_GUI_Travel-Book-Frame"
        `shouldSatisfy` isBadSegmentErr
      parseLogicalName vocab "ui_gui_travel book frame"
        `shouldSatisfy` isBadSegmentErr

  describe "P-022#EX-10" $
    it "mkSegment 的四個輸入" $ do
      fmap segmentText (mkSegment "travel-book-frame")
        `shouldBe` Right "travel-book-frame"
      mkSegment "" `shouldBe` Left EmptySegment
      mkSegment "-foo" `shouldBe` Left (BadSegment "-foo")
      mkSegment "foo--bar" `shouldBe` Left (BadSegment "foo--bar")

  describe "P-022#EX-11" $
    it "npKind 為 zzz" $
      mkLogicalName
        vocab
        NameParts
          { npKind = seg "zzz"
          , npDomain = seg "gui"
          , npSubject = seg "frame"
          , npVariant = Nothing
          , npState = Nothing
          , npIndex = Nothing
          }
        `shouldBe` Left (UnknownKindPrefix "zzz")

  describe "P-022#EX-12" $
    it "npKind 為 spr、npState 為 Just zzz / Just up" $ do
      let parts st =
            NameParts
              { npKind = seg "spr"
              , npDomain = seg "char"
              , npSubject = seg "hero"
              , npVariant = Nothing
              , npState = Just (seg st)
              , npIndex = Nothing
              }
      mkLogicalName vocab (parts "zzz") `shouldBe` Left (UnknownState "zzz")
      mkLogicalName vocab (parts "up")
        `shouldBe` Right (LogicalName "spr_char_hero_up")

  describe "P-022#EX-13" $
    it "subject 為 61 個 a,拼出來 68 字元" $ do
      let parts =
            NameParts
              { npKind = seg "ui"
              , npDomain = seg "gui"
              , npSubject = seg (T.replicate 61 "a")
              , npVariant = Nothing
              , npState = Nothing
              , npIndex = Nothing
              }
      renderParts parts `shouldBe` Right ("ui_gui_" <> T.replicate 61 "a")
      mkLogicalName vocab parts
        `shouldBe` Left (TooLong 68 ("ui_gui_" <> T.replicate 61 "a"))

  describe "P-022#EX-14" $
    it "indexSegment 的四個輸入" $ do
      fmap segmentText (indexSegment 0) `shouldBe` Right "000"
      fmap segmentText (indexSegment 999) `shouldBe` Right "999"
      indexSegment 1000 `shouldBe` Left (IndexOutOfRange 1000)
      indexSegment (-1) `shouldBe` Left (IndexOutOfRange (-1))
      isIndexShaped "000" `shouldBe` True
      isIndexShaped "999" `shouldBe` True

  describe "P-022#EX-15" $
    it "validateLogicalName 換 TypeKey 結果逐字相同" $ do
      let nm = LogicalName "ui_gui_travel-book-frame_001"
      validateLogicalName vocab (TypeKey "asset-image") nm `shouldBe` Right ()
      validateLogicalName vocab (TypeKey "asset-audio") nm `shouldBe` Right ()
      validateLogicalName vocab (TypeKey "asset-image") nm
        `shouldBe` validateLogicalName vocab (TypeKey "asset-audio") nm
