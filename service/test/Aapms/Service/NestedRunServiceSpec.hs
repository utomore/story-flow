-- | F001 L23:巢狀 'Aapms.Service.Monad.runService' 的靜態防線——對
-- @service\/src\/@ 底下每一個 @.hs@ 檔的原始碼文字做斷言:除
-- @Aapms\/Service\/Monad.hs@ 之外,任何檔案的程式碼行都不得含子字串
-- @runService@;@Monad.hs@ 之內只允許匯出清單段、簽名行、第 0 欄起頭的定義等式
-- 三種形狀。
--
-- __本檔的判準本身寫成對「(檔名, 檔案全文)」的純函數__('runServiceViolations'),
-- 骨架(X24)與一份合成文字(X25)餵給同一個判準——沒有 X25 這條就可能是空洞的
-- (掃描器寫壞時 X24 也會綠)。
--
-- __spec 對照__(「1-to-1 測試對照表」——__預期綠__:骨架自身就承載的事實,
-- 從第一天就綠,而且應該綠,不得因為它綠就退回或改寫):
--
-- @
-- L23,X24  對 service\/src\/ 實況跑判準,違規清單為空;Monad.hs 恰好 3 行、其餘檔案 0 行 -> test_l23_real_source_is_clean, test_l23_real_source_line_counts [綠]
-- X25      合成文字裡插入巢狀呼叫,判準抓到那一行,插入的註解行不算違規           -> test_l23_synthetic_violation_detected [綠]
-- @
module Aapms.Service.NestedRunServiceSpec (spec) where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Aapms.Service.Fixtures (readServiceSource, serviceSourceFiles)

--------------------------------------------------------------------------------
-- 判準(spec「巢狀 runService 的靜態防線」步驟 1–4,逐字翻譯)

-- | 去掉行尾 @\\r@(專案的 @core.autocrlf@ 讓 @.hs@ 在乾淨 checkout 上是 CRLF)。
stripCR :: Text -> Text
stripCR = T.dropWhileEnd (== '\r')

-- | trim 後以 @--@ 開頭的整行(行註解與 haddock)。
isFullCommentLine :: Text -> Bool
isFullCommentLine = T.isPrefixOf "--" . T.stripStart

-- | 從第一個「前面至少一個空白的雙連字號」(@\" --\"@)起截掉(行尾註解)。
cutTrailingComment :: Text -> Text
cutTrailingComment = fst . T.breakOn " --"

-- | 一個檔案正規化後的「程式碼行」,保留原始行號。
codeLinesOf :: Text -> [(Int, Text)]
codeLinesOf txt =
  [ (i, cutTrailingComment stripped)
  | (i, raw) <- zip [1 :: Int ..] (T.lines txt)
  , let stripped = stripCR raw
  , not (isFullCommentLine stripped)
  ]

mentionsRunService :: Text -> Bool
mentionsRunService = T.isInfixOf "runService"

-- | 相對路徑正規化(反斜線 → 正斜線),與 'Aapms.Service.Fixtures.serviceSourceFiles'
-- 產生的路徑格式一致。
normalizePath :: FilePath -> FilePath
normalizePath = map (\c -> if c == '\\' then '/' else c)

isMonadFile :: FilePath -> Bool
isMonadFile path = normalizePath path == "Aapms/Service/Monad.hs"

-- | @Monad.hs@ 內的匯出清單範圍(兩端都含),依原始行號:從 trim 後以
-- @module Aapms.Service.Monad@ 起頭的那一行,到第一個含 @) where@ 的行為止。
exportListRange :: [(Int, Text)] -> Maybe (Int, Int)
exportListRange cls = do
  (startI, _) <- find (\(_, l) -> "module Aapms.Service.Monad" `T.isPrefixOf` T.strip l) cls
  (endI, _) <- find (\(i, l) -> i >= startI && ") where" `T.isInfixOf` l) cls
  pure (startI, endI)

-- | 型別簽名行:trim 後逐字等於這一行。
isSignatureLine :: Text -> Bool
isSignatureLine l = T.strip l == "runService :: Env -> ServiceM a -> IO (Either ServiceError a)"

-- | 定義等式的開頭:以 @runService@ 起頭於第 0 欄(行首完全無空白)。
isDefinitionStartLine :: Text -> Bool
isDefinitionStartLine = T.isPrefixOf "runService"

-- | __本檔的核心判準__:(檔名, 檔案全文) -> 每一條違規 (檔名, 行號)。
-- @service\/src\/@ 的實況(X24)與一份合成文字(X25)餵的是同一個函數。
runServiceViolations :: [(FilePath, Text)] -> [(FilePath, Int)]
runServiceViolations files = concatMap checkFile files
  where
    checkFile (path, txt)
      | isMonadFile path =
          let cls = codeLinesOf txt
              mRange = exportListRange cls
              inExportRange i = maybe False (\(s, e) -> i >= s && i <= e) mRange
           in [ (path, i)
              | (i, l) <- cls
              , mentionsRunService l
              , not (inExportRange i)
              , not (isSignatureLine l)
              , not (isDefinitionStartLine l)
              ]
      | otherwise =
          [(path, i) | (i, l) <- codeLinesOf txt, mentionsRunService l]

-- | 單一檔案裡「程式碼行含 runService」的數量(不分是否違規),X24 用來核對
-- Types.hs/Scope.hs 各 0 行、Monad.hs 恰好 3 行。
mentionCountFor :: [(FilePath, Text)] -> FilePath -> Int
mentionCountFor files name =
  length
    [ ()
    | (path, txt) <- files
    , normalizePath path == name
    , (_, l) <- codeLinesOf txt
    , mentionsRunService l
    ]

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F001 L23: service/src/ 不得在 Monad.hs 之外提到 runService(骨架承載,預期綠)" $ do
  it "test_l23_real_source_is_clean (X24, L23): 對 service/src/ 的實況跑判準,違規清單為空" $ do
    files <- serviceSourceFiles
    runServiceViolations files `shouldBe` []

  it "test_l23_real_source_line_counts (X24): Types.hs/Scope.hs 各 0 行,Monad.hs 恰好 3 行(匯出清單、簽名、定義等式)" $ do
    files <- serviceSourceFiles
    mentionCountFor files "Aapms/Service/Types.hs" `shouldBe` 0
    mentionCountFor files "Aapms/Service/Scope.hs" `shouldBe` 0
    mentionCountFor files "Aapms/Service/Monad.hs" `shouldBe` 3

  it "test_l23_synthetic_violation_detected (X25): 合成文字插入巢狀呼叫,判準恰好抓到那一行;插入的註解行不算" $ do
    scopeOriginal <- readServiceSource "Aapms/Service/Scope.hs"
    monadOriginal <- readServiceSource "Aapms/Service/Monad.hs"
    let scopeLines = T.lines scopeOriginal
        insertedLineNo = length scopeLines + 1
        injected =
          [ "  _ <- liftIO (runService env inner)"
          , "-- 這裡本來想 runService,別這麼做"
          ]
        newScopeText = T.unlines (scopeLines ++ injected)
        files = [("Aapms/Service/Scope.hs", newScopeText), ("Aapms/Service/Monad.hs", monadOriginal)]
    runServiceViolations files `shouldBe` [("Aapms/Service/Scope.hs", insertedLineNo)]
