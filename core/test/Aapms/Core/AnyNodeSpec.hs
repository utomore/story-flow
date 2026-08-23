-- | graph-core/F001 T9 的對照測試:AnyNode 的 anyMeta 與 prefixOf。
module Aapms.Core.AnyNodeSpec (spec) where

import Aapms.Core.AnyNode
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Fixtures
import Aapms.Core.Id (IdPrefix (..))
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Pack (Pack (..))
import Test.Hspec

spec :: Spec
spec = describe "AnyNode" $ do
  it "anyMeta 對六種建構子回傳正確的 Meta" $ do
    anyMeta (NEntity sampleEntity) `shouldBe` entMeta sampleEntity
    anyMeta (NAsset sampleAsset) `shouldBe` astMeta sampleAsset
    anyMeta (NPack samplePack) `shouldBe` pckMeta samplePack
    anyMeta (NLicense sampleLicense) `shouldBe` licMeta sampleLicense
    anyMeta (NLevel sampleLevel) `shouldBe` lvlMeta sampleLevel
    anyMeta (NNode sampleNode) `shouldBe` nodMeta sampleNode

  it "prefixOf 對六種建構子回傳對應的 IdPrefix" $ do
    prefixOf (NEntity sampleEntity) `shouldBe` PEnt
    prefixOf (NAsset sampleAsset) `shouldBe` PAst
    prefixOf (NPack samplePack) `shouldBe` PPck
    prefixOf (NLicense sampleLicense) `shouldBe` PLic
    prefixOf (NLevel sampleLevel) `shouldBe` PLvl
    prefixOf (NNode sampleNode) `shouldBe` PNod
