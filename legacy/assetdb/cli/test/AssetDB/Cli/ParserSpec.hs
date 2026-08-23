-- | 參數解析(delivery/E004 T4)。
--
-- 這裡測的是**規格本身**:哪些旗標存在、預設值是什麼、哪些組合必須被拒絕。
-- 'AssetDB.Cli.OptionsSpec' 測的是資料庫路徑解析,'AssetDB.Cli.EndToEndSpec'
-- 測的是組合根把哪個 resolve 接到哪個指令 —— 三者不重疊。
--
-- 走 @execParserPure@ 而不是真的跑執行檔:預設值與拒絕條件是純函式的性質,
-- 不需要為了看它們而啟動一個行程。
module AssetDB.Cli.ParserSpec (spec) where

import AssetDB.Cli.Options
import Data.List (isInfixOf)
import Data.Text (Text)
import Options.Applicative
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "--help" $ do
    it "以「成功」結束,而不是被當成解析錯誤" $
      -- 使用者打 --help 是想看說明,不是打錯字。結束碼混在一起的話,
      -- 任何把 CLI 包起來的腳本都會把「印出說明」當成失敗。
      helpExit ["--help"] `shouldBe` Just ExitSuccess

    it "說明裡列出所有頂層指令" $ do
      let t = helpText ["--help"]
      mapM_
        (\c -> t `shouldSatisfy` (c `isInfixOf`))
        ["scan", "search", "new-project", "reorganize", "cluster", "pack", "ai", "note", "link", "doctor"]

    it "子指令也有自己的說明" $
      helpExit ["ai", "--help"] `shouldBe` Just ExitSuccess

    it "說明裡列出 --version" $
      helpText ["--help"] `shouldSatisfy` ("--version" `isInfixOf`)

  describe "--version" $ do
    it "以成功結束,不需要子指令(delivery/E006)" $
      helpExit ["--version"] `shouldBe` Just ExitSuccess

    it "輸出是執行檔名加 .cabal 的版本號" $ do
      -- 版本號只有一個來源:assetdb-cli.cabal 的 version 欄位。
      helpText ["--version"] `shouldSatisfy` ("assetdb 0.1.0.0" `isInfixOf`)
      versionText `shouldBe` "assetdb 0.1.0.0"

  describe "全域選項" $ do
    it "--db 收得到,而且是全域的(位置在子指令之前)" $
      case parse ["--db", "X.sqlite", "doctor"] of
        Just (Invocation g CmdDoctor) -> gaDbPath g `shouldBe` Just "X.sqlite"
        other -> unexpected other

    it "沒給 --db 時是 Nothing,不是某個預設路徑字串" $
      -- 預設路徑的決定屬於 resolveDbPathFor*,不屬於解析層(delivery/B001)。
      case parse ["doctor"] of
        Just (Invocation g CmdDoctor) -> gaDbPath g `shouldBe` Nothing
        other -> unexpected other

  describe "scan" $ do
    it "--root 是必填,漏掉就解析失敗" $
      rejects ["scan"]

    it "只給 --root 時其餘欄位採預設值" $
      case parse ["scan", "--root", "C:/lib"] of
        Just (Invocation _ (CmdScan a)) -> do
          saRoot a `shouldBe` "C:/lib"
          saKind a `shouldBe` "packs"
          saLabel a `shouldBe` Nothing
          saRehash a `shouldBe` False
          saQuiet a `shouldBe` False
        other -> unexpected other

    it "旗標與選項一起給時全部收得到" $
      case parse ["scan", "--root", "C:/lib", "--kind", "studio", "--label", "自製", "--rehash", "--quiet"] of
        Just (Invocation _ (CmdScan a)) -> do
          saKind a `shouldBe` "studio"
          saLabel a `shouldBe` Just "自製"
          saRehash a `shouldBe` True
          saQuiet a `shouldBe` True
        other -> unexpected other

  describe "search" $ do
    it "-q 與 --text 是同一個選項" $ do
      queryText (parse ["search", "-q", "book"]) `shouldBe` Just (Just "book")
      queryText (parse ["search", "--text", "book"]) `shouldBe` Just (Just "book")

    it "沒有任何條件時也是合法呼叫" $
      -- search 的每個條件都是選填的,「列出前 N 筆」是有意義的操作。
      queryText (parse ["search"]) `shouldBe` Just Nothing

    it "可重複的選項累積成清單,順序保留" $
      case parse ["search", "--kind", "image", "--kind", "audio", "--pack", "demo"] of
        Just (Invocation _ (CmdSearch a)) -> do
          seKinds a `shouldBe` ["image", "audio"]
          sePacks a `shouldBe` ["demo"]
        other -> unexpected other

    it "--limit 預設 20" $
      case parse ["search"] of
        Just (Invocation _ (CmdSearch a)) -> seLimit a `shouldBe` 20
        other -> unexpected other

    it "--limit 收非數字時解析失敗,而不是靜靜地用預設值" $
      rejects ["search", "--limit", "abc"]

    it "各個布林旗標互不影響" $
      case parse ["search", "--named", "--facets"] of
        Just (Invocation _ (CmdSearch a)) -> do
          seNamed a `shouldBe` True
          seFacets a `shouldBe` True
          seCommercial a `shouldBe` False
          seIncludeReference a `shouldBe` False
          seIncludeExcluded a `shouldBe` False
        other -> unexpected other

  describe "new-project" $ do
    it "--name 與 --path 都是必填" $ do
      rejects ["new-project"]
      rejects ["new-project", "--name", "game"]
      rejects ["new-project", "--path", "C:/g"]

    it "授權閘門預設是開的" $
      -- 這個預設值寫錯的後果是非商用素材靜靜地進到商業專案。
      case parse ["new-project", "--name", "game", "--path", "C:/g"] of
        Just (Invocation _ (CmdNewProject a)) -> do
          paName a `shouldBe` "game"
          paPath a `shouldBe` "C:/g"
          paPacks a `shouldBe` []
          paAllowNonCommercial a `shouldBe` False
        other -> unexpected other

    it "--allow-non-commercial 要明講才會關掉閘門" $
      case parse ["new-project", "--name", "g", "--path", "p", "--allow-non-commercial"] of
        Just (Invocation _ (CmdNewProject a)) -> paAllowNonCommercial a `shouldBe` True
        other -> unexpected other

  describe "cluster apply" $ do
    it "--help 以成功結束並列出 --confirm" $ do
      helpExit ["cluster", "apply", "--help"] `shouldBe` Just ExitSuccess
      let t = helpText ["cluster", "apply", "--help"]
      mapM_ (\f -> t `shouldSatisfy` (f `isInfixOf`)) ["--pack", "--confirm"]

    it "預設只預覽 —— 它一次改動的是全域唯一的邏輯名稱,而且沒有 undo" $
      case parse ["cluster", "apply"] of
        Just (Invocation _ (CmdClusterApply mSlug confirm)) -> do
          mSlug `shouldBe` Nothing
          confirm `shouldBe` False
        other -> unexpected other

    it "--confirm 要明講才會真的寫入,--pack 一起收得到" $
      case parse ["cluster", "apply", "--pack", "demo", "--confirm"] of
        Just (Invocation _ (CmdClusterApply mSlug confirm)) -> do
          mSlug `shouldBe` Just "demo"
          confirm `shouldBe` True
        other -> unexpected other

    it "cluster rule 與 cluster list 的解析不受影響" $ do
      case parse ["cluster", "list", "--pack", "demo"] of
        Just (Invocation _ (CmdClusterList s)) -> s `shouldBe` Just "demo"
        other -> unexpected other
      case parse ["cluster", "rule", "--pack", "p", "--shape", "s", "--kind", "ui", "--domain", "gui"] of
        Just (Invocation _ (CmdClusterRule _)) -> pure ()
        other -> unexpected other

  describe "ai suggest import" $ do
    it "--help 以成功結束並列出 --dry-run" $ do
      helpExit ["ai", "suggest", "import", "--help"] `shouldBe` Just ExitSuccess
      helpText ["ai", "suggest", "import", "--help"] `shouldSatisfy` ("--dry-run" `isInfixOf`)

    it "檔案路徑是必填的位置參數,--dry-run 為選填" $ do
      -- ai-tagging/F007 T6。沒有 --confirm:寫進暫存表本身就是預覽。
      rejects ["ai", "suggest", "import"]
      case parse ["ai", "suggest", "import", "picks.jsonl"] of
        Just (Invocation _ (CmdAiSuggestImport a)) -> do
          iaFile a `shouldBe` "picks.jsonl"
          iaDryRun a `shouldBe` False
        other -> unexpected other
      case parse ["ai", "suggest", "import", "picks.jsonl", "--dry-run"] of
        Just (Invocation _ (CmdAiSuggestImport a)) -> iaDryRun a `shouldBe` True
        other -> unexpected other

  describe "project sync" $ do
    it "--help 以成功結束並列出全部旗標" $ do
      helpExit ["project", "sync", "--help"] `shouldBe` Just ExitSuccess
      let t = helpText ["project", "sync", "--help"]
      mapM_
        (\f -> t `shouldSatisfy` (f `isInfixOf`))
        ["--name", "--pack", "--match", "--allow-non-commercial", "--confirm"]

    it "--name 是必填,漏掉就解析失敗" $
      rejects ["project", "sync"]

    it "會改動狀態的動作預設只預覽,授權閘門預設是開的" $
      -- 兩個預設值寫錯的後果分別是:靜靜覆寫使用者的專案、
      -- 以及非商用素材靜靜地進到商業專案。
      case parse ["project", "sync", "--name", "game"] of
        Just (Invocation _ (CmdProjectSync a)) -> do
          syName a `shouldBe` "game"
          syPacks a `shouldBe` []
          syQuery a `shouldBe` Nothing
          syConfirm a `shouldBe` False
          syAllowNonCommercial a `shouldBe` False
        other -> unexpected other

    it "--pack 可重複並保留順序,--match 與旗標一起收得到" $
      case parse
        ["project", "sync", "--name", "g", "--pack", "a", "--pack", "b", "--match", "ui", "--confirm", "--allow-non-commercial"] of
        Just (Invocation _ (CmdProjectSync a)) -> do
          syPacks a `shouldBe` ["a", "b"]
          syQuery a `shouldBe` Just "ui"
          syConfirm a `shouldBe` True
          syAllowNonCommercial a `shouldBe` True
        other -> unexpected other

    it "沒有 sync 子指令時解析失敗,而不是落進某個預設動作" $
      rejects ["project"]

    -- new-project 維持原名不動:改名會讓既有的腳本與文件全部失效。
    it "new-project 的解析結果不受 project 指令群影響" $ do
      helpText ["--help"] `shouldSatisfy` ("new-project" `isInfixOf`)
      case parse ["new-project", "--name", "game", "--path", "C:/g"] of
        Just (Invocation _ (CmdNewProject a)) -> do
          paName a `shouldBe` "game"
          paPath a `shouldBe` "C:/g"
          paAllowNonCommercial a `shouldBe` False
        other -> unexpected other

  describe "reorganize" $ do
    -- 其中一個模式會刪掉五千個檔案。「忘記給旗標」不該落進任何一個會動到
    -- 檔案的模式 —— 這條測試鎖住的正是「沒有預設模式」這個刻意的設計。
    it "沒有給模式旗標時解析失敗" $
      rejects ["reorganize", "--source", "A", "--target", "B"]

    it "--dry-run 不需要其他旗標" $
      case parse ["reorganize", "--source", "A", "--target", "B", "--dry-run"] of
        Just (Invocation _ (CmdReorgPlan a)) -> do
          raSource a `shouldBe` "A"
          raTarget a `shouldBe` "B"
          case raMode a of
            ModeDryRun out verbose -> do
              out `shouldBe` Nothing
              verbose `shouldBe` False
            m -> expectationFailure ("預期 ModeDryRun,收到 " <> modeName m)
        other -> unexpected other

    it "--apply 的不可回退部分要另外明講" $
      case parse ["reorganize", "--source", "A", "--target", "B", "--apply"] of
        Just (Invocation _ (CmdReorgPlan a)) ->
          case raMode a of
            ModeApply del -> del `shouldBe` False
            m -> expectationFailure ("預期 ModeApply,收到 " <> modeName m)
        other -> unexpected other

    it "--delete-covered 單獨給不算指定模式" $
      rejects ["reorganize", "--source", "A", "--target", "B", "--delete-covered"]

    it "--source 與 --target 是必填,即使已經給了模式" $ do
      rejects ["reorganize", "--dry-run"]
      rejects ["reorganize", "--source", "A", "--dry-run"]

  describe "未知輸入" $ do
    it "不存在的指令解析失敗" $
      rejects ["nosuchcommand"]

    it "不存在的旗標解析失敗,不會被當成位置參數吞掉" $
      rejects ["doctor", "--nosuchflag"]

