-- | T5:OpenAPI 文件完整,而且每條路由都有說明。
--
-- 驗收標準 2 是「一個沒讀過原始碼的人(或 Agent)能靠這份文件完成建立、查詢、
-- 掛關聯」。「每個 operation 都有非空 summary」是那句話能被機器檢查的部分——
-- 一條沒有說明的路由,Agent 只能從路徑猜它做什麼。
module StoryFlow.Api.OpenApiSpec (spec) where

import Control.Lens ((^.))
import Data.Aeson (decode, encode, toJSON)
import qualified Data.HashMap.Strict.InsOrd as IOM
import Data.List (nub, sort)
import Data.Maybe (isJust, mapMaybe)
import Data.OpenApi
  ( OpenApi
  , Operation
  , PathItem
  , components
  , delete
  , description
  , get
  , info
  , operationId
  , patch
  , paths
  , post
  , put
  , schemas
  , summary
  , title
  , version
  )
import qualified Data.Text as T
import StoryFlow.Api (deriveOperationId, storyFlowOpenApi)
import Test.Hspec

spec :: Spec
spec = describe "OpenAPI 文件" $ do
  -- conflict-detection/F004 加了 POST /conflict/context:14 → 15 條路徑、
  -- 23 → 24 個 operation。conflict-detection/F006 再加 POST /conflict/check:
  -- 15 → 16 條路徑、24 → 25 個 operation。llm-workshop-mcp/F004 加了
  -- POST /workshop、POST /workshop/:id/step、POST /workshop/:id/commit:
  -- 16 → 19 條路徑、25 → 28 個 operation。
  it "paths 數等於實際的路徑數(19 條路徑、28 個 operation)" $ do
    IOM.size (doc ^. paths) `shouldBe` 19
    length operations `shouldBe` 28

  it "每個 operation 都有非空 summary" $
    mapM_ (\(k, op) -> (k, fmap T.null (op ^. summary)) `shouldBe` (k, Just False)) labelled

  -- llm-workshop-mcp/F005:storyflow-mcp 的 tool 名字直接讀 operationId 這個欄位
  -- (不在 Mcp.Tools 另外重算一次)。這條斷言擋的正是「兩個 operation 撞名」
  -- ——那會讓兩個 MCP tool 撞名,claude code 那邊分不出是哪一個。
  it "全部 28 個 operation 的 operationId 都非空、彼此不重複、與 deriveOperationId 規則相符" $ do
    let ids = mapMaybe (^. operationId) operations
    length ids `shouldBe` length operations
    length (nub ids) `shouldBe` length ids
    sort ids `shouldBe` sort expectedOperationIds

  it "info 有 title、version 與 description" $ do
    doc ^. info . title `shouldBe` "story-flow API"
    doc ^. info . version `shouldBe` "0.1.0"
    doc ^. info . description `shouldSatisfy` isJust

  it "文件可以被重新解碼(它真的是合法的 OpenAPI JSON)" $
    (decode (encode doc) :: Maybe OpenApi) `shouldSatisfy` isJust

  it "components.schemas 含全部具名型別,NodeTree 的遞迴以 $ref 收斂" $ do
    let names = IOM.keys (doc ^. components . schemas)
    mapM_ (\n -> (n, n `elem` names) `shouldBe` (n, True)) expectedSchemas

  -- F004 A9 的裁定不變:GraphEvidence 的 ToSchema 實例只給 SchemaSpec 對帳用,
  -- HitLayer 的 wire 形狀是攤平的,沒有任何 $ref 指向它。不為了讓型別出現在
  -- components 就強制登記它。
  it "components.schemas 仍然不含 GraphEvidence(F004 A9)" $ do
    let names = IOM.keys (doc ^. components . schemas)
    ("GraphEvidence" `elem` names) `shouldBe` False

  it "編碼出來的 JSON 是有限的(遞迴 schema 沒有爆炸)" $
    length (show (encode doc)) `shouldSatisfy` (> 0)

  it "toJSON 與 encode 走同一條路,兩者都不拋例外" $
    length (show (toJSON doc)) `shouldSatisfy` (> 0)

-- | 每個在 API 簽名裡出現過的具名型別都該進 components,Agent 才查得到欄位。
expectedSchemas :: [T.Text]
expectedSchemas =
  [ "Meta"
  , "Entity"
  , "Level"
  , "Node"
  , "NodeTree"
  , "Link"
  , "EntityView"
  , "LevelView"
  , "VaultView"
  , "SearchHit"
  , "LinkReport"
  , "IndexReport"
  , "DeleteReport"
  , "EntityTypeSpec"
  , "NewEntityReq"
  , "NewFragmentReq"
  , "NewLevelReq"
  , "NewNodeReq"
  , "EntityPatch"
  , "NewVaultReq"
  , "BodyReq"
  , -- conflict-detection/F004
    "ContextReq"
  , "ContextHit"
  , "HitLayer"
  , "Draft"
  , "ConflictOpts"
  , -- conflict-detection/F006(GraphEvidence 仍然不進 components,見 A9)
    "CheckReq"
  , "ConflictHit"
  , "ReportNote"
  , "ConflictReport"
  , -- llm-workshop-mcp/F004
    "WorkshopStartReq"
  , "WorkshopStepReq"
  , "WorkshopStepResp"
  , "WorkshopCommitResp"
  , "Session"
  , "StageDraft"
  , "Message"
  , "Role"
  ]

doc :: OpenApi
doc = storyFlowOpenApi

labelled :: [(String, Operation)]
labelled =
  [ (p <> " " <> verb, op)
  | (p, item) <- IOM.toList (doc ^. paths)
  , (verb, Just op) <- verbsOf item
  ]

operations :: [Operation]
operations = map snd labelled

-- | 拿 method+path 逐一重算一遍 'deriveOperationId',與文件裡實際出現的
-- operationId 對帳(不看順序,只看集合是否相等)。
expectedOperationIds :: [T.Text]
expectedOperationIds =
  [ deriveOperationId (T.pack verb) (T.pack p)
  | (p, item) <- IOM.toList (doc ^. paths)
  , (verb, Just _) <- verbsOf item
  ]

verbsOf :: PathItem -> [(String, Maybe Operation)]
verbsOf item =
  [ ("get", item ^. get)
  , ("post", item ^. post)
  , ("patch", item ^. patch)
  , ("put", item ^. put)
  , ("delete", item ^. delete)
  ]
