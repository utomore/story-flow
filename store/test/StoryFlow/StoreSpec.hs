module StoryFlow.StoreSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import StoryFlow.Core (coreVersion)
import StoryFlow.Store (storeVersion)
import Test.Hspec

spec :: Spec
spec = do
  describe "storyflow-store 骨架" $ do
    it "storeVersion 非空" $
      T.null storeVersion `shouldBe` False

    it "可 import storyflow-core,證明 store → core 的依賴方向已接上" $
      coreVersion `shouldBe` storeVersion

  describe "SQLite 建置環境" $ do
    it "direct-sqlite 已編入 FTS5 且支援 trigram tokenizer" $
      withTrigramTable $ \conn -> do
        rows <-
          query_ conn "SELECT body FROM t WHERE t MATCH '織紋刀'" ::
            IO [Only Text]
        rows `shouldBe` [Only "埃提亞崩塌前的織紋刀"]

    -- trigram 以三字元為索引單位,查詢字串少於 3 個字元一律不命中。
    -- 這不是 flag 沒生效,而是 tokenizer 的固有限制;P4 的候選撈取
    -- 必須自己處理二字詞(例如角色名「琳達」),見 func-0001 實作備註。
    it "查詢字串少於 3 個字元時 trigram 不命中(已知限制)" $
      withTrigramTable $ \conn -> do
        rows <-
          query_ conn "SELECT body FROM t WHERE t MATCH '織紋'" ::
            IO [Only Text]
        rows `shouldBe` []

-- | 建立一張裝了測試內容的 FTS5 trigram 表。
withTrigramTable :: (Connection -> IO a) -> IO a
withTrigramTable act =
  withConnection ":memory:" $ \conn -> do
    execute_ conn "CREATE VIRTUAL TABLE t USING fts5(body, tokenize='trigram')"
    execute_ conn "INSERT INTO t(body) VALUES ('埃提亞崩塌前的織紋刀')"
    act conn
