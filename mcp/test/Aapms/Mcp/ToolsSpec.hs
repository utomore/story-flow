-- | T5 / T11:'Aapms.Mcp.Tools' 從 'aapmsOpenApi' 反推出來的 tools。
--
-- 第一條斷言就是驗收標準的可測形式:tools 數 == OpenAPI operation 數,兩邊都從
-- 同一份 'aapmsOpenApi' 算出來,不會出現「新增 REST 路由卻忘了補 tool」。
module Aapms.Mcp.ToolsSpec (spec) where

import Control.Lens ((^.))
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.OpenApi
  ( Operation
  , PathItem
  , delete
  , get
  , operationId
  , patch
  , paths
  , post
  , put
  )
import qualified Data.HashMap.Strict.InsOrd as IOM
import Data.Text (Text)
import Aapms.Api (aapmsOpenApi)
import Aapms.Mcp.Tools (Tool (..), lookupTool, toolsFromOpenApi)
import Test.Hspec

spec :: Spec
spec = do
  let tools = toolsFromOpenApi aapmsOpenApi

  describe "tools 數" $
    it "等於 aapmsOpenApi 的 operation 數(28)" $
      length tools `shouldBe` length allOperations

  describe "tool 名稱" $ do
    it "與全部 operation 的 operationId 集合逐一相等" $
      sort (map toolName tools) `shouldBe` sort (mapMaybe (^. operationId) allOperations)

    it "彼此不重複" $
      length (map toolName tools) `shouldBe` length (nubText (map toolName tools))

  describe "lookupTool" $ do
    it "找得到存在的 tool" $
      fmap toolName (lookupTool "postWorkshop" tools) `shouldBe` Just "postWorkshop"

    it "找不到不存在的名字時回 Nothing" $
      lookupTool "noSuchTool" tools `shouldBe` Nothing

  describe "inputSchema——代表性 operation" $ do
    it "postWorkshop:只有 body,body 必填" $
      schemaOf "postWorkshop" `shouldBe` Just (["body"], ["body"])

    it "getEntitiesById:只有 path 參數 id,必填" $
      schemaOf "getEntitiesById" `shouldBe` Just (["id"], ["id"])

    it "deleteEntitiesByIdLinks:id/kind/revision/target 都在,全部必填" $
      schemaOf "deleteEntitiesByIdLinks"
        `shouldBe` Just (["id", "kind", "revision", "target"], ["id", "kind", "revision", "target"])

    it "postNodesById:body/id/levelId/revision 都在,全部必填" $
      schemaOf "postNodesById"
        `shouldBe` Just (["body", "id", "levelId", "revision"], ["body", "id", "levelId", "revision"])
  where
    schemaOf nm = do
      t <- lookupTool nm (toolsFromOpenApi aapmsOpenApi)
      pure (sort (propsKeys (toolInputSchema t)), sort (requiredKeys (toolInputSchema t)))

-- 內部 -------------------------------------------------------------------------

allOperations :: [Operation]
allOperations =
  [op | (_, item) <- IOM.toList (aapmsOpenApi ^. paths), (_, Just op) <- verbsOf item]

verbsOf :: PathItem -> [(String, Maybe Operation)]
verbsOf item =
  [ ("get", item ^. get)
  , ("post", item ^. post)
  , ("patch", item ^. patch)
  , ("put", item ^. put)
  , ("delete", item ^. delete)
  ]

propsKeys :: Value -> [Text]
propsKeys (Object o) = case KM.lookup "properties" o of
  Just (Object p) -> map AK.toText (KM.keys p)
  _ -> []
propsKeys _ = []

requiredKeys :: Value -> [Text]
requiredKeys (Object o) = case KM.lookup "required" o of
  Just (Array a) -> [t | String t <- toList a]
  _ -> []
requiredKeys _ = []

nubText :: [Text] -> [Text]
nubText = go []
  where
    go seen [] = reverse seen
    go seen (x : xs)
      | x `elem` seen = go seen xs
      | otherwise = go (x : seen) xs