--------------------------------------------------------------------------------

-- | 跑一次完整的參數解析。'Nothing' 代表 optparse 拒絕了這組參數
-- (@--help@ 在 optparse 裡也是一種 @Failure@,所以同樣是 'Nothing')。
parse :: [String] -> Maybe Invocation
parse args = getParseResult (execParserPure defaultPrefs invocationInfo args)

-- | 斷言這組參數被拒絕。'Invocation' 沒有 'Show' 實例,所以失敗訊息自己組:
-- 只印出它意外解析成的指令名,足以定位問題。
rejects :: [String] -> Expectation
rejects args = case parse args of
  Nothing -> pure ()
  Just (Invocation _ c) -> expectationFailure ("預期解析失敗,卻解析成 " <> commandName c)

unexpected :: Maybe Invocation -> Expectation
unexpected Nothing = expectationFailure "解析失敗,但預期成功"
unexpected (Just (Invocation _ c)) = expectationFailure ("解析成了非預期的指令:" <> commandName c)

-- | @--help@ 這類「形式上是 Failure、實際上是成功」的結束碼。
helpExit :: [String] -> Maybe ExitCode
helpExit args = case execParserPure defaultPrefs invocationInfo args of
  Failure f -> Just (snd (renderFailure f "assetdb"))
  _ -> Nothing

