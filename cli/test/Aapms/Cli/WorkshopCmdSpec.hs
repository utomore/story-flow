-- | T17(llm-workshop-mcp/F004):@workshop start@ \/ @step@ \/ @commit@,內嵌模式。
--
-- 仿 "Aapms.Cli.ContextCmdSpec" 的形狀:一個真的跑在本機的 OpenAI 相容 stub
-- 端點(@step@ 需要它),把臨時 Vault 的 @.storyflow\/config.toml@ 指過去
-- ——與 @llm\/test\/Aapms\/Llm\/Fixtures.hs@ 的 @appendConfig@ 同一份寫法。
module Aapms.Cli.WorkshopCmdSpec (spec) where

import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types.Status (status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Aapms.Cli.Fixtures
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "workshop start" $ do
    it "內嵌模式 exit 0,人類輸出印出 session id" $ withCliVault $ \_ -> do
      out <- sfOk ["workshop", "start", "--type", "character-fragment"]
      out `shouldContainT` "已建立工作坊 wksp-"

    it "--json 的 data 是完整的 Session,data.id 帶著 session id" $ withCliVault $ \_ -> do
      env <- sfJson ["workshop", "start", "--type", "character-fragment"]
      case jsonPath ["data", "id"] env of
        Just (String sid) -> "wksp-" `T.isPrefixOf` sid `shouldBe` True
        other -> expectationFailure ("data.id 取不到:" <> show other)

    it "--constraint 可重複,寫進 constraints" $ withCliVault $ \_ -> do
      linda <-
        idFromJson
          <$> sfJson
            ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
      env <- sfJson ["workshop", "start", "--type", "character-fragment", "--constraint", linda]
      case jsonPath ["data", "constraints"] env of
        Just (Array xs) -> map asString (toList xs) `shouldContain` [T.pack linda]
        other -> expectationFailure ("data.constraints 取不到:" <> show other)

    it "型別不存在時是業務失敗(unknown_type),不是用法錯誤" $ withCliVault $ \_ -> do
      r <- sf ["workshop", "start", "--type", "沒這種型別"]
      crExit r `shouldBe` ExitFailure 1
      crErr r `shouldContainT` "unknown_type"

  describe "workshop step / commit(需要本機 LLM stub)" $ do
    it "step 的人類輸出是模型回覆本身,commit 定案後印出已定案" $
      withCliVaultLlm draftReply $ \_ -> do
        sid <- sessionIdOf <$> sfJson ["workshop", "start", "--type", "character-fragment"]
        out <- sfOk ["workshop", "step", T.unpack sid, "--input", "使用者輸入"]
        out `shouldContainT` "以下是這個階段可以定案的草稿"
        commitOut <- sfOk ["workshop", "commit", T.unpack sid]
        commitOut `shouldContainT` "已定案"

    it "--json 模式下 step 的 data 同時帶 session 與 reply" $
      withCliVaultLlm draftReply $ \_ -> do
        sid <- sessionIdOf <$> sfJson ["workshop", "start", "--type", "character-fragment"]
        env <- sfJson ["workshop", "step", T.unpack sid, "--input", "使用者輸入"]
        jsonPath ["data", "reply"] env `shouldSatisfy` isJustV
        jsonPath ["data", "session", "pending"] env `shouldSatisfy` isJustV

    it "--input-file 讀得到檔案內容" $ withCliVaultLlm draftReply $ \dir -> do
      sid <- sessionIdOf <$> sfJson ["workshop", "start", "--type", "character-fragment"]
      f <- inputFile dir "從檔案來的輸入"
      r <- sf ["workshop", "step", T.unpack sid, "--input-file", f]
      crExit r `shouldBe` ExitSuccess

    it "- 從 stdin 讀得到輸入" $ withCliVaultLlm draftReply $ \_ -> do
      sid <- sessionIdOf <$> sfJson ["workshop", "start", "--type", "character-fragment"]
      r <- sfIn "從 stdin 來的輸入" ["workshop", "step", T.unpack sid, "-"]
      crExit r `shouldBe` ExitSuccess

  describe "錯誤" $
    it "不存在的 session id → workshop_session_not_found,exit 1" $ withCliVault $ \_ -> do
      r <- sf ["workshop", "step", "wksp-00000000", "--input", "x"]
      crExit r `shouldBe` ExitFailure 1
      env <- sfJson ["workshop", "step", "wksp-00000000", "--input", "x"]
      env `shouldHaveCode` "workshop_session_not_found"

-- 底稿 -------------------------------------------------------------------------

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

asString :: Value -> Text
asString (String s) = s
asString other = error ("預期字串,拿到 " <> show other)

isJustV :: Maybe Value -> Bool
isJustV = maybe False (const True)

inputFile :: FilePath -> Text -> IO FilePath
inputFile dir txt = do
  let p = dir </> "input.md"
  BS.writeFile p (TE.encodeUtf8 txt)
  pure p

-- | 起一個本機的假 OpenAI 相容端點,再建臨時 Vault 並把它的 @[llm]@ 段指過去。
withCliVaultLlm :: Text -> (FilePath -> IO a) -> IO a
withCliVaultLlm reply act =
  withLlmStub reply $ \port ->
    withCliVault $ \dir -> do
      appendLlmConfig dir port
      act dir

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
