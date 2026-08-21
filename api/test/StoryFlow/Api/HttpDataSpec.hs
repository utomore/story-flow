-- | T2:四組 HttpApiData round-trip。
--
-- URL 裡的 @ent-7f3a@ 與 JSON 裡的 @"ent-7f3a"@ 必須是同一套寫法,否則 Agent 得
-- 學兩種。這一組把「@toUrlPiece@ 之後再 @parseUrlPiece@ 回得來」釘住,並確認
-- 非法輸入回的是 'Left' 而不是靜默接受。
module StoryFlow.Api.HttpDataSpec (spec) where

import Data.Aeson (Result (..), fromJSON, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Data.Text as T
import Servant.API (FromHttpApiData (..), ToHttpApiData (..))
import StoryFlow.Api (CheckReq (..), ContextReq (..))
import StoryFlow.Api.Fixtures (idOf, refOf, sampleCheckReq, sampleContextReq, sampleDraft)
import StoryFlow.Conflict.Json ()
import StoryFlow.Conflict.Types (ConflictOpts (..), defaultConflictOpts)
import StoryFlow.Core.Id (Id, Ref, renderRef)
import StoryFlow.Core.Level (NodeKind (..), allNodeKinds)
import StoryFlow.Core.Link (LinkKind (Custom, PartOf), coreLinkKinds)
import StoryFlow.Core.Meta (Source (..), Status (..))
import Test.Hspec

spec :: Spec
spec = do
  httpApiDataSpec
  contextReqSpec
  checkReqSpec

httpApiDataSpec :: Spec
httpApiDataSpec = describe "HttpApiData" $ do
  describe "round-trip" $ do
    it "Id" $ roundTrips (idOf "ent-7f3a")
    it "Ref(本 Vault)" $ roundTrips (refOf "ent-7f3a")
    it "Ref(跨 Vault 前綴)" $ do
      let r = refOf "shared-lore:ent-7f3a"
      renderRef r `shouldBe` "shared-lore:ent-7f3a"
      roundTrips r
    it "Status 的三個值" $ mapM_ roundTrips [Draft, Canon, Deprecated]
    it "Source 的三種形狀" $ mapM_ roundTrips [Human, Agent "claude-code", Workshop "character"]
    it "全部核心 LinkKind" $ mapM_ roundTrips coreLinkKinds
    it "自訂 LinkKind" $ roundTrips (Custom "師承於")
    it "全部 NodeKind" $ mapM_ roundTrips allNodeKinds

  describe "非法輸入" $ do
    it "Id 的格式錯誤回 Left,而且訊息說得出正確格式" $ do
      let r = parseUrlPiece "這不是一個 id" :: Either Text Id
      r `shouldSatisfy` isLeft
      either (`shouldContainT` "ent-7f3a") (const (expectationFailure "預期 Left")) r

    it "Ref 的格式錯誤回 Left" $
      (parseUrlPiece "a:b:c:d" :: Either Text Ref) `shouldSatisfy` isLeft

    it "Status 不認得的值回 Left" $
      (parseUrlPiece "沒這種狀態" :: Either Text Status) `shouldSatisfy` isLeft

    it "NodeKind 不認得的值回 Left,訊息列出合法值" $ do
      let r = parseUrlPiece "沒這種" :: Either Text NodeKind
      r `shouldSatisfy` isLeft
      either (`shouldContainT` "scene") (const (expectationFailure "預期 Left")) r

  describe "LinkKind 沒有非法輸入" $
    -- parseLinkKind 是全函式:自訂關聯一律合法(ADR-005)。
    -- 這不是漏測,是規格——擋下來會擋到「師承於」這種合法用法。
    it "任何字串都解得出來,而且解成 Custom" $ do
      (parseUrlPiece "隨便打的字" :: Either Text LinkKind) `shouldBe` Right (Custom "隨便打的字")
      (parseUrlPiece "partOf" :: Either Text LinkKind) `shouldBe` Right PartOf

-- | conflict-detection/F004 T7:@POST \/conflict\/context@ 的 body 包裝。
--
-- 它走的是 JSON body 而不是 URL 片段,所以驗的是 aeson 那一對而不是
-- 'FromHttpApiData'。
contextReqSpec :: Spec
contextReqSpec = describe "ContextReq" $ do
  it "toJSON / parseJSON round-trip 不失真" $
    case fromJSON (toJSON sampleContextReq) of
      Success r -> r `shouldBe` sampleContextReq
      Error e -> expectationFailure ("解不回來:" <> e)

  it "opts 鍵缺席時退回 defaultConflictOpts" $
    -- 客戶端只想問「和這段草稿有關的片段有哪些」時,不必知道有 opts 這個東西。
    case fromJSON (object ["draft" .= sampleDraft]) of
      Success r -> r `shouldBe` ContextReq sampleDraft defaultConflictOpts
      Error e -> expectationFailure ("opts 缺席時應該退預設,實際:" <> e)

  it "opts 只給一欄時其餘欄位仍退預設" $
    case fromJSON (object ["draft" .= sampleDraft, "opts" .= object ["top_n" .= (3 :: Int)]]) of
      Success (ContextReq d o) -> do
        d `shouldBe` sampleDraft
        o `shouldBe` defaultConflictOpts {coTopN = 3}
      Error e -> expectationFailure ("部分 opts 應該解得開,實際:" <> e)

  it "draft 缺席是解析失敗(它是唯一必填的鍵)" $
    case fromJSON (object ["opts" .= defaultConflictOpts]) :: Result ContextReq of
      Error _ -> pure ()
      Success r -> expectationFailure ("draft 缺席不該解得開:" <> show r)

-- | conflict-detection/F006 T6:@POST \/conflict\/check@ 的 body 包裝。
checkReqSpec :: Spec
checkReqSpec = describe "CheckReq" $ do
  it "toJSON / parseJSON round-trip 不失真" $
    case fromJSON (toJSON sampleCheckReq) of
      Success r -> r `shouldBe` sampleCheckReq
      Error e -> expectationFailure ("解不回來:" <> e)

  it "opts 與 no_llm 都缺席時分別退回 defaultConflictOpts 與 False" $
    case fromJSON (object ["draft" .= sampleDraft]) of
      Success r -> r `shouldBe` CheckReq sampleDraft defaultConflictOpts False
      Error e -> expectationFailure ("opts / no_llm 缺席時應該退預設,實際:" <> e)

  it "draft 缺席是解析失敗(它是唯一必填的鍵)" $
    case fromJSON (object ["opts" .= defaultConflictOpts]) :: Result CheckReq of
      Error _ -> pure ()
      Success r -> expectationFailure ("draft 缺席不該解得開:" <> show r)

roundTrips :: (Eq a, Show a, FromHttpApiData a, ToHttpApiData a) => a -> Expectation
roundTrips x = parseUrlPiece (toUrlPiece x) `shouldBe` Right x

shouldContainT :: Text -> Text -> Expectation
shouldContainT hay needle
  | needle `T.isInfixOf` hay = pure ()
  | otherwise =
      expectationFailure ("訊息裡找不到「" <> T.unpack needle <> "」:" <> T.unpack hay)
