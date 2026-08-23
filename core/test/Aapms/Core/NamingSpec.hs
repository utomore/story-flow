-- | graph-core/F002 T1(Segment / NameParts 形狀)與 T9(位置式
-- 'parseLogicalName' 演算法、'mkLogicalName' 的 'nvKinds' 檢查、'renderParts')
-- 的對照測試。
module Aapms.Core.NamingSpec (spec) where

import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Naming
import Data.Either (isLeft, isRight, rights)
import qualified Data.Text as T
import Test.Hspec

-- | 對照 @types/registry/naming.toml@ 的 12 個 kind,@domains@ 留空。
vocab :: NamingVocab
vocab =
  NamingVocab
    { nvKinds =
        rights (map mkSegment ["spr", "tex", "atlas", "ui", "fnt", "sfx", "bgm", "vo", "lvl", "shd", "src", "doc"])
    , nvDomains = []
    }

-- | 7 個合法案例,逐字取自 @contract/fixtures/naming-cases.txt@(T10 對同一份
-- fixture 做逐行驗證;這裡只是拿它們當 'renderParts' 往返測試的固定樣本)。
okNames :: [T.Text]
okNames =
  [ "ui_gui_travel-book-frame_001"
  , "ui_gui_travel-book-frame_01a"
  , "ui_gui_holo-book-alert_01a_000"
  , "spr_item_blue-potion_02"
  , "tex_ground_tileset-grass"
  , "spr_char_hero_attack-01_up"
  , "fnt_rune_runic-codex_100"
  ]

