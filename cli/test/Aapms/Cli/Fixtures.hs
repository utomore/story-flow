-- | CLI 測試的共用底稿。
--
-- service-and-interfaces/F002 的「library 讓測試不必跑子行程」在這裡兌現:每一條測試都是一次
-- 'runCliWith' 呼叫,三個 handle 換成暫存檔就拿得到 stdout \/ stderr \/ exit code。
-- 沒有 @readProcess@,失敗時堆疊追蹤是完整的。
--
-- 兩個環境變數在建臨時 Vault 時一起設好,測試因此__碰不到使用者真實的環境__:
--
-- * @STORYFLOW_VAULTS@ 指向臨時目錄裡的 @vaults.toml@
-- * @STORYFLOW_REGISTRY@ 指向原始碼樹的 @types\/registry\/@
module Aapms.Cli.Fixtures
  ( -- * 跑指令
    CliResult (..)
  , capture
  , captureIn
  , sf
  , sfIn
  , sfOk
  , sfJson
  , dataOf

    -- * 環境
  , withCliVault
  , withCliServer
  , withCliServerToken
  , sfRemote
  , sfRemoteJson
  , withEnvVars
  , registryDir

    -- * 斷言小工具
  , shouldContainT
  , shouldHaveCode
  , idFromJson
  , jsonPath
  ) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), decodeStrict)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Network.Wai.Handler.Warp as Warp
import Aapms.Cli (CliIO (..), runCliWith)
import Aapms.Server (app)
import Aapms.Server.State (newAppState)
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
  ( Handle
  , SeekMode (AbsoluteSeek)
  , hFlush
  , hSeek
  , hSetEncoding
  , hSetNewlineMode
  , noNewlineTranslation
  , utf8
  )
import System.IO.Temp (withSystemTempDirectory, withSystemTempFile)
import Test.Hspec

-- 跑指令 -----------------------------------------------------------------------

data CliResult = CliResult
  { crExit :: ExitCode
  , crOut :: Text
  , crErr :: Text
  }
  deriving stock (Show, Eq)

-- | 一次 CLI 呼叫,stdin 為空。
capture :: [String] -> IO CliResult
capture = captureIn ""

-- | 一次 CLI 呼叫,stdin 餵指定內容(@entity set-body -@ 用得到)。
captureIn :: Text -> [String] -> IO CliResult
captureIn input args =
  withTempHandle $ \hOut ->
    withTempHandle $ \hErr ->
      withTempHandle $ \hIn -> do
        TIO.hPutStr hIn input
        hFlush hIn
        hSeek hIn AbsoluteSeek 0
        code <- runCliWith (CliIO hOut hErr hIn) args
        CliResult code <$> readBack hOut <*> readBack hErr

-- | 暫存檔當 handle。編碼與換行都釘死:預設的 code page 會讓繁中變成
-- @InvalidArgument@,而 Windows 的 @\\r\\n@ 轉換會讓逐行比對整片失敗。
withTempHandle :: (Handle -> IO a) -> IO a
withTempHandle act = withSystemTempFile "aapms-cli-io" $ \_ h -> do
  hSetEncoding h utf8
  hSetNewlineMode h noNewlineTranslation
  act h

-- | 以位元組讀回再自己解 UTF-8,不受 handle 編碼狀態影響。
readBack :: Handle -> IO Text
readBack h = do
  hFlush h
  hSeek h AbsoluteSeek 0
  TE.decodeUtf8 <$> BS.hGetContents h

-- | 對 'withCliVault' 建好的那個 Vault 下指令。
sf :: [String] -> IO CliResult
sf args = capture ("--vault" : "liftgame" : args)

sfIn :: Text -> [String] -> IO CliResult
sfIn input args = captureIn input ("--vault" : "liftgame" : args)

-- | 預期成功;失敗就把 stderr 印出來讓測試看得懂發生什麼事。
sfOk :: [String] -> IO Text
sfOk args = do
  r <- sf args
  case crExit r of
    ExitSuccess -> pure (crOut r)
    c ->
      fail $
        "指令 " <> unwords args <> " 以 " <> show c <> " 收場:\n" <> T.unpack (crErr r)

-- | @--json@ 跑一次,回解出來的信封。
sfJson :: [String] -> IO Value
sfJson args = do
  r <- capture ("--vault" : "liftgame" : "--json" : args)
  case decodeStrict (TE.encodeUtf8 (crOut r)) of
    Just v -> pure v
    Nothing -> fail ("stdout 不是合法 JSON:" <> T.unpack (crOut r) <> T.unpack (crErr r))

