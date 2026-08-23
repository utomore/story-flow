-- | 叢集推論的測試。
--
-- 輸入全部是真實素材庫裡實際存在的路徑。形狀的抽象層級是這個模組唯一
-- 需要調校的東西,而調校的依據只能是真實資料 —— 編造的檔名不會展現
-- 「Sprites 與 Sprites Animated 需要不同規則」這種結構。
module AssetDB.Ingest.ClusterSpec (spec) where

import AssetDB.Ingest.Cluster
import AssetDB.Naming (defaultVocab, logicalNameText, renderNameError)
import AssetDB.Types (KindPrefix (..))
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "fileShape" $ do
    let cases :: [(Text, Text)]
        cases =
          [ ("UI_TravelBook_Frame01a", "U_W_WNa")
          , ("UI_HoloBook_Alert02b", "U_W_WNa")
          , ("UI_TravelBook_Alert01a_1", "U_W_WNa_N")
          , ("ores-minerals13", "w_wN")
          , ("Blue Potion 2", "W_W_N")
          , ("00", "N")
          , ("idle_down", "w_w")
          , ("attack1_up", "wN_w")
          , ("TX Tileset Grass", "U_W_W")
          , ("#1 - Transparent Icons", "N_W_W")
          , ("rune_gold98", "w_wN")
          , ("", "")
          ]
    mapM_
      (\(i, o) -> it (T.unpack (i <> " → " <> o)) $ fileShape i `shouldBe` o)
      cases

    it "同一系列的不同成員形狀相同 —— 這就是分群能成立的前提" $ do
      let series = ["UI_TravelBook_Frame01a", "UI_HoloBook_Banner02b", "UI_TabletBook_Bar06c"]
      length (dedupe (map fileShape series)) `shouldBe` 1

    it "分隔符不影響形狀" $
      fileShape "idle_down" `shouldBe` fileShape "idle-down"

  describe "dirRole" $ do
    it "認得廠商的通用目錄慣例" $ do
      dirRole "Pack/01_TravelBook/Sprites/x.png" `shouldBe` RoleSprites
      dirRole "Pack/01_TravelBook/Sprites Animated/x.png" `shouldBe` RoleAnimated
      dirRole "Pack/01_TravelBook/Spritesheets/x.png" `shouldBe` RoleSheet
      dirRole "Pack/01_TravelBook/Aseprite/x.aseprite" `shouldBe` RoleSource
      dirRole "Pack/01_TravelBook/Preview/x.png" `shouldBe` RolePreview

    it "preview 優先於 sprites" $
      -- 誤把宣傳圖當素材的代價,比誤把素材當宣傳圖高。
      dirRole "Pack/Sprites/Preview/x.png" `shouldBe` RolePreview

    it "沒有可辨識的目錄時是 other" $ do
      dirRole "32x32/A/00.png" `shouldBe` RoleOther
      dirRole "x.png" `shouldBe` RoleOther

  describe "clusterBy" $ do
    it "同形狀同角色歸為一群" $ do
      let ps =
            [ "P/Sprites/UI_A_Frame01a.png"
            , "P/Sprites/UI_B_Alert02b.png"
            , "P/Preview/UI_A_Frame01a.png"
            ]
      map clCount (clusterBy ps) `shouldBe` [2, 1]

    it "副檔名不同就分開 —— aseprite 與 png 需要不同規則" $
      length (clusterBy ["P/Aseprite/Book.aseprite", "P/Aseprite/Book.png"]) `shouldBe` 2

    it "依數量遞減排序,大群先看" $ do
      let ps = ["a/x1.png", "a/x2.png", "a/x3.png", "b/Y_Z.png"]
      map clCount (clusterBy ps) `shouldBe` [3, 1]

  describe "applyRule" $ do
    -- 每一條都對應真實素材庫裡的一種命名風格。
    it "Crusenho:丟掉與 kind 重複的 UI 前綴" $
      run
        (rule PUi "gui") {nrDropTokens = [0]}
        "Pack/01_TravelBook/Sprites/UI_TravelBook_Frame01a.png"
        `shouldBe` Right "ui_gui_travel-book-frame_01a"

    it "Crusenho 動畫:尾端序號當格號" $
      run
        (rule PUi "gui") {nrDropTokens = [0], nrNumeric = NumIndex}
        "Pack/Sprites Animated/UI_TravelBook_Alert01a_3.png"
        `shouldBe` Right "ui_gui_travel-book-alert-01a_003"

    it "MattzArt:檔名裡沒有主體,由規則提供" $
      -- idle_down.png 是誰的 idle?那個資訊只存在於人的腦袋裡。
      run
        (rule PSpr "char") {nrSubject = Just "hero"}
        "Sprites/idle_down.png"
        `shouldBe` Right "spr_char_hero-idle_down"

    it "BDragon:純數字檔名,主體來自目錄" $
      -- 32x32/A/00.png … 32x32/K/11.png。不含目錄的話整群同名,
      -- 而 logical_name 是唯一的。
      run
        (rule PSpr "fx") {nrSubject = Just "impact", nrIncludeDirs = 1, nrNumeric = NumIndex}
        "32x32/A/00.png"
        `shouldBe` Right "spr_fx_a-impact_000"

    it "Kibyra:小寫加序號" $
      run
        (rule PSpr "item") {nrNumeric = NumVariant}
        "Books/Books/book10.png"
        `shouldBe` Right "spr_item_book_10"

    it "Cainos:空格分隔的 Title Case" $
      run (rule PTex "ground") "Sprites/TX Tileset Grass.png"
        `shouldBe` Right "tex_ground_tx-tileset-grass"

    it "三位數以上自動判為格號而非變體" $
      -- 兩位數的 variant 裝不下 100,不需要人來說。
      run (rule PFnt "rune") "runes/rune100.png"
        `shouldBe` Right "fnt_rune_rune_100"

    it "產生的名稱一律通過命名文法的驗證" $
      -- applyRule 走的是 mkLogicalName,所以不可能產生不合法的名稱。
      run (rule PSpr "item") "a/Blue Potion 2.png"
        `shouldBe` Right "spr_item_blue-potion_02"

    it "純中文檔名回報錯誤而不是產生垃圾" $
      run (rule PDoc "ref") "reference/金門建築.png"
        `shouldSatisfy` either (const True) (const False)

--------------------------------------------------------------------------------

rule :: KindPrefix -> Text -> NameRule
rule k d =
  NameRule
    { nrKind = k
    , nrDomain = d
    , nrSubject = Nothing
    , nrDropTokens = []
    , nrIncludeDirs = 0
    , nrNumeric = NumAuto
    , nrTags = []
    }

run :: NameRule -> Text -> Either Text Text
run r p =
  either (Left . renderNameError) (Right . logicalNameText) (applyRule defaultVocab r p)

dedupe :: Eq a => [a] -> [a]
dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
