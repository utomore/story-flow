-- | T8:外部改動的過時偵測。
--
-- 這是 ADR-0002 那條「必須處理檔案被外部改動後索引過時」的成本。作者用編輯器
-- 改完檔案直接查詢,結果就該是新的,不必手動 @index rebuild@。
module StoryFlow.Store.StaleSpec (spec) where

import Control.Concurrent (threadDelay)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..))
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Index
import StoryFlow.Store.Vault (vaultAbsPath)
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec = describe "T8 過時偵測" $ do
  it "沒有任何改動時 staleFiles 是空的" $
    withSampleIndex $ \v conn ->
      staleFiles conn v `shouldReturn` []

  it "外部改動某一份檔案後 staleFiles 只回報那一份" $
    withSampleIndex $ \v conn -> do
      touchAfterDelay
      writeVaultFile v linda (lindaMd <> "\n補一段正文。\n")
      staleFiles conn v `shouldReturn` [linda]

  it "refreshStale 之後查得到新內容" $
    withSampleIndex $ \v conn -> do
      touchAfterDelay
      writeVaultFile v linda (T.replace "銀灰短髮,左眼下方有織紋刺青" "改過的總結" lindaMd)
      issues <- orDie =<< refreshStale conn v
      filter issueHasError issues `shouldBe` []
      textsOf conn "SELECT summary FROM entities WHERE id = 'ent-7f3b'" ()
        `shouldReturn` ["改過的總結"]
      staleFiles conn v `shouldReturn` []

  -- size 相同、只有 mtime 不同的改動最容易被漏掉:只比大小的實作會在這裡紅燈
  it "改動後大小相同但 mtime 不同的檔案仍被偵測到" $
    withSampleIndex $ \v conn -> do
      touchAfterDelay
      writeVaultFile v linda (T.replace "銀灰短髮剪到耳際" "銀灰長髮束在腦後" lindaMd)
      staleFiles conn v `shouldReturn` [linda]
      _ <- orDie =<< refreshStale conn v
      textsOf conn "SELECT id FROM entities WHERE id = 'ent-7f3b'" ()
        `shouldReturn` ["ent-7f3b"]

  it "檔案被刪除後 refreshStale 移除它的全部記錄" $
    withSampleIndex $ \v conn -> do
      removeFile (vaultAbsPath v linda)
      _ <- orDie =<< refreshStale conn v
      countRows conn "files" `shouldReturn` 4
      textsOf conn "SELECT id FROM entities WHERE file_path = ?" (Only (T.pack linda))
        `shouldReturn` []
      countRows conn "entities" `shouldReturn` 5
      countRows conn "entity_aliases" `shouldReturn` 1
      countRows conn "fts_map" `shouldReturn` 5
      countRows conn "entities_fts" `shouldReturn` 5

  it "新增一份檔案後 refreshStale 會把它補進來" $
    withSampleIndex $ \v conn -> do
      writeVaultFile v "lore/新的一篇.md" newLoreMd
      staleFiles conn v `shouldReturn` ["lore/新的一篇.md"]
      _ <- orDie =<< refreshStale conn v
      countRows conn "files" `shouldReturn` 6
      textsOf conn "SELECT id FROM entities WHERE file_path = 'lore/新的一篇.md'" ()
        `shouldReturn` ["ent-3001"]
  where
    linda = "characters/琳達.md"

-- | 檔案系統的時間戳解析度有限,連續兩次寫入可能落在同一個刻度上。
touchAfterDelay :: IO ()
touchAfterDelay = threadDelay 100000

newLoreMd :: T.Text
newLoreMd =
  T.unlines
    [ "---"
    , "id: ent-3001"
    , "vault: liftgame"
    , "type: lore"
    , "title: 新的一篇"
    , "summary: 後來才補寫的一段設定"
    , "status: draft"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 新的一篇"
    , ""
    , "正文。"
    ]
