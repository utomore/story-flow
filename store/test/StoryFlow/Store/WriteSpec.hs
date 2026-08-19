-- | entity-graph-core/F004 T9 + entity-graph-core/F005 T8 \/ T9 \/ T10:樂觀鎖寫入、主體 frontmatter、
-- 正文與關聯。
--
-- 「以過期 revision 寫入時檔案位元組完全未變」是本檔最重要的一條:樂觀鎖只要
-- 在拒絕之前先寫了任何東西,它就沒有意義了。
module StoryFlow.Store.WriteSpec (spec) where

import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, secondsToDiffTime, utctDay)
import Database.SQLite.Simple
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, IdPrefix (PEnt), mkId, renderId)
import StoryFlow.Core.Link (Link (..), LinkKind (..))
import StoryFlow.Core.Meta (Meta (..), Status (..))
import StoryFlow.Md (MetaOverride (..))
import StoryFlow.Store.Error (StoreError (..))
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Index (rebuildIndex)
import StoryFlow.Store.Query (linksFrom, lookupEntity)
import StoryFlow.Store.Row (dayText)
import StoryFlow.Store.Write
import Test.Hspec

spec :: Spec
spec = do
  describe "T9 writeEntityMeta(片段)" $ do
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

  -- entity-graph-core/F005 T8:writeEntityMeta 能改主體的 frontmatter
  describe "T8 writeEntityMeta(檔案層主體)" $ do
    it "改主體的 summary:frontmatter 更新、revision 加一、索引跟著更新" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< writeEntityMeta conn v main_ 3 (\ov -> ov {moSummary = Just "改過的主體總結"})
        wrNewRevision r `shouldBe` 4

        updated <- readVaultFile v linda
        updated `shouldSatisfy` T.isInfixOf "summary: 改過的主體總結"
        updated `shouldSatisfy` T.isInfixOf "revision: 4"

        textsOf conn "SELECT summary FROM entities WHERE id = 'ent-7f3a'" ()
          `shouldReturn` ["改過的主體總結"]
        scalarInt conn "SELECT revision FROM entities WHERE id = 'ent-7f3a'" ()
          `shouldReturn` 4

    it "沒被指定的 frontmatter 欄位原值保留(applyOverride 只覆蓋有給的那幾欄)" $
      withSampleIndex $ \v conn -> do
        _ <- orDie =<< writeEntityMeta conn v main_ 3 (\ov -> ov {moSummary = Just "換一句"})
        Just e <- lookupEntity conn main_
        metaTitle (entMeta e) `shouldBe` "琳達"
        metaAliases (entMeta e) `shouldBe` ["小琳", "第七織手"]
        metaStatus (entMeta e) `shouldBe` Canon
        metaCreated (entMeta e) `shouldBe` fromGregorian 2026 8 16

    it "節層一個位元組都沒動 —— frontmatter 整段重寫不牽連片段" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        _ <- orDie =<< writeEntityMeta conn v main_ 3 (\ov -> ov {moSummary = Just "換一句"})
        updated <- readVaultFile v linda
        snd (T.breakOn "## 外貌" updated) `shouldBe` snd (T.breakOn "## 外貌" original)

    it "主體以過期的 revision 寫入時回 StaleRevision,檔案位元組完全未變" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- writeEntityMeta conn v main_ 1 (\ov -> ov {moSummary = Just "不該被寫進去"})
        r `shouldBe` Left (StaleRevision main_ 1 3)
        readVaultFile v linda `shouldReturn` original

  -- entity-graph-core/F005 T9:writeEntityBody 對節與主體各自改到正確的正文
  describe "T9 writeEntityBody" $ do
    it "改片段的正文:片段的 entBody 是新值,主體的 entBody 不變" $
      withSampleIndex $ \v conn -> do
        Just mBefore <- lookupEntity conn main_
        _ <- orDie =<< writeEntityBody conn v frag 1 "她把頭髮剪短了。"
        Just f <- lookupEntity conn frag
        entBody f `shouldBe` "她把頭髮剪短了。"
        Just mAfter <- lookupEntity conn main_
        entBody mAfter `shouldBe` entBody mBefore
        -- 正文改了,revision 也要動
        metaRevision (entMeta f) `shouldBe` 2

    it "改主體的正文:主體的 entBody 是新值,兩個片段都不變" $
      withSampleIndex $ \v conn -> do
        Just b1 <- lookupEntity conn frag
        _ <- orDie =<< writeEntityBody conn v main_ 3 "# 琳達\n\n改過的概述。"
        Just m <- lookupEntity conn main_
        entBody m `shouldBe` "# 琳達\n\n改過的概述。"
        Just a1 <- lookupEntity conn frag
        entBody a1 `shouldBe` entBody b1
        metaRevision (entMeta a1) `shouldBe` metaRevision (entMeta b1)

    it "改完的檔案仍然解析得回來,節數不變" $
      withSampleIndex $ \v conn -> do
        _ <- orDie =<< writeEntityBody conn v frag 1 "新的正文。"
        scalarInt conn "SELECT count(*) FROM entities WHERE file_path = ?" (Only linda)
          `shouldReturn` 3

    it "revision 不符時一個位元組都不寫" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- writeEntityBody conn v frag 99 "不該被寫進去"
        r `shouldBe` Left (StaleRevision frag 99 1)
        readVaultFile v linda `shouldReturn` original

  -- entity-graph-core/F005 T10:addEntityLink 與 removeEntityLink 只動來源端
  describe "T10 addEntityLink / removeEntityLink" $ do
    it "加一筆 contradicts:linksFrom 多一筆,目標端的檔案位元組不變" $
      withSampleIndex $ \v conn -> do
        targetBefore <- readVaultFile v dao
        _ <- orDie =<< addEntityLink conn v frag 1 (Link Contradicts (refOf "ent-1001") Nothing)
        ls <- linksFrom conn frag
        map linkKind ls `shouldBe` [PartOf, Contradicts]
        map linkTarget ls `shouldBe` [refOf "ent-7f3a", refOf "ent-1001"]
        readVaultFile v dao `shouldReturn` targetBefore

    it "主體也加得動(frontmatter 的 links)" $
      withSampleIndex $ \v conn -> do
        _ <- orDie =<< addEntityLink conn v main_ 3 (Link References (refOf "ent-c41d") (Just "背景"))
        ls <- linksFrom conn main_
        map linkKind ls `shouldBe` [References]
        txt <- readVaultFile v linda
        txt `shouldSatisfy` T.isInfixOf "  - {kind: references, target: ent-c41d, note: 背景}"

    it "刪掉一筆已存在的關聯" $
      withSampleIndex $ \v conn -> do
        _ <- orDie =<< removeEntityLink conn v frag2 4 OccursIn (refOf "ent-c41d")
        ls <- linksFrom conn frag2
        map linkKind ls `shouldBe` [PartOf, Contradicts]

    it "刪除不存在的配對回 LinkNotFound,且檔案位元組完全未變" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- removeEntityLink conn v frag 1 Contradicts (refOf "ent-1001")
        r `shouldBe` Left (LinkNotFound frag Contradicts (refOf "ent-1001"))
        readVaultFile v linda `shouldReturn` original

    it "同一對出現多次時全部刪掉" $
      withSampleIndex $ \v conn -> do
        _ <- orDie =<< addEntityLink conn v frag 1 (Link PartOf (refOf "ent-7f3a") Nothing)
        _ <- orDie =<< removeEntityLink conn v frag 2 PartOf (refOf "ent-7f3a")
        linksFrom conn frag `shouldReturn` []

    it "關聯操作也走樂觀鎖" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- addEntityLink conn v frag 99 (Link Contradicts (refOf "ent-1001") Nothing)
        r `shouldBe` Left (StaleRevision frag 99 1)
        readVaultFile v linda `shouldReturn` original

  -- entity-graph-core/F005 驗收標準 3
  describe "驗收標準 3:未被修改的區塊逐字不變" $ do
    it "含 YAML 註解、混合行尾、非標準縮排的檔案,只有目標節的 meta 區塊改變" $
      withVaultIndex $ \v conn -> do
        writeVaultFile v odd_ oddMd
        _ <- orDie =<< rebuildIndex conn v
        _ <-
          orDie
            =<< writeEntityMeta conn v (idOf "ent-000b") 1 (\ov -> ov {moSummary = Just "換掉的總結"})
        updated <- readVaultFile v odd_

        -- frontmatter 的註解、LF 行尾、第一節的四空白縮排全部逐字還在
        fst (T.breakOn "## 第二節" updated) `shouldBe` fst (T.breakOn "## 第二節" oddMd)
        updated `shouldSatisfy` T.isInfixOf "# 這份檔案的 frontmatter 有註解"
        updated `shouldSatisfy` T.isInfixOf "vault: liftgame     # 行末註解"
        updated `shouldSatisfy` T.isInfixOf "    - {kind: partOf, target: ent-0001}"

        -- 改到的只有目標節,而且沿用該檔多數的 CRLF
        updated `shouldSatisfy` T.isInfixOf "summary: 換掉的總結\r\n"
        updated `shouldSatisfy` T.isInfixOf "revision: 2\r\n"
        -- 目標節之後的正文也沒被動到
        snd (T.breakOn "正文二。" updated) `shouldBe` snd (T.breakOn "正文二。" oddMd)

    it "改主體的 frontmatter 時,兩個節都逐字不變" $
      withVaultIndex $ \v conn -> do
        writeVaultFile v odd_ oddMd
        _ <- orDie =<< rebuildIndex conn v
        _ <-
          orDie
            =<< writeEntityMeta conn v (idOf "ent-0001") 1 (\ov -> ov {moSummary = Just "主體的總結"})
        updated <- readVaultFile v odd_
        snd (T.breakOn "## 第一節" updated) `shouldBe` snd (T.breakOn "## 第一節" oddMd)
        -- 代價講明:frontmatter 是整段重寫,YAML 註解會被抹掉
        updated `shouldSatisfy` (not . T.isInfixOf "行末註解")

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
    dao = "items/織紋刀.md"
    odd_ = "lore/混合風格.md"
    main_ = idOf "ent-7f3a"
    frag = idOf "ent-7f3b"
    frag2 = idOf "ent-7f3c"

