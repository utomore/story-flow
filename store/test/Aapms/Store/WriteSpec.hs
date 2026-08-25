-- | graph-core\/F008:契約 E 的改寫\/配號組——'writeMeta' \/ 'writeAssetFields' \/
-- 'writeBody' \/ 'addLink' \/ 'removeLink' \/ 'upsertLicense' \/ 'allocateId'。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F008-store-write-operations.md@)
--
-- @
-- L1   樂觀鎖:不符即拒且檔案未動                    -> test_E5(writeMeta 案例)
-- L2   revision 恰好 +1,且與檔案一致                -> test_E5 / 各 it 內建的 wrRevision 檢查
-- L3   位元組保留                                    -> test_E5 / test_writeBody
-- L4   asset 唯讀欄位不變                            -> test_L4_L5
-- L5   AssetPatch 的三態語意                         -> test_L4_L5
-- L6   addLink / removeLink 往返                     -> test_L6
-- L7   removeLink 沒命中不寫檔                        -> test_E7
-- L8   upsertLicense 讀回相等                        -> test_L8
-- L14  allocateId 互異,且成功時才給 id(固定 t,2026-08-25 G8 收緊)  -> test_L14
-- L14b 碰撞查詢失敗即失敗                             -> test_E15
-- E4   writeAssetFields 三態語意 + 唯讀欄位           -> test_L4_L5(以 E4 的情境為準,合併寫)
-- E5   樂觀鎖失敗路徑                                -> test_E5
-- E6   allocateId 人為碰撞(2026-08-25 G8 裁決:t 明碼參數後可精確重現) -> test_E6
-- E7   removeLink 沒命中                             -> test_E7
-- E9   writeBody 不吃掉 payload 欄位                  -> test_writeBody
-- E15  allocateId 索引查詢失敗                        -> test_E15
-- @
module Aapms.Store.WriteSpec (spec) where

import Control.Monad (forM_)
import Data.List (find, nub)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple (execute, execute_, withTransaction)
import Test.Hspec
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (PEnt), Ref, VaultId (..), idPrefix, localRef, newId)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), LinkKind (References))
import Aapms.Core.Meta (Meta (..), Revision (..), Source (Human), Status (Canon), TypeKey (..))
import Aapms.Md.Document (Document (..), Section (..))
import Aapms.Md.Inherit (MetaOverride (..))
import Aapms.Md.Parse (parseDocument, toLicenses, toPack, toTopic)
import Aapms.Md.Render (renderSection)
import Aapms.Store.Atomic (readTextFile)
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Fixtures
import Aapms.Store.Marker (VaultHandle, vhConn, vhRoot)
import Aapms.Store.Query (linksFrom)
import Aapms.Store.Row (insertSql, nodeColumnList, nodeFields)
import Aapms.Store.Write
import System.FilePath ((</>))

--------------------------------------------------------------------------------

parseOrFail :: Text -> IO Document
parseOrFail raw = either (\e -> fail ("解析失敗:" <> show e)) pure (parseDocument raw)

rereadDoc :: VaultHandle -> FilePath -> IO Document
rereadDoc vh rel = parseOrFail =<< orDie =<< readTextFile (vhRoot vh </> rel)

sectionBytes :: Document -> Id -> Maybe Text
sectionBytes doc sid = renderSection <$> find ((== sid) . secId) (docSections doc)