-- | 信封的 @data@。
dataOf :: Value -> Value
dataOf v = case jsonPath ["data"] v of
  Just d -> d
  Nothing -> error ("信封裡沒有 data:" <> show v)

-- | 依鍵名逐層往下鑽。
jsonPath :: [Text] -> Value -> Maybe Value
jsonPath [] v = Just v
jsonPath (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= jsonPath ks
jsonPath _ _ = Nothing

-- 環境 -------------------------------------------------------------------------

registryDir :: IO FilePath
registryDir = go ["../types/registry", "types/registry", "../../types/registry"]
  where
    go [] = fail "找不到 types/registry/;測試需要真正的型別註冊表"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

withEnvVars :: [(String, String)] -> IO a -> IO a
withEnvVars vars act = bracket save restore (const act)
  where
    save = mapM apply vars
    apply (k, v) = do
      old <- lookupEnv k
      setEnv k v
      pure (k, old)
    restore = mapM_ (\(k, mv) -> maybe (unsetEnv k) (setEnv k) mv)

-- | 臨時目錄 + 已經 @vault init@ 過的 Vault。回呼拿到的是 Vault 根目錄。
withCliVault :: (FilePath -> IO a) -> IO a
withCliVault act =
  withSystemTempDirectory "aapms-cli" $ \dir -> do
    reg <- registryDir
    withEnvVars
      [ ("STORYFLOW_VAULTS", dir </> "vaults.toml")
      , ("STORYFLOW_REGISTRY", reg)
      ]
      $ do
        r <- capture ["vault", "init", dir, "--name", "liftgame"]
        case crExit r of
          ExitSuccess -> act dir
          c -> fail ("vault init 失敗(" <> show c <> "):" <> T.unpack (crErr r))

-- 斷言小工具 -------------------------------------------------------------------

shouldContainT :: Text -> Text -> Expectation
shouldContainT hay needle =
  if needle `T.isInfixOf` hay
    then pure ()
    else expectationFailure ("找不到「" <> T.unpack needle <> "」,實際輸出:\n" <> T.unpack hay)

-- | 信封是失敗、且 code 相符。
shouldHaveCode :: Value -> Text -> Expectation
shouldHaveCode env code = case jsonPath ["error", "code"] env of
  Just (String c) | c == code -> pure ()
  other -> expectationFailure ("預期 code " <> T.unpack code <> ",實際 " <> show other)

-- | 從 @data@ 裡挖出 Entity 的 id ——寫入類指令回的是 'EntityView'。
idFromJson :: Value -> String
idFromJson env = case jsonPath ["data", "entity", "id"] env of
  Just (String i) -> T.unpack i
  other -> error ("data.entity.id 取不到:" <> show other)

-- | 臨時 Vault + 一台跑在隨機埠上的 aapms 伺服器。
--
-- 回呼拿到 Vault 根目錄與 base url,因此同一個 Vault 可以__同時__以內嵌與遠端
-- 兩種模式操作 —— T15 的逐字元比對就是靠這一點:兩邊看到的是同一份資料、同一批
-- id,輸出若有差就真的是渲染路徑的差,不是資料的差。
withCliServer :: (FilePath -> String -> IO a) -> IO a
withCliServer act = withCliVault $ \dir -> do
  st <- newAppState (Just "liftgame") dir
  Warp.testWithApplication (pure (app Nothing st)) $ \port ->
    act dir ("http://127.0.0.1:" <> show port)

-- | 對遠端伺服器下指令。刻意__不帶 --vault__ —— 那兩個不能併用。
sfRemote :: String -> [String] -> IO CliResult
sfRemote url args = capture ("--remote" : url : args)

sfRemoteJson :: String -> [String] -> IO Value
sfRemoteJson url args = do
  r <- capture ("--remote" : url : "--json" : args)
  case decodeStrict (TE.encodeUtf8 (crOut r)) of
    Just v -> pure v
    Nothing -> fail ("stdout 不是合法 JSON:" <> T.unpack (crOut r) <> T.unpack (crErr r))

-- | 要求 token 的伺服器版本。client 端的 token 由 @STORYFLOW_TOKEN@ 環境變數
-- 提供,所以呼叫端自己用 withEnvVars 設(可以故意設錯)。
withCliServerToken :: Text -> (FilePath -> String -> IO a) -> IO a
withCliServerToken token act = withCliVault $ \dir -> do
  st <- newAppState (Just "liftgame") dir
  Warp.testWithApplication (pure (app (Just token) st)) $ \port ->
    act dir ("http://127.0.0.1:" <> show port)