-- | frontmatter 有註解、frontmatter 用 LF 而正文用 CRLF、meta 區塊的 links
-- 縮排四個空白。三種「作者的手筆」一次湊齊。
oddMd :: T.Text
oddMd =
  T.intercalate
    "\n"
    [ "---"
    , "# 這份檔案的 frontmatter 有註解"
    , "id: ent-0001"
    , "vault: liftgame     # 行末註解"
    , "type: lore"
    , "title: 混合風格的檔案"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    ]
    <> "\n"
    <> T.replace
      "\n"
      "\r\n"
      ( T.unlines
          [ ""
          , "概述。"
          , ""
          , "## 第一節 {#ent-000a}"
          , ""
          , "```meta"
          , "summary: 第一節"
          , "links:"
          , "    - {kind: partOf, target: ent-0001}"
          , "```"
          , ""
          , "正文一。"
          , ""
          , "## 第二節 {#ent-000b}"
          , ""
          , "```meta"
          , "summary: 第二節"
          , "```"
          , ""
          , "正文二。"
          ]
      )

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

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 8 16) (secondsToDiffTime 0)

-- | 被改的那一節之前的全部內容(frontmatter、主體正文、該節標題)。
headPart :: T.Text -> T.Text
headPart = fst . T.breakOn "```meta"

-- | 下一節開始之後的全部內容。
tailPart :: T.Text -> T.Text
tailPart = snd . T.breakOn "## 與塔主的過節"
