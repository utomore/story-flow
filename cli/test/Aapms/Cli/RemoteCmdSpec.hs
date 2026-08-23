-- | T14:每個子指令的遠端路徑都可用。
--
-- 逐一在遠端模式跑過每個子指令,斷言 exit code 是 0 且 @--json@ 的 @data@ 解得開。
-- 這是「沒有只有內嵌模式做得到的事」的可測形式。
module Aapms.Cli.RemoteCmdSpec (spec) where

import Data.Aeson (Value (Array, Bool, Object, String), decodeStrict, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Network.HTTP.Types.Status (status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Aapms.Cli.Fixtures
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, hSetEncoding, openFile, utf8)
import Test.Hspec

spec :: Spec
spec = describe "遠端模式的每個子指令" $ do
  it "vault list / info" $ withCliServer $ \_ url -> do
    okJson url ["vault", "list"]
    okJson url ["vault", "info"]

  it "index rebuild / refresh" $ withCliServer $ \_ url -> do
    okJson url ["index", "rebuild"]
    okJson url ["index", "refresh"]

  it "type list" $ withCliServer $ \_ url -> okJson url ["type", "list"]

  it "entity new / show / list / add" $ withCliServer $ \_ url -> do
    okJson url ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    okJson url ["entity", "show", "琳達"]
    okJson url ["entity", "list"]
    okJson url ["entity", "add", "琳達", "--title", "外貌", "--summary", "銀灰短髮", "--type", "character-fragment"]

  it "entity set / set-body / rm" $ withCliServer $ \_ url -> do
    okJson url ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "s"]
    okJson url ["entity", "set", "琳達", "--summary", "改過的"]
    okJson url ["entity", "set-body", "琳達", "--body", "遠端寫的正文"]
    okJson url ["entity", "rm", "琳達", "--force"]

  it "entity set-body 從 stdin 讀" $ withCliServer $ \_ url -> do
    okJson url ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "s"]
    r <- captureIn "從 stdin 來的" ["--remote", url, "entity", "set-body", "琳達", "-"]
    crExit r `shouldBe` ExitSuccess
    out <- sfOk ["entity", "show", "琳達"]
    out `shouldContainT` "從 stdin 來的"

  it "search" $ withCliServer $ \_ url -> do
    okJson url ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "埃提亞的第七織手"]
    okJson url ["search", "第七織手"]

  it "link add / list / rm" $ withCliServer $ \_ url -> do
    a <- idFromJson <$> sfRemoteJson url ["entity", "new", "--type", "character-fragment", "--title", "琳達", "--summary", "s"]
    _ <- sfRemoteJson url ["entity", "new", "--type", "character-fragment", "--title", "外貌", "--summary", "s"]
    okJson url ["link", "add", "外貌", "--kind", "partOf", "--target", a]
    okJson url ["link", "list", "外貌"]
    okJson url ["link", "rm", "外貌", "--kind", "partOf", "--target", a]

  it "非核心 kind 的提示在遠端模式也出現" $ withCliServer $ \_ url -> do
    a <- idFromJson <$> sfRemoteJson url ["entity", "new", "--type", "character-fragment", "--title", "琳達", "--summary", "s"]
    _ <- sfRemoteJson url ["entity", "new", "--type", "character-fragment", "--title", "外貌", "--summary", "s"]
    r <- sfRemote url ["link", "add", "外貌", "--kind", "contradict", "--target", a]
    crExit r `shouldBe` ExitSuccess
    crErr r `shouldContainT` "contradicts"

  it "level new / show / list / rm" $ withCliServer $ \_ url -> do
    okJson url ["level", "new", "--title", "教室", "--root-title", "午後的教室", "--root-kind", "scene"]
    okJson url ["level", "show", "教室"]
    okJson url ["level", "list"]
    okJson url ["level", "rm", "教室"]

  it "node add / rm" $ withCliServer $ \_ url -> do
    okJson url ["level", "new", "--title", "教室", "--root-title", "午後的教室", "--root-kind", "scene"]
    okJson url ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    okJson url ["node", "rm", "出場人物"]

  it "vault init 在遠端模式打到伺服器,不是在本機建" $ withCliServer $ \dir url -> do
    r <- sfRemote url ["vault", "init", dir <> "/second", "--name", "second"]
    -- 不論成功與否,它都不該是「解析不出指令」或崩潰
    crExit r `shouldNotBe` ExitFailure 2

  -- conflict-detection/F006 T10:conflict check 的遠端路徑。伺服器沒有設定
  -- [llm] 段,所以第 3 層一律退化——這正是 D6 hermetic 的作法:不需要真端點,
  -- --no-llm 真的傳到伺服器就足以觀察退化原因的差別。
  describe "conflict check 的遠端路徑" $ do
    it "exit 0,而且 --json 的 data 是合法的 ConflictReport" $ withCliServer $ \dir url -> do
      f <- draftFile dir "琳達走進廢墟"
      r <- sfRemote url ["conflict", "check", "--draft", f]
      crExit r `shouldBe` ExitSuccess
      env <- sfRemoteJson url ["conflict", "check", "--draft", f]
      jsonPath ["data", "hits"] env `shouldSatisfy` isJustV
      jsonPath ["data", "scanned"] env `shouldSatisfy` isJustV
      jsonPath ["data", "llm_used"] env `shouldSatisfy` isJustV
      jsonPath ["data", "notes"] env `shouldSatisfy` isJustV

    it "--no-llm 真的傳到伺服器:notes 是 judge_disabled 而不是 judge_not_configured" $
      withCliServer $ \dir url -> do
        -- 退化 note 只在候選非空時才產生,所以要先讓第 2 層真的撈到東西。
        okJson url ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手", "--status", "canon"]
        f <- draftFile dir "琳達走進廢墟"
        env <- sfRemoteJson url ["conflict", "check", "--draft", f, "--no-llm"]
        firstNoteCode env `shouldBe` Just "judge_disabled"

    it "沒有 --no-llm、伺服器也沒設定 [llm] 時退化成 judge_not_configured,指令仍然 exit 0" $
      withCliServer $ \dir url -> do
        okJson url ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手", "--status", "canon"]
        f <- draftFile dir "琳達走進廢墟"
        r <- sfRemote url ["conflict", "check", "--draft", f]
        crExit r `shouldBe` ExitSuccess
        env <- sfRemoteJson url ["conflict", "check", "--draft", f]
        firstNoteCode env `shouldBe` Just "judge_not_configured"

  -- llm-workshop-mcp/F004 T19:workshop 三指令的遠端路徑。
  describe "workshop 的遠端路徑" $ do
    it "start / step / commit 全部 exit 0,--json 的 data 解得開" $
      withCliServerLlm draftReply $ \_ url -> do
        startEnv <- sfRemoteJson url ["workshop", "start", "--type", "character-fragment"]
        let sid = T.unpack (sessionIdOf startEnv)
        stepEnv <- sfRemoteJson url ["workshop", "step", sid, "--input", "使用者輸入"]
        jsonPath ["data", "reply"] stepEnv `shouldSatisfy` isJustV
        commitEnv <- sfRemoteJson url ["workshop", "commit", sid]
        jsonPath ["data", "entities"] commitEnv `shouldSatisfy` isJustV

    it "不存在的 session id 遠端也回 workshop_session_not_found" $ withCliServer $ \_ url -> do
      env <- sfRemoteJson url ["workshop", "step", "wksp-00000000", "--input", "x"]
      env `shouldHaveCode` "workshop_session_not_found"

