-- | T15:內嵌與遠端輸出完全相同。
--
-- 這是 service-and-interfaces/F003 的驗收標準 4。作法是__同一個 Vault__ 同時以兩種模式操作:
-- 'withCliServer' 起的伺服器綁在測試剛建好的那個臨時 Vault 上,所以兩邊看到的是
-- 同一份資料、同一批 id。輸出若有差,就真的是渲染路徑的差,不是資料的差。
--
-- 讀取指令逐字元比對;寫入指令不能跑兩次(會改到狀態),所以改驗「遠端寫、內嵌讀
-- 得到」與「同一個失敗在兩邊的信封相同」。
module StoryFlow.Cli.ParitySpec (spec) where

import Data.Aeson (Value (String), encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types.Status (status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import StoryFlow.Cli.Fixtures
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "內嵌與遠端的輸出" $ do
  describe "人類可讀模式逐字元相等" $
    it "七條讀取指令的 stdout 一模一樣" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameHuman url) readCommands

  describe "--json 模式逐字元相等" $
    it "同樣那七條的信封一模一樣" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameJson url) readCommands

  describe "錯誤路徑" $ do
    it "業務錯誤的 code 與 message 在兩邊相同" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameJson url) errorCommands

    it "人類模式的錯誤訊息也逐字元相同" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameHumanErr url) errorCommands

    it "exit code 在兩邊相同" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameExit url) (readCommands <> errorCommands)

  describe "寫入" $ do
    it "遠端寫進去的,內嵌讀得到" $ withCliServer $ \_ url -> do
      seedVault
      _ <- sfRemote url ["entity", "set", "琳達", "--summary", "遠端改的"]
      out <- sfOk ["entity", "show", "琳達"]
      out `shouldContainT` "遠端改的"

    it "內嵌寫進去的,遠端讀得到" $ withCliServer $ \_ url -> do
      seedVault
      _ <- sfOk ["entity", "set", "琳達", "--summary", "內嵌改的"]
      r <- sfRemote url ["entity", "show", "琳達"]
      crOut r `shouldContainT` "內嵌改的"

    it "寫入後兩邊的讀取輸出仍然逐字元相等" $ withCliServer $ \_ url -> do
      seedVault
      _ <- sfRemote url ["entity", "set", "琳達", "--summary", "改過一次"]
      mapM_ (sameHuman url) readCommands

  -- llm-workshop-mcp/F004 T21:session id 在兩種介面裡是同一個東西——同一份
  -- .storyflow/workshops/<id>.json,CLI 開的 session 用 REST 接得下去,反之亦然。
  describe "workshop(llm-workshop-mcp/F004)" $ do
    it "CLI 開的 session,REST 用同一個 id 接得到 step" $ withCliServerLlm draftReply $ \_ url -> do
      startOut <- sfOk ["workshop", "start", "--type", "character-fragment"]
      let sid = sessionIdFromStartOut startOut
      r <- sfRemote url ["workshop", "step", sid, "--input", "使用者輸入"]
      crExit r `shouldBe` ExitSuccess

    it "REST 開的 session,CLI 接得到 commit" $ withCliServerLlm draftReply $ \_ url -> do
      startEnv <- sfRemoteJson url ["workshop", "start", "--type", "character-fragment"]
      let sid = T.unpack (sessionIdOf startEnv)
      _ <- sfRemote url ["workshop", "step", sid, "--input", "使用者輸入"]
      r <- sf ["workshop", "commit", sid]
      crExit r `shouldBe` ExitSuccess

    it "workshop step 不存在的 id,錯誤 code/message 兩邊相同" $ withCliServer $ \_ url -> do
      emb <- sfJson ["workshop", "step", "wksp-00000000", "--input", "x"]
      rem' <- sfRemoteJson url ["workshop", "step", "wksp-00000000", "--input", "x"]
      jsonPath ["error", "code"] emb `shouldBe` jsonPath ["error", "code"] rem'
      jsonPath ["error", "message"] emb `shouldBe` jsonPath ["error", "message"] rem'

-- | 兩種模式都要看得到的內容:主體 + 片段 + 關聯 + 一個 Level。
seedVault :: IO ()
seedVault = do
  linda <-
    idFromJson
      <$> sfJson
        ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "埃提亞的第七織手", "--status", "canon"]
  _ <-
    sfOk
      [ "entity"
      , "add"
      , "琳達"
      , "--title"
      , "外貌"
      , "--type"
      , "character-fragment"
      , "--summary"
      , "銀灰短髮,左眼下方有織紋刺青"
      , "--link"
      , "partOf:" <> linda
      ]
  _ <-
    sfOk
      ["level", "new", "--title", "教室", "--summary", "崩塌後的午後教室", "--root-title", "午後的教室", "--root-kind", "scene"]
  _ <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
  pure ()

