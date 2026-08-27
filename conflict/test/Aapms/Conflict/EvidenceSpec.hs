-- | T3:第 1 層的證據。
--
-- 重點不是「欄位存得住值」,而是 'GraphEvidence' 的形狀__接得上 core 既有的
-- 兩個輸出__:@contradictionPairs :: LinkGraph -> [(Id, Ref)]@ 與
-- @supersededSet :: LinkGraph -> Set Ref@。接不上的話,第 1 層就得在中間
-- 自己轉一手,而那個轉換遲早會把跨 Vault 的命中弄丟。
module Aapms.Conflict.EvidenceSpec (spec) where

import Aapms.Conflict.Fixtures (idOf, refOf)
import Aapms.Conflict.Types
import Aapms.Core.Id (Ref (..), localRef, renderRef)
import Aapms.Core.Link (LinkKind (Contradicts, Supersedes))
import Test.Hspec

spec :: Spec
spec = describe "GraphEvidence 表達得出 core 的兩種輸出" $ do
  it "contradictionPairs 形狀的 (Id, Ref) 直接組得出 GraphEvidence" $ do
    -- 這正是 contradictionPairs 的回傳元素形狀,沒有任何轉換
    let pairs = [(idOf "ent-7f3c", localRef (idOf "ent-91cc"))]
        evs = [GraphEvidence f Contradicts t | (f, t) <- pairs]
    map geFrom evs `shouldBe` [idOf "ent-7f3c"]
    map geTo evs `shouldBe` [localRef (idOf "ent-91cc")]
    map geKind evs `shouldBe` [Contradicts]

  it "supersededSet 的 Ref 也放得進 geTo" $ do
    let ev = GraphEvidence (idOf "ent-7f3c") Supersedes (refOf "ent-4d10")
    geKind ev `shouldBe` Supersedes
    refVault (geTo ev) `shouldBe` Nothing

  -- core 的圖遍歷明說「跨 Vault 的 target 會被收進結果,但它的關聯不在這張圖裡」。
  -- geTo 若是 Id,第 1 層就只能把那種命中偷偷丟掉。
  it "跨 Vault 的目標構造得出來且欄位不失真" $ do
    let ev = GraphEvidence (idOf "ent-7f3c") Contradicts (refOf "shared-lore:ent-91cc")
    refVault (geTo ev) `shouldBe` Just "shared-lore"
    renderRef (geTo ev) `shouldBe` "shared-lore:ent-91cc"
