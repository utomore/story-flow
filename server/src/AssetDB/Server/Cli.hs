-- | 伺服器執行檔的命令列參數解析。
--
-- 刻意放在 library 而不是 @app\/Main.hs@:參數解析是最容易讓使用者踩到的
-- 一段程式,而放在執行檔裡的東西測不到(delivery/B003)。
module AssetDB.Server.Cli
  ( CliCommand (..)
  , parseArgs
  , parsePort
  , extractHost
  , defaultPort
  , usageText
  , versionText
  ) where

import AssetDB.Server.App (ServerConfig (..), defaultHost)
import Data.List (partition)
import Data.Version (showVersion)
import Paths_assetdb_server (version)
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

-- | 伺服器預設監聽埠。
--
-- @web\/vite.config.ts@ 的 dev proxy 指向同一個埠號,而 Vite 設定檔與
-- Haskell 沒有共用的設定來源 —— 改這裡記得同步改那裡(delivery/E002)。
defaultPort :: Int
defaultPort = 8787

data CliCommand
  = ShowUsage
  | ShowVersion
  | EmitTypes FilePath
  | RunServer ServerConfig
  deriving stock (Eq, Show)

-- | 版本字串,唯一來源是 @assetdb-server.cabal@ 的 @version@ 欄位(delivery/E006)。
versionText :: String
versionText = "assetdb-server " <> showVersion version

-- | 解析參數。失敗時回傳給使用者看的訊息,而不是拋例外。
parseArgs :: [String] -> Either String CliCommand
parseArgs args
  -- @--help@ / @--version@ 必須在「第一個參數是 db 路徑」之前比對。否則它會被當成
  -- 資料庫檔名,伺服器直接啟動並阻塞 —— 一個想看用法的人得到的是一個掛住的終端機。
  | any (`elem` ["--help", "-h"]) args = Right ShowUsage
  | "--version" `elem` args = Right ShowVersion
  | otherwise = do
      (mHost, rest') <- extractHost args
      let (initFlags, positional) = partition (== "--init") rest'
          wantsInit = not (null initFlags)
          host = maybe defaultHost id mHost
      case positional of
        ["--emit-types", out] -> Right (EmitTypes out)
        (db : rest) | not (isFlag db) -> RunServer . mkConfig db wantsInit host <$> parsePort rest
        [] -> Right ShowUsage
        (bad : _) -> Left ("無法辨識的參數:" <> bad <> "\n\n" <> usageText)
  where
    isFlag s = take 1 s == "-"

-- | 抽出 @--host \<位址\>@,回傳位址與其餘參數。後出現者勝。
--
-- 值長得像旗標時**拒絕**而不是照收:@--host --init@ 若照收,會安靜地把伺服器
-- 綁到一個叫 @--init@ 的介面上(Warp 會當成主機名),而使用者以為自己開了
-- @--init@。這與 delivery/B003 的 partial read 是同一類錯誤 —— 參數被吃掉而沒人抗議。
extractHost :: [String] -> Either String (Maybe String, [String])
extractHost = go Nothing []
  where
    go acc seen [] = Right (acc, reverse seen)
    go _ _ ["--host"] = Left ("--host 需要一個位址,例如 --host 0.0.0.0\n\n" <> usageText)
    go _ seen ("--host" : v : rest)
      | take 1 v == "-" = Left ("--host 的值不能是旗標,收到:" <> v <> "\n\n" <> usageText)
      | null v = Left ("--host 的值不能是空字串\n\n" <> usageText)
      | otherwise = go (Just v) seen rest
    go acc seen (a : rest) = go acc (a : seen) rest

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

mkConfig :: FilePath -> Bool -> String -> Int -> ServerConfig
mkConfig db doInit host port =
  ServerConfig
    { scDbPath = db
    , scCacheRoot = assetdbDir </> "cache" </> "thumbs"
    , scWebRoot = takeDirectory assetdbDir </> "web"
    , scHost = host
    , scPort = port
    , scInit = doInit
    }
  where
    assetdbDir = takeDirectory db

usageText :: String
usageText =
  unlines
    [ "用法:assetdb-server <db 路徑> [port] [--host 位址] [--init]"
    , "                                              預設 port " <> show defaultPort <> "、host " <> defaultHost
    , "     assetdb-server --emit-types <輸出檔>       產生前端的 TypeScript 型別"
    , "     assetdb-server --version                   顯示版本號"
    , ""
    , "--init  對不存在的路徑建立新資料庫。不加時找不到檔案就是錯誤,"
    , "        不會靜默建出一個查詢全回 0 筆的空庫。"
    , ""
    , "--host  要綁定的網路介面。預設 " <> defaultHost <> ",只有本機連得到。"
    , "        本服務**沒有任何身分驗證**,填 0.0.0.0 或 * 等於把整個素材庫"
    , "        開放給同網段的所有機器 —— 那是你的決定,不是預設值。"
    , ""
    , "靜態前端由 <db 的上上層目錄>/web 提供,縮圖由 <db 的上層目錄>/cache/thumbs 提供。"
    ]
