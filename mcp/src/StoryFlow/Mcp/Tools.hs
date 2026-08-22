-- | 從 'storyFlowOpenApi' 反推全部 MCP tools(llm-workshop-mcp/F005 T5)。
--
-- __完全不連線__:'storyFlowOpenApi' 是 @storyflow-api@ 匯出的純值,在編譯期就
-- 已經確定,不是伺服器執行期反射自己的路由表。這正是驗收標準「tools 數 ==
-- OpenAPI operation 數」能在編譯期成立的原因——'StoryFlowAPI' 一改,
-- 'storyFlowOpenApi' 自動跟著變,這個模組的輸出不需要任何人手動同步。
module StoryFlow.Mcp.Tools
  ( Tool (..)
  , toolsFromOpenApi
  , lookupTool
  ) where

import Control.Lens ((^.))
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key as AK
import Data.Aeson.Key (Key)
import qualified Data.HashMap.Strict.InsOrd as IOM
import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.OpenApi
  ( OpenApi
  , Operation
  , Param
  , PathItem
  , Reference (..)
  , Referenced (..)
  , RequestBody
  , components
  , content
  , delete
  , get
  , name
  , operationId
  , parameters
  , patch
  , paths
  , post
  , put
  , requestBodies
  , requestBody
  , required
  , schema
  , summary
  )
import Data.Text (Text)
import qualified Data.Text as T

-- | 一個 MCP tool。與 REST operation 一一對應——'toolPath' \/ 'toolMethod'
-- 是 'StoryFlow.Mcp.Client.invoke' 組 HTTP 請求要用的路徑模板與方法,
-- 'toolInputSchema' 是 @tools\/list@ 直接回給客戶端的 JSON schema。
data Tool = Tool
  { toolName :: Text
  , toolDescription :: Text
  , toolPath :: Text
  -- ^ 路徑模板,原樣保留大括號(如 @\"\/entities\/{id}\/links\"@)。
  , toolMethod :: Text
  -- ^ 小寫:@\"get\"@ \/ @\"post\"@ \/ @\"patch\"@ \/ @\"put\"@ \/ @\"delete\"@。
  , toolInputSchema :: Value
  }
  deriving stock (Show, Eq)

-- | 從靜態的 'OpenApi' 值反推全部 Tool,不連線、不需要 IO。
toolsFromOpenApi :: OpenApi -> [Tool]
toolsFromOpenApi doc =
  [ toolFor doc path verb op
  | (path, item) <- IOM.toList (doc ^. paths)
  , (verb, Just op) <- verbsOf item
  ]

-- | 依 tool 名字反查。名字不存在時回 'Nothing'——'StoryFlow.Mcp.Server' 據此
-- 決定回 JSON-RPC error @-32602@,而不是硬湊一個假 'Tool'。
lookupTool :: Text -> [Tool] -> Maybe Tool
lookupTool n = find ((== n) . toolName)

-- 內部 -------------------------------------------------------------------------

verbsOf :: PathItem -> [(Text, Maybe Operation)]
verbsOf item =
  [ ("get", item ^. get)
  , ("post", item ^. post)
  , ("patch", item ^. patch)
  , ("put", item ^. put)
  , ("delete", item ^. delete)
  ]

toolFor :: OpenApi -> FilePath -> Text -> Operation -> Tool
toolFor doc path verb op =
  Tool
    { toolName = maybe "" id (op ^. operationId)
    , toolDescription = maybe "" id (op ^. summary)
    , toolPath = T.pack path
    , toolMethod = verb
    , toolInputSchema = inputSchemaFor doc op
    }

-- | @op ^. parameters@ 的每一筆(path 或 query 參數)貢獻一個同名鍵;若有
-- @requestBody@ 再貢獻一個 @\"body\"@ 鍵(巢狀 \$ref,見 design.md「為什麼 body
-- 用巢狀」段)。@required@ = 全部必填參數名,加上(有 requestBody 時)@\"body\"@
-- ——REST 的 'Servant.API.ReqBody' 本來就是必填的。
inputSchemaFor :: OpenApi -> Operation -> Value
inputSchemaFor doc op =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object (paramProps <> bodyProp)
    , "required" .= (paramRequired <> bodyRequired)
    ]
  where
    resolvedParams = mapMaybe (resolveParam doc) (op ^. parameters)
    paramProps :: [(Key, Value)]
    paramProps =
      [(AK.fromText (p ^. name), maybe Null toJSON (p ^. schema)) | p <- resolvedParams]
    paramRequired = [p ^. name | p <- resolvedParams, p ^. required == Just True]
    bodySchema = op ^. requestBody >>= resolveRequestBody doc >>= firstJsonSchema
    bodyProp :: [(Key, Value)]
    bodyProp = maybe [] (\s -> [(AK.fromText "body", s)]) bodySchema
    bodyRequired = maybe [] (const ["body"]) bodySchema

resolveParam :: OpenApi -> Referenced Param -> Maybe Param
resolveParam _ (Inline p) = Just p
resolveParam doc (Ref (Reference n)) = IOM.lookup n (doc ^. components . parameters)

resolveRequestBody :: OpenApi -> Referenced RequestBody -> Maybe RequestBody
resolveRequestBody _ (Inline rb) = Just rb
resolveRequestBody doc (Ref (Reference n)) = IOM.lookup n (doc ^. components . requestBodies)

-- | 取 requestBody 內容裡__第一個__ media type 的 schema(這份 API 一律只有
-- @application\/json@ 一種)。不特意比對 @Network.HTTP.Media.MediaType@ 的鍵,
-- 避免只為了這一次查找多拉一個套件相依。
firstJsonSchema :: RequestBody -> Maybe Value
firstJsonSchema rb = case IOM.elems (rb ^. content) of
  (mto : _) -> toJSON <$> (mto ^. schema)
  [] -> Nothing
