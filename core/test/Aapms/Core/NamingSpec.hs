-- | graph-core/F002 STEP-1(Segment / NameParts 形狀)與 STEP-9(「由右往左剝、只查
-- nvStates」的 'parseLogicalName' 演算法、'mkLogicalName' 的 'nvKinds' /
-- 'nvStates' 檢查、'renderParts')的對照測試。
module Aapms.Core.NamingSpec (spec) where

import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Naming
import Data.Either (isLeft, isRight, rights)
import qualified Data.Text as T
import Test.Hspec

-- | 對照 @types/registry/naming.toml@:12 個 kind、空 domains、37 個 state。
vocab :: NamingVocab
vocab =
  NamingVocab
    { nvKinds =
        rights (map mkSegment ["spr", "tex", "atlas", "ui", "fnt", "sfx", "bgm", "vo", "lvl", "shd", "src", "doc"])
    , nvDomains = []
    , nvStates =
        rights
          ( map
              mkSegment
              [ "idle", "hover", "pressed", "disabled", "active", "selected", "focus"
              , "open", "closed", "empty", "full", "on", "off"
              , "walk", "run", "attack", "dash", "death", "hurt", "cast"
              , "up", "down", "left", "right", "front", "back", "north", "south", "east", "west"
              , "day", "night", "dawn", "dusk", "intro", "loop", "outro"
              ]
          )
    }

