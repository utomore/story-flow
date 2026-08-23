-- | 命名文法的測試。
--
-- 單元測試的輸入**全部取自真實素材庫**,不是編造的例子。
-- 每一條都對應到 @Game Assets itchio@ 底下實際存在的檔名風格。
module AssetDB.NamingSpec (spec) where

import AssetDB.Naming
import AssetDB.Types (KindPrefix (..), TextEnum (..))
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "splitCamel" $ do
    let cases :: [(Text, [Text])]
        cases =
          [ ("TravelBook", ["Travel", "Book"])
          , ("HoloBook", ["Holo", "Book"])
          , ("UI", ["UI"])
          , ("UIIcon", ["UI", "Icon"])
          , -- Cainos 的 "TX Player" / "TX Tileset Grass" 前綴
            ("TXPlayer", ["TX", "Player"])
          , ("potion", ["potion"])
          , ("", [])
          , -- 字母數字邊界刻意不切,那是 splitTrailingNumber 的職責
            ("Frame01a", ["Frame01a"])
          , ("Alert01a", ["Alert01a"])
          ]
    mapM_
      (\(input, expected) -> it (T.unpack ("切開 " <> tshow input)) $ splitCamel input `shouldBe` expected)
      cases

  describe "splitTrailingNumber" $ do
    let cases :: [(Text, (Text, Maybe Text))]
        cases =
          [ ("Frame01a", ("Frame", Just "01a"))
          , ("Alert02a", ("Alert", Just "02a"))
          , ("potion10", ("potion", Just "10"))
          , ("rune100", ("rune", Just "100"))
          , ("ores-minerals13", ("ores-minerals", Just "13"))
          , ("attack1", ("attack", Just "1"))
          , -- BDragon1727 的 FX 資料夾:檔名就是純數字
            ("00", ("", Just "00"))
          , ("grass", ("grass", Nothing))
          , -- 結尾字母前面不是數字,不算變體後綴
            ("Frames", ("Frames", Nothing))
          , ("", ("", Nothing))
          ]
    mapM_
      (\(input, expected) -> it (T.unpack ("剝離 " <> tshow input)) $ splitTrailingNumber input `shouldBe` expected)
      cases

  describe "normalizeSegment" $ do
    let ok :: [(Text, Text)]
        ok =
          [ ("Blue Potion", "blue-potion")
          , ("Green Potion 3", "green-potion-3")
          , ("Empty Bottle", "empty-bottle")
          , ("TravelBook", "travel-book")
          , ("TX Tileset Grass", "tx-tileset-grass")
          , ("TX Village Building - Barn 01", "tx-village-building-barn-01")
          , ("herbs&medicinal-plants", "herbs-medicinal-plants")
          , -- 撇號刪除而非變成分隔符:Shikashi's → shikashis,不是 shikashi-s
            ("Shikashi's", "shikashis")
          , ("Idylwild's Runic Codex", "idylwilds-runic-codex")
          , ("Lifon (work in progress)", "lifon-work-in-progress")
          , ("#1 - Transparent Icons", "1-transparent-icons")
          , ("[GUI] Pixel Art Icon Pack - Food", "gui-pixel-art-icon-pack-food")
          , ("Anpan", "anpan")
          , ("   ", "") -- 全空白 → 下面驗證會失敗
          ]
    mapM_
      ( \(input, expected) ->
          if T.null expected
            then it (T.unpack ("拒絕 " <> tshow input)) $ normalizeSegment input `shouldSatisfy` isLeft
            else
              it (T.unpack ("正規化 " <> tshow input)) $
                fmap segmentText (normalizeSegment input) `shouldBe` Right expected
      )
      ok

    it "純中文名稱回報 NoAsciiContent 而不是自作主張音譯" $ do
      normalizeSegment "福岡廟宇" `shouldBe` Left (NoAsciiContent "福岡廟宇")
      normalizeSegment "金門地道" `shouldBe` Left (NoAsciiContent "金門地道")

    it "中英混合只保留 ASCII 部分" $
      fmap segmentText (normalizeSegment "1990 年代文化風格") `shouldBe` Right "1990"

    it "輸出永遠通過 mkSegment 的驗證" $
      property $ \(s :: String) ->
        case normalizeSegment (T.pack s) of
          Left _ -> property True
          Right seg -> mkSegment (segmentText seg) === Right seg

  describe "數字部位的形狀互斥" $ do
    it "variant 是兩位數字加可選字母" $ do
      map isVariantShaped ["01", "02a", "99z"] `shouldBe` [True, True, True]
      map isVariantShaped ["1", "001", "0", "abc", "0ab", "01A"] `shouldBe` replicate 6 False

    it "index 剛好三位數字" $ do
      map isIndexShaped ["000", "100", "999"] `shouldBe` [True, True, True]
      map isIndexShaped ["01", "0001", "01a", "10a"] `shouldBe` replicate 4 False

    it "兩種形狀永不同時成立" $
      property $ \(s :: String) ->
        let t = T.pack s in not (isVariantShaped t && isIndexShaped t)

    it "variantFromNumber 補零到兩位,三位數拒絕" $ do
      fmap segmentText (variantFromNumber 1) `shouldBe` Just "01"
      fmap segmentText (variantFromNumber 42) `shouldBe` Just "42"
      variantFromNumber 100 `shouldBe` Nothing

    it "indexSegment 補零到三位" $ do
      fmap segmentText (indexSegment 0) `shouldBe` Right "000"
      fmap segmentText (indexSegment 7) `shouldBe` Right "007"
      indexSegment 1000 `shouldBe` Left (IndexOutOfRange 1000)

  describe "mkLogicalName / parseLogicalName" $ do
    it "組出計畫裡的實際目標名稱" $ do
      render (parts PUi "gui" "travel-book-frame" (Just "01a") Nothing Nothing)
        `shouldBe` Right "ui_gui_travel-book-frame_01a"
      render (parts PUi "gui" "holo-book-alert" (Just "01a") Nothing (Just 0))
        `shouldBe` Right "ui_gui_holo-book-alert_01a_000"
      render (parts PSpr "item" "blue-potion" (Just "02") Nothing Nothing)
        `shouldBe` Right "spr_item_blue-potion_02"
      render (parts PTex "ground" "tileset-grass" Nothing Nothing Nothing)
        `shouldBe` Right "tex_ground_tileset-grass"
      render (parts PSpr "char" "hero" (Just "attack-01") (Just "up") Nothing)
        `shouldBe` Right "spr_char_hero_attack-01_up"
      render (parts PFnt "rune" "runic-codex" Nothing Nothing (Just 100))
        `shouldBe` Right "fnt_rune_runic-codex_100"

    it "拆得回來" $ do
      let n = "ui_gui_holo-book-alert_01a_000"
      case parseLogicalName defaultVocab n of
        Left e -> expectationFailure (T.unpack (renderNameError e))
        Right p -> do
          npKind p `shouldBe` PUi
          segmentText (npDomain p) `shouldBe` "gui"
          segmentText (npSubject p) `shouldBe` "holo-book-alert"
          fmap segmentText (npVariant p) `shouldBe` Just "01a"
          npState p `shouldBe` Nothing
          npIndex p `shouldBe` Just 0

    it "缺項組合:有 state 沒 variant" $ do
      case parseLogicalName defaultVocab "spr_char_hero_up" of
        Right p -> do
          segmentText (npSubject p) `shouldBe` "hero"
          npVariant p `shouldBe` Nothing
          fmap segmentText (npState p) `shouldBe` Just "up"
        Left e -> expectationFailure (T.unpack (renderNameError e))

    it "缺項組合:有 variant 沒 state" $ do
      case parseLogicalName defaultVocab "spr_item_potion_blue" of
        Right p -> do
          segmentText (npSubject p) `shouldBe` "potion"
          fmap segmentText (npVariant p) `shouldBe` Just "blue"
          npState p `shouldBe` Nothing
        Left e -> expectationFailure (T.unpack (renderNameError e))

    it "主體含連字號時不會被誤拆" $
      -- blue-potion 是一整段,不該被當成 variant "blue" + 主體 "potion"
      fmap (fmap segmentText . Just . npSubject) (parseLogicalName defaultVocab "spr_item_blue-potion")
        `shouldBe` Right (Just "blue-potion")

  describe "拒絕不合法的名稱" $ do
    let bad =
          [ ("空字串", "")
          , ("段數不足", "spr_gui")
          , ("未知 kind 前綴", "xyz_gui_frame")
          , ("大寫", "UI_gui_frame")
          , ("空格", "ui gui frame")
          , ("連續底線", "ui__gui_frame")
          , ("結尾底線", "ui_gui_frame_")
          , ("連續連字號", "ui_gui_travel--book")
          , ("主體位置剩多段", "ui_gui_travel_book_frame")
          , ("超長", T.replicate 30 "ab" <> "_gui_x")
          ]
    mapM_
      (\(label, n) -> it label $ parseLogicalName defaultVocab n `shouldSatisfy` isLeft)
      bad

    it "主體長得像修飾詞時,建構就要擋下" $ do
      -- 若允許,spr_char_idle 會被解析成「有 state 沒 subject」
      render (parts PSpr "char" "idle" Nothing Nothing Nothing)
        `shouldBe` Left (SubjectLooksLikeModifier "idle")
      render (parts PSpr "gui" "01a" Nothing Nothing Nothing)
        `shouldBe` Left (SubjectLooksLikeModifier "01a")
      render (parts PSpr "gui" "000" Nothing Nothing Nothing)
        `shouldBe` Left (SubjectLooksLikeModifier "000")
      render (parts PSpr "item" "blue" Nothing Nothing Nothing)
        `shouldBe` Left (SubjectLooksLikeModifier "blue")

  describe "round-trip 性質" $ do
    it "任何 mkLogicalName 接受的組合都解析得回原樣" $
      property $
        forAll genParts $ \p ->
          case mkLogicalName defaultVocab p of
            Left _ -> property Discard
            Right ln ->
              counterexample (T.unpack (logicalNameText ln)) $
                parseLogicalName defaultVocab (logicalNameText ln) === Right p

    it "validateLogicalName 接受所有自己產生的名稱" $
      property $
        forAll genParts $ \p ->
          case mkLogicalName defaultVocab p of
            Left _ -> property Discard
            Right ln ->
              property (either (const False) (const True) (validateLogicalName (logicalNameText ln)))

