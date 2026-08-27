-- | T6:'chat' 的成功路徑,以及__送出去的請求到底長什麼樣__。
--
-- 後半段才是這一節的重點:回覆解得出來只證明 happy path 通了,但「路徑對不對」
-- 「@stream@ 有沒有明寫 false」「沒有 api_key 時會不會多送一個 Authorization」
-- 這些是端點相容性真正會踩到的地方,而它們只有從 stub 收到的請求裡看得出來。
module Aapms.Llm.ClientSpec (spec) where

import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Foldable (toList)
import Data.Text (Text)
import Network.HTTP.Types.Header (HeaderName, hAuthorization, hContentType)
import Aapms.Llm
import Aapms.Llm.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  describe "回覆" $ do
    it "回 Right,內容等於 stub 的 choices[0].message.content" $
      withStub okStub {stubBody = chatCompletion "琳達點了點頭。"} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h))
        chat client [Message User "她怎麼回應?"] `shouldReturn` Right "琳達點了點頭。"

    -- 空回覆是模型的合法輸出,不是格式錯誤——這一條與 T7(d) 的
    -- 「choices 是空陣列 → LlmBadResponse」剛好是一組對照。
    it "content 是空字串時回 Right \"\"" $
      withStub okStub {stubBody = chatCompletion ""} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h))
        chat client [Message User "嗯?"] `shouldReturn` Right ""

  describe "送出去的請求" $ do
    it "路徑是 /v1/chat/completions" $
      withStub okStub $ \h -> do
        _ <- send (stubConfig (stubPort h)) [Message User "嗨"]
        path <- fmap rrPath <$> stubLast h
        path `shouldBe` Just "/v1/chat/completions"

    -- base_url 抄自設定檔,尾斜線是最常見的手滑;兩種寫法必須等價,
    -- 否則使用者會拿到一個 404 而不知道自己多打了一個字元。
    it "base_url 帶尾斜線時路徑相同" $
      withStub okStub $ \h -> do
        let cfg = (stubConfig (stubPort h)) {lcBaseUrl = baseUrlOf (stubPort h) <> "/"}
        _ <- send cfg [Message User "嗨"]
        path <- fmap rrPath <$> stubLast h
        path `shouldBe` Just "/v1/chat/completions"

    it "body 的 model 等於 lcModel" $
      withStub okStub $ \h -> do
        let cfg = (stubConfig (stubPort h)) {lcModel = "llama3.1-8b"}
        body <- sendBody h cfg [Message User "嗨"]
        field "model" body `shouldBe` Just (String "llama3.1-8b")

    it "messages 的 role 依序是 system / user / assistant" $
      withStub okStub $ \h -> do
        body <-
          sendBody
            h
            (stubConfig (stubPort h))
            [ Message System "你是設定編輯助手"
            , Message User "琳達是誰?"
            , Message Assistant "第七織手。"
            ]
        roles body `shouldBe` [String "system", String "user", String "assistant"]

    it "messages 的 content 原樣送出(這一層不組 prompt)" $
      withStub okStub $ \h -> do
        body <- sendBody h (stubConfig (stubPort h)) [Message User "琳達是誰?"]
        contents body `shouldBe` [String "琳達是誰?"]

    -- 不做串流是硬邊界,而有些端點的預設值不是 false,所以要明寫。
    it "stream 明寫 false" $
      withStub okStub $ \h -> do
        body <- sendBody h (stubConfig (stubPort h)) [Message User "嗨"]
        field "stream" body `shouldBe` Just (Bool False)

    it "Content-Type 是 application/json" $
      withStub okStub $ \h -> do
        _ <- send (stubConfig (stubPort h)) [Message User "嗨"]
        hdr <- header hContentType h
        hdr `shouldBe` Just "application/json"

  describe "Authorization" $ do
    it "lcApiKey = Just \"sk-x\" 時帶 Bearer" $
      withStub okStub $ \h -> do
        let cfg = (stubConfig (stubPort h)) {lcApiKey = Just "sk-x"}
        _ <- send cfg [Message User "嗨"]
        hdr <- header hAuthorization h
        hdr `shouldBe` Just "Bearer sk-x"

    -- 地端端點通常不認 Authorization,多送一個 header 有機會被拒;
    -- 「沒有就不送」是地端與雲端共用同一條路徑的前提之一。
    it "lcApiKey = Nothing 時完全沒有那個 header" $
      withStub okStub $ \h -> do
        _ <- send (stubConfig (stubPort h)) [Message User "嗨"]
        hdr <- header hAuthorization h
        hdr `shouldBe` Nothing

-- 輔助 -------------------------------------------------------------------------

baseUrlOf :: Int -> Text
baseUrlOf port = lcBaseUrl (stubConfig port)

send :: LlmConfig -> [Message] -> IO (Either LlmError Text)
send cfg msgs = do
  client <- newLlmClient cfg
  chat client msgs

-- | 送一次,把 stub 收到的 body 解成 JSON。
sendBody :: StubHandle -> LlmConfig -> [Message] -> IO Value
sendBody h cfg msgs = do
  _ <- send cfg msgs
  stubLast h >>= \case
    Nothing -> fail "stub 沒有收到任何請求"
    Just r -> case decode (rrBody r) of
      Nothing -> fail "stub 收到的 body 不是合法 JSON"
      Just v -> pure v

-- | stub 收到的某個 header。@HeaderName@ 是 CI 的,所以比對不分大小寫。
header :: HeaderName -> StubHandle -> IO (Maybe BS.ByteString)
header name h = do
  last_ <- stubLast h
  pure (last_ >>= lookup name . rrHeaders)

field :: Text -> Value -> Maybe Value
field k (Object o) = KM.lookup (Key.fromText k) o
field _ _ = Nothing

roles :: Value -> [Value]
roles = messageField "role"

contents :: Value -> [Value]
contents = messageField "content"

-- | @messages[*].k@。用 'toList' 走 aeson 的 Array,免得為了一個轉換
-- 把 @vector@ 加進相依清單。
messageField :: Text -> Value -> [Value]
messageField k body = case field "messages" body of
  Just (Array xs) -> [v | Just v <- map (field k) (toList xs)]
  _ -> []
