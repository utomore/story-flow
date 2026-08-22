-- | 端對端:直接跑 @assetdb@ 執行檔。
--
-- delivery/B001 的病灶只在「組合根把哪個 resolve 接到哪個指令」這一層顯現,
-- 單測 'AssetDB.Cli.Options' 看不到接錯線,所以這裡真的把程式跑起來。
module AssetDB.Cli.EndToEndSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple (execute, withConnection)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), openFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import Test.Hspec

spec :: Spec
spec = do
  -- delivery/F006 V1 的 CLI 側:專案定位失敗必須是非 0 結束碼。
  -- 腳本只看得到結束碼,「未登記」被當成成功的話,包裝它的自動化會繼續往下走。
  describe "assetdb project sync(未登記的專案)" $
    it "以非 0 結束碼失敗,而不是靜靜地回報沒有東西要加" $
      inEmptyDir $ \dir -> do
        (initCode, _) <- runCli dir ["scan", "--root", dir, "--quiet"]
        initCode `shouldBe` ExitSuccess
        (code, _) <- runCli dir ["project", "sync", "--name", "nosuchproject"]
        code `shouldNotBe` ExitSuccess

  describe "assetdb search(錯誤的工作目錄)" $ do
    it "以非 0 結束碼失敗,而不是回報查無結果" $
      inEmptyDir $ \dir -> do
        (code, _) <- runCli dir ["search", "-q", "book"]
        code `shouldNotBe` ExitSuccess

    it "印出的訊息告訴使用者可以用 --db 指定路徑" $
      inEmptyDir $ \dir -> do
        (_, err) <- runCli dir ["search", "-q", "book"]
        -- 訊息本體是中文,這裡只比對訊息裡必然出現的 ASCII 片段,
        -- 避免測試被主控台編碼影響
        err `shouldSatisfy` (BC.pack "--db" `BS.isInfixOf`)

    it "不會在工作目錄下靜默建出空資料庫" $
      inEmptyDir $ \dir -> do
        _ <- runCli dir ["search", "-q", "book"]
        doesDirectoryExist (dir </> ".assetdb") `shouldReturn` False
        doesFileExist (dir </> ".assetdb" </> "assetdb.sqlite") `shouldReturn` False

  -- G-E003 目標 8。頂層 handler 最容易寫錯的地方就在這兩條之間:
  -- 要接住逃出來的例外,又不能把「刻意的非 0 結束」也一起接走。
  describe "頂層例外處理" $ do
    it "版本比程式新的資料庫:非 0 結束,訊息可行動,不吐 backtrace" $
      inEmptyDir $ \dir -> do
        (initCode, _) <- runCli dir ["scan", "--root", dir, "--quiet"]
        initCode `shouldBe` ExitSuccess
        bumpSchemaVersion (dir </> ".assetdb" </> "assetdb.sqlite") 999

        (code, err) <- runCli dir ["search", "-q", "book"]
        code `shouldNotBe` ExitSuccess
        -- 訊息本體是中文,這裡比對必然出現的 ASCII 片段。
        -- 「發生什麼事」:認得的版本號;「該做什麼」:重新安裝的指令。
        err `shouldSatisfy` contains "v999"
        err `shouldSatisfy` contains "cabal install"
        -- 使用者不該看到 GHC 的資料建構子名稱或 backtrace。
        err `shouldNotSatisfy` contains "DatabaseNewerThanCode"
        err `shouldNotSatisfy` contains "HasCallStack"

    it "刻意的 exitFailure 不會被頂層 handler 吞成一則錯誤訊息" $
      inEmptyDir $ \dir -> do
        -- Haskell 的 exitFailure 是用例外實作的,天真的 catch @SomeException
        -- 會把它變成「頂層印了一則錯誤」—— 訊息與結束碼雙雙錯掉。
        -- 被吞掉的話 stderr 會出現渲染過的 `ExitFailure 1` 而不是原本的提示。
        (code, err) <- runCli dir ["search", "-q", "book"]
        code `shouldNotBe` ExitSuccess
        err `shouldSatisfy` contains "--db"
        err `shouldNotSatisfy` contains "ExitFailure"
        err `shouldNotSatisfy` contains "未預期"

  -- G-E003 T10。繁中 Windows 上把 packs.toml 存成 CP950 很容易發生,而
  -- 嚴格解碼拋的 UnicodeException 只會告訴使用者「有個英文例外」,不會
  -- 告訴他「這個檔案的編碼不對」。
  describe "assetdb pack apply(編碼不對的 packs.toml)" $ do
    it "CP950 的檔案不會拋例外,而是以可讀的解析錯誤結束" $
      inEmptyDir $ \dir -> do
        (initCode, _) <- runCli dir ["scan", "--root", dir, "--quiet"]
        initCode `shouldBe` ExitSuccess
        let toml = dir </> "packs.toml"
        -- 「金門」的 CP950 位元組。以 UTF-8 嚴格解碼必定失敗。
        BS.writeFile toml (BC.pack "[[pack]]\narchive = \"" <> BS.pack [0xAA, 0xF7, 0xAA, 0xF9] <> BC.pack "\"\n")

        (code, err) <- runCli dir ["pack", "apply", "--catalogue", toml]
        code `shouldNotBe` ExitSuccess
        -- 壞掉的位元組變成替代字元,TOML 解析器接著指出是哪裡出錯 ——
        -- 那才是可行動的訊息。使用者不該看到 UnicodeException。
        err `shouldNotSatisfy` contains "UnicodeException"
        err `shouldNotSatisfy` contains "Cannot decode byte"

    it "合法 UTF-8 但欄位不全時同樣是可讀的解析錯誤" $
      inEmptyDir $ \dir -> do
        (initCode, _) <- runCli dir ["scan", "--root", dir, "--quiet"]
        initCode `shouldBe` ExitSuccess
        let toml = dir </> "packs.toml"
        BS.writeFile toml (encodeUtf8 "[[pack]]\nname = \"金門建築\"\n")
        (code, _) <- runCli dir ["pack", "apply", "--catalogue", toml]
        code `shouldNotBe` ExitSuccess

