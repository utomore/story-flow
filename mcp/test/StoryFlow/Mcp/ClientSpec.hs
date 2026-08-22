-- | T7:'StoryFlow.Mcp.Client' 的連線探測與實際呼叫。
--
-- 起本機 warp stub 模擬 @story-flow-serve@(見 'StoryFlow.Mcp.Fixtures'),
-- 不寫死埠號、不用固定長 sleep——與 llm\/workshop 兩個子系統既有的 Fixtures
-- 同一個先例。
module StoryFlow.Mcp.ClientSpec (spec) where

import Data.Aeson (Value (..), decode, object, (.=))
import qualified Data.ByteString.Char8 as BS8
import Network.HTTP.Types.URI (parseQuery)
import StoryFlow.Mcp.Client (invoke, probe)
import StoryFlow.Mcp.Fixtures
import StoryFlow.Mcp.Tools (Tool (..))
import Test.Hspec

-- | 一個手造的 Tool——path 帶一個路徑參數 @id@、一個 query 參數 @revision@、
-- 一個 requestBody(@\"body\"@ 鍵)。不用真正的 storyFlowOpenApi 反推,是刻意
-- 的:這個模組只測「Client 依這個形狀組出正確的 HTTP 請求」,不重複
-- 'StoryFlow.Mcp.ToolsSpec' 已經測過的反推邏輯。
patchEntityTool :: Tool
patchEntityTool =
  Tool
    { toolName = "patchEntitiesById"
    , toolDescription = "改 Meta 欄位"
    , toolPath = "/entities/{id}"
    , toolMethod = "patch"
    , toolInputSchema =
        object
          [ "type" .= ("object" :: String)
          , "properties" .= object []
          , "required" .= (["id", "revision", "body"] :: [String])
          ]
    }

spec :: Spec
spec = do
  describe "probe" $ do
    it "打得到 GET /vaults、回 2xx 時成功" $
      withStub [rule "GET" "/vaults" 200 (Array mempty)] $ \stub -> do
        r <- probe (configFor (stubPort stub))
        r `shouldBe` Right ()

    it "連不上時分類成 remote_unavailable" $
      withDeadPort $ \port -> do
        r <- probe (configFor port)
        case r of
          Left ("remote_unavailable", _) -> pure ()
          other -> expectationFailure ("expected Left remote_unavailable, got " <> show other)

    it "伺服器回 401 時,原樣沿用伺服器的 code/message" $
      withStub
        [rule "GET" "/vaults" 401 (object ["error" .= object ["code" .= ("unauthorized" :: String), "message" .= ("no token" :: String)]])]
        $ \stub -> do
          r <- probe (configFor (stubPort stub))
          r `shouldBe` Left ("unauthorized", "no token")

  describe "invoke——成功案例(path + query + body 都要對)" $
    it "組出正確的 HTTP 請求,並把 2xx 的 body 原樣解成 Value 回傳" $
      withStub [rule "PATCH" "/entities/ent-1" 200 (object ["id" .= ("ent-1" :: String), "revision" .= (4 :: Int)])] $ \stub -> do
        let args = object ["id" .= ("ent-1" :: String), "revision" .= (3 :: Int), "body" .= object ["summary" .= ("new" :: String)]]
        result <- invoke (configFor (stubPort stub)) patchEntityTool args
        result `shouldBe` Right (object ["id" .= ("ent-1" :: String), "revision" .= (4 :: Int)])
        reqs <- stubRequests stub
        case reqs of
          [r] -> do
            rrMethod r `shouldBe` "PATCH"
            rrPath r `shouldBe` "/entities/ent-1"
            lookup "revision" (parseQuery (queryOf r)) `shouldBe` Just (Just "3")
            (decode (rrBody r) :: Maybe Value) `shouldBe` Just (object ["summary" .= ("new" :: String)])
          other -> expectationFailure ("expected exactly one recorded request, got " <> show (length other))

  describe "invoke——REST 業務錯誤" $
    it "原樣轉出伺服器的 error.code / error.message" $
      withStub
        [rule "PATCH" "/entities/ent-1" 409 (object ["error" .= object ["code" .= ("stale_revision" :: String), "message" .= ("revision 過期" :: String)]])]
        $ \stub -> do
          let args = object ["id" .= ("ent-1" :: String), "revision" .= (3 :: Int), "body" .= object []]
          result <- invoke (configFor (stubPort stub)) patchEntityTool args
          result `shouldBe` Left ("stale_revision", "revision 過期")

  describe "invoke——傳輸失敗" $
    it "stub 直接斷線時分類成 remote_unavailable" $
      withDeadPort $ \port -> do
        let args = object ["id" .= ("ent-1" :: String), "revision" .= (3 :: Int), "body" .= object []]
        result <- invoke (configFor port) patchEntityTool args
        case result of
          Left ("remote_unavailable", _) -> pure ()
          other -> expectationFailure ("expected Left remote_unavailable, got " <> show other)

-- | 把 'Network.Wai.queryString' 的紀錄重編回一段 query bytestring,方便用
-- 'Network.HTTP.Types.URI.parseQuery' 統一比對(避免直接比對 tuple 順序)。
queryOf :: RecordedRequest -> BS8.ByteString
queryOf r = BS8.intercalate "&" (map one (rrQuery r))
  where
    one (k, Nothing) = k
    one (k, Just v) = k <> "=" <> v