spec :: Spec
spec = do
  describe "T1 test_segment_and_nameparts_shape" $ do
    it "mkSegment 接受小寫英數字與連字號連接的分段" $
      mkSegment "travel-book-frame" `shouldSatisfy` isRight

    it "mkSegment 拒絕空字串" $
      mkSegment "" `shouldBe` Left EmptySegment

    it "mkSegment 拒絕大寫" $
      mkSegment "Foo" `shouldSatisfy` isLeft

    it "mkSegment 拒絕開頭、結尾、連續的連字號" $ do
      mkSegment "-foo" `shouldSatisfy` isLeft
      mkSegment "foo-" `shouldSatisfy` isLeft
      mkSegment "foo--bar" `shouldSatisfy` isLeft

    it "segmentText 是 mkSegment 的左逆函式" $
      case mkSegment "blue-potion" of
        Right s -> segmentText s `shouldBe` "blue-potion"
        Left e -> expectationFailure (show e)

    it "NameParts 可以直接建構與逐欄存取" $ do
      let Right k = mkSegment "spr"
          Right d = mkSegment "char"
          Right s = mkSegment "hero"
          parts = NameParts {npKind = k, npDomain = d, npSubject = s, npModifiers = [], npIndex = Nothing}
      npKind parts `shouldBe` k
      npDomain parts `shouldBe` d
      npSubject parts `shouldBe` s
      npModifiers parts `shouldBe` []
      npIndex parts `shouldBe` Nothing

  describe "T9 test_parselogicalname_positional" $ do
    it "三段(無修飾詞、無序號)正確拆解" $
      case parseLogicalName "tex_ground_tileset-grass" of
        Right p -> do
          segmentText (npKind p) `shouldBe` "tex"
          segmentText (npDomain p) `shouldBe` "ground"
          segmentText (npSubject p) `shouldBe` "tileset-grass"
          npModifiers p `shouldBe` []
          npIndex p `shouldBe` Nothing
        Left e -> expectationFailure (show e)

    it "尾段剛好三位數字被剝成 npIndex" $
      case parseLogicalName "ui_gui_travel-book-frame_001" of
        Right p -> do
          npIndex p `shouldBe` Just 1
          npModifiers p `shouldBe` []
        Left e -> expectationFailure (show e)

    it "1 個修飾詞(長得像 variant,但不再語意標記)被保留" $
      case parseLogicalName "ui_gui_travel-book-frame_01a" of
        Right p -> map segmentText (npModifiers p) `shouldBe` ["01a"]
        Left e -> expectationFailure (show e)

    it "2 個修飾詞依原始順序保留(legacy 演算法會誤拒的案例,新演算法接受)" $
      case parseLogicalName "spr_char_hero_attack-01_up" of
        Right p -> do
          map segmentText (npModifiers p) `shouldBe` ["attack-01", "up"]
          npIndex p `shouldBe` Nothing
        Left e -> expectationFailure (show e)

    it "修飾詞與序號同時出現時順序不亂" $
      case parseLogicalName "ui_gui_holo-book-alert_01a_000" of
        Right p -> do
          map segmentText (npModifiers p) `shouldBe` ["01a"]
          npIndex p `shouldBe` Just 0
        Left e -> expectationFailure (show e)

    it "超過 2 個修飾詞回 AmbiguousTrailing" $
      case parseLogicalName "a_b_c_d_e_f" of
        Left (AmbiguousTrailing _ _) -> pure ()
        other -> expectationFailure ("預期 AmbiguousTrailing,卻得到:" <> show other)

    it "少於三段回 TooFewSegments" $
      case parseLogicalName "ui_gui" of
        Left (TooFewSegments 2 _) -> pure ()
        other -> expectationFailure ("預期 TooFewSegments,卻得到:" <> show other)

    it "非 ASCII 回 NoAsciiContent" $
      case parseLogicalName "福岡廟宇" of
        Left (NoAsciiContent _) -> pure ()
        other -> expectationFailure ("預期 NoAsciiContent,卻得到:" <> show other)

    it "超過 64 字元回 TooLong" $
      case parseLogicalName (T.replicate 70 "a") of
        Left (TooLong _ _) -> pure ()
        other -> expectationFailure ("預期 TooLong,卻得到:" <> show other)

    it "空段(連續底線)回 EmptySegment" $
      case parseLogicalName "ui__gui_frame" of
        Left EmptySegment -> pure ()
        other -> expectationFailure ("預期 EmptySegment,卻得到:" <> show other)

    it "renderParts . parseLogicalName == id(限定合法輸入)" $
      mapM_
        ( \name -> case parseLogicalName name of
            Right parts -> renderParts parts `shouldBe` Right name
            Left e -> expectationFailure (T.unpack name <> ": " <> show e)
        )
        okNames

    it "mkLogicalName:kind 在 nvKinds 內時成功" $
      case parseLogicalName "spr_char_hero" of
        Right parts -> mkLogicalName vocab parts `shouldSatisfy` isRight
        Left e -> expectationFailure (show e)

    it "mkLogicalName:kind 不在 nvKinds 內時回 UnknownKindPrefix" $ do
      let Right kind = mkSegment "zzz"
          Right dom = mkSegment "char"
          Right subj = mkSegment "hero"
          parts = NameParts kind dom subj [] Nothing
      mkLogicalName vocab parts `shouldBe` Left (UnknownKindPrefix "zzz")

  describe "renderParts" $
    it "依序拼回 kind_domain_subject + modifiers + index(補零到三位)" $ do
      let Right kind = mkSegment "spr"
          Right dom = mkSegment "char"
          Right subj = mkSegment "hero"
          Right m1 = mkSegment "attack-01"
          parts = NameParts kind dom subj [m1] (Just 7)
      renderParts parts `shouldBe` Right "spr_char_hero_attack-01_007"

  describe "validateLogicalName(契約卡驗收標準 5)" $ do
    it "對 ui_gui_travel-book-frame_001 通過" $
      validateLogicalName vocab (TypeKey "asset-image") (LogicalName "ui_gui_travel-book-frame_001")
        `shouldBe` Right ()

    it "對非 ASCII 拒絕" $
      validateLogicalName vocab (TypeKey "asset-image") (LogicalName "福岡廟宇")
        `shouldSatisfy` isLeft

    it "對超過 64 字元拒絕" $
      validateLogicalName vocab (TypeKey "asset-image") (LogicalName (T.replicate 70 "a"))
        `shouldSatisfy` isLeft

    it "對少於三段拒絕" $
      validateLogicalName vocab (TypeKey "asset-image") (LogicalName "ui_gui")
        `shouldSatisfy` isLeft
