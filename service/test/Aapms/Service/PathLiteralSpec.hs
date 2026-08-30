-- | F002 L26:Machine 不自己拼路徑的靜態防線——對 @service\/src\/@ 底下每一個
-- @.hs@ 檔的原始碼文字做斷言:任何程式碼行都不得含以下五個__帶引號的__子字串之一
-- (逐字,含前後的雙引號):@".aapms"@、@"config.toml"@、@"index.db"@、@"cache"@、
-- @"thumbs"@。
--
-- 正規化規則與 F001 的 L23\/L25(見 "Aapms.Service.NestedRunServiceSpec")__逐字
-- 相同__(去行尾 @\\r@ → 丟掉 trim 後以 @--@ 開頭的整行 → 截掉第一個 @\" --\"@
-- 起的行尾註解):模組 haddock 本來就要寫「不自己拼 @.aapms\/@ 底下的路徑」這句話,
-- 全檔字串搜尋會把「文件寫得清楚」誤判成「越界」。
--
-- __本檔的判準本身寫成對「(檔名, 檔案全文)」的純函數__('pathLiteralViolations'),
-- @service\/src\/@ 的實況(X25)與一份合成文字(X26)餵給同一個判準——沒有 X26
-- 這條就可能是空洞的(掃描器寫壞時 X25 也會綠)。
--
-- __spec 對照__(「1-to-1 測試對照表」——__預期綠__:對原始碼文字的斷言,骨架自身
-- 就承載這個事實,從第一天就綠,而且應該綠,不得因為它綠就退回或改寫):
--
-- @
-- L26,X25  對 service\/src\/ 實況跑判準,違規清單為空                              -> test_l26_real_source_is_clean [綠]
-- X26      合成文字插入越界路徑字面,判準恰好抓到那一行,插入的註解行不算違規      -> test_l26_synthetic_violation_detected [綠]
-- @
module Aapms.Service.PathLiteralSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Aapms.Service.Fixtures (serviceSourceFiles)

--------------------------------------------------------------------------------
-- 正規化(與 F001 L23/L25 逐字相同,見 "Aapms.Service.NestedRunServiceSpec")

stripCR :: Text -> Text
stripCR = T.dropWhileEnd (== '\r')

isFullCommentLine :: Text -> Bool
isFullCommentLine = T.isPrefixOf "--" . T.stripStart

cutTrailingComment :: Text -> Text
cutTrailingComment = fst . T.breakOn " --"

codeLinesOf :: Text -> [(Int, Text)]
codeLinesOf txt =
  [ (i, cutTrailingComment stripped)
  | (i, raw) <- zip [1 :: Int ..] (T.lines txt)
  , let stripped = stripCR raw
  , not (isFullCommentLine stripped)
  ]

--------------------------------------------------------------------------------
-- 判準(spec「Machine 不自己拼路徑的靜態防線」步驟 1–2,逐字翻譯)

-- | 五個__帶引號的__路徑字面,逐字(含前後雙引號)。
pathLiterals :: [Text]
pathLiterals = ["\".aapms\"", "\"config.toml\"", "\"index.db\"", "\"cache\"", "\"thumbs\""]

-- | __本檔的核心判準__:(檔名, 檔案全文) -> 每一條違規 (檔名, 行號)。
-- @service\/src\/@ 的實況(X25)與一份合成文字(X26)餵的是同一個函數。
pathLiteralViolations :: [(FilePath, Text)] -> [(FilePath, Int)]
pathLiteralViolations files =
  [ (path, i)
  | (path, txt) <- files
  , (i, l) <- codeLinesOf txt
  , any (`T.isInfixOf` l) pathLiterals
  ]

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 L26: service/src/ 不得出現五個帶引號的路徑字面(骨架承載,預期綠)" $ do
  it "test_l26_real_source_is_clean (X25, L26): 對 service/src/ 的實況跑判準,違規清單為空" $ do
    files <- serviceSourceFiles
    pathLiteralViolations files `shouldBe` []

  it "test_l26_synthetic_violation_detected (X26): 合成文字插入越界路徑字面,判準恰好抓到那一行;插入的註解行不算" $ do
    files <- serviceSourceFiles
    machineOriginal <- case lookup "Aapms/Service/Machine.hs" files of
      Just txt -> pure txt
      Nothing -> fail "測試前置:serviceSourceFiles 裡找不到 Aapms/Service/Machine.hs,骨架可能已改動"
    let machineLines = T.lines machineOriginal
        insertedLineNo = length machineLines + 1
        injected =
          [ "  let p = root </> \".aapms\" </> \"index.db\""
          , "-- 別自己拼 \".aapms\" 底下的路徑"
          ]
        newMachineText = T.unlines (machineLines ++ injected)
        syntheticFiles = [("Aapms/Service/Machine.hs", newMachineText)]
    pathLiteralViolations syntheticFiles `shouldBe` [("Aapms/Service/Machine.hs", insertedLineNo)]
