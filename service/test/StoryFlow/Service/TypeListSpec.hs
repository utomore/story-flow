-- | T10:'listEntityTypes'。
--
-- 這是 CLI 的 @--type@ 選項與 API 型別清單的唯一來源(垂直切片 1:新增一個型別
-- 不必改程式)。輸出必須__穩定排序__ ——順序會飄的清單沒辦法拿來做 diff,也
-- 會讓 CLI 的說明文字每次不一樣。
module StoryFlow.Service.TypeListSpec (spec) where

import Data.List (sort)
import StoryFlow.Core.Registry (EntityTypeSpec (..))
import StoryFlow.Service
import StoryFlow.Service.Fixtures
import System.Directory (listDirectory)
import System.FilePath (takeExtension)
import Test.Hspec

spec :: Spec
spec = describe "listEntityTypes" $ do
  it "數量與 types/registry/ 的 .toml 檔數相同" $
    withServiceEnv $ \env -> do
      specs <- runS env listEntityTypes
      dir <- registryDir
      tomls <- filter ((== ".toml") . takeExtension) <$> listDirectory dir
      length specs `shouldBe` length tomls

  it "依 key 排序,而且連續呼叫結果相同" $
    withServiceEnv $ \env -> do
      specs <- runS env listEntityTypes
      let keys = map etsKey specs
      keys `shouldBe` sort keys
      again <- runS env listEntityTypes
      map etsKey again `shouldBe` keys

  it "帶出 dir 與 owner_type(新建檔案要靠它決定放哪裡)" $
    withServiceEnv $ \env -> do
      specs <- runS env listEntityTypes
      let character = [s | s <- specs, etsKey s == "character-fragment"]
      map etsDir character `shouldBe` [Just "characters"]
      map etsOwnerType character `shouldBe` [Just "character"]
