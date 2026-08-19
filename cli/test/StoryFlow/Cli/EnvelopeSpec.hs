-- | T3:信封的成功與失敗都是合法 JSON。
--
-- 重點不只是「編得出 JSON」,而是 @code@ __確實來自 service__。CLI 自己編一套
-- 錯誤碼的話,同一個失敗在 CLI 與 REST 會回不同的字串,而 AI Agent 就得為每個
-- 介面各學一次——那正是 ADR-006 把錯誤定義在 service 的理由。
--
-- @StoreFailed@ 往內取建構子名(@stale_revision@)那條走真實路徑驗,在
-- "StoryFlow.Cli.EntityWriteSpec" ——'StoryFlow.Store.StoreError' 的建構子沒有被
-- service 的門面重新匯出,而 CLI 依定義碰不到 @storyflow-store@(T1)。
module StoryFlow.Cli.EnvelopeSpec (spec) where

import Data.Aeson (Value, decodeStrict, object, toJSON, (.=))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import StoryFlow.Cli.Fixtures (shouldContainT)
import StoryFlow.Cli.Render
import StoryFlow.Cli.Error
import StoryFlow.Core.Id (Ref, parseRef)
import StoryFlow.Service
import Test.Hspec

spec :: Spec
spec = describe "統一信封" $ do
  it "成功是 {ok:true, data:…}" $
    decode' (encodeEnvelope (Ok (object ["x" .= (1 :: Int)])))
      `shouldBe` Just (object ["ok" .= True, "data" .= object ["x" .= (1 :: Int)]])

  it "失敗是 {ok:false, error:{code, message}}" $
    decode' (encodeEnvelope (Err "entity_not_found" "索引裡找不到 ent-7f3a" :: Envelope Value))
      `shouldBe` Just
        ( object
            [ "ok" .= False
            , "error"
                .= object
                  [ "code" .= ("entity_not_found" :: Text)
                  , "message" .= ("索引裡找不到 ent-7f3a" :: Text)
                  ]
            ]
        )

  it "繁中不被逃逸成 \\uXXXX(Agent 拿到的是可讀的字,不是編碼)" $
    encodeEnvelope (Ok (toJSON ("琳達" :: Text))) `shouldContainT` "\"琳達\""

  it "業務錯誤的 code 就是 service 的 errorCode,CLI 不重編一套" $ do
    map (cliErrorCode . CliService) serviceErrors `shouldBe` map errorCode serviceErrors

  it "message 就是 renderServiceError 的輸出" $
    map (cliErrorMessage . CliService) serviceErrors `shouldBe` map renderServiceError serviceErrors

  it "定址失敗是 CLI 自己的 code(service 沒有『用標題找實體』這回事)" $ do
    cliErrorCode (CliResolve (NotFound SubEntity "琳達")) `shouldBe` "title_not_found"
    cliErrorCode (CliResolve (Ambiguous SubEntity "琳達" [])) `shouldBe` "title_ambiguous"

  it "讀不到正文來源時也是合法信封" $
    decode' (encodeEnvelope (errEnv (CliInput "讀不到 b.md")))
      `shouldBe` Just
        ( object
            [ "ok" .= False
            , "error"
                .= object
                  [ "code" .= ("input_unreadable" :: Text)
                  , "message" .= ("讀不到 b.md" :: Text)
                  ]
            ]
        )

serviceErrors :: [ServiceError]
serviceErrors =
  [ UnknownType "沒這種型別"
  , DanglingLinkTarget (refOf "ent-7f3a")
  , CrossVaultUnsupported (refOf "other:ent-7f3a")
  , RegistryUnavailable "找過 types/registry/"
  ]

errEnv :: CliError -> Envelope Value
errEnv e = Err (cliErrorCode e) (cliErrorMessage e)

decode' :: Text -> Maybe Value
decode' = decodeStrict . TE.encodeUtf8

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error (show e)
