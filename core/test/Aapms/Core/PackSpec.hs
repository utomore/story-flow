-- | graph-core/F001 STEP-6 的對照測試:Pack 型別、AiDisclosure 與 Author。
module Aapms.Core.PackSpec (spec) where

import Aapms.Core.Fixtures
import Aapms.Core.Pack
import Test.Hspec

spec :: Spec
spec = describe "Pack —— 全欄位建構" $ do
  it "專屬欄位全部可存取" $ do
    pckVendor samplePack `shouldBe` Just "Kenney"
    pckArchive samplePack `shouldBe` Just "packs/kenney/ui-pack.zip"
    pckSourceUrl samplePack `shouldBe` Just "https://kenney.nl/assets/ui-pack"
    pckLicense samplePack `shouldBe` Just (refOf "lic-9f8e7d6c")

  it "AiDisclosure 四值可用" $ do
    pckAiDisclosure samplePack `shouldBe` AiNone
    [minBound .. maxBound :: AiDisclosure]
      `shouldBe` [AiUnknown, AiNone, AiAssisted, AiGenerated]

  it "Author 三欄位可建構與讀取" $ do
    let a = Author "Kenney" (Just "https://kenney.nl") Nothing
    authorName a `shouldBe` "Kenney"
    authorUrl a `shouldBe` Just "https://kenney.nl"
    authorContact a `shouldBe` Nothing
    pckAuthor samplePack `shouldBe` Just a

  it "pckArchive = Nothing 表示散檔目錄" $
    pckArchive (samplePack {pckArchive = Nothing}) `shouldBe` Nothing
