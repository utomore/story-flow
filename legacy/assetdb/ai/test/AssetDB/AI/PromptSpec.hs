module AssetDB.AI.PromptSpec (spec) where

import AssetDB.AI.Prompt
import AssetDB.AI.Vocab
import AssetDB.Store
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Database.SQLite.Simple (close)
import Test.Hspec

spec :: Spec
spec = around withVocab $ do
  describe "vocab 與 schema 同源" $ do
    it "prompt 裡出現的每個頂層分類都在 schema 的列舉裡" $ \v -> do
      -- 這是整個設計最重要的不變量。實測過不一致的下場:只給列舉、
      -- 沒給定義時,一張牛排圖示被分類成 audio。兩者出自同一個 Vocab,
      -- 漂移就不可能發生 —— 這個測試把那件事釘住。
      let sys = visionSystem v
          es = enumValues (visionSchema v) "category"
      mapM_ (\s -> (s, T.isInfixOf s sys) `shouldBe` (s, True)) (topSlugs v)
      mapM_ (\s -> (s, s `elem` es) `shouldBe` (s, True)) (topSlugs v)

    it "視覺標註的列舉裡沒有 audio / level / reference" $ \v -> do
      -- 錯誤答案在 GBNF 層無法被表達,比在 prompt 裡拜託模型不要選有效得多。
      let es = enumValues (visionSchema v) "category"
      es `shouldNotContain` ["audio"]
      es `shouldNotContain` ["level"]
      es `shouldNotContain` ["reference"]

    it "列舉一定含 unknown" $ \v ->
      enumValues (visionSchema v) "category" `shouldContain` ["unknown"]

  describe "gui 與 icon 的分野" $
    it "兩邊的定義都寫了指向對方的反例" $ \v -> do
      -- 1,693 筆介面外框對上約一千筆物品圖示,是這個素材庫裡模型最容易
      -- 混淆的一對。定義沒寫反例,分錯的代價就是全庫最大的 facet 失效。
      let sys = visionSystem v
      T.isInfixOf "icon" sys `shouldBe` True
      T.isInfixOf "gui" sys `shouldBe` True
      T.isInfixOf "不是" sys `shouldBe` True

  describe "isChildOf" $ do
    it "認得真正的父子關係" $ \v ->
      isChildOf v "icon" "icon/potion" `shouldBe` True

    it "擋掉張冠李戴的子分類" $ \v -> do
      -- 驅動器靠它做優雅降級:保留正確的粗分類,丟掉錯誤的細分類,
      -- 而不是整筆作廢。
      isChildOf v "gui" "icon/potion" `shouldBe` False
      isChildOf v "icon" "icon/不存在" `shouldBe` False

  describe "查詢翻譯" $
    it "要求中英文都給" $ \v -> do
      -- 檔名是英文,AI 標籤是中文,兩邊都要搜才會完整。
      let sys = querySystem v
      T.isInfixOf "中英文" sys `shouldBe` True

  describe "promptVersion" $
    it "不是空的" $ \_ ->
      T.null promptVersion `shouldBe` False

--------------------------------------------------------------------------------

enumValues :: Value -> Key -> [T.Text]
enumValues rf k =
  case go of
    Just (Array a) -> [t | String t <- foldr (:) [] a]
    _ -> []
  where
    go = do
      js <- obj rf >>= KM.lookup "json_schema"
      sc <- obj js >>= KM.lookup "schema"
      ps <- obj sc >>= KM.lookup "properties"
      f <- obj ps >>= KM.lookup k
      obj f >>= KM.lookup "enum"
    obj (Object o) = Just o
    obj _ = Nothing

withVocab :: (Vocab -> IO ()) -> IO ()
withVocab f = do
  st <- openStoreInMemory
  void (initSchema st)
  v <- loadVocab (storeConn st) visionScopes
  f v
  close (storeConn st)