--------------------------------------------------------------------------------
-- 輔助

parts :: KindPrefix -> Text -> Text -> Maybe Text -> Maybe Text -> Maybe Int -> Either NameError NameParts
parts k d s v st ix = do
  d' <- mkSegment d
  s' <- mkSegment s
  v' <- traverse mkSegment v
  st' <- traverse mkSegment st
  Right (NameParts k d' s' v' st' ix)

render :: Either NameError NameParts -> Either NameError Text
render ep = do
  p <- ep
  logicalNameText <$> mkLogicalName defaultVocab p

tshow :: Show a => a -> Text
tshow = T.pack . show

--------------------------------------------------------------------------------
-- 產生器

genSegment :: Gen Segment
genSegment = do
  nParts <- choose (1, 2 :: Int)
  ps <- vectorOf nParts genPart
  case mkSegment (T.intercalate "-" ps) of
    Right s -> pure s
    Left _ -> genSegment
  where
    genPart = T.pack <$> (choose (1, 6) >>= \n -> vectorOf n (elements segChars))
    segChars = ['a' .. 'z'] <> ['0' .. '9']

-- 主體不可佔用修飾詞的形狀,否則 mkLogicalName 會(正確地)拒絕,
-- 性質測試就永遠走 Discard 分支,什麼也沒測到。
genSubject :: Gen Segment
genSubject = genSegment `suchThat` (not . modifierLike . segmentText)

modifierLike :: Text -> Bool
modifierLike t =
  isVariantShaped t
    || isIndexShaped t
    || Set.member t (nvStates defaultVocab)
    || Set.member t (nvVariants defaultVocab)

genVariant :: Gen Segment
genVariant =
  oneof
    [ elements (mapMaybeSeg (Set.toList (nvVariants defaultVocab)))
    , do
        n <- choose (0, 99 :: Int)
        maybe genVariant pure (variantFromNumber n)
    ]

genState :: Gen Segment
genState = elements (mapMaybeSeg (Set.toList (nvStates defaultVocab)))

mapMaybeSeg :: [Text] -> [Segment]
mapMaybeSeg = foldr (\t acc -> either (const acc) (: acc) (mkSegment t)) []

genParts :: Gen NameParts
genParts =
  NameParts
    <$> arbitraryBoundedEnum
    <*> genSegment
    <*> genSubject
    <*> liftArbitrary genVariant
    <*> liftArbitrary genState
    <*> liftArbitrary (choose (0, 999))
