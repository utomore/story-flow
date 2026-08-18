module AssetDB.Server.CliSpec (spec) where

import AssetDB.Server.App (ServerConfig (..), defaultHost)
import AssetDB.Server.Cli
import Data.List (isInfixOf)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "parsePort" $ do
    it "非數字時回傳清楚的錯誤訊息,而不是 read 的例外" $
      case parsePort ["abc"] of
        Left err -> do
          err `shouldSatisfy` ("port" `isInfixOf`)
          err `shouldSatisfy` ("abc" `isInfixOf`)
          err `shouldNotSatisfy` ("no parse" `isInfixOf`)
        Right n -> expectationFailure ("應該要失敗,卻解析成 " <> show n)

    it "合法數字時正確解析" $
      parsePort ["9000"] `shouldBe` Right 9000

    it "缺省時使用預設值 8787" $ do
      defaultPort `shouldBe` 8787
      parsePort [] `shouldBe` Right defaultPort

    it "超出 1..65535 時視為錯誤" $ do
      parsePort ["0"] `shouldSatisfy` isLeft
      parsePort ["70000"] `shouldSatisfy` isLeft
      parsePort ["-1"] `shouldSatisfy` isLeft

  describe "parseArgs" $ do
    it "db 路徑帶非數字 port 時整體失敗,不會啟動伺服器" $
      parseArgs ["db.sqlite", "abc"] `shouldSatisfy` isLeft

    it "只給 db 路徑時用預設 port、預設 host 且不啟用 --init" $
      case parseArgs ["lib/.assetdb/assetdb.sqlite"] of
        Right (RunServer cfg) -> do
          scPort cfg `shouldBe` defaultPort
          scHost cfg `shouldBe` defaultHost
          scInit cfg `shouldBe` False
          scDbPath cfg `shouldBe` "lib/.assetdb/assetdb.sqlite"
        other -> expectationFailure ("預期 RunServer,收到 " <> show other)

    it "--init 可以出現在任意位置" $ do
      let wants as = case parseArgs as of
            Right (RunServer cfg) -> scInit cfg
            _ -> False
      wants ["db.sqlite", "--init"] `shouldBe` True
      wants ["--init", "db.sqlite"] `shouldBe` True
      wants ["db.sqlite", "9000", "--init"] `shouldBe` True

    it "--help 優先於「第一個參數是 db 路徑」" $ do
      parseArgs ["--help"] `shouldBe` Right ShowUsage
      parseArgs ["db.sqlite", "--help"] `shouldBe` Right ShowUsage

    it "--emit-types 帶輸出檔" $
      parseArgs ["--emit-types", "types.ts"] `shouldBe` Right (EmitTypes "types.ts")

    it "無法辨識的旗標是錯誤,不會被當成 db 路徑" $
      parseArgs ["--wat"] `shouldSatisfy` isLeft

    -- bug-0004:預設不對區網開放,要開放得使用者明講。
    it "--host 可以覆寫預設綁定介面,且不影響 db 路徑與 port" $
      case parseArgs ["db.sqlite", "9000", "--host", "0.0.0.0"] of
        Right (RunServer cfg) -> do
          scHost cfg `shouldBe` "0.0.0.0"
          scPort cfg `shouldBe` 9000
          scDbPath cfg `shouldBe` "db.sqlite"
        other -> expectationFailure ("預期 RunServer,收到 " <> show other)

    it "--host 可以出現在 db 路徑之前" $
      case parseArgs ["--host", "0.0.0.0", "db.sqlite"] of
        Right (RunServer cfg) -> scHost cfg `shouldBe` "0.0.0.0"
        other -> expectationFailure ("預期 RunServer,收到 " <> show other)

    -- 照收的話會安靜地綁到一個叫 "--init" 的介面上,而使用者以為自己開了 --init。
    it "--host 後面接旗標是錯誤,不會把旗標吃掉" $ do
      parseArgs ["db.sqlite", "--host", "--init"] `shouldSatisfy` isLeft
      parseArgs ["db.sqlite", "--host"] `shouldSatisfy` isLeft

    it "--host 的值不會被誤認成 db 路徑或 port" $
      case parseArgs ["--host", "0.0.0.0", "db.sqlite", "--init"] of
        Right (RunServer cfg) -> do
          scDbPath cfg `shouldBe` "db.sqlite"
          scPort cfg `shouldBe` defaultPort
          scInit cfg `shouldBe` True
        other -> expectationFailure ("預期 RunServer,收到 " <> show other)

  describe "extractHost" $ do
    it "沒有 --host 時原樣回傳其餘參數" $
      extractHost ["db.sqlite", "9000"] `shouldBe` Right (Nothing, ["db.sqlite", "9000"])

    it "抽走 --host 與它的值" $
      extractHost ["db.sqlite", "--host", "0.0.0.0", "9000"]
        `shouldBe` Right (Just "0.0.0.0", ["db.sqlite", "9000"])

    it "重複指定時後者勝" $
      extractHost ["--host", "1.2.3.4", "--host", "0.0.0.0"]
        `shouldBe` Right (Just "0.0.0.0", [])

  describe "parseArgs 的路徑推導" $ do
    -- 分隔符用 '</>' 組出來,不寫死 —— Windows 上是反斜線。
    it "cache 與 web 路徑由 db 路徑推導" $
      case parseArgs ["root" </> ".assetdb" </> "assetdb.sqlite"] of
        Right (RunServer cfg) -> do
          scCacheRoot cfg `shouldBe` "root" </> ".assetdb" </> "cache" </> "thumbs"
          scWebRoot cfg `shouldBe` "root" </> "web"
        other -> expectationFailure ("預期 RunServer,收到 " <> show other)

  describe "usageText" $ do
    -- enhance-0007:usage 的預設 port 必須引用 defaultPort 常數,
    -- 兩者再次漂移時這條會紅。
    it "包含的預設 port 與 defaultPort 常數一致" $ do
      defaultPort `shouldBe` 8787
      usageText `shouldSatisfy` (show defaultPort `isInfixOf`)

    it "說明 --init 的用途" $
      usageText `shouldSatisfy` ("--init" `isInfixOf`)

    it "說明 --host 與預設值,並點出服務沒有身分驗證" $ do
      usageText `shouldSatisfy` ("--host" `isInfixOf`)
      usageText `shouldSatisfy` (defaultHost `isInfixOf`)
      usageText `shouldSatisfy` ("身分驗證" `isInfixOf`)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
