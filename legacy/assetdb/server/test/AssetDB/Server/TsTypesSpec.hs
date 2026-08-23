-- | 前端型別定義的**防漂移**測試。
--
-- @AssetDB.Server.TsTypes@ 宣告的欄位必須與 @AssetDB.Server.Api@ 的
-- @ToJSON@ instance 實際輸出的欄位完全一致。這個測試把兩邊都抽出來比對 ——
-- 改了一邊沒改另一邊,這裡就紅。
--
-- 這是用「產生器 + 一致性測試」取代 servant-openapi3 → openapi-typescript
-- 的關鍵:少了那整套工具鏈,但沒有少掉它要解決的問題。
module AssetDB.Server.TsTypesSpec (spec) where

import AssetDB.Server.Api
import AssetDB.Server.TsTypes
import Data.Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "TypeScript 定義與 JSON 輸出一致" $ do
    it "SearchItem" $ check "SearchItem" sampleItem
    it "SearchResponse" $ check "SearchResponse" (SearchResponse 0 [])
    it "PackSummary" $ check "PackSummary" samplePack
    it "Health" $ check "Health" (Health 1 2 3 4 False)

  describe "產生的定義" $ do
    it "含有所有型別" $ do
      let ts = tsDefinitions
      mapM_
        (\n -> ts `shouldSatisfy` T.isInfixOf ("export interface " <> n))
        ["SearchItem", "SearchResponse", "FacetValue", "Facets", "PackSummary", "Health"]

    it "標明為產生檔,避免有人手動編輯" $
      tsDefinitions `shouldSatisfy` T.isInfixOf "請勿手動編輯"

    it "可為 null 的欄位在 TS 側也是可為 null" $ do
      -- Maybe Text 在 JSON 裡是 null,TS 型別必須反映這件事,
      -- 否則前端會在 name 為 null 時炸掉。
      let ts = tsDefinitions
      ts `shouldSatisfy` T.isInfixOf "name: string | null;"
      ts `shouldSatisfy` T.isInfixOf "original: string;"

--------------------------------------------------------------------------------

check :: ToJSON a => Text -> a -> Expectation
check name x = sort (jsonKeys x) `shouldBe` sort (tsFieldsOf name)

jsonKeys :: ToJSON a => a -> [Text]
jsonKeys x = case toJSON x of
  Object o -> map K.toText (KM.keys o)
  other -> error ("預期是 JSON 物件,收到 " <> show other)

sampleItem :: SearchItem
sampleItem = SearchItem "01U" (Just "n") "o.png" "image" (Just "p") (Just "a") "x/o.png" (Just "sha")

samplePack :: PackSummary
samplePack = PackSummary "s" "n" (Just "v") (Just "a") (Just "l") "ready" "none" 7
