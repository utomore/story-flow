-- | conflict-detection/F004 T12 \/ T13 \/ T14:@aapms context@。
--
-- 三件事要驗:兩條後端路徑都跑得通、兩種輸出格式都對、__兩條路徑回同一批結果__。
--
-- 最後那一條(T14)是契約卡的驗收標準 4。它在結構上已經成立
-- ——'Aapms.Cli.Backend.gatherContextB' 兩條分支回的是同一個型別,渲染器只有
-- 一份——但仍然有一條逐字元比對守著,作法與 "Aapms.Cli.ParitySpec" 相同。
module Aapms.Cli.ContextCmdSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Aapms.Cli.Fixtures
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, hSetEncoding, openFile, utf8)
import Test.Hspec

spec :: Spec
spec = do
  describe "兩條後端路徑" $ do
    it "內嵌模式 exit 0,而且 --json 的 data 是陣列" $ withCliServer $ \dir _ -> do
      seedVault
      f <- draftFile dir "琳達走進廢墟"
      r <- sf ["context", "--for", f]
      crExit r `shouldBe` ExitSuccess
      env <- sfJson ["context", "--for", f]
      dataOf env `shouldSatisfy` isArray

    it "--remote 模式同一條指令一樣 exit 0 且解得開" $ withCliServer $ \dir url -> do
      seedVault
      f <- draftFile dir "琳達走進廢墟"
      r <- sfRemote url ["context", "--for", f]
      crExit r `shouldBe` ExitSuccess
      env <- sfRemoteJson url ["context", "--for", f]
      dataOf env `shouldSatisfy` isArray

    it "--ref 讓第 1 層動起來:兩種模式都撈得到被標了 contradicts 的那一筆" $
      withCliServer $ \dir url -> do
        (linda, old) <- seedContradiction
        f <- draftFile dir "琳達走進廢墟"

        emb <- sfOk ["context", "--for", f, "--ref", linda]
        emb `shouldContainT` T.pack old
        emb `shouldContainT` "graph(contradicts→"

        rem' <- sfRemote url ["context", "--for", f, "--ref", linda]
        crExit rem' `shouldBe` ExitSuccess
        crOut rem' `shouldContainT` T.pack old

    it "--ref 給一個不存在的 id 不會失敗(第 1 層在圖上查不到就沒有命中)" $
      withCliServer $ \dir _ -> do
        seedVault
        f <- draftFile dir "琳達走進廢墟"
        r <- sf ["context", "--for", f, "--ref", "ent-00000000"]
        crExit r `shouldBe` ExitSuccess

  describe "輸出" $ do
    it "人類模式印出六欄表頭" $ withCliVault $ \dir -> do
      seedVault
      f <- draftFile dir "琳達走進廢墟"
      out <- sfOk ["context", "--for", f]
      mapM_ (shouldContainT out) ["id", "type", "status", "title", "via", "snippet"]

    it "via 欄同時看得到 graph( 與 retrieval(" $ withCliVault $ \dir -> do
      -- 第 1 層是事實、第 2 層是相關度,ADR-007 說「使用者需要知道差別」
      -- ——在人類模式裡那個差別就是這一欄。
      (linda, _) <- seedContradiction
      f <- draftFile dir "琳達走進廢墟"
      out <- sfOk ["context", "--for", f, "--ref", linda]
      out `shouldContainT` "graph("
      out `shouldContainT` "retrieval("

    it "沒有命中時印 (沒有相關的片段)" $ withCliVault $ \dir -> do
      seedVault
      f <- draftFile dir ""
      out <- sfOk ["context", "--for", f]
      out `shouldContainT` "(沒有相關的片段)"

    it "--json 是合法信封,而且每筆帶 meta / snippet / via" $ withCliVault $ \dir -> do
      seedVault
      f <- draftFile dir "琳達走進廢墟"
      env <- sfJson ["context", "--for", f]
      jsonPath ["ok"] env `shouldBe` Just (Bool True)
      case dataOf env of
        Array xs | not (null xs) -> mapM_ hasHitKeys xs
        other -> expectationFailure ("data 應該是非空陣列:" <> show other)

    it "--json 的 via 帶 layer 標籤(和積型別不洩漏 Haskell 建構子名)" $
      withCliVault $ \dir -> do
        seedVault
        f <- draftFile dir "琳達走進廢墟"
        env <- sfJson ["context", "--for", f]
        case dataOf env of
          Array xs | not (null xs) ->
            mapM_ (\x -> jsonPath ["via", "layer"] x `shouldBe` Just (String "retrieval")) xs
          other -> expectationFailure ("data 應該是非空陣列:" <> show other)

    it "--for - 從 stdin 讀得到草稿" $ withCliVault $ \_ -> do
      seedVault
      r <- sfIn "琳達走進廢墟" ["context", "--for", "-"]
      crExit r `shouldBe` ExitSuccess
      crOut r `shouldContainT` "琳達"

    it "--for 指的檔案讀不到時 exit 1,而且訊息說得出是哪個檔" $ withCliVault $ \dir -> do
      seedVault
      let missing = dir </> "沒這個檔.md"
      r <- sf ["context", "--for", missing]
      crExit r `shouldBe` ExitFailure 1
      crErr r `shouldContainT` "讀不到"

    it "--top-n 收得緊時輸出跟著變少" $ withCliVault $ \dir -> do
      -- 「琳達」這個既有名稱要先存在,關鍵詞才抽得出來(第 2 層的反向名稱比對);
      -- 其餘五筆的標題含它,所以 LIKE 那條路徑全部命中。
      seedVault
      mapM_
        (\n -> newEntity ("琳達的側寫" <> T.pack (show n)) "琳達的另一個側面")
        [1 .. 5 :: Int]
      f <- draftFile dir "琳達走進廢墟"
      wide <- sfOk ["context", "--for", f]
      narrow <- sfOk ["context", "--for", f, "--top-n", "1"]
      length (T.lines narrow) `shouldSatisfy` (< length (T.lines wide))

  describe "內嵌與遠端回同一批結果" $ do
    it "人類模式的 stdout 逐字元相等" $ withCliServer $ \dir url -> do
      (linda, _) <- seedContradiction
      f <- draftFile dir "琳達走進廢墟"
      emb <- sf ["context", "--for", f, "--ref", linda]
      rem' <- sfRemote url ["context", "--for", f, "--ref", linda]
      crOut emb `shouldBe` crOut rem'

    it "--json 的信封逐字元相等" $ withCliServer $ \dir url -> do
      (linda, _) <- seedContradiction
      f <- draftFile dir "琳達走進廢墟"
      emb <- capture ["--vault", "liftgame", "--json", "context", "--for", f, "--ref", linda]
      rem' <- capture ["--remote", url, "--json", "context", "--for", f, "--ref", linda]
      crOut emb `shouldBe` crOut rem'

    it "exit code 相等" $ withCliServer $ \dir url -> do
      (linda, _) <- seedContradiction
      f <- draftFile dir "琳達走進廢墟"
      emb <- sf ["context", "--for", f, "--ref", linda]
      rem' <- sfRemote url ["context", "--for", f, "--ref", linda]
      crExit emb `shouldBe` crExit rem'

    it "空草稿的兩種模式也一樣(空清單也是一批結果)" $ withCliServer $ \dir url -> do
      seedVault
      f <- draftFile dir ""
      emb <- sf ["context", "--for", f]
      rem' <- sfRemote url ["context", "--for", f]
      crOut emb `shouldBe` crOut rem'
      crExit emb `shouldBe` crExit rem'