-- | 7 個合法案例,逐字取自 @contract/fixtures/naming-cases.txt@(STEP-10 對同一份
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
  describe "STEP-1 test_segment_and_nameparts_shape" $ do
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

    it "NameParts 可以直接建構與逐欄存取,npVariant / npState 是獨立欄位" $ do
      let Right k = mkSegment "spr"
          Right d = mkSegment "char"
          Right s = mkSegment "hero"
          parts =
            NameParts
              { npKind = k
              , npDomain = d
              , npSubject = s
              , npVariant = Nothing
              , npState = Nothing
              , npIndex = Nothing
              }
      npKind parts `shouldBe` k
      npDomain parts `shouldBe` d
      npSubject parts `shouldBe` s
      npVariant parts `shouldBe` Nothing
      npState parts `shouldBe` Nothing
      npIndex parts `shouldBe` Nothing

  describe "STEP-9 test_parselogicalname_vocab_driven" $ do
    it "三段(無 variant/state、無序號)正確拆解" $
      case parseLogicalName vocab "tex_ground_tileset-grass" of
        Right p -> do
          segmentText (npKind p) `shouldBe` "tex"
          segmentText (npDomain p) `shouldBe` "ground"
          segmentText (npSubject p) `shouldBe` "tileset-grass"
          npVariant p `shouldBe` Nothing
          npState p `shouldBe` Nothing
          npIndex p `shouldBe` Nothing
        Left e -> expectationFailure (show e)

    it "尾段剛好三位數字被剝成 npIndex" $
      case parseLogicalName vocab "ui_gui_travel-book-frame_001" of
        Right p -> do
          npIndex p `shouldBe` Just 1
          npVariant p `shouldBe` Nothing
          npState p `shouldBe` Nothing
        Left e -> expectationFailure (show e)

    it "候選段落不在 nvStates 內時落回 npVariant(開放,不查表)" $
      case parseLogicalName vocab "ui_gui_travel-book-frame_01a" of
        Right p -> do
          fmap segmentText (npVariant p) `shouldBe` Just "01a"
          npState p `shouldBe` Nothing
        Left e -> expectationFailure (show e)

    it "spr_char_hero_attack-01_up 拆出 npVariant = attack-01、npState = up" $
      case parseLogicalName vocab "spr_char_hero_attack-01_up" of
        Right p -> do
          fmap segmentText (npVariant p) `shouldBe` Just "attack-01"
          fmap segmentText (npState p) `shouldBe` Just "up"
          npIndex p `shouldBe` Nothing
        Left e -> expectationFailure (show e)

    it "variant/state/index 同時出現時順序不亂" $
      -- fnt_rune_runic-codex 的 subject 就是 runic-codex,加一個 state 詞
      -- 與一個三位數序號,確認三者能同時解析且互不干擾。
      case parseLogicalName vocab "fnt_rune_runic-codex_hurt_000" of
        Right p -> do
          fmap segmentText (npVariant p) `shouldBe` Nothing
          fmap segmentText (npState p) `shouldBe` Just "hurt"
          npIndex p `shouldBe` Just 0
        Left e -> expectationFailure (show e)

    it "ASM-4 guard:單段 subject 剛好是 state 詞時不誤判成 TooFewSegments" $
      case parseLogicalName vocab "spr_char_up" of
        Right p -> do
          segmentText (npSubject p) `shouldBe` "up"
          npState p `shouldBe` Nothing
          npVariant p `shouldBe` Nothing
        Left e -> expectationFailure (show e)

    it "3 段以上非 index 尾段回 AmbiguousTrailing" $
      case parseLogicalName vocab "a_b_c_d_e_f" of
        Left (AmbiguousTrailing _ _) -> pure ()
        other -> expectationFailure ("預期 AmbiguousTrailing,卻得到:" <> show other)

    it "少於三段回 TooFewSegments" $
      case parseLogicalName vocab "ui_gui" of
        Left (TooFewSegments 2 _) -> pure ()
        other -> expectationFailure ("預期 TooFewSegments,卻得到:" <> show other)

    it "非 ASCII 回 NoAsciiContent" $
      case parseLogicalName vocab "福岡廟宇" of
        Left (NoAsciiContent _) -> pure ()
        other -> expectationFailure ("預期 NoAsciiContent,卻得到:" <> show other)

    it "超過 64 字元回 TooLong" $
      case parseLogicalName vocab (T.replicate 70 "a") of
        Left (TooLong _ _) -> pure ()
        other -> expectationFailure ("預期 TooLong,卻得到:" <> show other)

    it "空段(連續底線)回 EmptySegment" $
      case parseLogicalName vocab "ui__gui_frame" of
        Left EmptySegment -> pure ()
        other -> expectationFailure ("預期 EmptySegment,卻得到:" <> show other)

    it "renderParts . parseLogicalName == id(限定合法輸入)" $
      mapM_
        ( \name -> case parseLogicalName vocab name of
            Right parts -> renderParts parts `shouldBe` Right name
            Left e -> expectationFailure (T.unpack name <> ": " <> show e)
        )
        okNames

    it "mkLogicalName:kind 在 nvKinds 內時成功" $
      case parseLogicalName vocab "spr_char_hero" of
        Right parts -> mkLogicalName vocab parts `shouldSatisfy` isRight
        Left e -> expectationFailure (show e)

    it "mkLogicalName:kind 不在 nvKinds 內時回 UnknownKindPrefix" $ do
      let Right kind = mkSegment "zzz"
          Right dom = mkSegment "char"
          Right subj = mkSegment "hero"
          parts = NameParts kind dom subj Nothing Nothing Nothing
      mkLogicalName vocab parts `shouldBe` Left (UnknownKindPrefix "zzz")

    it "mkLogicalName:手工建構的 npState 不在 nvStates 內時回 UnknownState" $ do
      let Right kind = mkSegment "spr"
          Right dom = mkSegment "char"
          Right subj = mkSegment "hero"
          Right st = mkSegment "zzz"
          parts = NameParts kind dom subj Nothing (Just st) Nothing
      mkLogicalName vocab parts `shouldBe` Left (UnknownState "zzz")

    it "mkLogicalName:npState 在 nvStates 內時成功" $ do
      let Right kind = mkSegment "spr"
          Right dom = mkSegment "char"
          Right subj = mkSegment "hero"
          Right st = mkSegment "up"
          parts = NameParts kind dom subj Nothing (Just st) Nothing
      mkLogicalName vocab parts `shouldSatisfy` isRight

  describe "renderParts" $
    it "依序拼回 kind_domain_subject + variant + state + index(補零到三位)" $ do
      let Right kind = mkSegment "spr"
          Right dom = mkSegment "char"
          Right subj = mkSegment "hero"
          Right var = mkSegment "attack-01"
          Right st = mkSegment "up"
          parts = NameParts kind dom subj (Just var) (Just st) (Just 7)
      renderParts parts `shouldBe` Right "spr_char_hero_attack-01_up_007"

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
