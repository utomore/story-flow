-- | graph-core\/F007:"Aapms.Store.Query".'search' 的 facet 計數(契約 F
-- 'FacetCounts')。
--
-- __spec 對照__(每條 law\/example 對回
-- @.design\/subsystems\/graph-core\/features\/F007-store-fts-dual-index.md@):
--
-- @
-- L16 sqFacets 控制 srFacets 的 Just/Nothing;fcVaults 恰一筆      -> test_L16
-- L17 facet 計數不受該 facet 自己的過濾條件影響                  -> test_L17
-- L18 facet 每筆計數等於疊加該值的 listNodes 筆數                -> test_L18
-- E11 有資料的 vault 開 facet,五個維度皆非空                    -> test_E11
-- @
module Aapms.Store.FacetSpec (spec) where

import Control.Monad (forM_)
import Data.Maybe (isJust)
import Data.Text (Text)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Id (Id, Ref, VaultId (..))
import Aapms.Core.Meta (TypeKey)
import Aapms.Store.Fixtures
import Aapms.Store.Marker
import Aapms.Store.Query

spec :: Spec
spec = describe "graph-core/F007 facet" $ do
  -- hspec-hedgehog 的 'hedgehog' 產生 'PropertyT IO ()',塞不進
  -- 'withIndexedAssetVault' 這類 (VaultHandle -> IO a) -> IO a 的 callback
  -- (那要的是 IO a)。改用 'around' 讓 hspec 接管 fixture 的取得/收尾,
  -- 'it' 直接吃 'VaultHandle -> PropertyT IO ()'。
  around withIndexedAssetVault $ do
    it "L16: sqFacets 控制 srFacets 的 Just/Nothing;True 時 fcVaults 恰一筆,\
       \等於本 vault 的 vmId、計數等於 srTotal" $
      \vh -> hedgehog $ do
        facetsOn <- forAll Gen.bool
        txt <- forAll genSqTextCandidate
        r <- evalIO (search vh (emptySearchQuery {sqText = txt, sqFacets = facetsOn}))
        isJust (srFacets r) === facetsOn
        case (facetsOn, srFacets r) of
          (True, Just fc) -> do
            let VaultId vaultText = vmId (vhMarker vh)
            fcVaults fc === [(vaultText, srTotal r)]
          (False, Nothing) -> pure ()
          _ -> assert False

    it "L17: facet 計數不受該 facet 自己的過濾條件影響(nfTypes/nfTags/nfOwner/nfLicense)" $
      \vh -> hedgehog $ do
        baseR <- evalIO (search vh (emptySearchQuery {sqFacets = True}))
        fcBase <- case srFacets baseR of
          Just fc -> pure fc
          Nothing -> do
            annotate "預期 baseline search(sqFacets = True)回 Just facets"
            failure

        ts <- forAll (Gen.list (Range.linear 0 2) genTypeCandidate)
        tags <- forAll (Gen.list (Range.linear 0 2) genTagCandidate)
        ownerCand <- forAll (Gen.maybe genOwnerCandidate)
        licCand <- forAll (Gen.maybe genLicenseCandidate)

        rTypes <-
          evalIO (search vh (emptySearchQuery {sqFacets = True, sqFilter = emptyNodeFilter {nfTypes = ts}}))
        fmap fcTypes (srFacets rTypes) === Just (fcTypes fcBase)

        rTags <-
          evalIO (search vh (emptySearchQuery {sqFacets = True, sqFilter = emptyNodeFilter {nfTags = tags}}))
        fmap fcTags (srFacets rTags) === Just (fcTags fcBase)

        rOwner <-
          evalIO
            (search vh (emptySearchQuery {sqFacets = True, sqFilter = emptyNodeFilter {nfOwner = ownerCand}}))
        fmap fcOwners (srFacets rOwner) === Just (fcOwners fcBase)

        rLic <-
          evalIO
            (search vh (emptySearchQuery {sqFacets = True, sqFilter = emptyNodeFilter {nfLicense = licCand}}))
        fmap fcLicenses (srFacets rLic) === Just (fcLicenses fcBase)

  it "L18: fcTags/fcTypes/fcOwners/fcLicenses 每一筆的計數,等於疊加該值後的 listNodes 筆數\
     \(facet 受其他條件影響,不受自己影響)" $
    withIndexedAssetVault $ \vh -> do
      let filt = emptyNodeFilter {nfIncludeReference = True}
      r <- search vh (emptySearchQuery {sqFilter = filt, sqFacets = True})
      case srFacets r of
        Nothing -> expectationFailure "預期 Just facets"
        Just fc -> do
          forM_ (fcTags fc) $ \(tag, n) -> do
            hits <- listNodes vh filt {nfTags = [tag]}
            length hits `shouldBe` n
          forM_ (fcTypes fc) $ \(ty, n) -> do
            hits <- listNodes vh filt {nfTypes = [typeOf ty]}
            length hits `shouldBe` n
          forM_ (fcOwners fc) $ \(ownerText, n) -> do
            hits <- listNodes vh filt {nfOwner = Just (idOf ownerText)}
            length hits `shouldBe` n
          forM_ (fcLicenses fc) $ \(licText, n) -> do
            hits <- listNodes vh filt {nfLicense = Just (refOf licText)}
            length hits `shouldBe` n

  it "E11: 有資料的 vault 開 facet,五個維度皆非空,fcVaults 恰一筆" $
    withIndexedAssetVault $ \vh -> do
      r <- search vh (emptySearchQuery {sqFacets = True})
      case srFacets r of
        Nothing -> expectationFailure "預期 Just facets"
        Just fc -> do
          length (fcVaults fc) `shouldBe` 1
          fcTypes fc `shouldNotSatisfy` null
          fcTags fc `shouldNotSatisfy` null
          fcOwners fc `shouldNotSatisfy` null
          fcLicenses fc `shouldNotSatisfy` null

--------------------------------------------------------------------------------
-- 產生器

-- | L16 用:文字條件的代表性樣本(有\/無皆有)。
genSqTextCandidate :: Gen (Maybe Text)
genSqTextCandidate = Gen.choice [pure Nothing, Just <$> Gen.element ["ui", "asset", "pack"]]

-- | L17 用:混合「vault 裡真的存在」與「不存在」的型別\/標籤\/owner\/license 值,
-- 驗證 facet 對自己的過濾條件完全免疫,不論該值是否命中任何節點。
genTypeCandidate :: Gen TypeKey
genTypeCandidate = Gen.element [typeOf "asset-image", typeOf "asset-pack", typeOf "不存在的型別"]

genTagCandidate :: Gen Text
genTagCandidate = Gen.element ["gui", "不存在的標籤"]

genOwnerCandidate :: Gen Id
genOwnerCandidate = Gen.element [idOf "pck-00000001", idOf "ast-00000001", idOf "ast-ffffffff"]

genLicenseCandidate :: Gen Ref
genLicenseCandidate = Gen.element [refOf "lic-0000000a", refOf "lic-00000001", refOf "lic-ffffffff"]
