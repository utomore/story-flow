-- | T4:路由涵蓋 service 的全部操作,而且 @revision@ 必填。
--
-- 驗收標準 1 是「沒有只有 CLI 做得到的事」。它的可測形式是:API 的 operation 數
-- 等於 service-and-interfaces/F001 的業務操作數,而且每一個操作都找得到對應的路由。
--
-- @revision@ 必填在型別層就成立了(@QueryParam' '[Required]@ ——省略它的
-- @servant-client@ 呼叫根本編譯不過),所以這裡驗的是__同一件事的文件面__:
-- OpenAPI 把它標成 @required: true@,照文件寫的 Agent 才不會漏掉它。
module StoryFlow.Api.ApiSpec (spec) where

import Control.Lens ((^.))
import qualified Data.HashMap.Strict.InsOrd as IOM
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.OpenApi
  ( OpenApi
  , Operation
  , Param
  , PathItem
  , delete
  , get
  , name
  , parameters
  , patch
  , paths
  , post
  , put
  , Referenced (Inline)
  , required
  )
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Api (storyFlowOpenApi)
import Test.Hspec

spec :: Spec
spec = describe "API 契約" $ do
  -- conflict-detection/F004:23 → 24。多的那一個是 POST /conflict/context,
  -- 它對應的不是 service-and-interfaces/F001 的業務操作,而是
  -- conflict-detection 的對外契約 gatherContext ——所以下面 expectedRoutes 那張
  -- 表分成兩段,兩份來源清單各自對得上帳。
  it "operation 數等於 service 的 23 個業務操作 + conflict 的 1 個出口" $
    length allOperations `shouldBe` 24

  it "service-and-interfaces/F001 的每個操作都有對應的路由" $
    sort (map fst expectedRoutes) `shouldBe` sort (map fst actualRoutes)

  it "路徑與方法逐條相符" $
    sort expectedRoutes `shouldBe` sort actualRoutes

  it "每個寫入端點都有 required 的 revision" $
    mapM_ hasRequiredRevision revisionRoutes

  it "唯讀端點沒有 revision" $
    mapM_ (\k -> revisionParamOf k `shouldBe` Nothing) readOnlyRoutes

  it "加片段沒有 revision(service 自己讀,收一個不用的參數是說謊)" $
    revisionParamOf ("/entities/{id}/fragments", "post") `shouldBe` Nothing

-- | service-and-interfaces/F001 的 23 個業務操作各對應一條路由。
--
-- 手寫這張表而不是從型別推導,是刻意的:它是 service-and-interfaces/F001 那份清單的__獨立副本__,
-- 兩邊對不上時才有東西可以比。從型別推導出來的清單只會永遠等於它自己。
expectedRoutes :: [(Text, Text)]
expectedRoutes =
  [ ("/vaults", "get") -- listVaults
  , ("/vaults", "post") -- createVault
  , ("/vault", "get") -- vaultInfo
  , ("/vault/index/rebuild", "post") -- reindex
  , ("/vault/index/refresh", "post") -- refreshIndex
  , ("/types", "get") -- listEntityTypes
  , ("/entities", "get") -- listEntities
  , ("/entities", "post") -- createEntity
  , ("/entities/{id}", "get") -- getEntity
  , ("/entities/{id}", "patch") -- updateEntity
  , ("/entities/{id}", "delete") -- deleteEntity
  , ("/entities/{id}/body", "put") -- setEntityBody
  , ("/entities/{id}/fragments", "post") -- addFragment
  , ("/entities/{id}/links", "get") -- linksOf
  , ("/entities/{id}/links", "post") -- addLink
  , ("/entities/{id}/links", "delete") -- removeLink
  , ("/search", "get") -- searchEntity
  , ("/levels", "get") -- listLevels
  , ("/levels", "post") -- createLevel
  , ("/levels/{id}", "get") -- getLevel
  , ("/levels/{id}", "delete") -- deleteLevel
  , ("/nodes/{id}", "post") -- addNode
  , ("/nodes/{id}", "delete") -- removeNode
  ]
    ++ conflictRoutes

