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
-- __W1 交付後的定向修訂(2026-08-30)加了 L25__:'Aapms.Service.Monad.ServiceM'
-- 不透明的守衛——@service\/src\/@ 底下不得宣告任何 type class 實例、不得用
-- standalone deriving 或 @StandaloneDeriving@ pragma 補一個實例,而 'ServiceM'
-- 自己的 deriving 子句逐字釘死。正規化規則與 L23 __逐字共用__,判準同樣寫成對
-- 「(檔名, 檔案全文)」的純函數('instanceDerivingViolations'),骨架(X28)與三份
-- 合成文字(X29)餵給同一個判準。
--
-- __spec 對照__(「1-to-1 測試對照表」——__預期綠__:骨架自身就承載的事實,
-- 從第一天就綠,而且應該綠,不得因為它綠就退回或改寫):
--
-- @
-- L23,X24  對 service\/src\/ 實況跑判準,違規清單為空;Monad.hs 恰好 3 行、其餘檔案 0 行 -> test_l23_real_source_is_clean, test_l23_real_source_line_counts [綠]
-- X25      合成文字裡插入巢狀呼叫,判準抓到那一行,插入的註解行不算違規           -> test_l23_synthetic_violation_detected [綠]
-- L25,X28  對 service\/src\/ 實況跑判準,違規清單為空;instance/StandaloneDeriving 各 0 行,deriving 起頭恰好 2 行、含 Monad 的恰好 1 行且逐字等於 canonical -> test_l25_real_source_is_clean, test_l25_real_source_line_counts [綠]
-- X29      三份合成文字(補 MonadError deriving instance / 改寫 deriving 子句 / 手寫 instance),各自恰好抓到那一行,插入的註解行不算違規 -> test_l25_synthetic_extra_monaderror_instance_detected, test_l25_synthetic_monaderror_appended_to_deriving_clause_detected, test_l25_synthetic_hand_written_instance_detected [綠]
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
-- L25 判準(spec「ServiceM 額外實例的靜態防線」四條,逐字翻譯)。
-- 正規化('codeLinesOf' \/ 'stripCR' \/ 'isFullCommentLine' \/ 'cutTrailingComment')
-- 與 L23 __逐字共用__,不重寫。

-- | 判準 4 釘死的 canonical 字面。
expectedServiceMDerivingLine :: Text
expectedServiceMDerivingLine = "deriving newtype (Functor, Applicative, Monad, MonadIO)"

-- | 判準 1:trim 後以 @instance @ 起頭(含尾隨空白,只擋宣告不擋 @instance@ 這個詞
-- 出現在別的位置)。
isInstanceDeclLine :: Text -> Bool
isInstanceDeclLine l = "instance " `T.isPrefixOf` T.strip l

-- | trim 後以 @deriving@ 起頭——判準 2 與判準 4 共用的前置條件。
isDerivingLine :: Text -> Bool
isDerivingLine l = "deriving" `T.isPrefixOf` T.strip l

-- | 判準 2:@deriving@ 起頭且含子字串 @instance@(擋
-- @deriving instance@ \/ @deriving newtype instance@ \/
-- @deriving anyclass instance@ \/ @deriving stock instance@ 全部四種寫法)。
isStandaloneDerivingInstanceLine :: Text -> Bool
isStandaloneDerivingInstanceLine l = isDerivingLine l && "instance" `T.isInfixOf` l

-- | 判準 3:任何程式碼行含子字串 @StandaloneDeriving@。
mentionsStandaloneDerivingPragma :: Text -> Bool
mentionsStandaloneDerivingPragma = T.isInfixOf "StandaloneDeriving"

-- | 判準 4 的候選行:@deriving@ 起頭且含子字串 @Monad@(篩選條件本身,不含
-- 「恰好一行」與「內容逐字相等」——那兩件事在下面逐行核對)。
isServiceMDerivingCandidateLine :: Text -> Bool
isServiceMDerivingCandidateLine l = isDerivingLine l && "Monad" `T.isInfixOf` l

-- | 判準 4 的「這一行合法」判定:必須落在 @Monad.hs@,且 trim 後逐字等於
-- 'expectedServiceMDerivingLine'。
isCanonicalServiceMDerivingLine :: FilePath -> Text -> Bool
isCanonicalServiceMDerivingLine path l =
  isMonadFile path && T.strip l == expectedServiceMDerivingLine

-- | __本檔 L25 的核心判準__:(檔名, 檔案全文) -> 每一條違規 (檔名, 行號)。
-- @service\/src\/@ 的實況(X28)與三份合成文字(X29)餵的是同一個函數。
--
-- 四條判準以 __布林 OR__ 合併成單一次每行掃描:同一行同時違反多條判準(例如
-- X29(a) 插入的 @deriving newtype instance MonadError …@ 同時撞上判準 2 與判準
-- 4 的候選條件)只計一次違規,對應 spec「違規行的清單」是行的集合,不是
-- (行, 判準) 的集合。
instanceDerivingViolations :: [(FilePath, Text)] -> [(FilePath, Int)]
instanceDerivingViolations files = concatMap checkFile files
  where
    checkFile (path, txt) =
      [ (path, i)
      | (i, l) <- codeLinesOf txt
      , isInstanceDeclLine l
          || isStandaloneDerivingInstanceLine l
          || mentionsStandaloneDerivingPragma l
          || (isServiceMDerivingCandidateLine l && not (isCanonicalServiceMDerivingLine path l))
      ]