-- | 去掉 meta 區塊裡的 @revision:@ \/ @updated:@ 兩行後的內容(L6 用)。
stripRevisionUpdated :: Text -> Text
stripRevisionUpdated =
  T.unlines
    . filter (\ln -> not (isKeyLine "revision:" ln) && not (isKeyLine "updated:" ln))
    . T.lines
  where
    isKeyLine key ln = key `T.isPrefixOf` T.dropWhile (== ' ') ln

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "graph-core/F008 Aapms.Store.Write" $ do
  --------------------------------------------------------------------------------
  describe "E5 / L1 / L2 / L3: writeMeta" $
    it "revision 不符時拒絕且檔案不變;revision 相符時 +1、重讀相符、其他節位元組不變" $
      withIndexedStoryVault $ \vh -> do
        let topicPath = "characters/test-character.md"
            target = idOf "ent-00000002"
        beforeDoc <- rereadDoc vh topicPath
        (_, fragsBefore) <- either (\e -> fail ("toTopic 失敗:" <> show e)) pure (toTopic beforeDoc)
        r0 <- case find ((== target) . metaId . entMeta) fragsBefore of
          Just f -> pure (metaRevision (entMeta f))
          Nothing -> fail "找不到目標片段 ent-00000002"
        let (Revision n0) = r0
            wrong = Revision (n0 + 5)

        -- E5:revision 不符
        rBad <- writeMeta vh target wrong (\o -> o {moSummary = Just "不應該被寫入"})
        rBad `shouldBe` Left (RevisionMismatch target wrong r0)
        afterBadDoc <- rereadDoc vh topicPath
        sectionBytes afterBadDoc target `shouldBe` sectionBytes beforeDoc target

        -- L1/L2/L3:revision 相符
        r <- writeMeta vh target r0 (\o -> o {moSummary = Just "新的摘要"})
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right wr -> do
            wrId wr `shouldBe` target
            wrRevision wr `shouldBe` Revision (n0 + 1)
        afterDoc <- rereadDoc vh topicPath
        (_, fragsAfter) <- either (\e -> fail ("toTopic 失敗:" <> show e)) pure (toTopic afterDoc)
        case find ((== target) . metaId . entMeta) fragsAfter of
          Just f -> do
            metaRevision (entMeta f) `shouldBe` Revision (n0 + 1)
            metaSummary (entMeta f) `shouldBe` "新的摘要"
          Nothing -> expectationFailure "找不到目標片段(改寫後)"
        -- L3:除目標外,ent-00000003 的位元組不變
        sectionBytes afterDoc (idOf "ent-00000003") `shouldBe` sectionBytes beforeDoc (idOf "ent-00000003")

  -- 'Aapms.Store.Edit.locate' 沒有獨立 law(見 "Aapms.Store.EditSpec" 頂端說明),依它自己的
  -- haddock(骨架允許讀,見 delegation 指示)「查不到回 NodeNotFound」經由公開介面驗證。
  describe "locate(經由 writeMeta 間接驗證,見 Aapms.Store.EditSpec 對 locate 的說明)" $
    it "目標 id 不在索引裡時,回 Left (NodeNotFound i)" $
      withIndexedStoryVault $ \vh -> do
        let missing = idOf "ent-99999999"
        r <- writeMeta vh missing (Revision 1) (\o -> o {moSummary = Just "不會被寫入"})
        r `shouldBe` Left (NodeNotFound missing)

  --------------------------------------------------------------------------------
  describe "E4 / L4 / L5: writeAssetFields" $
    it "三態語意(不動/清空/設值)正確,且 sha256/entry/ext/kindMeta/body 全程不變" $
      withIndexedAssetVault $ \vh -> do
        let packPath = "packs/test-vendor/pack.md"
            target = idOf "ast-00000001"
            licRef = localRef (idOf "lic-0000000a")
        doc0 <- rereadDoc vh packPath
        (_, assets0) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc0)
        a0 <- case find ((== target) . metaId . astMeta) assets0 of
          Just a -> pure a
          Nothing -> fail "找不到 ast-00000001"
        let r0 = metaRevision (astMeta a0)
            (Revision n0) = r0

        -- 第一步:清空 name(apName = Just Nothing),設定 license(apLicense = Just (Just licRef))
        r1 <-
          writeAssetFields
            vh
            target
            r0
            AssetPatch {apName = Just Nothing, apLicense = Just (Just licRef), apAuthor = Nothing, apTags = Nothing}
        case r1 of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right wr -> wrRevision wr `shouldBe` Revision (n0 + 1)
        doc1 <- rereadDoc vh packPath
        (_, assets1) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc1)
        a1 <- case find ((== target) . metaId . astMeta) assets1 of
          Just a -> pure a
          Nothing -> fail "找不到 ast-00000001(第一步後)"
        astName a1 `shouldBe` Nothing
        astLicense a1 `shouldBe` Just licRef
        astSha256 a1 `shouldBe` astSha256 a0
        astEntry a1 `shouldBe` astEntry a0
        astExt a1 `shouldBe` astExt a0
        astKindMeta a1 `shouldBe` astKindMeta a0
        astBody a1 `shouldBe` astBody a0

        -- 第二步:設定新名字、新作者、新 tags;license 不動(apLicense = Nothing)應維持第一步設的值
        r2 <-
          writeAssetFields
            vh
            target
            (metaRevision (astMeta a1))
            AssetPatch
              { apName = Just (Just (LogicalName "重新命名的資產"))
              , apLicense = Nothing
              , apAuthor = Just (Just "某人")
              , apTags = Just ["t1", "t2"]
              }
        case r2 of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right _wr -> pure ()
        doc2 <- rereadDoc vh packPath
        (_, assets2) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc2)
        a2 <- case find ((== target) . metaId . astMeta) assets2 of
          Just a -> pure a
          Nothing -> fail "找不到 ast-00000001(第二步後)"
        astName a2 `shouldBe` Just (LogicalName "重新命名的資產")
        astLicense a2 `shouldBe` Just licRef -- L5:Nothing = 不動,維持第一步設的值
        astAuthor a2 `shouldBe` Just "某人"
        metaTags (astMeta a2) `shouldBe` ["t1", "t2"]
        astSha256 a2 `shouldBe` astSha256 a0
        astEntry a2 `shouldBe` astEntry a0
        astExt a2 `shouldBe` astExt a0
        astKindMeta a2 `shouldBe` astKindMeta a0
        astBody a2 `shouldBe` astBody a0
        -- 另一個 asset(ast-00000002)全程不受影響
        sectionBytes doc2 (idOf "ast-00000002") `shouldBe` sectionBytes doc0 (idOf "ast-00000002")

  --------------------------------------------------------------------------------
  describe "E9 / L3: writeBody" $
    it "換掉 asset 節的正文,不吃掉 sha256/entry 等 payload 欄位,其他節位元組不變" $
      withIndexedAssetVault $ \vh -> do
        let packPath = "packs/test-vendor/pack.md"
            target = idOf "ast-00000001"
        doc0 <- rereadDoc vh packPath
        (_, assets0) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc0)
        a0 <- case find ((== target) . metaId . astMeta) assets0 of
          Just a -> pure a
          Nothing -> fail "找不到 ast-00000001"
        let r0 = metaRevision (astMeta a0)

        r <- writeBody vh target r0 "新的說明"
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right wr -> wrId wr `shouldBe` target
        doc1 <- rereadDoc vh packPath
        (_, assets1) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc1)
        a1 <- case find ((== target) . metaId . astMeta) assets1 of
          Just a -> pure a
          Nothing -> fail "找不到 ast-00000001(改寫後)"
        astBody a1 `shouldBe` "新的說明"
        astSha256 a1 `shouldBe` astSha256 a0
        astEntry a1 `shouldBe` astEntry a0
        sectionBytes doc1 (idOf "ast-00000002") `shouldBe` sectionBytes doc0 (idOf "ast-00000002")

  --------------------------------------------------------------------------------
  describe "L6 / L7 / E7: addLink / removeLink" $ do
    it "L6: addLink 再 removeLink 同一筆關聯後,linksFrom 回到最初;檔案位元組除 revision/updated 外不變" $
      withIndexedStoryVault $ \vh -> do
        let topicPath = "characters/test-character.md"
            target = idOf "ent-00000002"
            l = Link References (localRef (idOf "ent-00000003")) Nothing
        beforeRaw <- orDie =<< readTextFile (vhRoot vh </> topicPath)
        r0 <- currentFragRevision vh topicPath target

        before <- linksFrom vh target
        before `shouldBe` []

        r1 <- addLink vh target r0 l
        rev1 <- case r1 of
          Right wr -> pure (wrRevision wr)
          Left e -> expectationFailure ("addLink 預期成功,得到 " <> show e) >> pure r0

        mid <- linksFrom vh target
        mid `shouldBe` [l]

        r2 <- removeLink vh target rev1 l
        case r2 of
          Left e -> expectationFailure ("removeLink 預期成功,得到 " <> show e)
          Right _ -> pure ()

        afterRaw <- orDie =<< readTextFile (vhRoot vh </> topicPath)
        stripRevisionUpdated afterRaw `shouldBe` stripRevisionUpdated beforeRaw
        afterLinks <- linksFrom vh target
        afterLinks `shouldBe` before

    it "E7/L7: removeLink 對沒有的關聯回 Left (LinkNotFound i l),檔案不變" $
      withIndexedStoryVault $ \vh -> do
        let topicPath = "characters/test-character.md"
            target = idOf "ent-00000002"
            notPresent = Link References (localRef (idOf "ent-00000001")) (Just "沒有這筆")
        r0 <- currentFragRevision vh topicPath target
        beforeRaw <- orDie =<< readTextFile (vhRoot vh </> topicPath)
        r <- removeLink vh target r0 notPresent
        r `shouldBe` Left (LinkNotFound target notPresent)
        afterRaw <- orDie =<< readTextFile (vhRoot vh </> topicPath)
        afterRaw `shouldBe` beforeRaw

  --------------------------------------------------------------------------------
  describe "L8: upsertLicense" $
    it "讀回相等(除 licMeta 的 metaRevision/metaUpdated 與 licFullText 外);對同一個 id 呼叫兩次節數不變" $
      withIndexedAssetVault $ \vh -> do
        let licensesPath = "licenses.md"
        doc0 <- rereadDoc vh licensesPath
        existing0 <- either (\e -> fail ("toLicenses 失敗:" <> show e)) pure (toLicenses doc0)
        orig <- case find ((== idOf "lic-0000000a") . metaId . licMeta) existing0 of
          Just l -> pure l
          Nothing -> fail "找不到 lic-0000000a"

        let updated1 = orig {licCommercial = False, licSourceUrl = Just "https://example.com/license"}
        r1 <- upsertLicense vh updated1
        case r1 of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right wr -> wrId wr `shouldBe` idOf "lic-0000000a"

        doc1 <- rereadDoc vh licensesPath
        existing1 <- either (\e -> fail ("toLicenses 失敗:" <> show e)) pure (toLicenses doc1)
        reread1 <- case find ((== idOf "lic-0000000a") . metaId . licMeta) existing1 of
          Just l -> pure l
          Nothing -> fail "找不到 lic-0000000a(第一次 upsert 後)"
        licCommercial reread1 `shouldBe` False
        licSourceUrl reread1 `shouldBe` Just "https://example.com/license"
        licAttributionRequired reread1 `shouldBe` licAttributionRequired updated1
        length existing1 `shouldBe` length existing0

        -- 對同一個 id 再呼叫一次(用剛讀回的 revision),節數應維持不變
        let updated2 = reread1 {licResaleAllowed = Just True}
        r2 <- upsertLicense vh updated2
        case r2 of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right _ -> pure ()
        doc2 <- rereadDoc vh licensesPath
        existing2 <- either (\e -> fail ("toLicenses 失敗:" <> show e)) pure (toLicenses doc2)
        length existing2 `shouldBe` length existing0

  --------------------------------------------------------------------------------
  describe "L14 / E6 / E15 / L14b: allocateId(2026-08-25 G8 裁決:t 是明碼參數)" $ do
    it "L14: 固定同一個 t,連續呼叫 3 次(每次把結果寫進索引)全部成功、互異、idPrefix 皆等於 prefix" $
      withIndexedStoryVault $ \vh -> do
        let fixedT = UTCTime (fromGregorian 2026 8 25) 0
        ids <- allocateThreeDistinctIds vh fixedT
        length ids `shouldBe` 3
        nub ids `shouldBe` ids
        forM_ ids $ \i -> idPrefix i `shouldBe` PEnt

    it "E6: 索引裡已存在 newId p c t 0 / newId p c t 1(同一個 t),allocateId vh p c t 回 Right (newId p c t 2)" $
      withIndexedStoryVault $ \vh -> do
        let fixedT = UTCTime (fromGregorian 2026 8 25) 0
            p = PEnt
            c = "琳達"
            collide0 = newId p c fixedT 0
            collide1 = newId p c fixedT 1
            expected = newId p c fixedT 2
        insertMinimalNode vh collide0
        insertMinimalNode vh collide1
        r <- allocateId vh p c fixedT
        case r of
          Right i -> do
            i `shouldBe` expected
            i `shouldNotBe` collide0
            i `shouldNotBe` collide1
          Left e -> expectationFailure ("預期成功,得到 " <> show e)

    it "E15/L14b: nodes 表被 DROP 掉時,allocateId 回 Left (SqliteError _),不是 Right" $
      withIndexedStoryVault $ \vh -> do
        execute_ (vhConn vh) "DROP TABLE nodes"
        let fixedT = UTCTime (fromGregorian 2026 8 25) 0
        r <- allocateId vh PEnt "琳達" fixedT
        case r of
          Left (SqliteError _) -> pure ()
          other -> expectationFailure ("預期 Left (SqliteError _),得到 " <> show other)

