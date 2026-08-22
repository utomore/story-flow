-- | T9:'StoryFlow.Workshop.Stages.buildMessages'(純函式的組裝規則,以及
-- 「改 TOML 就改得動」這條驗收標準的直接證明)。
module StoryFlow.Workshop.PromptSpec (spec) where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, parseId)
import StoryFlow.Core.Registry (EntityTypeSpec (..), FieldSpec (..))
import StoryFlow.Llm (Message (..), Role (..))
import StoryFlow.Service (Env, listEntityTypes)
import StoryFlow.Workshop.Fixtures (runS, withCustomVault)
import StoryFlow.Workshop.Session (Session (..))
import StoryFlow.Workshop.Stages (buildMessages)
import Test.Hspec

spec :: Spec
spec = do
  describe "純函式組裝規則" $ do
    let session =
          baseSession {wsStages = ["定位", "外貌與舉止"], wsCurrent = 0}
        constraints = [(constraintId, "既有摘要文字")]
        fields =
          [ FieldSpec "summary" True "一句話摘要"
          , FieldSpec "timeline" False "模糊時期"
          ]
        messages = buildMessages session constraints fields "使用者說的話"

    it "system message 含目前階段名與 N/總數" $ do
      systemText messages `shouldSatisfy` ("定位" `T.isInfixOf`)
      systemText messages `shouldSatisfy` ("1/2" `T.isInfixOf`)

    it "硬約束的 (id, summary) 逐條出現在文字裡" $ do
      systemText messages `shouldSatisfy` ("ent-11111111" `T.isInfixOf`)
      systemText messages `shouldSatisfy` ("既有摘要文字" `T.isInfixOf`)

    it "含 JSON 陣列格式指示,五個鍵名都出現" $
      mapM_
        (\k -> systemText messages `shouldSatisfy` (k `T.isInfixOf`))
        ["title", "summary", "body", "tags", "timeline"]

    it "欄位要求區塊逐條含欄位名、必填/選填標記與 hint 原文" $ do
      systemText messages `shouldSatisfy` ("必填" `T.isInfixOf`)
      systemText messages `shouldSatisfy` ("一句話摘要" `T.isInfixOf`)
      systemText messages `shouldSatisfy` ("選填" `T.isInfixOf`)
      systemText messages `shouldSatisfy` ("模糊時期" `T.isInfixOf`)

    it "訊息組成是 [system] ++ wsHistory ++ [user input]" $ do
      let hist = [Message User "上一輪的話", Message Assistant "上一輪的回覆"]
          withHistory = buildMessages session {wsHistory = hist} constraints fields "這一輪的話"
      map msgRole withHistory `shouldBe` [System, User, Assistant, User]
      msgContent (last withHistory) `shouldBe` "這一輪的話"

  describe "改 TOML 就改得動(不改 buildMessages 或任何 Workshop.Stages 的程式碼)" $ do
    it "版本一的 etsFields 出現在組裝出的文字裡" $
      withCustomVault (registryToml "hint-A-一號提示" True "hint-B-二號提示" False) $ \env -> do
        spec_ <- findType env "workshop-prompt-test"
        let text_ = systemText (buildMessages baseSession [] (etsFields spec_) "輸入")
        text_ `shouldSatisfy` ("hint-A-一號提示" `T.isInfixOf`)
        text_ `shouldSatisfy` ("hint-B-二號提示" `T.isInfixOf`)
        text_ `shouldSatisfy` ("aliases" `T.isInfixOf`)
        text_ `shouldSatisfy` ("links" `T.isInfixOf`)

    it "把 required 與 hint 都改掉(等效於改 TOML)後,重新載入,輸出的對應文字跟著換" $
      withCustomVault (registryToml "換過的提示 A" False "換過的提示 B" True) $ \env -> do
        spec_ <- findType env "workshop-prompt-test"
        let text_ = systemText (buildMessages baseSession [] (etsFields spec_) "輸入")
        text_ `shouldSatisfy` ("換過的提示 A" `T.isInfixOf`)
        text_ `shouldSatisfy` ("換過的提示 B" `T.isInfixOf`)
        text_ `shouldNotSatisfy` ("hint-A-一號提示" `T.isInfixOf`)

-- fixture --------------------------------------------------------------------

baseSession :: Session
baseSession =
  Session
    { wsId = "wksp-00000001"
    , wsType = "character"
    , wsConstraints = []
    , wsStages = ["定位", "外貌與舉止"]
    , wsCurrent = 0
    , wsHistory = []
    , wsOwner = Nothing
    , wsPending = []
    , wsCommitted = []
    }

constraintId :: Id
constraintId = case parseId "ent-11111111" of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

systemText :: [Message] -> Text
systemText (Message System t : _) = t
systemText _ = error "第一則不是 system message"

findType :: Env -> Text -> IO EntityTypeSpec
findType env key = do
  specs <- runS env listEntityTypes
  case find ((== key) . etsKey) specs of
    Just s -> pure s
    Nothing -> fail ("registry 裡找不到型別 " <> T.unpack key)

registryToml :: Text -> Bool -> Text -> Bool -> Text
registryToml hint1 req1 hint2 req2 =
  T.unlines
    [ "key  = \"workshop-prompt-test\""
    , "name = \"工作坊提示測試型別\""
    , "dir  = \"characters\""
    , ""
    , "[[fields]]"
    , "name = \"aliases\""
    , "required = " <> boolText req1
    , "hint = \"" <> hint1 <> "\""
    , ""
    , "[[fields]]"
    , "name = \"links\""
    , "required = " <> boolText req2
    , "hint = \"" <> hint2 <> "\""
    ]
  where
    boolText b = if b then "true" else "false"
