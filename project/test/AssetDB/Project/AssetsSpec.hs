module AssetDB.Project.AssetsSpec (spec) where

import AssetDB.Project.Assets
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "haskellIdent" $ do
    it "邏輯名稱轉成 camelCase" $ do
      haskellIdent "ui_gui_travel-book-frame_01a" `shouldBe` "uiGuiTravelBookFrame01a"
      haskellIdent "spr_item_blue-potion_02" `shouldBe` "sprItemBluePotion02"

    it "開頭是數字時前置底線" $
      -- Haskell 識別字不能以數字開頭,而 00.png 這種檔名在素材庫裡真的存在。
      haskellIdent "00_x" `shouldBe` "_00X"

    it "空輸入不會產生非法識別字" $
      haskellIdent "" `shouldBe` "_unnamed"

  describe "renderAssetsModule" $ do
    let out = renderAssetsModule "Circle" [ref "ui_gui_a_01a" "assets/sprites/gui/a.png", ref "spr_item_b" "assets/sprites/items/b.png"]

    it "產生可編譯的模組標頭" $ do
      out `shouldSatisfy` T.isInfixOf "module Assets where"
      out `shouldSatisfy` T.isInfixOf "import AssetDB.Manifest (AssetKey (..))"

    it "每個素材一個常數,型別是 AssetKey" $ do
      out `shouldSatisfy` T.isInfixOf "uiGuiA01a :: AssetKey"
      out `shouldSatisfy` T.isInfixOf "uiGuiA01a = AssetKey \"ui_gui_a_01a\""

    it "標明為產生檔" $
      out `shouldSatisfy` T.isInfixOf "請勿手動編輯"

    it "識別字撞名時去重 —— 產生重複定義的模組根本編不過" $ do
      -- 命名文法保證邏輯名稱唯一,但不保證轉出的識別字唯一。
      let dup = renderAssetsModule "X" [ref "a_b_c" "p1", ref "a-b-c" "p2"]
      length (filter (T.isInfixOf ":: AssetKey") (T.lines dup)) `shouldBe` 1
  where
    ref k p = AssetRef k p Nothing
