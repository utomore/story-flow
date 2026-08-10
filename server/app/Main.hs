module Main (main) where

import AssetDB.Server.App
import AssetDB.Server.TsTypes (tsDefinitions)
import Data.ByteString qualified as BS
import Data.Text.Encoding (encodeUtf8)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))
import System.IO

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- getArgs
  case args of
    ["--emit-types", out] -> do
      -- 明確以 UTF-8 位元組寫檔。Data.Text.IO 用 locale 編碼,
      -- Windows 上會寫壞非 ASCII 內容。
      BS.writeFile out (encodeUtf8 tsDefinitions)
      putStrLn ("已寫入 " <> out)
    (db : rest) -> do
      let assetdbDir = takeDirectory db
          port = case rest of (p : _) -> read p; _ -> 8787
      runServer
        ServerConfig
          { scDbPath = db
          , scCacheRoot = assetdbDir </> "cache" </> "thumbs"
          , scWebRoot = takeDirectory assetdbDir </> "web"
          , scPort = port
          }
    _ -> do
      putStrLn "用法:assetdb-server <db 路徑> [port]"
      putStrLn "     assetdb-server --emit-types <輸出檔>"