-- | 讀取指令:跑幾次都不改狀態,所以可以兩種模式各跑一次再逐字元比對。
readCommands :: [[String]]
readCommands =
  [ ["vault", "info"]
  , ["type", "list"]
  , ["entity", "list"]
  , ["entity", "show", "琳達"]
  , ["link", "list", "外貌"]
  , ["level", "show", "教室"]
  , ["search", "織紋刺青"]
  ]

-- | 失敗案例:兩邊的 code 與 message 都要一致。
errorCommands :: [[String]]
errorCommands =
  [ ["entity", "show", "ent-00000000"]
  , ["entity", "show", "沒這個人"]
  , ["entity", "new", "--type", "沒這種型別", "--title", "x", "--summary", "s"]
  , ["level", "show", "沒這個場景"]
  , ["entity", "set", "琳達", "--summary", "x", "--revision", "999"]
  ]

sameHuman :: String -> [String] -> Expectation
sameHuman url args = do
  emb <- sf args
  rem' <- sfRemote url args
  labelled args (crOut emb) (crOut rem')

sameHumanErr :: String -> [String] -> Expectation
sameHumanErr url args = do
  emb <- sf args
  rem' <- sfRemote url args
  labelled args (crErr emb) (crErr rem')

sameJson :: String -> [String] -> Expectation
sameJson url args = do
  emb <- capture ("--vault" : "liftgame" : "--json" : args)
  rem' <- capture ("--remote" : url : "--json" : args)
  labelled args (crOut emb) (crOut rem')

sameExit :: String -> [String] -> Expectation
sameExit url args = do
  emb <- sf args
  rem' <- sfRemote url args
  (unwords args, crExit emb) `shouldBe` (unwords args, crExit rem' :: ExitCode)

-- | 比對失敗時要看得出是哪一條指令,不然一堆中文字裡找不到差在哪。
labelled :: [String] -> Text -> Text -> Expectation
labelled args a b
  | a == b = pure ()
  | otherwise =
      expectationFailure . T.unpack $
        "指令「"
          <> T.pack (unwords args)
          <> "」兩種模式的輸出不同。\n內嵌:\n"
          <> a
          <> "\n遠端:\n"
          <> b

-- 工作坊的底稿(llm-workshop-mcp/F004) ---------------------------------------------

draftReply :: Text
draftReply =
  T.unlines
    [ "以下是這個階段可以定案的草稿。"
    , "```json"
    , "[{\"title\":\"外貌\",\"summary\":\"銀灰短髮\",\"body\":\"銀灰短髮剪到耳際……\",\"tags\":[\"外觀\"]}]"
    , "```"
    ]

-- | 從 @renderWorkshopStarted@ 的人類輸出「已建立工作坊 wksp-xxxx(…)」擷取 id。
sessionIdFromStartOut :: Text -> String
sessionIdFromStartOut =
  T.unpack . T.takeWhile (/= '(') . T.strip . T.drop (T.length prefix)
  where
    prefix = "已建立工作坊 "

sessionIdOf :: Value -> Text
sessionIdOf env = case jsonPath ["data", "id"] env of
  Just (String sid) -> sid
  other -> error ("data.id 取不到:" <> show other)

-- | 與 'withCliServer' 相同,但多起一個本機 stub 端點並把伺服器綁定的那個
-- Vault 的 @[llm]@ 段指過去。
withCliServerLlm :: Text -> (FilePath -> String -> IO a) -> IO a
withCliServerLlm reply act =
  withLlmStub reply $ \port ->
    withCliServer $ \dir url -> do
      appendLlmConfig dir port
      act dir url

withLlmStub :: Text -> (Int -> IO a) -> IO a
withLlmStub reply act = Warp.testWithApplication (pure (stubApp reply)) act

stubApp :: Text -> Wai.Application
stubApp reply _req respond =
  respond $
    Wai.responseLBS status200 [("Content-Type", "application/json")] (chatCompletion reply)

chatCompletion :: Text -> LBS.ByteString
chatCompletion content =
  encode $
    object
      [ "id" .= ("chatcmpl-stub" :: Text)
      , "object" .= ("chat.completion" :: Text)
      , "created" .= (1755648000 :: Int)
      , "model" .= ("qwen2.5-14b-instruct" :: Text)
      , "choices"
          .= [ object
                 [ "index" .= (0 :: Int)
                 , "finish_reason" .= ("stop" :: Text)
                 , "message" .= object ["role" .= ("assistant" :: Text), "content" .= content]
                 ]
             ]
      ]

appendLlmConfig :: FilePath -> Int -> IO ()
appendLlmConfig dir port = do
  let fp = dir </> ".storyflow" </> "config.toml"
  old <- TE.decodeUtf8 <$> BS.readFile fp
  BS.writeFile
    fp
    ( TE.encodeUtf8
        ( old
            <> T.unlines
              [ ""
              , "[llm]"
              , "base_url = \"http://127.0.0.1:" <> T.pack (show port) <> "/v1\""
              , "model = \"qwen2.5-14b-instruct\""
              ]
        )
    )