-- | @data.notes@ 的第一筆 @code@。'jsonPath' 只往 'Object' 裡鑽,不索引
-- 'Array',所以陣列這一段自己拆。
firstNoteCode :: Value -> Maybe T.Text
firstNoteCode env = case jsonPath ["data", "notes"] env of
  Just (Array xs) -> case toList xs of
    (note : _) -> case jsonPath ["code"] note of
      Just (String t) -> Just t
      _ -> Nothing
    [] -> Nothing
  _ -> Nothing

-- | 把草稿寫成 UTF-8 檔案,回它的路徑(與 "Aapms.Cli.ContextCmdSpec" 同一份寫法)。
draftFile :: FilePath -> T.Text -> IO FilePath
draftFile dir txt = do
  let p = dir </> "draft.md"
  h <- openFile p WriteMode
  hSetEncoding h utf8
  TIO.hPutStr h txt
  hClose h
  pure p

isJustV :: Maybe Value -> Bool
isJustV = maybe False (const True)

-- 工作坊的遠端路徑底稿(llm-workshop-mcp/F004) ------------------------------------

draftReply :: Text
draftReply =
  T.unlines
    [ "以下是這個階段可以定案的草稿。"
    , "```json"
    , "[{\"title\":\"外貌\",\"summary\":\"銀灰短髮\",\"body\":\"銀灰短髮剪到耳際……\",\"tags\":[\"外觀\"]}]"
    , "```"
    ]

sessionIdOf :: Value -> Text
sessionIdOf env = case jsonPath ["data", "id"] env of
  Just (String sid) -> sid
  other -> error ("data.id 取不到:" <> show other)

-- | 與 'withCliServer' 相同,但多起一個本機 stub 端點並把伺服器綁定的那個
-- Vault 的 @[llm]@ 段指過去——@Env@ 延遲取得,寫檔發生在第一個請求之前。
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

-- | 跑__一次__遠端指令,從那一次的結果同時斷言 exit code 與信封。
--
-- 刻意只跑一次:這些指令多半有副作用,跑兩次的話第二次會撞上「同名的東西已經
-- 有了」,而後面以標題定址的步驟就會變成 @title_ambiguous@ ——那是測試自己製造的
-- 失敗,不是被測程式的問題。
okJson :: String -> [String] -> Expectation
okJson url args = do
  r <- sfRemote url ("--json" : args)
  case decodeStrict (TE.encodeUtf8 (crOut r)) of
    Nothing ->
      expectationFailure $
        unwords args <> " 的 stdout 不是合法 JSON:" <> T.unpack (crOut r) <> T.unpack (crErr r)
    Just env -> do
      (unwords args, crExit r) `shouldBe` (unwords args, ExitSuccess)
      (unwords args, jsonPath ["ok"] env) `shouldBe` (unwords args, Just (Bool True))
      case (jsonPath ["data"] env, env) of
        (Just _, Object _) -> pure ()
        _ -> expectationFailure (unwords args <> " 的信封形狀不對:" <> show env)