--------------------------------------------------------------------------------
-- 小工具

-- | 讀目前檔案裡某個片段的實際 revision(不假設繼承預設值)。
currentFragRevision :: VaultHandle -> FilePath -> Id -> IO Revision
currentFragRevision vh rel target = do
  doc <- rereadDoc vh rel
  (_, frags) <- either (\e -> fail ("toTopic 失敗:" <> show e)) pure (toTopic doc)
  case find ((== target) . metaId . entMeta) frags of
    Just f -> pure (metaRevision (entMeta f))
    Nothing -> fail ("找不到片段:" <> show target)

-- | L14 用:__同一個固定的 t__,連續呼叫 3 次 allocateId,每次都把結果寫進索引
-- (law 的前提條件,2026-08-25 G8 裁決收緊)。t 若每次不同,就算 salt 恆為 0 也幾乎必然
-- 互異——那樣測到的是「t 在變」,不是「salt 在遞增」。
allocateThreeDistinctIds :: VaultHandle -> UTCTime -> IO [Id]
allocateThreeDistinctIds vh fixedT = go 3 []
  where
    go 0 acc = pure (reverse acc)
    go n acc = do
      r <- allocateId vh PEnt "配號測試" fixedT
      case r of
        Left e -> fail ("allocateId 預期成功,得到 " <> show e)
        Right i -> do
          insertMinimalNode vh i
          go (n - 1 :: Int) (i : acc)

