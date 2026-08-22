module AssetDB.AI.LlmSpec (spec) where

import AssetDB.AI.Llm
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "replyPayload" $ do
    it "有 content 就用 content" $
      replyPayload (reply "{\"a\":1}" "想了一下" "stop") `shouldBe` Right "{\"a\":1}"

    it "content 空且 finish=length -> LlmTruncated" $
      -- 這是這顆模型實際會發生的失敗:推理吃光 token 預算,content 是空的。
      replyPayload (reply "" "很長的推理…" "length") `shouldBe` Left (LlmTruncated 400)

    it "content 空且 finish=stop -> LlmEmptyContent,並帶著推理片段" $
      replyPayload (reply "" "我想了但沒答" "stop")
        `shouldBe` Left (LlmEmptyContent "我想了但沒答")

    it "**絕不**把 reasoning_content 當成回答" $ do
      -- 這是本模組最重要的一條不變量。若在 content 為空時回頭讀 reasoning,
      -- 等於把不受 grammar 約束的散文餵進 JSON parser,再把產生的垃圾標籤
      -- 寫進 asset_tags —— 而且看起來會像是成功了。
      let r = replyPayload (reply "" "{\"tags\":[\"這是推理裡剛好長得像 JSON 的東西\"]}" "stop")
      r `shouldSatisfy` isLeft
      case r of
        Left (LlmEmptyContent _) -> pure ()
        other -> expectationFailure ("預期 LlmEmptyContent,得到 " <> show other)

    it "只有空白的 content 也算空" $
      replyPayload (reply "   \n  " "" "stop") `shouldSatisfy` isLeft

  describe "isTransient" $ do
    it "服務沒開與逾時是暫時性的" $ do
      isTransient (LlmUnavailable "refused") `shouldBe` True
      isTransient (LlmTimeout 120) `shouldBe` True
      isTransient (LlmHttpStatus 503 "") `shouldBe` True

    it "模型自己的輸出問題不是暫時性的" $ do
      -- 這個區別決定驅動器是「跳過這一筆」還是「整批中止」。分錯的話,
      -- 服務中途掛掉會讓剩下幾千筆全被標成 failed,工作佇列就毀了。
      isTransient (LlmTruncated 1600) `shouldBe` False
      isTransient (LlmEmptyContent "") `shouldBe` False
      isTransient (LlmBadJson "" "") `shouldBe` False
      isTransient (LlmHttpStatus 400 "") `shouldBe` False

  describe "parseReply" $ do
    it "缺 reasoning_content 欄位不是錯誤" $ do
      let v =
            object
              [ "choices"
                  .= [ object
                        [ "message" .= object ["content" .= ("hi" :: T.Text)]
                        , "finish_reason" .= ("stop" :: T.Text)
                        ]
                     ]
              ]
      fmap clContent (parseReply v) `shouldBe` Right "hi"
      fmap clReasoning (parseReply v) `shouldBe` Right ""

    it "choices 是空陣列 -> LlmBadEnvelope" $
      parseReply (object ["choices" .= ([] :: [Value])]) `shouldSatisfy` isLeft

  describe "encodeMessage" $ do
    it "單一文字段落輸出字串形式的 content" $ do
      -- 維持與效能量測當初送出的位元組一致。這裡若悄悄改成陣列形式,
      -- 之後的迴歸會很難歸因。
      case encodeMessage (userText "hi") of
        Object o -> KM.lookup "content" o `shouldBe` Just (String "hi")
        other -> expectationFailure ("預期物件,得到 " <> show other)

    it "含圖時輸出 parts 陣列" $ do
      case encodeMessage (userTextImage "看圖" "data:image/png;base64,AA") of
        Object o -> case KM.lookup "content" o of
          Just (Array a) -> length a `shouldBe` 2
          other -> expectationFailure ("預期陣列,得到 " <> show other)
        other -> expectationFailure ("預期物件,得到 " <> show other)

  describe "fakeLlm" $
    it "讓整條呼叫路徑不需要真的推論服務" $ do
      -- 這個接縫的存在意義:十小時驅動器的每一條路徑都能在毫秒內測完。
      let llm = fakeLlm defaultLlmConfig $ \ep _ -> pure $ case ep of
            Models -> Right (object ["data" .= [object ["id" .= ("m1" :: T.Text)]]])
            ChatCompletions -> Left (LlmUnavailable "測試")
      ping llm `shouldReturn` Right "m1"
      r <- chat llm (defaultChatRequest [userText "x"])
      r `shouldBe` Left (LlmUnavailable "測試")

  describe "renderLlmError" $
    it "壓成單行,可以直接存進 ai_error" $ do
      let t = renderLlmError (LlmEmptyContent "第一行\n第二行")
      T.isInfixOf "\n" t `shouldBe` False

reply :: T.Text -> T.Text -> T.Text -> ChatReply
reply c r f = ChatReply {clContent = c, clReasoning = r, clFinish = f, clUsage = Usage 10 400 410}

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
