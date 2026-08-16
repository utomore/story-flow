-- | func-0005 T17:從空 Vault 建出 architecture.md 的兩份範例檔。
--
-- 這是本 spec 的驗收標準 1 與 2 合在一起的那一條:__只用本 spec 新增的函式__
-- (加上 func-0004 的 'openVaultIndex' \/ 'rebuildIndex')把琳達與教室從零建
-- 起來,再刪掉 @index.db@ 重建,證明「檔案才是真相來源」在寫入路徑上也成立。
--
-- 對照的不是位元組:id 是雜湊產生的,不可能與 architecture.md 的
-- @ent-7f3a@ 相同。對照的是__解析回來的結構__——標題、總結、關聯、標籤、
-- 樹的形狀。
module StoryFlow.Store.EndToEndSpec (spec) where

import Control.Exception (bracket)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, Ref, localRef, renderId, renderRef)
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind (..))
import StoryFlow.Core.Link (Link (..), LinkKind (..))
import StoryFlow.Core.Meta
import StoryFlow.Core.Tree (buildTree, preorder)
import StoryFlow.Store.Create
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Index (rebuildIndex)
import StoryFlow.Store.Node (addNode)
import StoryFlow.Store.Query
import StoryFlow.Store.Schema (closeIndex, openIndex)
import StoryFlow.Store.Vault (Vault, indexDbPath)
import System.Directory (doesFileExist, removeFile)
import Test.Hspec

-- | 建好之後要對照的一份快照。
data Snapshot = Snapshot
  { snEntities :: [(Text, Text, [Text], [Text])]
  -- ^ (title, summary, tags, links 的字串形式)
  , snLevels :: [(Text, Text)]
  -- ^ (title, summary)
  , snTree :: [(Text, Text, Int)]
  -- ^ 前序走訪的 (title, kind, order)
  , snSearch :: [Text]
  }
  deriving stock (Show, Eq)

spec :: Spec
spec = describe "T17 從空 Vault 建出琳達與教室" $ do
  it "只用本 spec 的函式就建得出兩份範例檔,且解析回來與 architecture.md 等價" $
    withBuiltVault $ \v conn ids -> do
      -- 琳達:主體 + 兩個片段
      readVaultFile v "characters/琳達.md" >>= \txt -> do
        txt `shouldSatisfy` T.isInfixOf "type: character"
        txt `shouldSatisfy` T.isInfixOf "title: 琳達"
        txt `shouldSatisfy` T.isInfixOf "## 外貌 {#"
        txt `shouldSatisfy` T.isInfixOf "## 與塔主的過節 {#"

      Just main_ <- lookupEntity conn (bMain ids)
      metaTitle (entMeta main_) `shouldBe` "琳達"
      metaSummary (entMeta main_) `shouldBe` "埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
      metaAliases (entMeta main_) `shouldBe` ["小琳", "第七織手"]
      metaStatus (entMeta main_) `shouldBe` Canon
      entBody main_ `shouldSatisfy` T.isInfixOf "角色主體的概述"

      Just look <- lookupEntity conn (bLook ids)
      metaTitle (entMeta look) `shouldBe` "外貌"
      metaSummary (entMeta look) `shouldBe` "銀灰短髮,左眼下方有織紋刺青"
      metaTags (entMeta look) `shouldBe` ["外觀"]
      metaType (entMeta look) `shouldBe` "character-fragment"
      metaLinks (entMeta look) `shouldBe` [Link PartOf (localRef (bMain ids)) Nothing]
      entBody look `shouldBe` "銀灰短髮剪到耳際……"

      Just feud <- lookupEntity conn (bFeud ids)
      metaTimeline (entMeta feud) `shouldBe` Timeline (Just "埃提亞崩塌前") Nothing
      map linkKind (metaLinks (entMeta feud)) `shouldBe` [PartOf, OccursIn, Contradicts]
      map linkNote (metaLinks (entMeta feud))
        `shouldBe` [Nothing, Nothing, Just "對雙親死因的敘述不一致"]
      map linkTarget (metaLinks (entMeta feud))
        `shouldBe` map localRef [bMain ids, bLore ids, bTower ids]

  it "教室 Level 的六個 Node 組成 architecture.md 畫的那棵樹" $
    withBuiltVault $ \_ conn ids -> do
      Just (lvl, nodes) <- lookupLevel conn (bLevel ids)
      metaTitle (lvlMeta lvl) `shouldBe` "教室"
      length nodes `shouldBe` 6
      case buildTree lvl nodes of
        Left es -> expectationFailure ("樹不合法:" <> show es)
        Right t ->
          [(metaTitle (nodMeta n), nodKind n, nodOrder n) | n <- preorder t]
            `shouldBe` [ ("午後的教室", KScene, 1)
                       , ("出場人物", KCast, 1)
                       , ("琳達走向講台", KInteraction, 1)
                       , ("A-to-B 對話", KDialogue, 1)
                       , ("琳達選擇動手", KBranch, 1)
                       , ("鏡頭", KCamera, 2)
                       ]

  it "Node 指向的 Entity 由 involves / references 推導出來" $
    withBuiltVault $ \_ conn ids -> do
      Just (_, nodes) <- lookupLevel conn (bLevel ids)
      let byTitle t = concat [nodEntities n | n <- nodes, metaTitle (nodMeta n) == t]
      map renderRef (byTitle "出場人物")
        `shouldBe` [renderId (bMain ids), renderId (bTower ids)]
      byTitle "琳達走向講台" `shouldBe` []

  it "rm index.db 之後 rebuildIndex,結果逐項與寫入當下相同" $
    withBuilt $ \v ids -> do
      prev <- withIndex v (`snapshot` ids)
      removeFile (indexDbPath v)
      doesFileExist (indexDbPath v) `shouldReturn` False
      rebuilt <- withIndex v $ \conn -> do
        _ <- orDie =<< rebuildIndex conn v
        snapshot conn ids
      rebuilt `shouldBe` prev

  it "產出的兩份檔案都是 LF、都能被 rebuildIndex 無警告地讀回" $
    withBuiltVault $ \v conn _ -> do
      mapM_
        ( \p -> do
            txt <- readVaultFile v p
            txt `shouldSatisfy` (not . T.isInfixOf "\r")
        )
        ["characters/琳達.md", "levels/教室.md"]
      issues <- orDie =<< rebuildIndex conn v
      -- 只允許「沒寫 summary」這一種警告(根 Node 與分支 Node 本來就沒有)
      length issues `shouldSatisfy` (<= 1)