-- 底稿 -------------------------------------------------------------------------

-- | 一個 canon 片段,標題與總結都含「琳達」——第 2 層靠它命中。
seedVault :: IO ()
seedVault = newEntity "琳達" "埃提亞的第七織手"

-- | @琳達 contradicts 舊版設定@。回 @(琳達的 id, 舊版設定的 id)@。
seedContradiction :: IO (String, String)
seedContradiction = do
  old <- idFromJson <$> sfJson (newArgs "舊版設定" "早就被推翻的說法")
  linda <- idFromJson <$> sfJson (newArgs "琳達" "埃提亞的第七織手" <> ["--link", "contradicts:" <> old])
  pure (linda, old)

newEntity :: T.Text -> T.Text -> IO ()
newEntity title summary = do
  _ <- sfOk (newArgs title summary)
  pure ()

newArgs :: T.Text -> T.Text -> [String]
newArgs title summary =
  [ "entity"
  , "new"
  , "--type"
  , "character"
  , "--title"
  , T.unpack title
  , "--summary"
  , T.unpack summary
  , "--status"
  , "canon"
  ]

-- | 把草稿寫成 UTF-8 檔案,回它的路徑。
--
-- 編碼釘死是必要的:Vault 的內容是繁中,而 Windows 的預設 code page 會在寫到
-- 第一個中文字時就丟 @InvalidArgument@ ——那會變成測試自己的失敗。
draftFile :: FilePath -> T.Text -> IO FilePath
draftFile dir txt = do
  let p = dir </> "draft.md"
  h <- openFile p WriteMode
  hSetEncoding h utf8
  TIO.hPutStr h txt
  hClose h
  pure p

isArray :: Value -> Bool
isArray = \case
  Array _ -> True
  _ -> False

-- | 一筆 @ContextHit@ 該有的三個鍵。@meta@ 直接帶著整份 Meta,是驗收標準 2
-- (「外部 Agent 不必再往返一次」)的可測形式。
hasHitKeys :: Value -> Expectation
hasHitKeys v = do
  jsonPath ["snippet"] v `shouldSatisfy` isJust'
  jsonPath ["via"] v `shouldSatisfy` isJust'
  jsonPath ["meta", "id"] v `shouldSatisfy` isJust'
  jsonPath ["meta", "title"] v `shouldSatisfy` isJust'
  where
    isJust' = maybe False (const True)
