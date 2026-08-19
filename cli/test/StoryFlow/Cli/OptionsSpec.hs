-- | T2:每個子指令的引數都解析成正確的 'Command'。
--
-- 這一組全部是純的——'parseCli' 不碰 IO,所以「引數怎麼寫」能被釘死而不必開
-- Vault。指令樹一旦被改動(改選項名、換順序、漏掉一個動詞),這裡先紅。
module StoryFlow.Cli.OptionsSpec (spec) where

import Data.List (isInfixOf)
import Data.Text (Text)
import Options.Applicative (ParserResult (..), renderFailure)
import StoryFlow.Cli.Options
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Core.Level (NodeKind (KCast, KScene))
import StoryFlow.Core.Link (Link (..), LinkKind (Custom, PartOf))
import StoryFlow.Core.Meta (Source (Human), Status (Canon, Draft), Timeline (..))
import StoryFlow.Service
import Test.Hspec

spec :: Spec
spec = describe "引數解析" $ do
  describe "全域選項" $ do
    it "--json 與 --vault 在名詞之前" $ do
      let (g, c) = parseOk ["--vault", "liftgame", "--json", "entity", "list"]
      goVault g `shouldBe` Just "liftgame"
      goJson g `shouldBe` True
      c `shouldBe` EntityList emptyFilter

    it "不給時兩者都是預設值" $ do
      let (g, _) = parseOk ["vault", "list"]
      (goVault g, goJson g) `shouldBe` (Nothing, False)

  describe "vault / index / type" $ do
    it "vault init 的目錄是選配的位置引數" $ do
      snd (parseOk ["vault", "init", "/tmp/v", "--name", "liftgame"])
        `shouldBe` VaultInit "/tmp/v" "liftgame"
      snd (parseOk ["vault", "init", "--name", "liftgame"])
        `shouldBe` VaultInit "." "liftgame"

    it "其餘三條沒有引數" $ do
      snd (parseOk ["vault", "info"]) `shouldBe` VaultInfo
      snd (parseOk ["index", "rebuild"]) `shouldBe` IndexRebuild
      snd (parseOk ["index", "refresh"]) `shouldBe` IndexRefresh
      snd (parseOk ["type", "list"]) `shouldBe` TypeList

  describe "entity" $ do
    it "new 帶齊欄位" $ do
      let (_, c) =
            parseOk
              [ "entity"
              , "new"
              , "--type"
              , "character"
              , "--title"
              , "琳達"
              , "--summary"
              , "第七織手"
              , "--status"
              , "canon"
              , "--timeline"
              , "崩塌前"
              , "--order"
              , "3"
              ]
      case c of
        EntityNew req bs -> do
          nerType req `shouldBe` "character"
          nerTitle req `shouldBe` "琳達"
          nerSummary req `shouldBe` "第七織手"
          nerStatus req `shouldBe` Canon
          nerTimeline req `shouldBe` Timeline (Just "崩塌前") (Just 3)
          nerSource req `shouldBe` Human
          bs `shouldBe` BodyLiteral ""
        _ -> expectationFailure ("解析成 " <> show c)

    it "--tag 與 --alias 重複出現即累積" $ do
      let (_, c) =
            parseOk
              ["entity", "new", "--type", "character", "--title", "琳達", "--tag", "a", "--tag", "b", "--alias", "小琳"]
      case c of
        EntityNew req _ -> do
          nerTags req `shouldBe` ["a", "b"]
          nerAliases req `shouldBe` ["小琳"]
        _ -> expectationFailure ("解析成 " <> show c)

    it "--body-file 與 --body 各自成為一種 BodySource" $ do
      bodyOf (parseOk ["entity", "new", "--type", "t", "--title", "x", "--body", "正文"])
        `shouldBe` Just (BodyLiteral "正文")
      bodyOf (parseOk ["entity", "new", "--type", "t", "--title", "x", "--body-file", "b.md"])
        `shouldBe` Just (BodyFile "b.md")

    it "set-body 的 - 讀 stdin" $
      snd (parseOk ["entity", "set-body", "ent-7f3a", "-"])
        `shouldBe` EntitySetBody (SelById (idOf "ent-7f3a")) Nothing BodyStdin

    it "缺 --title 時失敗,而且訊息提到那個選項" $
      failureMessage ["entity", "new", "--type", "character"] `shouldSatisfy` isInfixOf "--title"

    it "list 的四個過濾選項組成 EntityFilter" $
      snd (parseOk ["entity", "list", "--type", "character", "--status", "draft", "--tag", "外觀", "--limit", "5"])
        `shouldBe` EntityList (EntityFilter (Just "character") (Just Draft) (Just "外觀") (Just 5))

    it "rm 的 --revision 與 --force" $
      snd (parseOk ["entity", "rm", "ent-7f3a", "--revision", "4", "--force"])
        `shouldBe` EntityRm (SelById (idOf "ent-7f3a")) (Just 4) True

  describe "定址" $ do
    it "id 格式當 id,其餘當標題" $ do
      mkSelector "ent-7f3a" `shouldBe` SelById (idOf "ent-7f3a")
      mkSelector "琳達" `shouldBe` SelByTitle "琳達"

  describe "--link 的緊湊格式" $ do
    it "三段解出 kind / target / note" $
      parseLinkSpec "partOf:ent-7f3a:對雙親死因不一致"
        `shouldBe` Right (Link PartOf (refOf "ent-7f3a") (Just "對雙親死因不一致"))

    it "兩段時 note 是 Nothing" $
      parseLinkSpec "partOf:ent-7f3a" `shouldBe` Right (Link PartOf (refOf "ent-7f3a") Nothing)

    it "只切前兩個冒號,其餘算進說明" $
      parseLinkSpec "partOf:ent-7f3a:前:後"
        `shouldBe` Right (Link PartOf (refOf "ent-7f3a") (Just "前:後"))

    it "非核心關聯照收(ADR-005:自訂關聯合法)" $
      parseLinkSpec "師承於:ent-7f3a"
        `shouldBe` Right (Link (Custom "師承於") (refOf "ent-7f3a") Nothing)

    it "缺目標時失敗" $
      parseLinkSpec "partOf" `shouldSatisfy` isLeft

  describe "link / level / node" $ do
    it "link add 組出 Link" $
      snd (parseOk ["link", "add", "琳達", "--kind", "partOf", "--target", "ent-7f3a", "--note", "n"])
        `shouldBe` LinkAdd (SelByTitle "琳達") Nothing (Link PartOf (refOf "ent-7f3a") (Just "n"))

    it "link rm 分開吃 kind 與 target" $
      snd (parseOk ["link", "rm", "ent-7f3b", "--kind", "partOf", "--target", "ent-7f3a"])
        `shouldBe` LinkRm (SelById (idOf "ent-7f3b")) Nothing PartOf (refOf "ent-7f3a")

    it "level new 要 --root-title 與 --root-kind" $
      snd (parseOk ["level", "new", "--title", "教室", "--root-title", "午後的教室", "--root-kind", "scene"])
        `shouldBe` LevelNew (NewLevelReq "教室" "" "" "午後的教室" KScene Draft)

    it "node add 吃父節點與 --kind" $
      snd (parseOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"])
        `shouldBe` NodeAdd (SelByTitle "午後的教室") Nothing (NewNodeReq "出場人物" KCast "" "" [])

    it "--root-kind 給不認得的值時失敗" $
      failureMessage ["level", "new", "--title", "x", "--root-title", "y", "--root-kind", "沒這種"]
        `shouldSatisfy` isInfixOf "root-kind"

-- 小工具 -----------------------------------------------------------------------

parseOk :: [String] -> (GlobalOpts, Command)
parseOk args = case parseCli args of
  Success x -> x
  Failure f -> error ("預期解析成功,實際失敗:" <> fst (renderFailure f "story-flow"))
  CompletionInvoked _ -> error "預期解析成功,實際觸發了 completion"

failureMessage :: [String] -> String
failureMessage args = case parseCli args of
  Failure f -> fst (renderFailure f "story-flow")
  other -> error ("預期解析失敗,實際 " <> show (constructor other))
  where
    constructor :: ParserResult a -> String
    constructor = \case
      Success _ -> "Success"
      Failure _ -> "Failure"
      CompletionInvoked _ -> "CompletionInvoked"

bodyOf :: (GlobalOpts, Command) -> Maybe BodySource
bodyOf (_, EntityNew _ bs) = Just bs
bodyOf (_, EntityAdd _ _ bs) = Just bs
bodyOf _ = Nothing

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error (show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error (show e)
