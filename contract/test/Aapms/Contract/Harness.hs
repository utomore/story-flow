-- | 契約測試的共用底稿:從__外面__跑 aapms。
--
-- 與 @cli/test@ 的 Fixtures 不同,這裡__不__ import 任何 aapms library——每一條測試都是
-- 真的起一個子行程、餵參數、收位元組。這是 ADR-018 第二條的前提:契約測試只依賴對外契約,
-- 整個重建期(S1–S3)都有效。
--
-- 執行檔由 cabal 的 @build-tool-depends@ 放進 PATH;找不到就直接 fail,不退回任何猜測。
--
-- 執行期契約名稱集中在這裡(下方「環境變數」一節):S3 的 @workspace@ / @shell@ 依 ADR-017
-- 把 @STORYFLOW_*@ 換成 @AAPMS_*@、@.storyflow/@ 換成 @.aapms/@ 時,只改這一個模組。
module Aapms.Contract.Harness
  ( -- * 跑指令
    Run (..)
  , aapms
  , aapmsIn
  , aapmsJson
  , aapmsOk
  , serve

    -- * 環境
  , Vault (..)
  , withVault
  , findIndexDb

    -- * JSON 小工具
  , jsonPath
  , jsonText
  , decodeValue

    -- * 斷言
  , shouldContainT
  , shouldHaveCode
  ) where

import Control.Monad (filterM)
import Data.Aeson (Value (..), eitherDecodeStrict)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , listDirectory
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
import Test.Hspec

-- 環境變數 ---------------------------------------------------------------------
-- 這三個名字是目前(S0)的執行期契約,S3 依 ADR-017 改名時只動這裡。

envVaults, envRegistry :: String
envVaults = "STORYFLOW_VAULTS"
envRegistry = "STORYFLOW_REGISTRY"

-- 跑指令 -----------------------------------------------------------------------

data Run = Run
  { runExit :: ExitCode
  , runOut :: Text
  , runErr :: Text
  , runOutBytes :: BS.ByteString
  }
  deriving stock (Show, Eq)

exe :: String -> IO FilePath
exe name =
  findExecutable name >>= \case
    Just p -> pure p
    Nothing -> fail ("PATH 上找不到執行檔 " <> name <> ";build-tool-depends 沒生效")

-- | 起子行程;stdout / stderr 以位元組收回,自己解 UTF-8。
-- 不用 @readProcess@ 系列:它們依 locale 解碼,Windows 的 cp950 會把繁中弄壞。
runExe :: String -> [(String, String)] -> Maybe FilePath -> BS.ByteString -> [String] -> IO Run
runExe name extraEnv cwd' input args = do
  path <- exe name
  base <- getEnvironment
  let env' = extraEnv <> filter ((`notElem` map fst extraEnv) . fst) base
      cp =
        (proc path args)
          { env = Just env'
          , cwd = cwd'
          , std_in = CreatePipe
          , std_out = CreatePipe
          , std_err = CreatePipe
          }
  (Just hIn, Just hOut, Just hErr, ph) <- createProcess cp
  mapM_ (`hSetBinaryMode` True) [hIn, hOut, hErr]
  BS.hPut hIn input
  hClose hIn
  out <- BS.hGetContents hOut
  err <- BS.hGetContents hErr
  code <- waitForProcess ph
  pure Run {runExit = code, runOut = lenient out, runErr = lenient err, runOutBytes = out}
  where
    lenient = TE.decodeUtf8With TE.lenientDecode

-- | 對 'withVault' 建好的 Vault 下指令(自動帶 @--vault@)。
aapms :: Vault -> [String] -> IO Run
aapms v = aapmsIn v ""

aapmsIn :: Vault -> BS.ByteString -> [String] -> IO Run
aapmsIn v input args = runExe "aapms" (vaultEnv v) (Just (vaultRoot v)) input ("--vault" : vaultName v : args)

-- | @--json@ 跑一次,回解出來的信封(不管成功失敗)。
aapmsJson :: Vault -> [String] -> IO Value
aapmsJson v args = do
  r <- aapms v ("--json" : args)
  decodeValue (runOutBytes r) (runErr r)

