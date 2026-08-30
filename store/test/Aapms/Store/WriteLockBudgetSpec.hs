-- | graph-core\/F008 LAW-17(ADR-022 寫鎖預算,結構約束)。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F008-store-write-operations.md@)
--
-- @
-- LAW-17(部分) withTransaction 出現 0 次,也不出現字面量 \"BEGIN\" \/ \"COMMIT\"        -> test_no_withTransaction
-- LAW-17(部分) Database.SQLite.Simple 只在 Edit 與 Write 被 import                        -> test_sqlite_import_scope
-- @
--
-- LAW-17 原本的第三個子句——「所有檔案 IO 與所有 md 序列化都不在任何 SQLite 呼叫的括號內」——
-- __2026-08-25 GAP-12 裁決已經從 law 本身移除__(不是延後,是撤掉):「X 是否巢狀在 Y 的括號內」
-- 是語法樹層級的問題,文字掃描在真實的多行 @do@\/@let@\/縮排排版下會同時製造偽陽性與偽陰性
-- (與 spec-gaps.md 的 GAP-3、F007 同一個根)。降級為 @\/arch-audit subsys graph-core@ 階段閘門的
-- 人工檢查項(spec「實作備註」段的清單),不是 qa 的自動化測試範圍。__L17 現在只剩兩個子句,
-- 本檔對它們的覆蓋就是完整覆蓋__,不再有待補的第三條。
module Aapms.Store.WriteLockBudgetSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Test.Hspec

-- | LAW-17 涵蓋的四個檔案(相對 @aapms-store@ 套件根目錄——@cabal test@ 的工作目錄)。
lockBudgetFiles :: [FilePath]
lockBudgetFiles =
  [ "src/Aapms/Store/Edit.hs"
  , "src/Aapms/Store/Write.hs"
  , "src/Aapms/Store/Node.hs"
  , "src/Aapms/Store/Create.hs"
  ]

-- | 去掉每一行 @--@ 之後的內容(含 Haddock @-- |@ \/ @-- ^@ 的說明文字),逐行處理。
-- 這四個檔案目前沒有把 @--@ 用在字串字面值裡,不處理那種情況。
stripLineComments :: Text -> Text
stripLineComments = T.unlines . map stripLine . T.lines
  where
    stripLine ln = fst (T.breakOn "--" ln)

readStripped :: FilePath -> IO Text
readStripped fp = stripLineComments <$> TIO.readFile fp

-- | 該行(去頭尾空白後)是不是一條 @import Database.SQLite.Simple@。
isSqliteImportLine :: Text -> Bool
isSqliteImportLine raw =
  let ln = T.strip raw
   in "import Database.SQLite.Simple" `T.isPrefixOf` ln
        || "import qualified Database.SQLite.Simple" `T.isPrefixOf` ln

hasSqliteImport :: Text -> Bool
hasSqliteImport content = any isSqliteImportLine (T.lines content)

spec :: Spec
spec = describe "graph-core/F008 LAW-17 ADR-022 寫鎖預算(結構約束,可讀原始碼判定)" $ do
  it "四個檔案的程式碼(排除 -- 註解)withTransaction 出現 0 次,不出現字面量 \"BEGIN\" / \"COMMIT\"" $ do
    contents <- mapM readStripped lockBudgetFiles
    let combined = T.concat contents
    T.count "withTransaction" combined `shouldBe` 0
    T.count (T.pack "\"BEGIN\"") combined `shouldBe` 0
    T.count (T.pack "\"COMMIT\"") combined `shouldBe` 0

  it "Database.SQLite.Simple 只在 Aapms.Store.Edit 與 Aapms.Store.Write 被 import(Node/Create 不 import)" $ do
    editHas <- hasSqliteImport <$> TIO.readFile "src/Aapms/Store/Edit.hs"
    writeHas <- hasSqliteImport <$> TIO.readFile "src/Aapms/Store/Write.hs"
    nodeHas <- hasSqliteImport <$> TIO.readFile "src/Aapms/Store/Node.hs"
    createHas <- hasSqliteImport <$> TIO.readFile "src/Aapms/Store/Create.hs"
    editHas `shouldBe` True
    writeHas `shouldBe` True
    nodeHas `shouldBe` False
    createHas `shouldBe` False
