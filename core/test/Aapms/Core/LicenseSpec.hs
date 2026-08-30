-- | graph-core/F001 STEP-7 的對照測試:License 型別的 9 個專屬欄位。
module Aapms.Core.LicenseSpec (spec) where

import Aapms.Core.Fixtures
import Aapms.Core.License
import Test.Hspec

spec :: Spec
spec = describe "License —— 9 個欄位(不含 licMeta)全部可建構與讀取" $
  it "全欄位可存取" $ do
    licCommercial sampleLicense `shouldBe` True
    licAttributionRequired sampleLicense `shouldBe` False
    licCreditText sampleLicense `shouldBe` Nothing
    licModificationAllowed sampleLicense `shouldBe` Just True
    licRedistributionAllowed sampleLicense `shouldBe` Just True
    licResaleAllowed sampleLicense `shouldBe` Just False
    licNftAllowed sampleLicense `shouldBe` Just False
    licSourceUrl sampleLicense
      `shouldBe` Just "https://creativecommons.org/publicdomain/zero/1.0/"
    licFullText sampleLicense `shouldBe` Nothing