-- | 預期成功;失敗就把 stderr 帶進錯誤訊息。
aapmsOk :: Vault -> [String] -> IO Run
aapmsOk v args = do
  r <- aapms v args
  case runExit r of
    ExitSuccess -> pure r
    c -> fail ("aapms " <> unwords args <> " 以 " <> show c <> " 收場:\n" <> T.unpack (runErr r))

-- | 跑 @aapms-serve@(不需要 Vault,例如 @--openapi@)。
serve :: [String] -> IO Run
serve = runExe "aapms-serve" [] Nothing ""

-- 環境 -------------------------------------------------------------------------

data Vault = Vault
  { vaultRoot :: FilePath
  , vaultName :: String
  , vaultEnv :: [(String, String)]
  }

registryDir :: IO FilePath
registryDir = go ["../types/registry", "types/registry"]
  where
    go [] = fail "找不到 types/registry/;契約測試需要真正的型別註冊表"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then canonicalizePath c else go rest

-- | 臨時目錄 + 已經 @vault init@ 過的 Vault,全域註冊表也在臨時目錄裡——
-- 測試碰不到使用者真實的環境。
withVault :: (Vault -> IO a) -> IO a
withVault act =
  withSystemTempDirectory "aapms-contract" $ \dir -> do
    reg <- registryDir
    let root = dir </> "vault"
        v =
          Vault
            { vaultRoot = root
            , vaultName = "contract"
            , vaultEnv = [(envVaults, dir </> "vaults.toml"), (envRegistry, reg)]
            }
    r <- runExe "aapms" (vaultEnv v) (Just dir) "" ["vault", "init", root, "--name", vaultName v]
    case runExit r of
      ExitSuccess -> act v
      c -> fail ("vault init 失敗(" <> show c <> "):" <> T.unpack (runErr r))

-- | 找 Vault 的索引檔:任何以 @.@ 開頭的子目錄底下的 @index.db@。
-- 不寫死 marker 目錄名,ADR-017 改成 @.aapms/@ 之後這個函式不用動。
findIndexDb :: Vault -> IO FilePath
findIndexDb v = do
  entries <- listDirectory (vaultRoot v)
  dots <- filterM (doesDirectoryExist . (vaultRoot v </>)) (filter ("." `isPrefixOf`) entries)
  hits <- filterM doesFileExist [vaultRoot v </> d </> "index.db" | d <- dots]
  case hits of
    [p] -> pure p
    [] -> fail ("Vault 裡找不到 index.db:" <> vaultRoot v)
    ps -> fail ("Vault 裡有不只一個 index.db:" <> show ps)

-- JSON 小工具 ------------------------------------------------------------------

decodeValue :: BS.ByteString -> Text -> IO Value
decodeValue bytes stderrText = case eitherDecodeStrict bytes of
  Right v -> pure v
  Left e ->
    fail
      ( "stdout 不是合法 JSON("
          <> e
          <> "):\n"
          <> T.unpack (TE.decodeUtf8With TE.lenientDecode bytes)
          <> "\nstderr:\n"
          <> T.unpack stderrText
      )

jsonPath :: [Text] -> Value -> Maybe Value
jsonPath [] v = Just v
jsonPath (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= jsonPath ks
jsonPath _ _ = Nothing

jsonText :: [Text] -> Value -> IO Text
jsonText ks v = case jsonPath ks v of
  Just (String t) -> pure t
  other -> fail ("JSON 路徑 " <> show ks <> " 不是字串:" <> show other <> "\n整份:" <> show v)

-- 斷言 -------------------------------------------------------------------------

shouldContainT :: Text -> Text -> Expectation
shouldContainT hay needle =
  if needle `T.isInfixOf` hay
    then pure ()
    else expectationFailure ("找不到「" <> T.unpack needle <> "」,實際輸出:\n" <> T.unpack hay)

-- | 信封是失敗、且 @error.code@ 相符。
shouldHaveCode :: Value -> Text -> Expectation
shouldHaveCode env code = case jsonPath ["error", "code"] env of
  Just (String c) | c == code -> pure ()
  other -> expectationFailure ("預期 code " <> T.unpack code <> ",實際 " <> show other)

