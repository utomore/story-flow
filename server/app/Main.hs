module Main (main) where

import AssetDB.Server.App
import AssetDB.Server.TsTypes (tsDefinitions)
import Data.ByteString qualified as BS
import Data.Text.Encoding (encodeUtf8)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))
import AssetDB.Console (setupConsole)

main :: IO ()
main = do
  setupConsole
  args <- getArgs
  case args of
    -- --help 必須在「第一個參數是 db 路徑」之前比對。否則它會被當成資料庫檔名,
    -- 伺服器直接啟動並阻塞 —— 一個想看用法的人得到的是一個掛住的終端機。
    _ | any (`elem` ["--help", "-h"]) args -> usage
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
    _ -> usage
  where
    usage = do
      putStrLn "用法:assetdb-server <db 路徑> [port]      預設 port 8787"
      putStrLn "     assetdb-server --emit-types <輸出檔>  產生前端的 TypeScript 型別"
      putStrLn ""
      putStrLn "靜態前端由 <db 的上上層目錄>/web 提供,縮圖由 <db 的上層目錄>/cache/thumbs 提供。"
