-- | @story-flow-serve@ ——REST 伺服器的執行檔。
--
-- __為什麼不是 @story-flow serve@__:func-0008 原本把它寫成 CLI 的子指令,但
-- architecture.md 讓 @storyflow-api@ 獨立成套件的理由正是「CLI 的遠端模式需要
-- API 型別、但__不需要 servant-server 與 warp__ ——一個預設根本不開伺服器的執行檔
-- 不該把整套 HTTP 伺服器拖進來」。CLI 要有 @serve@,就一定得依賴
-- @storyflow-server@,warp 就進來了。獨立成第二個執行檔,架構圖裡 server 與 cli
-- 平行的關係才守得住。
module Main (main) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Options.Applicative
import StoryFlow.Api (storyFlowOpenApi)
import StoryFlow.Server (ServeOpts (..), defaultServeOpts, runServer)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

data Opts = Opts
  { oPort :: Int
  , oBind :: Text
  , oVault :: Maybe Text
  , oOpenApi :: Bool
  }

main :: IO ()
main = do
  o <- execParser pinfo
  if oOpenApi o
    then -- 不啟動伺服器,把文件印到 stdout 後結束。
    -- story-flow-serve --openapi > openapi.json 因此是給 Agent 的一步驟交付。
      BL8.putStrLn (encode storyFlowOpenApi)
    else do
      token <- fmap T.pack <$> lookupEnv "STORYFLOW_TOKEN"
      let opts =
            defaultServeOpts
              { soPort = oPort o
              , soBind = oBind o
              , soToken = nonEmpty token
              , soVault = oVault o
              }
      runServer opts >>= \case
        Right () -> pure ()
        Left e -> TIO.hPutStrLn stderr e >> exitFailure
  where
    nonEmpty (Just t) | not (T.null t) = Just t
    nonEmpty _ = Nothing

pinfo :: ParserInfo Opts
pinfo =
  info
    (helper <*> optsP)
    ( fullDesc
        <> header "story-flow-serve —— story-flow 的 REST API 伺服器"
        <> progDesc
          ( "預設綁 127.0.0.1:8787。綁非 loopback 位址時必須先設定環境變數 "
              <> "STORYFLOW_TOKEN,否則拒絕啟動。"
          )
    )

optsP :: Parser Opts
optsP =
  Opts
    <$> option auto (long "port" <> metavar "<n>" <> value 8787 <> showDefault <> help "監聽的通訊埠")
    <*> option
      str
      ( long "bind"
          <> metavar "<位址>"
          <> value "127.0.0.1"
          <> showDefault
          <> help "綁定位址。非 loopback 時必須設定 STORYFLOW_TOKEN"
      )
    <*> optional
      (option str (long "vault" <> metavar "<名稱>" <> help "指定 Vault;不給時從目前目錄向上搜尋"))
    <*> switch (long "openapi" <> help "不啟動伺服器,把 OpenAPI 3 文件印到 stdout 後結束")
