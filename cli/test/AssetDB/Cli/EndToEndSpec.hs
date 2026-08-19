-- | 端對端:直接跑 @assetdb@ 執行檔。
--
-- delivery/B001 的病灶只在「組合根把哪個 resolve 接到哪個指令」這一層顯現,
-- 單測 'AssetDB.Cli.Options' 看不到接錯線,所以這裡真的把程式跑起來。
module AssetDB.Cli.EndToEndSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), openFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import Test.Hspec

spec :: Spec
spec =
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
