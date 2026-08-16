-- | func-0002 T7 的對照測試:關聯圖遍歷與推論。
module StoryFlow.Core.GraphSpec (spec) where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import StoryFlow.Core.Fixtures
import StoryFlow.Core.Graph
import StoryFlow.Core.Link
import StoryFlow.Core.Meta
import Test.Hspec

-- | 給一個 id 與它持有的關聯,做出一份 Meta。
withLinks :: Text -> [(LinkKind, Text)] -> Meta
withLinks i ls =
  (metaOf i i) {metaLinks = [Link k (refOf t) Nothing | (k, t) <- ls]}

-- | 一條 partOf 鏈:ent-0001 → ent-0002 → ent-0003
partOfChain :: LinkGraph
partOfChain =
  buildGraph
    [ withLinks "ent-0001" [(PartOf, "ent-0002")]
    , withLinks "ent-0002" [(PartOf, "ent-0003")]
    , withLinks "ent-0003" []
    ]

-- | 一個 derivedFrom 環:ent-000a → ent-000b → ent-000c → ent-000a
derivedCycle :: LinkGraph
derivedCycle =
  buildGraph
    [ withLinks "ent-000a" [(DerivedFrom, "ent-000b")]
    , withLinks "ent-000b" [(DerivedFrom, "ent-000c")]
    , withLinks "ent-000c" [(DerivedFrom, "ent-000a")]
    ]

spec :: Spec
spec = do
  describe "buildGraph" $ do
    it "以來源端的 id 為鍵收集關聯" $
      S.fromList (map renderKind (linksOf "ent-0001" partOfChain))
        `shouldBe` S.fromList ["partOf"]

    it "同一個來源的多筆 Meta 會合併關聯" $
      let g =
            buildGraph
              [ withLinks "ent-0001" [(PartOf, "ent-0002")]
              , withLinks "ent-0001" [(Involves, "ent-0003")]
              ]
       in length (linksOf "ent-0001" g) `shouldBe` 2

  describe "follow —— 深度上限" $ do
    it "深度 1 只走一層" $
      follow [PartOf] 1 (idOf "ent-0001") partOfChain
        `shouldBe` S.fromList [refOf "ent-0002"]

    it "深度 2 走兩層" $
      follow [PartOf] 2 (idOf "ent-0001") partOfChain
        `shouldBe` S.fromList [refOf "ent-0002", refOf "ent-0003"]

    it "深度 0 什麼都不走" $
      follow [PartOf] 0 (idOf "ent-0001") partOfChain `shouldBe` S.empty

    it "只跟隨指定的關聯種類" $
      follow [Involves] 3 (idOf "ent-0001") partOfChain `shouldBe` S.empty

    it "不含起點" $
      S.member (refOf "ent-0001") (follow [PartOf] 5 (idOf "ent-0001") partOfChain)
        `shouldBe` False

  describe "follow —— 防環" $ do
    it "derivedFrom 成環時終止,不無限迴圈" $
      follow [DerivedFrom] 10 (idOf "ent-000a") derivedCycle
        `shouldBe` S.fromList [refOf "ent-000b", refOf "ent-000c"]

    it "環上的起點不會被算進可達集合" $
      S.member
        (refOf "ent-000a")
        (follow [DerivedFrom] 10 (idOf "ent-000a") derivedCycle)
        `shouldBe` False

  describe "follow —— 跨 Vault" $
    it "跨 Vault 的 target 收進結果,但不再往下展開" $
      let g = buildGraph [withLinks "ent-0001" [(PartOf, "shared-lore:ent-00ff")]]
       in follow [PartOf] 5 (idOf "ent-0001") g
            `shouldBe` S.fromList [refOf "shared-lore:ent-00ff"]

  describe "supersededSet —— 遞移閉包" $ do
    it "A → B → C 的取代鏈回傳 {B, C}" $
      let g =
            buildGraph
              [ withLinks "ent-000a" [(Supersedes, "ent-000b")]
              , withLinks "ent-000b" [(Supersedes, "ent-000c")]
              , withLinks "ent-000c" []
              ]
       in supersededSet g `shouldBe` S.fromList [refOf "ent-000b", refOf "ent-000c"]

    it "沒有任何 supersedes 時是空集合" $
      supersededSet partOfChain `shouldBe` S.empty

    it "取代鏈成環時仍然終止" $
      let g =
            buildGraph
              [ withLinks "ent-000a" [(Supersedes, "ent-000b")]
              , withLinks "ent-000b" [(Supersedes, "ent-000a")]
              ]
       in supersededSet g `shouldBe` S.fromList [refOf "ent-000a", refOf "ent-000b"]

  describe "contradictionPairs —— 去重與正規化" $ do
    it "同一對矛盾雙向都寫時只回一筆" $
      let g =
            buildGraph
              [ withLinks "ent-000b" [(Contradicts, "ent-000a")]
              , withLinks "ent-000a" [(Contradicts, "ent-000b")]
              ]
       in contradictionPairs g `shouldBe` [(idOf "ent-000a", refOf "ent-000b")]

    it "單向寫的矛盾也正規化為 (較小 id, 較大 id)" $
      let g = buildGraph [withLinks "ent-000b" [(Contradicts, "ent-000a")]]
       in contradictionPairs g `shouldBe` [(idOf "ent-000a", refOf "ent-000b")]

    it "多對矛盾各回一筆" $
      let g =
            buildGraph
              [ withLinks "ent-000a" [(Contradicts, "ent-000b")]
              , withLinks "ent-000c" [(Contradicts, "ent-000d")]
              ]
       in length (contradictionPairs g) `shouldBe` 2

    it "跨 Vault 的矛盾保持原方向,不嘗試比較先後" $
      let g = buildGraph [withLinks "ent-000b" [(Contradicts, "shared-lore:ent-000a")]]
       in contradictionPairs g
            `shouldBe` [(idOf "ent-000b", refOf "shared-lore:ent-000a")]

    it "沒有 contradicts 時是空清單" $
      contradictionPairs partOfChain `shouldBe` []

linksOf :: Text -> LinkGraph -> [Link]
linksOf i g = M.findWithDefault [] (idOf i) g

renderKind :: Link -> Text
renderKind = renderLinkKind . linkKind
