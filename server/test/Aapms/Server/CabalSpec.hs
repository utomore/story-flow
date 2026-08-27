-- | T6:server 不依賴落地層。
--
-- service-and-interfaces/F003 驗收標準 3 的一半是「@aapms-server@ 不 import @aapms-store@」。
-- 那句話唯一守得住的形式是 @build-depends@ 裡沒有它——而這條約束正是
-- "Aapms.Server.Error" 改成以 'Aapms.Service.errorCode' 的字串分派狀態碼、
-- 而不是對 @StoreError@ 的建構子 pattern match 的原因。
module Aapms.Server.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "套件邊界" $ do

  -- G-E002 T4:--version 從 cabal 自動產生的 Paths_ 模組讀版本,它要登記在 autogen-modules。
  it "autogen-modules 含 Paths_aapms_server(G-E002)" $ do
    src <- readCabal
    ("Paths_aapms_server" `isInfixOf` src) `shouldBe` True
    ("autogen-modules" `isInfixOf` src) `shouldBe` True
  it "build-depends 不含落地層" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  it "build-depends 含它真正依賴的三個內部套件" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, True)) required

forbidden :: [String]
forbidden = ["aapms-store", "aapms-md", "sqlite-simple", "direct-sqlite", "aapms-cli"]

-- | conflict-detection/F004:@aapms-conflict@ 進了這張表。
--
-- @POST \/conflict\/context@ 的 handler 呼叫 @gatherContext@,所以 server 認得它
-- 是必然的。它__不是落地層__ ——那個套件的 @build-depends@ 逐字擋著
-- @aapms-store@ \/ @sqlite-simple@,所以「server 不 import 落地層」這條約束
-- 不會因為它而被繞過。
--
-- llm-workshop-mcp/F004:@aapms-workshop@ \/ @aapms-llm@ 同一個理由——
-- @workshopH@ 呼叫 @startWorkshop@\/@loadSession@\/@stepWorkshop@\/@commitStage@,
-- @acquireLlmClient@ 讀 @[llm]@ 設定並建 @LlmClient@,兩者都不是落地層。
required :: [String]
required =
  [ "aapms-api"
  , "aapms-conflict"
  , "aapms-core"
  , "aapms-llm"
  , "aapms-service"
  , "aapms-workshop"
  , "warp"
  , "servant-server"
  ]

readCabal :: IO String
readCabal = go ["aapms-server.cabal", "server/aapms-server.cabal"]
  where
    go [] = fail "找不到 aapms-server.cabal"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then T.unpack . TE.decodeUtf8 <$> BS.readFile c else go rest

-- | 只看以逗號開頭的行:本檔案的 .cabal 註解就正好提到了 aapms-store。
dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False
