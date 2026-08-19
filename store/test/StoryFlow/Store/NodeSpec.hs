-- | entity-graph-core/F005 T12 \/ T13 \/ T14:Level 檔與樹的編輯。
--
-- ADR-009「標題階層即樹」在這裡是可驗證的:測試斷言的是__標題層級__與
-- 索引裡推導出來的 @parent@ \/ @order@ 一致,而不是某個欄位被寫對了。
module StoryFlow.Store.NodeSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (renderId)
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind (..))
import StoryFlow.Core.Link (Link (..), LinkKind (..))
import StoryFlow.Core.Meta (Meta (..), Status (..))
import StoryFlow.Store.Create
import StoryFlow.Store.Error (StoreError (..))
import StoryFlow.Store.Edit (WriteResult (..))
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Index (rebuildIndex)
import StoryFlow.Store.Node
import StoryFlow.Store.Query (lookupLevel)
import StoryFlow.Store.Vault (vaultAbsPath)
import System.Directory (doesFileExist)
import Test.Hspec

newLevel :: Text -> NewLevel
newLevel title =
  NewLevel
    { nlTitle = title
    , nlSummary = "崩塌後的午後教室"
    , nlBody = "場景整體的說明寫在這裡。"
    , nlRootTitle = "午後的" <> title
    , nlRootKind = KScene
    , nlStatus = Canon
    }

newNode :: Text -> NodeKind -> NewNode
newNode title k =
  NewNode
    { nnTitle = title
    , nnKind = k
    , nnSummary = ""
    , nnBody = ""
    , nnLinks = []
    }

