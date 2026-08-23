-- | T10:'toLicenses' —— licenses.md 的檔案層是容器不是節點,每節一個
-- 'License',八個維度中 @commercial@ / @attribution_required@ 必填、其餘六個
-- 缺漏是 'Nothing'(graph-core/F004)。
module Aapms.Md.ParseLicenseSpec (spec) where

import qualified Data.Text as T
import Aapms.Core.License
import Aapms.Core.Meta (metaType)
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

doc :: Document
doc = docOf licensesMd

licenses :: [License]
licenses = licensesOf doc

licAt :: Int -> License
licAt = (licenses !!)

spec :: Spec
spec = do
  describe "檔案的判別" $
    it "type: asset-license 判為 LicenseDoc" $
      docKind doc `shouldBe` LicenseDoc

  describe "容器本身不出現在回傳的 [License] 裡" $
    it "得 2 筆 License(檔案層只是容器,不是第 3 筆)" $
      length licenses `shouldBe` 2

  describe "CC0(lic-0000000a,只寫兩個必填維度)" $ do
    it "commercial / attribution_required 逐值正確" $ do
      licCommercial (licAt 0) `shouldBe` True
      licAttributionRequired (licAt 0) `shouldBe` False

    it "其餘六維缺漏是 Nothing" $ do
      licCreditText (licAt 0) `shouldBe` Nothing
      licModificationAllowed (licAt 0) `shouldBe` Nothing
      licRedistributionAllowed (licAt 0) `shouldBe` Nothing
      licResaleAllowed (licAt 0) `shouldBe` Nothing
      licNftAllowed (licAt 0) `shouldBe` Nothing
      licSourceUrl (licAt 0) `shouldBe` Nothing

    it "type 繼承容器的 asset-license" $
      metaType (licMeta (licAt 0)) `shouldBe` typeOf "asset-license"

    it "full_text 節層不出現,一律 Nothing" $
      licFullText (licAt 0) `shouldBe` Nothing

  describe "CC-BY 4.0(lic-0000000b,八維度全寫)" $
    it "全部維度逐值正確" $ do
      licCommercial (licAt 1) `shouldBe` True
      licAttributionRequired (licAt 1) `shouldBe` True
      licCreditText (licAt 1) `shouldBe` Just "需標註原作者"
      licModificationAllowed (licAt 1) `shouldBe` Just True
      licRedistributionAllowed (licAt 1) `shouldBe` Just True
      licResaleAllowed (licAt 1) `shouldBe` Just False
      licNftAllowed (licAt 1) `shouldBe` Just False
      licSourceUrl (licAt 1) `shouldBe` Just "https://creativecommons.org/licenses/by/4.0/"

  describe "缺 commercial / attribution_required → SectionFieldMissing" $ do
    it "缺 commercial" $ do
      let bad = T.replace "commercial: true\nattribution_required: false\n" "attribution_required: false\n" licensesMd
      leftKind (toLicenses (docOf bad))
        `shouldBe` Just (SectionFieldMissing (idOf "lic-0000000a") "commercial")

    it "缺 attribution_required" $ do
      let bad = T.replace "commercial: true\nattribution_required: false\n" "commercial: true\n" licensesMd
      leftKind (toLicenses (docOf bad))
        `shouldBe` Just (SectionFieldMissing (idOf "lic-0000000a") "attribution_required")

  -- T11:renderMdError 對 SectionFieldMissing 印出節 id 與行號
  describe "SectionFieldMissing 的訊息" $
    it "renderMdError 印出節 id" $ do
      let bad = T.replace "commercial: true\nattribution_required: false\n" "attribution_required: false\n" licensesMd
      case toLicenses (docOf bad) of
        Left e -> renderMdError e `shouldSatisfy` T.isInfixOf "lic-0000000a"
        Right _ -> expectationFailure "應該失敗"

  describe "節 id 前綴必須是 lic" $
    it "節用 {#ent-0001} → IdPrefixMismatch" $ do
      let bad = T.replace "{#lic-0000000b}" "{#ent-00000001}" licensesMd
      leftKind (toLicenses (docOf bad))
        `shouldBe` Just (IdPrefixMismatch (idOf "ent-00000001") "lic")
