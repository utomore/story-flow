-- | graph-core\/F006 STEP-9('lookupNode' 七種 prefix 分支)、STEP-10('lookupByName')、
-- STEP-11('childrenOf')。
module Aapms.Store.NodeSpec (spec) where

import Aapms.Core.AnyNode (AnyNode (..))
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Ref (..))
import Aapms.Core.Level (Level (..), Node (..), NodeKind (KCast))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Store.Fixtures
import Aapms.Store.Query
import Test.Hspec

spec :: Spec
spec = describe "graph-core/F006 lookupNode / lookupByName / childrenOf" $ do
  describe "STEP-9: lookupNode 七種 prefix" $ do
    it "PEnt(主體):回 NEntity,body 來自檔案的 docPreamble" $
      withIndexedStoryVault $ \vh -> do
        r <- lookupNode vh (idOf "ent-00000001")
        case r of
          Just (NEntity (Entity m body)) -> do
            metaId m `shouldBe` idOf "ent-00000001"
            body `shouldBe` "主體內文。"
          other -> expectationFailure ("預期 NEntity,得到 " <> show (fmap tagOf other))

    it "PEnt(片段):回 NEntity,body 來自該節" $
      withIndexedStoryVault $ \vh -> do
        r <- lookupNode vh (idOf "ent-00000003")
        case r of
          Just (NEntity (Entity m body)) -> do
            metaId m `shouldBe` idOf "ent-00000003"
            body `shouldBe` "背景內文。"
          other -> expectationFailure ("預期 NEntity,得到 " <> show (fmap tagOf other))

    it "PAst:回 NAsset,索引欄位(name/sha256/entry)與回讀的 body 都正確" $
      withIndexedAssetVault $ \vh -> do
        r <- lookupNode vh (idOf "ast-00000001")
        case r of
          Just (NAsset a) -> do
            astName a `shouldBe` Just (LogicalName "ui_gui_panel_001")
            astSha256 a `shouldBe` Sha256 "1111111111111111111111111111111111111111111111111111111111111111"
            astEntry a `shouldBe` "PNG/panel.png"
          other -> expectationFailure ("預期 NAsset,得到 " <> show (fmap tagOf other))

    it "PPck:回 NPack,body 為容器的 docPreamble" $
      withIndexedAssetVault $ \vh -> do
        r <- lookupNode vh (idOf "pck-00000001")
        case r of
          Just (NPack p) -> do
            pckVendor p `shouldBe` Just "test-vendor"
            pckBody p `shouldBe` "Pack 說明。"
          other -> expectationFailure ("預期 NPack,得到 " <> show (fmap tagOf other))

    it "PLic:回 NLicense,純索引查詢(不回讀檔案)" $
      withIndexedAssetVault $ \vh -> do
        r <- lookupNode vh (idOf "lic-0000000a")
        case r of
          Just (NLicense l) -> do
            licCommercial l `shouldBe` True
            licAttributionRequired l `shouldBe` False
          other -> expectationFailure ("預期 NLicense,得到 " <> show (fmap tagOf other))

    it "PLvl:回 NLevel,lvlRoot 正確" $
      withIndexedStoryVault $ \vh -> do
        r <- lookupNode vh (idOf "lvl-00000001")
        case r of
          Just (NLevel lvl) -> lvlRoot lvl `shouldBe` idOf "nod-00000001"
          other -> expectationFailure ("預期 NLevel,得到 " <> show (fmap tagOf other))

    it "PNod:回 NNode,nodParent/nodOrder/nodKind/nodEntities 正確" $
      withIndexedStoryVault $ \vh -> do
        r <- lookupNode vh (idOf "nod-00000002")
        case r of
          Just (NNode n) -> do
            nodParent n `shouldBe` Just (idOf "nod-00000001")
            nodKind n `shouldBe` KCast
            map refId (nodEntities n) `shouldBe` [idOf "ent-00000001"]
          other -> expectationFailure ("預期 NNode,得到 " <> show (fmap tagOf other))

    it "vlt-/prj- 開頭的 id 回 Nothing" $
      withIndexedStoryVault $ \vh -> do
        lookupNode vh (idOf "vlt-00000001") `shouldReturn` Nothing
        lookupNode vh (idOf "prj-00000001") `shouldReturn` Nothing

  describe "STEP-10: lookupByName" $
    it "已命名的 asset 查得到,未命名或不存在的名稱回 Nothing" $
      withIndexedAssetVault $ \vh -> do
        found <- lookupByName vh (LogicalName "ui_gui_panel_001")
        fmap (metaId . astMeta) found `shouldBe` Just (idOf "ast-00000001")
        notFound <- lookupByName vh (LogicalName "not_a_real_name_999")
        notFound `shouldBe` Nothing

  describe "STEP-11: childrenOf" $
    it "對 pack id 回全部 asset、對主體 entity id 回全部片段,對沒有子節點的 id 回 []" $ do
      withIndexedAssetVault $ \vh -> do
        kids <- childrenOf vh (idOf "pck-00000001")
        map metaId kids `shouldMatchList` [idOf "ast-00000001", idOf "ast-00000002"]
      withIndexedStoryVault $ \vh -> do
        kids <- childrenOf vh (idOf "ent-00000001")
        map metaId kids `shouldMatchList` [idOf "ent-00000002", idOf "ent-00000003"]
        leaf <- childrenOf vh (idOf "ent-00000002")
        leaf `shouldBe` []

--------------------------------------------------------------------------------

-- | 錯誤訊息用:只印建構子名稱,不強求 'Show' 全部欄位。
tagOf :: AnyNode -> String
tagOf = \case
  NEntity _ -> "NEntity"
  NAsset _ -> "NAsset"
  NPack _ -> "NPack"
  NLicense _ -> "NLicense"
  NLevel _ -> "NLevel"
  NNode _ -> "NNode"