-- | conflict-detection 的對外契約。
--
-- 目前只有 @gatherContext@ 這一個出口(F004);階段二的 @checkConflict@(F006)
-- 會加上 @POST \/conflict\/check@。分成獨立的一張表而不是併進上面那張:那一張的
-- 註解說得很清楚,它是 service-and-interfaces/F001 業務操作清單的獨立副本,把
-- 別的子系統的出口混進去會讓「兩邊對不上時有東西可比」這件事失效。
conflictRoutes :: [(Text, Text)]
conflictRoutes = [("/conflict/context", "post")] -- gatherContext

-- | 全部會__覆蓋既有內容__的端點:樂觀鎖在遠端模式一樣生效,沒有逃生口。
--
-- @POST \/entities\/{id}\/fragments@ __不在這張表裡__,而且那是對的:service 的
-- @addFragment@ 自己讀主體的 revision(加一個片段不覆蓋任何東西),收一個不參與
-- 判斷的必填參數只會讓客戶端誤以為有保護。下面另有一條測試釘住它確實沒有。
revisionRoutes :: [(Text, Text)]
revisionRoutes =
  [ ("/entities/{id}", "patch")
  , ("/entities/{id}", "delete")
  , ("/entities/{id}/body", "put")
  , ("/entities/{id}/links", "post")
  , ("/entities/{id}/links", "delete")
  , ("/levels/{id}", "delete")
  , ("/nodes/{id}", "post")
  , ("/nodes/{id}", "delete")
  ]

-- | 讀取端點不該有 revision ——它是樂觀鎖的東西,出現在 GET 上只會讓人以為
-- 讀取也要帶版本。
-- | @POST \/conflict\/context@ 在這張表裡:它的方法是 @POST@(草稿是一段長文字,
-- 塞不進 query parameter),但整條路徑__只讀不寫__ ——樂觀鎖在它身上沒有意義。
readOnlyRoutes :: [(Text, Text)]
readOnlyRoutes =
  [ ("/entities", "get")
  , ("/entities/{id}", "get")
  , ("/levels/{id}", "get")
  , ("/search", "get")
  , ("/conflict/context", "post")
  ]

-- 從 OpenAPI 文件取出實際的路由 ---------------------------------------------------

doc :: OpenApi
doc = storyFlowOpenApi

actualRoutes :: [(Text, Text)]
actualRoutes =
  [ (T.pack p, verb)
  | (p, item) <- IOM.toList (doc ^. paths)
  , (verb, Just _) <- verbsOf item
  ]

allOperations :: [Operation]
allOperations = [op | (_, item) <- IOM.toList (doc ^. paths), (_, Just op) <- verbsOf item]

verbsOf :: PathItem -> [(Text, Maybe Operation)]
verbsOf item =
  [ ("get", item ^. get)
  , ("post", item ^. post)
  , ("patch", item ^. patch)
  , ("put", item ^. put)
  , ("delete", item ^. delete)
  ]

operationAt :: (Text, Text) -> Maybe Operation
operationAt (p, verb) = do
  item <- IOM.lookup (T.unpack p) (doc ^. paths)
  lookup verb (verbsOf item) >>= id

revisionParamOf :: (Text, Text) -> Maybe Param
revisionParamOf k = do
  op <- operationAt k
  let ps = mapMaybe inline (op ^. parameters)
  lookup "revision" [(pr ^. name, pr) | pr <- ps]
  where
    inline r = case r of
      Inline pr -> Just pr
      _ -> Nothing

hasRequiredRevision :: (Text, Text) -> Expectation
hasRequiredRevision k = case revisionParamOf k of
  Nothing -> expectationFailure (show k <> " 少了 revision query parameter")
  Just pr -> (k, pr ^. required) `shouldBe` (k, Just True)
