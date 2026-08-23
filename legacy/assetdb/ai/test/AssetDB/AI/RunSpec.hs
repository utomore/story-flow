-- | 批次驅動器的錯誤邊界(G-E003 T9)。
--
-- @ai_runs.status@ 是續跑邏輯的依據。前置步驟或驅動器本身炸掉時,一列
-- 永遠停在 @'running'@ 的 run 會讓「上次跑到哪裡」這個問題永遠沒有答案。
module AssetDB.AI.RunSpec (spec) where

import AssetDB.AI.Classify
import AssetDB.AI.Llm
import AssetDB.Store
import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad (void)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = around withSeeded $ do
  describe "classifyClusters 的前置步驟(G-E003)" $ do
    it "讀詞彙表失敗時回報中止,而且不留下 run 列" $ \st -> do
      let conn = storeConn st
      -- loadVocab 是 beginRun **之前**的一步。它失敗時還沒有 run 列可以
      -- 標記,所以正確的行為是回報中止,而不是讓例外穿出子系統邊界。
      execute_ conn "DROP TABLE categories"
      rep <- classifyClusters conn stubLlm defaultClassifyOptions [target]
      crAborted rep `shouldSatisfy` isJustText
      crDone rep `shouldBe` 0
      countRuns conn `shouldReturn` 0

    it "開 run 列失敗時一樣是回報,不是崩潰" $ \st -> do
      let conn = storeConn st
      execute_ conn "DROP TABLE ai_runs"
      rep <- classifyClusters conn stubLlm defaultClassifyOptions [target]
      crAborted rep `shouldSatisfy` isJustText

  describe "classifyClusters 的驅動器(G-E003)" $ do
    it "beginRun 之後炸掉時 run 列是 aborted,不是永遠 running" $ \st -> do
      let conn = storeConn st
          opts =
            defaultClassifyOptions
              { coOnProgress = \_ -> throwIO (ErrorCall "進度回呼炸了")
              }
      rep <- classifyClusters conn stubLlm opts [target]
      crAborted rep `shouldSatisfy` isJustText
      -- 這是整條測試的重點:run 列必須關掉。
      runStatuses conn `shouldReturn` ["aborted"]

    it "正常跑完時 run 列收在完成狀態" $ \st -> do
      let conn = storeConn st
      -- 空佇列是最單純的「跑完」:沒有任何一筆要處理,但 run 列照樣要收尾。
      rep <- classifyClusters conn stubLlm defaultClassifyOptions []
      crAborted rep `shouldBe` Nothing
      sts <- runStatuses conn
      sts `shouldSatisfy` all (`notElem` ["running", "aborted"])
      length sts `shouldBe` 1

--------------------------------------------------------------------------------

isJustText :: Maybe Text -> Bool
isJustText = maybe False (not . T.null)

-- | 永遠回「服務沒開」的 LLM。這幾條測試關心的是 run 列的生命週期,
-- 不是模型回了什麼 —— 逐筆失敗是合法結果,run 列照樣要收尾。
stubLlm :: Llm
stubLlm =
  fakeLlm
    defaultLlmConfig
    (\_ _ -> pure (Left (LlmUnavailable "測試用的假後端")))

target :: ClusterTarget
target =
  ClusterTarget
    { ctPackSlug = "demo"
    , ctPackName = "Demo"
    , ctShape = "sprites|U_W_WNa|.png"
    , ctCount = 4
    , ctSamples = ["P/Sprites/UI_A_B01a.png"]
    }

countRuns :: Connection -> IO Int
countRuns conn = do
  rows <- query_ conn "SELECT COUNT(*) FROM ai_runs" :: IO [Only Int]
  pure (case rows of (Only n : _) -> n; _ -> -1)

runStatuses :: Connection -> IO [Text]
runStatuses conn =
  map fromOnly <$> (query_ conn "SELECT status FROM ai_runs ORDER BY id" :: IO [Only Text])

withSeeded :: (Store -> IO ()) -> IO ()
withSeeded f = do
  st <- openStoreInMemory
  void (initSchema st)
  f st
  close (storeConn st)
