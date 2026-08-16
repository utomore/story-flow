-- | T9:樂觀鎖寫入。
--
-- 「以過期 revision 寫入時檔案位元組完全未變」是本檔最重要的一條:樂觀鎖只要
-- 在拒絕之前先寫了任何東西,它就沒有意義了。
module StoryFlow.Store.WriteSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, secondsToDiffTime, utctDay)
import Database.SQLite.Simple
import StoryFlow.Core.Id (Id, IdPrefix (PEnt), mkId, parseId, renderId)
import StoryFlow.Md (MetaOverride (..))
import StoryFlow.Store.Error (StoreError (..))
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Row (dayText)
import StoryFlow.Store.Write
import Test.Hspec

spec :: Spec
spec = do
  describe "T9 writeEntityMeta" $ do
    it "以正確的 revision 寫入:summary 換掉、revision 加一、updated 為今天" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- orDie =<< writeEntityMeta conn v frag 1 (\ov -> ov {moSummary = Just "改過的總結"})
        wrNewRevision r `shouldBe` 2
        wrPath r `shouldBe` linda

        updated <- readVaultFile v linda
        updated `shouldSatisfy` T.isInfixOf "summary: 改過的總結"
        updated `shouldSatisfy` T.isInfixOf "revision: 2"
        today <- utctDay <$> getCurrentTime
        updated `shouldSatisfy` T.isInfixOf ("updated: " <> dayText today)

        -- 其餘節逐字未變:只有 ent-7f3b 的 meta 區塊被重新序列化
        headPart updated `shouldBe` headPart original -- frontmatter + 主體正文 + 節標題
        tailPart updated `shouldBe` tailPart original -- ent-7f3c 整節

        -- 索引跟著更新
        textsOf conn "SELECT summary FROM entities WHERE id = 'ent-7f3b'" ()
          `shouldReturn` ["改過的總結"]
        scalarInt conn "SELECT revision FROM entities WHERE id = 'ent-7f3b'" ()
          `shouldReturn` 2

    it "以過期的 revision 寫入時回 StaleRevision,檔案位元組完全未變" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- writeEntityMeta conn v frag 99 (\ov -> ov {moSummary = Just "不該被寫進去"})
        r `shouldBe` Left (StaleRevision frag 99 1)
        readVaultFile v linda `shouldReturn` original

    it "寫入不存在的 id 回 EntityNotFound" $
      withSampleIndex $ \v conn -> do
        let ghost = idOf "ent-0000"
        r <- writeEntityMeta conn v ghost 1 id
        r `shouldBe` Left (EntityNotFound ghost)

    it "檔案層主體目前不支援,回 FrontmatterWriteUnsupported" $
      withSampleIndex $ \v conn -> do
        let main_ = idOf "ent-7f3a"
        r <- writeEntityMeta conn v main_ 3 id
        r `shouldBe` Left (FrontmatterWriteUnsupported main_)

    -- 索引寫不進去但檔案已經寫成功,語意上不是資料遺失。用 query_only 造出
    -- 「讀得到、寫不了」的索引,正好對應這個情境。
    it "索引更新失敗時回 IndexUpdateFailed,而檔案已經寫成功" $
      withSampleIndex $ \v conn -> do
        execute_ conn "PRAGMA query_only = ON"
        r <- writeEntityMeta conn v frag 1 (\ov -> ov {moSummary = Just "檔案寫得進去"})
        case r of
          Left (IndexUpdateFailed p _) -> p `shouldBe` linda
          other -> expectationFailure ("預期 IndexUpdateFailed,得到 " <> show other)
        execute_ conn "PRAGMA query_only = OFF"

        updated <- readVaultFile v linda
        updated `shouldSatisfy` T.isInfixOf "summary: 檔案寫得進去"
        -- 索引還停在舊值——這正是「資料已寫入,索引需重建」該有的樣子
        textsOf conn "SELECT summary FROM entities WHERE id = 'ent-7f3b'" ()
          `shouldReturn` ["銀灰短髮,左眼下方有織紋刺青"]

  describe "T9 allocateId" $ do
    it "沒撞號時直接用 salt 0 的結果" $
      withSampleIndex $ \_ conn -> do
        i <- orDie =<< allocateId conn PEnt "全新的片段" fixedTime
        i `shouldBe` mkId PEnt "全新的片段" fixedTime 0

    it "id 已存在時遞增 salt,產生相異 id" $
      withSampleIndex $ \_ conn -> do
        let taken = mkId PEnt "會撞號的內容" fixedTime 0
        occupy conn taken
        i <- orDie =<< allocateId conn PEnt "會撞號的內容" fixedTime
        i `shouldNotBe` taken
        i `shouldBe` mkId PEnt "會撞號的內容" fixedTime 1
  where
    linda = "characters/琳達.md"
    frag = idOf "ent-7f3b"

-- | 手動佔用一個 id,製造碰撞。
occupy :: Connection -> Id -> IO ()
occupy conn i =
  execute
    conn
    "INSERT INTO entities(id, vault, type, title, summary, status, source, revision,\
    \ created, updated, file_path)\
    \ VALUES (?, 'liftgame', 'lore', '佔位', '佔位', 'draft', 'human', 1,\
    \ '2026-08-16', '2026-08-16', 'characters/琳達.md')"
    (Only (renderId i))

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 8 16) (secondsToDiffTime 0)

-- | 被改的那一節之前的全部內容(frontmatter、主體正文、該節標題)。
headPart :: Text -> Text
headPart = fst . T.breakOn "```meta"

-- | 下一節開始之後的全部內容。
tailPart :: Text -> Text
tailPart = snd . T.breakOn "## 與塔主的過節"
