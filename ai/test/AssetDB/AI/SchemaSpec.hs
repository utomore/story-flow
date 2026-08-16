module AssetDB.AI.SchemaSpec (spec) where

import AssetDB.AI.Schema
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Test.Hspec

spec :: Spec
spec = do
  describe "objectOf" $ do
    it "每個欄位都是必填" $ do
      let v = objectOf [("a", stringOf "x"), ("b", stringOf "y")]
      required v `shouldBe` Just (toJSON (["a", "b"] :: [String]))

    it "不允許額外欄位" $ do
      -- 開著 additionalProperties 等於允許模型自己發明欄位,
      -- 而它發明的欄位不會有人讀。
      let v = objectOf [("a", stringOf "x")]
      prop "additionalProperties" v `shouldBe` Just (Bool False)

  describe "enumOf" $
    it "把列舉值原封不動放進 schema" $ do
      -- 這串值就是 GBNF 的字面選項。模型吐不出不在裡面的東西 ——
      -- 這是本套件對抗錯誤分類最有效的一道防線。
      let v = enumOf "分類" ["gui", "icon", "unknown"]
      prop "enum" v `shouldBe` Just (toJSON (["gui", "icon", "unknown"] :: [String]))

  describe "arrayOf" $
    it "帶上限" $ do
      let v = arrayOf "標籤" 6 (stringOf "t")
      prop "maxItems" v `shouldBe` Just (Number 6)

  describe "responseFormat" $
    it "是 llama.cpp 認得的 json_schema 形狀" $ do
      let v = responseFormat "t" (objectOf [("a", stringOf "x")])
      prop "type" v `shouldBe` Just (String "json_schema")
      (prop "json_schema" v >>= prop "name") `shouldBe` Just (String "t")

  describe "analysis 欄位的排序假設" $
    it "analysis 在字母序上早於 category" $
      -- 讓模型先寫理由再寫答案。實際輸出順序取決於 llama.cpp 怎麼走訪
      -- schema,而 aeson 不保證序列化順序 —— 所以這裡不賭順序被保留,
      -- 而是選一個在字母序下也成立的名字。這個測試把那個假設釘住。
      (("analysis" :: String) < "category") `shouldBe` True

prop :: Key -> Value -> Maybe Value
prop k (Object o) = KM.lookup k o
prop _ _ = Nothing

required :: Value -> Maybe Value
required = prop "required"