spec :: Spec
spec = do
  describe "T12 createLevelFile" $ do
    it "落在 levels/,產出的檔案解析得回 Level 與根 Node" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createLevelFile conn v (newLevel "教室")
        crPath r `shouldBe` "levels/教室.md"
        doesFileExist (vaultAbsPath v "levels/教室.md") `shouldReturn` True

        Just (lvl, nodes) <- lookupLevel conn (crId r)
        metaTitle (lvlMeta lvl) `shouldBe` "教室"
        metaType (lvlMeta lvl) `shouldBe` "level"
        metaStatus (lvlMeta lvl) `shouldBe` Canon
        map (metaTitle . nodMeta) nodes `shouldBe` ["午後的教室"]
        map nodKind nodes `shouldBe` [KScene]
        map nodParent nodes `shouldBe` [Nothing]
        map (metaId . nodMeta) nodes `shouldBe` [lvlRoot lvl]

    it "根 Node 用 ## 二級標題,與 system.md 的範例一致" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createLevelFile conn v (newLevel "教室")
        txt <- readVaultFile v (crPath r)
        txt `shouldSatisfy` T.isInfixOf "\n## 午後的教室 {#"
        txt `shouldSatisfy` T.isInfixOf "kind: scene"
        -- root 不寫進 frontmatter:它由標題階層推導(ADR-009)
        txt `shouldSatisfy` (not . T.isInfixOf "root:")

    it "Level 與根 Node 的 id 前綴各自正確" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createLevelFile conn v (newLevel "教室")
        renderId (crId r) `shouldSatisfy` T.isPrefixOf "lvl-"
        Just (_, nodes) <- lookupLevel conn (crId r)
        map (renderId . metaId . nodMeta) nodes `shouldSatisfy` all (T.isPrefixOf "nod-")

    it "撞名時遞增" $
      withVaultIndex $ \v conn -> do
        a <- orDie =<< createLevelFile conn v (newLevel "教室")
        b <- orDie =<< createLevelFile conn v (newLevel "教室")
        map crPath [a, b] `shouldBe` ["levels/教室.md", "levels/教室-2.md"]

    it "根 Node 沒寫 summary,警告一併帶出來" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createLevelFile conn v (newLevel "教室")
        length (crWarnings r) `shouldSatisfy` (> 0)

  describe "T13 addNode" $ do
    it "對 ## 父節點新增得到 ###,parent 與 order 由標題推導" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< addNode conn v (idOf "nod-0100") 1 (newNode "出場人物" KCast)
        crPath r `shouldBe` corridor

        txt <- readVaultFile v corridor
        txt `shouldSatisfy` T.isInfixOf ("### 出場人物 {#" <> renderId (crId r) <> "}")

        Just (_, nodes) <- lookupLevel conn (idOf "lvl-3a02")
        map (metaTitle . nodMeta) nodes `shouldBe` ["走廊", "鏡頭", "出場人物"]
        map (fmap renderId . nodParent) nodes
          `shouldBe` [Nothing, Just "nod-0100", Just "nod-0100"]
        map nodOrder nodes `shouldBe` [1, 1, 2]

    it "父節點已有子樹時新節排在子樹之後,而非緊貼父節點" $
      withSampleIndex $ \v conn -> do
        -- nod-0002(###)底下已經有 nod-0004(####)
        r <- orDie =<< addNode conn v (idOf "nod-0002") 1 (newNode "第二個互動" KInteraction)
        txt <- readVaultFile v classroom
        let titles = headingTitles txt
        titles
          `shouldBe` [ "午後的教室"
                     , "出場人物"
                     , "琳達走向講台"
                     , "第二個互動"
                     , "鏡頭"
                     ]
        renderId (crId r) `shouldSatisfy` T.isPrefixOf "nod-"

    it "層級會超過 6 時回 NodeDepthExceeded,且不寫檔" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v classroom
        -- 先疊到 ######(第六級)
        _ <- orDie =<< addNode conn v (idOf "nod-0004") 1 (newNode "第五級" KDialogue)
        Just (_, nodes) <- lookupLevel conn (idOf "lvl-3a01")
        let deep = last [metaId (nodMeta n) | n <- nodes, metaTitle (nodMeta n) == "第五級"]
        _ <- orDie =<< addNode conn v deep 2 (newNode "第六級" KBranch)
        Just (_, nodes2) <- lookupLevel conn (idOf "lvl-3a01")
        let deepest = last [metaId (nodMeta n) | n <- nodes2, metaTitle (nodMeta n) == "第六級"]

        beforeFail <- readVaultFile v classroom
        r <- addNode conn v deepest 3 (newNode "第七級" KBranch)
        r `shouldBe` Left (NodeDepthExceeded deepest 7)
        readVaultFile v classroom `shouldReturn` beforeFail
        original `shouldSatisfy` T.isInfixOf "午後的教室"

    it "Level 的 revision 走樂觀鎖,不符時一個位元組都不寫" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v classroom
        r <- addNode conn v (idOf "nod-0002") 99 (newNode "不該出現" KCast)
        r `shouldBe` Left (StaleRevision (idOf "lvl-3a01") 99 1)
        readVaultFile v classroom `shouldReturn` original

    it "成功後 Level 的 revision +1" $
      withSampleIndex $ \v conn -> do
        _ <- orDie =<< addNode conn v (idOf "nod-0002") 1 (newNode "新節點" KCast)
        Just (lvl, _) <- lookupLevel conn (idOf "lvl-3a01")
        metaRevision (lvlMeta lvl) `shouldBe` 2

    it "對 Level 的 id 呼叫 addNode 回 NotAFragment(要給父 Node)" $
      withSampleIndex $ \v conn -> do
        let l = idOf "lvl-3a01"
        r <- addNode conn v l 1 (newNode "x" KCast)
        r `shouldBe` Left (NotAFragment l)

    it "kind / summary / links 都寫得出來" $
      withSampleIndex $ \v conn -> do
        r <-
          orDie
            =<< addNode
              conn
              v
              (idOf "nod-0100")
              1
              (newNode "鏡頭二" KCamera)
                { nnSummary = "自門口拉遠"
                , nnLinks = [Link Involves (refOf "ent-7f3a") Nothing]
                , nnBody = "鏡頭的說明。"
                }
        Just (_, nodes) <- lookupLevel conn (idOf "lvl-3a02")
        let n = last [x | x <- nodes, metaId (nodMeta x) == crId r]
        nodKind n `shouldBe` KCamera
        metaSummary (nodMeta n) `shouldBe` "自門口拉遠"
        nodEntities n `shouldBe` [refOf "ent-7f3a"]

  describe "T14 removeNode" $ do
    it "刪一個有兩層子孫的 Node 後,子孫全部消失、兄弟不受影響" $
      withSampleIndex $ \v conn -> do
        -- nod-0002(出場人物)底下有 nod-0004(琳達走向講台)
        _ <- orDie =<< removeNode conn v (idOf "nod-0002") 1 DeleteForce
        txt <- readVaultFile v classroom
        headingTitles txt `shouldBe` ["午後的教室", "鏡頭"]

        Just (_, nodes) <- lookupLevel conn (idOf "lvl-3a01")
        map (renderId . metaId . nodMeta) nodes `shouldBe` ["nod-0001", "nod-0003"]
        -- 被刪節點的關聯也跟著消失
        scalarInt conn "SELECT count(*) FROM links WHERE src = 'nod-0002'" ()
          `shouldReturn` 0

    it "對根 Node 呼叫回 CannotRemoveRootNode,且不寫檔" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v classroom
        r <- removeNode conn v (idOf "nod-0001") 1 DeleteSafe
        r `shouldBe` Left (CannotRemoveRootNode (idOf "nod-0001"))
        readVaultFile v classroom `shouldReturn` original

    it "DeleteSafe 對子樹裡每一個 Node 做被引用檢查" $
      withSampleIndex $ \v conn -> do
        -- 讓別人 convergesTo 指向 nod-0004(nod-0002 的子孫)
        writeVaultFile v "levels/走廊.md" corridorWithConverge
        _ <- orDie =<< rebuildIndex conn v
        original <- readVaultFile v classroom
        r <- removeNode conn v (idOf "nod-0002") 1 DeleteSafe
        case r of
          Left (ReferencedBy i srcs) -> do
            i `shouldBe` idOf "nod-0002"
            map (renderId . fst) srcs `shouldContain` ["nod-0101"]
          other -> expectationFailure ("預期 ReferencedBy,得到 " <> show other)
        readVaultFile v classroom `shouldReturn` original

    it "刪完 Level 的 revision +1,且樹仍然合法" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< removeNode conn v (idOf "nod-0003") 1 DeleteSafe
        wrNewRevision r `shouldBe` 2
        Just (lvl, nodes) <- lookupLevel conn (idOf "lvl-3a01")
        metaRevision (lvlMeta lvl) `shouldBe` 2
        map nodOrder nodes `shouldBe` [1, 1, 1]

    it "Level 的 revision 走樂觀鎖" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v classroom
        r <- removeNode conn v (idOf "nod-0003") 99 DeleteSafe
        r `shouldBe` Left (StaleRevision (idOf "lvl-3a01") 99 1)
        readVaultFile v classroom `shouldReturn` original

    it "對 Entity 的 id 呼叫 removeNode 回 EntityNotFound" $
      withSampleIndex $ \v conn -> do
        let e = idOf "ent-7f3b"
        r <- removeNode conn v e 1 DeleteSafe
        r `shouldBe` Left (EntityNotFound e)
  where
    classroom = "levels/教室.md"
    corridor = "levels/走廊.md"

-- | 檔案裡所有節標題的文字,依文件順序。
headingTitles :: Text -> [Text]
headingTitles txt =
  [ T.strip (T.takeWhile (/= '{') (T.dropWhile (== '#') l))
  | l <- T.lines txt
  , "#" `T.isPrefixOf` l
  , "{#" `T.isInfixOf` l
  ]

-- | 走廊多一個 convergesTo,指向教室的 nod-0004。
corridorWithConverge :: Text
corridorWithConverge =
  T.unlines
    [ "---"
    , "id: lvl-3a02"
    , "vault: liftgame"
    , "type: level"
    , "title: 走廊"
    , "summary: 教室外的走廊"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "走廊的說明。"
    , ""
    , "## 走廊 {#nod-0100}"
    , ""
    , "```meta"
    , "kind: scene"
    , "summary: 崩塌後的走廊"
    , "```"
    , ""
    , "### 鏡頭 {#nod-0101}"
    , ""
    , "```meta"
    , "kind: camera"
    , "summary: 由走廊盡頭推向教室門口"
    , "links:"
    , "  - {kind: convergesTo, target: nod-0004}"
    , "```"
    ]