-- | 一批檔案裡符合某個程式碼行判準的行數(不分是否違規)。X28 用來核對
-- instance\/StandaloneDeriving 各 0 行、deriving 起頭恰好 2 行。
countCodeLinesWhere :: (Text -> Bool) -> [(FilePath, Text)] -> Int
countCodeLinesWhere p files =
  length [() | (_, txt) <- files, (_, l) <- codeLinesOf txt, p l]

--------------------------------------------------------------------------------

-- | L23 的原有測試(未動)。'spec' 在檔案末尾把它與新增的 'spec25' 接起來。
specL23 :: Spec
specL23 = describe "F001 L23: service/src/ 不得在 Monad.hs 之外提到 runService(骨架承載,預期綠)" $ do
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

--------------------------------------------------------------------------------

-- | F001 L25:'Aapms.Service.Monad.ServiceM' 不透明的靜態防線(骨架承載,預期綠)。
-- 正規化與 L23 逐字共用,判準見 'instanceDerivingViolations'。
spec25 :: Spec
spec25 = describe "F001 L25: service/src/ 不得宣告任何 instance,ServiceM 的 deriving 子句逐字釘死(骨架承載,預期綠)" $ do
  it "test_l25_real_source_is_clean (X28, L25): 對 service/src/ 的實況跑判準,違規清單為空" $ do
    files <- serviceSourceFiles
    instanceDerivingViolations files `shouldBe` []

  it "test_l25_real_source_line_counts (X28): instance 0 行、StandaloneDeriving 0 行,其中含 Monad 的 deriving 恰好 1 行且逐字等於 canonical" $ do
    files <- serviceSourceFiles
    countCodeLinesWhere isInstanceDeclLine files `shouldBe` 0
    countCodeLinesWhere mentionsStandaloneDerivingPragma files `shouldBe` 0
    let monadCandidates =
          [ (path, l)
          | (path, txt) <- files
          , (_, l) <- codeLinesOf txt
          , isServiceMDerivingCandidateLine l
          ]
    length monadCandidates `shouldBe` 1
    case monadCandidates of
      [(path, l)] -> do
        normalizePath path `shouldBe` "Aapms/Service/Monad.hs"
        T.strip l `shouldBe` expectedServiceMDerivingLine
      other -> expectationFailure ("預期恰好一行含 Monad 的 deriving,得到 " <> show (length other) <> " 行")

  it "test_l25_synthetic_extra_monaderror_instance_detected (X29a): 插入 deriving newtype instance MonadError …,判準恰好抓到那一行" $ do
    monadOriginal <- readServiceSource "Aapms/Service/Monad.hs"
    let monadLines = T.lines monadOriginal
        insertedLineNo = length monadLines + 1
        newMonadText = T.unlines (monadLines ++ ["deriving newtype instance MonadError ServiceError ServiceM"])
        files = [("Aapms/Service/Monad.hs", newMonadText)]
    instanceDerivingViolations files `shouldBe` [("Aapms/Service/Monad.hs", insertedLineNo)]

  it "test_l25_synthetic_monaderror_appended_to_deriving_clause_detected (X29b): 把 ServiceM 的 deriving 子句改成多帶 MonadError ServiceError,判準恰好抓到被改掉的那一行" $ do
    monadOriginal <- readServiceSource "Aapms/Service/Monad.hs"
    let original = expectedServiceMDerivingLine
        replaced = "deriving newtype (Functor, Applicative, Monad, MonadIO, MonadError ServiceError)"
        monadLines = T.lines monadOriginal
    targetLineNo <-
      case find (\(_, l) -> T.strip l == original) (zip [1 :: Int ..] monadLines) of
        Just (i, _) -> pure i
        Nothing -> fail "測試前置:骨架裡找不到 ServiceM 的 canonical deriving 行,骨架可能已改動"
    let newMonadLines = map (\l -> if T.strip l == original then replaced else l) monadLines
        newMonadText = T.unlines newMonadLines
        files = [("Aapms/Service/Monad.hs", newMonadText)]
    instanceDerivingViolations files `shouldBe` [("Aapms/Service/Monad.hs", targetLineNo)]

  it "test_l25_synthetic_hand_written_instance_detected (X29c): 插入 instance Semigroup (ServiceM ()) where,判準恰好抓到那一行;插入的註解行不算" $ do
    scopeOriginal <- readServiceSource "Aapms/Service/Scope.hs"
    let scopeLines = T.lines scopeOriginal
        insertedLineNo = length scopeLines + 1
        injected =
          [ "instance Semigroup (ServiceM ()) where"
          , "-- 這裡本來想 deriving newtype instance,別這麼做"
          ]
        newScopeText = T.unlines (scopeLines ++ injected)
        files = [("Aapms/Service/Scope.hs", newScopeText)]
    instanceDerivingViolations files `shouldBe` [("Aapms/Service/Scope.hs", insertedLineNo)]

--------------------------------------------------------------------------------

-- | 對外匯出的完整規格:L23(原有,未動)接上 L25(本次新增)。
spec :: Spec
spec = specL23 >> spec25
