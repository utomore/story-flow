-- | graph-core/F001 T3 的對照測試:核心關聯詞彙(擴充 Uses/Depicts)與
-- LinkGraph 型別別名(A2:只留型別,不含走訪函式)。
module Aapms.Core.LinkSpec (spec) where

import qualified Data.Map.Strict as M
import Aapms.Core.Fixtures (idOf, refOf)
import Aapms.Core.Link
import Test.Hspec

spec :: Spec
spec = do
  describe "核心關聯詞彙" $ do
    it "十個核心建構子的 parse . render 是恆等" $
      mapM_ (\k -> parseLinkKind (renderLinkKind k) `shouldBe` k) coreLinkKinds

    it "渲染成詞彙表的字串,含 uses / depicts" $
      map renderLinkKind coreLinkKinds
        `shouldBe` [ "contradicts"
                   , "supersedes"
                   , "derivedFrom"
                   , "partOf"
                   , "involves"
                   , "occursIn"
                   , "references"
                   , "convergesTo"
                   , "uses"
                   , "depicts"
                   ]

    it "恰好十個" $
      length coreLinkKinds `shouldBe` 10

    it "isCoreKind 對十個核心為真、對 Custom 為假" $ do
      all isCoreKind coreLinkKinds `shouldBe` True
      isCoreKind (Custom "師承於") `shouldBe` False

  describe "自訂關聯" $ do
    it "未知字串解析為 Custom 且不失真" $
      parseLinkKind "師承於" `shouldBe` Custom "師承於"

    it "Custom 的 render . parse 是恆等,原字串完整保留" $
      renderLinkKind (parseLinkKind "師承於") `shouldBe` "師承於"

    it "大小寫不同於核心關聯的字串仍是 Custom —— 引擎不猜" $
      parseLinkKind "Contradicts" `shouldBe` Custom "Contradicts"

  describe "suggestCoreKind —— ADR-005 的誤解緩解措施" $ do
    it "「矛盾於」建議 Contradicts" $
      suggestCoreKind "矛盾於" `shouldBe` Just Contradicts

    it "「宿敵」沒有建議" $
      suggestCoreKind "宿敵" `shouldBe` Nothing

    it "「師承於」沒有建議" $
      suggestCoreKind "師承於" `shouldBe` Nothing

    it "「取代」建議 Supersedes、「發生於」建議 OccursIn" $ do
      suggestCoreKind "取代" `shouldBe` Just Supersedes
      suggestCoreKind "發生於" `shouldBe` Just OccursIn

    it "大小寫與底線的差異不影響建議" $ do
      suggestCoreKind "Occurs_In" `shouldBe` Just OccursIn
      suggestCoreKind "PART OF" `shouldBe` Just PartOf

    it "已經是核心關聯的字串不再給建議" $
      suggestCoreKind "contradicts" `shouldBe` Nothing

    it "「使用」建議 Uses、「描繪」建議 Depicts(ADR-012 新增的兩個核心關聯)" $ do
      suggestCoreKind "使用" `shouldBe` Just Uses
      suggestCoreKind "描繪" `shouldBe` Just Depicts

  describe "LinkGraph —— 型別別名,只留資料結構(待確認假設 A2)" $
    it "可放入 Map.fromList 並依 Id 查詢" $
      let g :: LinkGraph
          g = M.fromList [(idOf "ent-7f3a", [Link Uses (refOf "ast-1a2b") Nothing])]
       in M.lookup (idOf "ent-7f3a") g `shouldBe` Just [Link Uses (refOf "ast-1a2b") Nothing]
