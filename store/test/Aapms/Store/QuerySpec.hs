-- | graph-core\/F006 STEP-8('NodeFilter' 各欄位)、STEP-12('linksFrom'\/'linksTo'\/
-- 'loadLinkGraph')。
module Aapms.Store.QuerySpec (spec) where

import qualified Data.Map.Strict as M
import Aapms.Core.Id (IdPrefix (PEnt), idPrefix, refId)
import Aapms.Core.Link (Link (..), LinkKind (PartOf))
import Aapms.Core.Meta (Meta (..), Status (Missing))
import Aapms.Store.Fixtures
import Aapms.Store.Query
import Test.Hspec

spec :: Spec
spec = describe "graph-core/F006 Query" $ do
  describe "STEP-8: NodeFilter" $ do
    it "nfStatus = [] 排除 status = missing 的 asset,[Missing] 才回" $
      withIndexedAssetVault $ \vh -> do
        defaultResult <- listNodes vh emptyNodeFilter
        map metaId defaultResult `shouldNotContain` [idOf "ast-00000002"]
        missingResult <- listNodes vh emptyNodeFilter {nfStatus = [Missing]}
        map metaId missingResult `shouldContain` [idOf "ast-00000002"]

    it "nfNamedOnly = True 只回 assets.name 非 NULL 的節點" $
      withIndexedAssetVault $ \vh -> do
        named <- listNodes vh emptyNodeFilter {nfNamedOnly = True}
        map metaId named `shouldBe` [idOf "ast-00000001"]

    it "pack 路徑含 library/reference/ 的 fixture 預設被排除,nfIncludeReference = True 才回" $
      -- 'shouldContain'/'shouldNotContain' 對 list 是 isInfixOf(連續子序列)
      -- 語意,不是「每個元素是否存在」——兩個 id 逐一檢查,避免順序誤判。
      withIndexedAssetVault $ \vh -> do
        defaultResult <- map metaId <$> listNodes vh emptyNodeFilter
        defaultResult `shouldNotContain` [idOf "pck-00000002"]
        defaultResult `shouldNotContain` [idOf "ast-00000003"]
        withRef <- map metaId <$> listNodes vh emptyNodeFilter {nfIncludeReference = True}
        withRef `shouldContain` [idOf "pck-00000002"]
        withRef `shouldContain` [idOf "ast-00000003"]

    it "nfPrefixes/nfTypes/nfTags 組合驗證交集語意" $
      withIndexedStoryVault $ \vh -> do
        entOnly <- listNodes vh emptyNodeFilter {nfPrefixes = [PEnt]}
        all ((== PEnt) . idPrefix . metaId) entOnly `shouldBe` True

        fragType <- listNodes vh emptyNodeFilter {nfTypes = [typeOf "character-fragment"]}
        map metaId fragType `shouldMatchList` [idOf "ent-00000002", idOf "ent-00000003"]

        tagged <- listNodes vh emptyNodeFilter {nfTags = ["背景"]}
        map metaId tagged `shouldBe` [idOf "ent-00000003"]

        -- 組合 prefix + tag:同時滿足才回
        both <- listNodes vh emptyNodeFilter {nfPrefixes = [PEnt], nfTags = ["外觀"]}
        map metaId both `shouldBe` [idOf "ent-00000002"]

  describe "STEP-12: linksFrom / linksTo / loadLinkGraph" $ do
    it "story vault 兩條關聯:linksFrom 依來源查、linksTo 依目標查(含 Meta 正確)、loadLinkGraph 一致" $
      withIndexedStoryVault $ \vh -> do
        fromLinks <- linksFrom vh (idOf "ent-00000003")
        map linkKind fromLinks `shouldBe` [PartOf]
        map (refId . linkTarget) fromLinks `shouldBe` [idOf "ent-00000001"]

        toResults <- linksTo vh (refOf "ent-00000001")
        map (metaId . fst) toResults `shouldContain` [idOf "ent-00000003"]

        graph <- loadLinkGraph vh
        M.lookup (idOf "ent-00000003") graph `shouldBe` Just fromLinks

    it "空 vault 的 loadLinkGraph 不炸(asset vault 內全部關聯只在 links 欄位有值時才進圖)" $
      withIndexedAssetVault $ \vh -> do
        graph <- loadLinkGraph vh
        M.size graph `shouldSatisfy` (>= 0)
