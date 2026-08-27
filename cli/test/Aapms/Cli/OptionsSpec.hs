-- | T2:每個子指令的引數都解析成正確的 'Command'。
--
-- 這一組全部是純的——'parseCli' 不碰 IO,所以「引數怎麼寫」能被釘死而不必開
-- Vault。指令樹一旦被改動(改選項名、換順序、漏掉一個動詞),這裡先紅。
module Aapms.Cli.OptionsSpec (spec) where

import Data.List (isInfixOf)
import Data.Text (Text)
import Options.Applicative (ParserResult (..), renderFailure)
import Aapms.Cli.Options
import Aapms.Conflict.Types (ConflictOpts (..), defaultConflictOpts)
import Aapms.Core.Id (Id, Ref, parseId, parseRef)
import Aapms.Core.Level (NodeKind (KCast, KScene))
import Aapms.Core.Link (Link (..), LinkKind (Custom, PartOf))
import Aapms.Core.Meta (Source (Human), Status (Canon, Draft), Timeline (..))
import Aapms.Service
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

  describe "context(conflict-detection/F004)" $ do
    it "只給 --for 時,refs 為空、opts 是 defaultConflictOpts" $
      snd (parseOk ["context", "--for", "draft.md"])
        `shouldBe` Context (BodyFile "draft.md") [] defaultConflictOpts

    it "--for - 解成 BodyStdin" $
      snd (parseOk ["context", "--for", "-"])
        `shouldBe` Context BodyStdin [] defaultConflictOpts

    it "--ref 可重複,而且順序保留" $
      -- 順序是 drRefs 的順序,而第 1 層的起點去重是「保持首次出現的順序」
      -- ——解析階段先把順序弄丟的話,輸出的確定性就沒了。
      snd (parseOk ["context", "--for", "d.md", "--ref", "ent-7f3a", "--ref", "ent-91cc"])
        `shouldBe` Context (BodyFile "d.md") [idOf "ent-7f3a", idOf "ent-91cc"] defaultConflictOpts

    it "--ref 給不合法的 id 時是用法錯誤,訊息說得出正確格式" $
      failureMessage ["context", "--for", "d.md", "--ref", "這不是一個 id"]
        `shouldSatisfy` isInfixOf "ent-7f3a"

    it "三個數值旗標各自落進 ConflictOpts 對應的欄位" $ do
      let (_, c) =
            parseOk
              [ "context"
              , "--for"
              , "d.md"
              , "--top-n"
              , "7"
              , "--timeline-window"
              , "3"
              , "--graph-depth"
              , "4"
              ]
      case c of
        Context bs refs o -> do
          bs `shouldBe` BodyFile "d.md"
          refs `shouldBe` []
          coTopN o `shouldBe` 7
          coTimelineWindow o `shouldBe` Just 3
          coGraphDepth o `shouldBe` 4
          -- coExpandBody 是第 3 層的東西,context 不跑第 3 層,所以沒有旗標
          coExpandBody o `shouldBe` coExpandBody defaultConflictOpts
        _ -> expectationFailure ("解析成 " <> show c)

    it "沒給 --timeline-window 時是 Nothing(不做時序過濾)" $
      case snd (parseOk ["context", "--for", "d.md"]) of
        Context _ _ o -> coTimelineWindow o `shouldBe` Nothing
        c -> expectationFailure ("解析成 " <> show c)

    it "缺 --for 是用法錯誤" $
      -- 草稿要從哪裡來猜不得,所以它沒有預設值。
      failureMessage ["context"] `shouldSatisfy` isInfixOf "for"

    it "--judge-n 讓 context 解析失敗(那兩欄是 conflict check 才開的旗標)" $
      case parseCli ["context", "--for", "d.md", "--judge-n", "3"] of
        Failure _ -> pure ()
        r -> expectationFailure ("預期解析失敗,實際:" <> show r)

  describe "conflict check(conflict-detection/F006)" $ do
    it "--draft 必填,其餘給預設時 refs 為空、opts 是 defaultConflictOpts、--no-llm 是 False" $
      snd (parseOk ["conflict", "check", "--draft", "draft.md"])
        `shouldBe` ConflictCheck (BodyFile "draft.md") [] defaultConflictOpts False

    it "--draft - 解成 BodyStdin" $
      snd (parseOk ["conflict", "check", "--draft", "-"])
        `shouldBe` ConflictCheck BodyStdin [] defaultConflictOpts False

    it "--ref 可重複,順序保留(與 context 共用同一個解析器)" $
      snd (parseOk ["conflict", "check", "--draft", "d.md", "--ref", "ent-7f3a", "--ref", "ent-91cc"])
        `shouldBe` ConflictCheck (BodyFile "d.md") [idOf "ent-7f3a", idOf "ent-91cc"] defaultConflictOpts False

    it "--ref 給不合法的 id 時是用法錯誤,訊息說得出正確格式" $
      failureMessage ["conflict", "check", "--draft", "d.md", "--ref", "這不是一個 id"]
        `shouldSatisfy` isInfixOf "ent-7f3a"

    it "五個旗標各給一次時五欄都對得上" $ do
      let (_, c) =
            parseOk
              [ "conflict"
              , "check"
              , "--draft"
              , "d.md"
              , "--top-n"
              , "7"
              , "--judge-n"
              , "9"
              , "--expand-body"
              , "--timeline-window"
              , "3"
              , "--graph-depth"
              , "4"
              ]
      case c of
        ConflictCheck bs refs o noLlm -> do
          bs `shouldBe` BodyFile "d.md"
          refs `shouldBe` []
          coTopN o `shouldBe` 7
          coJudgeN o `shouldBe` 9
          coExpandBody o `shouldBe` True
          coTimelineWindow o `shouldBe` Just 3
          coGraphDepth o `shouldBe` 4
          noLlm `shouldBe` False
        _ -> expectationFailure ("解析成 " <> show c)

    it "--expand-body 與 --no-llm 是 switch:不給就是 False,給了就是 True" $ do
      snd (parseOk ["conflict", "check", "--draft", "d.md", "--no-llm"])
        `shouldBe` ConflictCheck (BodyFile "d.md") [] defaultConflictOpts True
      case snd (parseOk ["conflict", "check", "--draft", "d.md", "--expand-body"]) of
        ConflictCheck _ _ o _ -> coExpandBody o `shouldBe` True
        c -> expectationFailure ("解析成 " <> show c)

    it "缺 --draft 時解析失敗,訊息含 draft" $
      failureMessage ["conflict", "check"] `shouldSatisfy` isInfixOf "draft"

  describe "workshop(llm-workshop-mcp/F004)" $ do
    it "start 帶 --type 與可重複的 --constraint" $
      snd
        ( parseOk
            [ "workshop"
            , "start"
            , "--type"
            , "character-fragment"
            , "--constraint"
            , "ent-7f3a"
            , "--constraint"
            , "ent-91cc"
            ]
        )
        `shouldBe` WorkshopStart "character-fragment" [idOf "ent-7f3a", idOf "ent-91cc"]

    it "start 沒給 --constraint 時是空清單" $
      snd (parseOk ["workshop", "start", "--type", "character-fragment"])
        `shouldBe` WorkshopStart "character-fragment" []

    it "缺 --type 時是用法錯誤" $
      failureMessage ["workshop", "start"] `shouldSatisfy` isInfixOf "type"

    it "step 的 --input 是字面文字" $
      snd (parseOk ["workshop", "step", "wksp-00000001", "--input", "使用者輸入"])
        `shouldBe` WorkshopStep "wksp-00000001" (BodyLiteral "使用者輸入")

    it "step 的 --input-file 是檔案來源" $
      snd (parseOk ["workshop", "step", "wksp-00000001", "--input-file", "input.md"])
        `shouldBe` WorkshopStep "wksp-00000001" (BodyFile "input.md")

    it "step 的 - 解成 BodyStdin" $
      snd (parseOk ["workshop", "step", "wksp-00000001", "-"])
        `shouldBe` WorkshopStep "wksp-00000001" BodyStdin

    it "step 三個輸入來源一個都沒給時解析失敗" $
      failureMessage ["workshop", "step", "wksp-00000001"] `shouldSatisfy` isInfixOf "input"

    it "commit 只吃 session id" $
      snd (parseOk ["workshop", "commit", "wksp-00000001"])
        `shouldBe` WorkshopCommit "wksp-00000001"

-- 小工具 -----------------------------------------------------------------------

parseOk :: [String] -> (GlobalOpts, Command)
parseOk args = case parseCli args of
  Success x -> x
  Failure f -> error ("預期解析成功,實際失敗:" <> fst (renderFailure f "aapms"))
  CompletionInvoked _ -> error "預期解析成功,實際觸發了 completion"

failureMessage :: [String] -> String
failureMessage args = case parseCli args of
  Failure f -> fst (renderFailure f "aapms")
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
