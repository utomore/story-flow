-- | 契約 5:OpenAPI golden file(system.md「系統對外介面 › 2. HTTP」)。
--
-- @aapms-serve --openapi@ 由 servant 型別推導;它一變,三個殼(CLI @--remote@ / HTTP / MCP)
-- 同時變。golden file 讓這種變動__必須是刻意的__:更新 golden 是一次 review 得到的 diff,
-- 不是不小心改了型別就靜默跟著走。
--
-- 比對的是解析後的 JSON 值(鍵序無關),不是位元組。
module Aapms.Contract.OpenApiGoldenSpec (spec) where

import Aapms.Contract.Harness
import Data.Aeson (Value, eitherDecodeStrict)
import qualified Data.ByteString as BS
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import Test.Hspec

goldenPath :: FilePath
goldenPath = "fixtures/openapi.golden.json"

spec :: Spec
spec = describe "OpenAPI golden" $ do
  it "aapms-serve --openapi 成功,輸出是合法 JSON 且有 paths" $ do
    r <- serve ["--openapi"]
    runExit r `shouldBe` ExitSuccess
    doc <- decodeValue (runOutBytes r) (runErr r)
    jsonPath ["paths"] doc `shouldSatisfy` (/= Nothing)
    jsonPath ["info", "title"] doc `shouldSatisfy` (/= Nothing)

  it "與 fixtures/openapi.golden.json 語意相同(API 改了就要刻意更新 golden)" $ do
    exists <- doesFileExist goldenPath
    exists `shouldBe` True
    golden <- BS.readFile goldenPath
    expected <- either (fail . ("golden 不是合法 JSON:" <>)) pure (eitherDecodeStrict golden :: Either String Value)
    r <- serve ["--openapi"]
    actual <- decodeValue (runOutBytes r) (runErr r)
    if actual == expected
      then pure ()
      else
        expectationFailure $
          unlines
            [ "OpenAPI 與 golden 不同。若這次改動是刻意的,重新產生 golden:"
            , "  cabal run aapms-serve -- --openapi > contract/" <> goldenPath
            , "然後在 PR 裡把 diff 當成 API 變更來 review。"
            ]
