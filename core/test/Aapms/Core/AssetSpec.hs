-- | graph-core/F001 STEP-5 的對照測試:Asset 型別與 Sha256 / LogicalName 具名純量。
module Aapms.Core.AssetSpec (spec) where

import Aapms.Core.Asset
import Aapms.Core.Fixtures
import Aapms.Core.Meta (metaTitle)
import Test.Hspec

spec :: Spec
spec = describe "Asset —— 全欄位建構與存取" $ do
  it "專屬欄位全部可存取" $ do
    astName sampleAsset `shouldBe` Just (LogicalName "ui_gui_travel-book-frame_001")
    astEntry sampleAsset `shouldBe` "ui/gui/travel-book-frame_001.png"
    astExt sampleAsset `shouldBe` Just "png"
    astLicense sampleAsset `shouldBe` Just (refOf "lic-9f8e7d6c")
    astAuthor sampleAsset `shouldBe` Just "Kenney"

  it "astMeta 是完整的 Meta,與其餘節點共用同一份型別" $
    metaTitle (astMeta sampleAsset) `shouldBe` "旅行手記畫框"

  it "Sha256 建構子可直接使用(委派決策記錄:具名純量建構子匯出)" $ do
    Sha256 "abc" `shouldBe` Sha256 "abc"
    astSha256 sampleAsset `shouldBe` Sha256 "deadbeefcafebabe0000000000000000000000000000000000000000000000"

  it "LogicalName 建構子可直接使用" $
    LogicalName "x" `shouldBe` LogicalName "x"