--------------------------------------------------------------------------------

-- | 在一個保證沒有任何上層 @.assetdb@ 的暫存目錄裡執行。
inEmptyDir :: (FilePath -> IO a) -> IO a
inEmptyDir f =
  withSystemTempDirectory "assetdb-cli-e2e" $ \dir -> do
    let work = dir </> "elsewhere"
    createDirectoryIfMissing True work
    f work

-- | 跑 @assetdb@ 並回傳結束碼與 stderr 的原始位元組。
--
-- stderr 導到檔案再以 ByteString 讀回,而不是用 'readProcessWithExitCode':
-- 後者會拿 locale 編碼去解 UTF-8 的中文訊息,在 Windows 上解出來的東西沒法比對。
runCli :: FilePath -> [String] -> IO (ExitCode, BS.ByteString)
runCli dir args = do
  let outPath = dir </> "stdout.log"
      errPath = dir </> "stderr.log"
  outH <- openFile outPath WriteMode
  errH <- openFile errPath WriteMode
  (_, _, _, ph) <-
    createProcess
      (proc "assetdb" args)
        { cwd = Just dir
        , std_out = UseHandle outH
        , std_err = UseHandle errH
        }
  code <- waitForProcess ph
  err <- BS.readFile errPath
  pure (code, err)

-- | 子行程的輸出是 UTF-8 位元組,所以比對前把期待的片段也編成 UTF-8。
-- 'BC.pack' 只處理得了 Latin-1,拿它去比中文會永遠不相等。
contains :: Text -> BS.ByteString -> Bool
contains needle hay = encodeUtf8 needle `BS.isInfixOf` hay

-- | 偽造一個「比程式新」的資料庫 —— 把一列不存在的 migration 版本寫進去。
--
-- 這是真實會發生的情境:PATH 上的舊執行檔開了一個新版建立的資料庫
-- (README「已知陷阱」第 7 條)。
bumpSchemaVersion :: FilePath -> Int -> IO ()
bumpSchemaVersion dbPath v =
  withConnection dbPath $ \conn ->
    execute
      conn
      "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?,?,'1970-01-01T00:00:00Z')"
      (v, "來自未來的 migration" :: Text)
