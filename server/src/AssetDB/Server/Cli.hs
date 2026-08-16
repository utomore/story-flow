-- | 伺服器執行檔的命令列參數解析。
--
-- 刻意放在 library 而不是 @app\/Main.hs@:參數解析是最容易讓使用者踩到的
-- 一段程式,而放在執行檔裡的東西測不到(bug-0003)。
module AssetDB.Server.Cli
  ( CliCommand (..)
  , parseArgs
  , parsePort
  , defaultPort
  , usageText
  ) where

import AssetDB.Server.App (ServerConfig (..))
import Data.List (partition)
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

-- | 伺服器預設監聽埠。
defaultPort :: Int
defaultPort = 8787

data CliCommand
  = ShowUsage
  | EmitTypes FilePath
  | RunServer ServerConfig
  deriving stock (Eq, Show)

-- | 解析參數。失敗時回傳給使用者看的訊息,而不是拋例外。
parseArgs :: [String] -> Either String CliCommand
parseArgs args
  -- @--help@ 必須在「第一個參數是 db 路徑」之前比對。否則它會被當成資料庫檔名,
  -- 伺服器直接啟動並阻塞 —— 一個想看用法的人得到的是一個掛住的終端機。
  | any (`elem` ["--help", "-h"]) args = Right ShowUsage
  | otherwise =
      case positional of
        ["--emit-types", out] -> Right (EmitTypes out)
        (db : rest) | not (isFlag db) -> RunServer . mkConfig db wantsInit <$> parsePort rest
        [] -> Right ShowUsage
        (bad : _) -> Left ("無法辨識的參數:" <> bad <> "\n\n" <> usageText)
  where
    (initFlags, positional) = partition (== "--init") args
    wantsInit = not (null initFlags)
    isFlag s = take 1 s == "-"

-- | Port 一律走 'readMaybe'。用 'read' 的話打錯值只會拿到
-- @Prelude.read: no parse@,看不出是哪個參數出錯。
parsePort :: [String] -> Either String Int
parsePort [] = Right defaultPort
parsePort (p : _) =
  case readMaybe p of
    Nothing -> Left ("port 必須是數字,收到:" <> p)
    Just n
      | n >= 1 && n <= 65535 -> Right n
      | otherwise -> Left ("port 必須介於 1 到 65535,收到:" <> show (n :: Int))

mkConfig :: FilePath -> Bool -> Int -> ServerConfig
mkConfig db doInit port =
  ServerConfig
    { scDbPath = db
    , scCacheRoot = assetdbDir </> "cache" </> "thumbs"
    , scWebRoot = takeDirectory assetdbDir </> "web"
    , scPort = port
    , scInit = doInit
    }
  where
    assetdbDir = takeDirectory db

usageText :: String
usageText =
  unlines
    [ "用法:assetdb-server <db 路徑> [port] [--init]   預設 port " <> show defaultPort
    , "     assetdb-server --emit-types <輸出檔>       產生前端的 TypeScript 型別"
    , ""
    , "--init  對不存在的路徑建立新資料庫。不加時找不到檔案就是錯誤,"
    , "        不會靜默建出一個查詢全回 0 筆的空庫。"
    , ""
    , "靜態前端由 <db 的上上層目錄>/web 提供,縮圖由 <db 的上層目錄>/cache/thumbs 提供。"
    ]