helpText :: [String] -> String
helpText args = case execParserPure defaultPrefs invocationInfo args of
  Failure f -> fst (renderFailure f "assetdb")
  _ -> ""

queryText :: Maybe Invocation -> Maybe (Maybe Text)
queryText (Just (Invocation _ (CmdSearch a))) = Just (seText a)
queryText _ = Nothing

modeName :: ReorgMode -> String
modeName = \case
  ModeDryRun {} -> "ModeDryRun"
  ModeApply {} -> "ModeApply"
  ModeUndo {} -> "ModeUndo"
  ModeListBatches -> "ModeListBatches"

commandName :: Command -> String
commandName = \case
  CmdScan {} -> "CmdScan"
  CmdTools -> "CmdTools"
  CmdDoctor -> "CmdDoctor"
  CmdPackList -> "CmdPackList"
  CmdPackApply {} -> "CmdPackApply"
  CmdReorgPlan {} -> "CmdReorgPlan"
  CmdClusterList {} -> "CmdClusterList"
  CmdClusterRule {} -> "CmdClusterRule"
  CmdClusterApply {} -> "CmdClusterApply"
  CmdSearch {} -> "CmdSearch"
  CmdIndex -> "CmdIndex"
  CmdThumbs {} -> "CmdThumbs"
  CmdNewProject {} -> "CmdNewProject"
  CmdProjectSync {} -> "CmdProjectSync"
  CmdNoteImport {} -> "CmdNoteImport"
  CmdNoteList {} -> "CmdNoteList"
  CmdLink {} -> "CmdLink"
  CmdAiPing {} -> "CmdAiPing"
  CmdAiClassify {} -> "CmdAiClassify"
  CmdAiVision {} -> "CmdAiVision"
  CmdAiSuggestList {} -> "CmdAiSuggestList"
  CmdAiSuggestImport {} -> "CmdAiSuggestImport"
  CmdAiDecide {} -> "CmdAiDecide"
  CmdAiApply {} -> "CmdAiApply"
  CmdAiQuery {} -> "CmdAiQuery"
  CmdAiStatus -> "CmdAiStatus"