-- | 把一個 id 以最小的 Meta 寫進 @nodes@ 表(先補一筆 @files@ 列滿足外鍵),
-- 供 L14 的碰撞查詢用。
insertMinimalNode :: VaultHandle -> Id -> IO ()
insertMinimalNode vh i = withTransaction (vhConn vh) $ do
  execute
    (vhConn vh)
    "INSERT OR IGNORE INTO files(path, mtime, size, doc_kind) VALUES (?, ?, ?, ?)"
    ("allocate-id-fixture.md" :: Text, 0 :: Int, 0 :: Int, "topic" :: Text)
  execute
    (vhConn vh)
    (insertSql "nodes" nodeColumnList)
    (nodeFields minimalMeta (idPrefix i) "allocate-id-fixture.md" Nothing Nothing)
  where
    minimalMeta =
      Meta
        { metaId = i
        , metaVault = VaultId "liftgame"
        , metaType = TypeKey "character"
        , metaTitle = "配號測試"
        , metaSummary = ""
        , metaTags = []
        , metaStatus = Canon
        , metaTimeline = Nothing
        , metaAliases = []
        , metaLinks = []
        , metaSource = Human
        , metaRevision = Revision 1
        , metaCreated = fromGregorian 2026 8 25
        , metaUpdated = fromGregorian 2026 8 25
        }
