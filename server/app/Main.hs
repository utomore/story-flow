module Main (main) where

import AssetDB.Console (setupConsole)
import AssetDB.Server.App (runServer)
import AssetDB.Server.Cli (CliCommand (..), parseArgs, usageText)
import AssetDB.Server.TsTypes (tsDefinitions)
import Data.ByteString qualified as BS
import Data.Text.Encoding (encodeUtf8)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  setupConsole
  args <- getArgs
  case parseArgs args of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right ShowUsage -> putStr usageText
    Right (EmitTypes out) -> do
      -- 明確以 UTF-8 位元組寫檔。Data.Text.IO 用 locale 編碼,
      -- Windows 上會寫壞非 ASCII 內容。
      BS.writeFile out (encodeUtf8 tsDefinitions)
      putStrLn ("已寫入 " <> out)
    Right (RunServer cfg) -> runServer cfg
