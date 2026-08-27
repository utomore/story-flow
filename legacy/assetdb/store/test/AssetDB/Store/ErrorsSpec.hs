module AssetDB.Store.ErrorsSpec (spec) where

import AssetDB.Store.Errors
import AssetDB.Store.Migrate (MigrationError (..))
import Control.Exception (ErrorCall (..), toException)
import Data.Text qualified as T
import Database.SQLite.Simple (Error (..), SQLError (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "renderMigrationError" $ do
    it "DatabaseNewerThanCode 說得出發生什麼事,也說得出該做什麼" $ do
      let msg = renderMigrationError (DatabaseNewerThanCode 4 3)
      -- 「發生什麼事」與「我現在該做什麼」兩件事都要有。
      -- 只講前者的錯誤訊息等於沒講(G-E003)。
      msg `shouldSatisfy` T.isInfixOf "較新版本"
      msg `shouldSatisfy` T.isInfixOf "cabal install"

    it "不再是 GHC 的英文 show 形狀" $ do
      -- 原本印的是 `DatabaseNewerThanCode 4 3` 加 backtrace ——
      -- 那對使用者沒有任何意義。
      let msg = renderMigrationError (DatabaseNewerThanCode 4 3)
      msg `shouldNotSatisfy` T.isInfixOf "DatabaseNewerThanCode"
      msg `shouldNotSatisfy` T.isInfixOf "CallStack"

    it "版本號如實出現在訊息裡" $ do
      let msg = renderMigrationError (DatabaseNewerThanCode 12 7)
      msg `shouldSatisfy` T.isInfixOf "v12"
      msg `shouldSatisfy` T.isInfixOf "v7"

  describe "isBusy" $ do
    it "SQLITE_BUSY 與 SQLITE_LOCKED 為真" $ do
      -- 這兩個的典型成因是背景掃描正在寫入 —— 預期中的並行,不是故障
      -- (ADR-009)。HTTP 層要靠它決定回 503 而不是 500。
      isBusy (sqlErr ErrorBusy) `shouldBe` True
      isBusy (sqlErr ErrorLocked) `shouldBe` True

    it "約束違反與損毀為假" $ do
      isBusy (sqlErr ErrorConstraint) `shouldBe` False
      isBusy (sqlErr ErrorCorrupt) `shouldBe` False
      isBusy (sqlErr ErrorReadOnly) `shouldBe` False

  describe "renderSqlError" $ do
    it "忙碌時建議重試" $
      renderSqlError (sqlErr ErrorBusy) `shouldSatisfy` T.isInfixOf "稍後重試"

    it "約束違反不建議重試(重試不會變好)" $ do
      let msg = renderSqlError (sqlErr ErrorConstraint)
      msg `shouldSatisfy` T.isInfixOf "約束"
      msg `shouldNotSatisfy` T.isInfixOf "稍後重試"

    it "細節壓成單行" $ do
      -- 多行的細節在終端機裡只會把有用的訊息推出畫面。
      let msg = renderSqlError (sqlErr ErrorCorrupt) {sqlErrorDetails = "第一行\n第二行"}
      T.lines msg `shouldSatisfy` ((== 1) . length)

  describe "renderUnexpected" $ do
    it "認得 MigrationError" $
      renderUnexpected (toException (DatabaseNewerThanCode 4 3))
        `shouldSatisfy` T.isInfixOf "較新版本"

    it "認得 SQLError" $
      renderUnexpected (toException (sqlErr ErrorFull))
        `shouldSatisfy` T.isInfixOf "磁碟空間"

    it "認不得的也壓成單行,不吐 backtrace" $ do
      let msg = renderUnexpected (toException (ErrorCall "壞了\n非常壞"))
      T.lines msg `shouldSatisfy` ((== 1) . length)
      msg `shouldSatisfy` T.isInfixOf "未預期"

sqlErr :: Error -> SQLError
sqlErr e = SQLError {sqlError = e, sqlErrorDetails = "details", sqlErrorContext = "ctx"}