-- 建置 ------------------------------------------------------------------------

-- | 建出來的東西的 id。
data Built = Built
  { bMain :: Id
  , bLook :: Id
  , bFeud :: Id
  , bTower :: Id
  , bLore :: Id
  , bLevel :: Id
  }

-- | 建好的 Vault + 一條開好的索引連線。
withBuiltVault :: (Vault -> Connection -> Built -> IO a) -> IO a
withBuiltVault act = withBuilt $ \v ids -> withIndex v $ \conn -> act v conn ids

withIndex :: Vault -> (Connection -> IO a) -> IO a
withIndex v act = bracket (orDie =<< openIndex v) closeIndex act

-- | 從空 Vault 出發,只用 func-0005 的寫入函式建出兩份範例檔。
--
-- 建完就把連線關掉:「rm index.db 再重建」那一條要在連線關閉之後才刪得動
-- 檔案(Windows 不讓你刪還開著的檔)。
withBuilt :: (Vault -> Built -> IO a) -> IO a
withBuilt act = withEmptyVault $ \v -> do
  ids <- withIndex v (buildAll v)
  act v ids

buildAll :: Vault -> Connection -> IO Built
buildAll v conn = do
  -- 先建被指向的兩個對象:塔主與埃提亞崩塌
  tower <- crId <$> (orDie =<< createEntityFile conn v testRegistry (person "塔主" "織塔的主人"))
  lore <-
    crId
      <$> ( orDie
              =<< createEntityFile
                conn
                v
                testRegistry
                (person "埃提亞崩塌" "埃提亞在崩塌前後的樣貌") {neType = "lore"}
          )

  main_ <-
    crId
      <$> ( orDie
              =<< createEntityFile
                conn
                v
                testRegistry
                (person "琳達" "埃提亞的第七織手,因塔主徵召失去雙親而敵視議會")
                  { neBody = "# 琳達\n\n角色主體的概述寫在這裡。"
                  , neAliases = ["小琳", "第七織手"]
                  }
          )

  look <-
    crId
      <$> ( orDie
              =<< addFragment
                conn
                v
                main_
                1
                (fragment "外貌" "銀灰短髮,左眼下方有織紋刺青")
                  { nfType = Just "character-fragment"
                  , nfTags = ["外觀"]
                  , nfBody = "銀灰短髮剪到耳際……"
                  , nfLinks = [Link PartOf (localRef main_) Nothing]
                  }
          )

  feud <-
    crId
      <$> ( orDie
              =<< addFragment
                conn
                v
                main_
                2
                (fragment "與塔主的過節" "十四歲時因塔主徵召失去雙親,自此對議會抱持敵意")
                  { nfType = Just "character-fragment"
                  , nfTags = ["動機", "仇恨"]
                  , nfTimeline = Just (Timeline (Just "埃提亞崩塌前") Nothing)
                  , nfBody = "那年她十四歲……"
                  , nfLinks =
                      [ Link PartOf (localRef main_) Nothing
                      , Link OccursIn (localRef lore) Nothing
                      , Link Contradicts (localRef tower) (Just "對雙親死因的敘述不一致")
                      ]
                  }
          )

  -- 教室:Level + 根 Node,再往下長五個
  lvl <-
    orDie
      =<< createLevelFile
        conn
        v
        NewLevel
          { nlTitle = "教室"
          , nlSummary = "崩塌後的午後教室,琳達與塔主的第一次對峙"
          , nlBody = "場景整體的說明寫在這裡(對應 Level 的 body,不進 Node)。"
          , nlRootTitle = "午後的教室"
          , nlRootKind = KScene
          , nlStatus = Canon
          }
  Just (lvlMain, _) <- lookupLevel conn (crId lvl)
  let root = lvlRoot lvlMain

  cast <-
    crId
      <$> ( orDie
              =<< addNode
                conn
                v
                root
                1
                (node_ "出場人物" KCast)
                  { nnLinks =
                      [ Link Involves (localRef main_) Nothing
                      , Link Involves (localRef tower) Nothing
                      ]
                  }
          )
  inter <- crId <$> (orDie =<< addNode conn v cast 2 (node_ "琳達走向講台" KInteraction))
  dia <- crId <$> (orDie =<< addNode conn v inter 3 (node_ "A-to-B 對話" KDialogue))
  _ <- orDie =<< addNode conn v dia 4 (node_ "琳達選擇動手" KBranch)
  -- 鏡頭掛在根底下,是「出場人物」的兄弟 —— 插在子樹尾端,不是緊貼根
  _ <-
    orDie
      =<< addNode
        conn
        v
        root
        5
        (node_ "鏡頭" KCamera) {nnSummary = "自窗外緩推至講台,焦段 35mm"}

  pure (Built main_ look feud tower lore (crId lvl))

person :: Text -> Text -> NewEntity
person title summary =
  NewEntity
    { neType = "character"
    , neTitle = title
    , neSummary = summary
    , neBody = ""
    , neTags = []
    , neAliases = []
    , neStatus = Canon
    , neTimeline = emptyTimeline
    , neLinks = []
    , neSource = Human
    , nePath = Nothing
    }

fragment :: Text -> Text -> NewFragment
fragment title summary =
  NewFragment
    { nfTitle = title
    , nfSummary = summary
    , nfBody = ""
    , nfType = Nothing
    , nfTags = []
    , nfAliases = []
    , nfStatus = Nothing
    , nfTimeline = Nothing
    , nfLinks = []
    , nfSource = Nothing
    }

node_ :: Text -> NodeKind -> NewNode
node_ title k = NewNode {nnTitle = title, nnKind = k, nnSummary = "", nnBody = "", nnLinks = []}

-- 快照 ------------------------------------------------------------------------

snapshot :: Connection -> Built -> IO Snapshot
snapshot conn ids = do
  metas <- listEntities conn emptyFilter
  levels <- listLevels conn emptyFilter
  Just (lvl, nodes) <- lookupLevel conn (bLevel ids)
  hits <- searchEntities conn "織紋" emptyFilter
  pure
    Snapshot
      { snEntities =
          [ (metaTitle m, metaSummary m, sort (metaTags m), map showLink (metaLinks m))
          | m <- metas
          ]
      , snLevels = [(metaTitle m, metaSummary m) | m <- levels]
      , snTree = case buildTree lvl nodes of
          Right t -> [(metaTitle (nodMeta n), kindOf n, nodOrder n) | n <- preorder t]
          Left _ -> []
      , snSearch = sort [metaTitle m | (m, _) <- hits]
      }
  where
    kindOf n = T.pack (show (nodKind n))

showLink :: Link -> Text
showLink Link {..} = T.pack (show linkKind) <> "→" <> showRef linkTarget

showRef :: Ref -> Text
showRef = renderRef
