-- | entity-graph-core/F005 T6 \/ T7:建主題檔與增片段。
--
-- 「以過期 revision 增節時檔案位元組完全未變」與 WriteSpec 的同一條同等重要:
-- 樂觀鎖在__每一條__會改動既有實體的路徑上都要生效,漏一條就等於沒有。
module Aapms.Store.CreateSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime, utctDay)
import Database.SQLite.Simple
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (renderId)
import Aapms.Core.Link (Link (..), LinkKind (..))
import Aapms.Core.Meta
import Aapms.Md (MdWarning (..))
import Aapms.Store.Create
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Fixtures
import Aapms.Store.Query (lookupEntity)
import Aapms.Store.Row (dayText)
import Aapms.Store.Vault (vaultAbsPath)
import System.Directory (doesFileExist)
import Test.Hspec

-- | 最小的 NewEntity:只給型別與標題。
newEntity :: Text -> Text -> NewEntity
newEntity ty title =
  NewEntity
    { neType = ty
    , neTitle = title
    , neSummary = ""
    , neBody = ""
    , neTags = []
    , neAliases = []
    , neStatus = Draft
    , neTimeline = emptyTimeline
    , neLinks = []
    , neSource = Human
    , nePath = Nothing
    }

newFragment :: Text -> Text -> NewFragment
newFragment title summary =
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

spec :: Spec
spec = do
  describe "T6 createEntityFile" $ do
    it "依註冊表落在正確的目錄,檔名保留中文原字元" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" "琳達")
        crPath r `shouldBe` "characters/琳達.md"
        doesFileExist (vaultAbsPath v(crPath r)) `shouldReturn` True

    it "片段型別鍵與主體型別鍵都命中同一個目錄" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createEntityFile conn v testRegistry (newEntity "character-fragment" "外貌集")
        crPath r `shouldBe` "characters/外貌集.md"

    it "同標題再建一次得到 -2,再一次得到 -3" $
      withVaultIndex $ \v conn -> do
        a <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" "琳達")
        b <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" "琳達")
        c <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" "琳達")
        map crPath [a, b, c]
          `shouldBe` ["characters/琳達.md", "characters/琳達-2.md", "characters/琳達-3.md"]
        map crId [a, b, c] `shouldSatisfy` allDistinct

    it "標題含 / 與 : 時被淨化成 -" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" "琳達/塔主: 對峙")
        crPath r `shouldBe` "characters/琳達-塔主- 對峙.md"

    it "標題全是不合法字元時退回 id" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" " ... ")
        crPath r `shouldBe` ("characters/" <> T.unpack (idText r) <> ".md")

    it "型別沒宣告 dir 且 nePath 為 Nothing 時回 RegistryDirUnknown" $
      withVaultIndex $ \v conn -> do
        r <- createEntityFile conn v testRegistry (newEntity "sketch" "草稿")
        r `shouldBe` Left (RegistryDirUnknown "sketch")

    it "呼叫端指定 nePath 時照用,不查註冊表" $
      withVaultIndex $ \v conn -> do
        r <-
          orDie
            =<< createEntityFile
              conn
              v
              testRegistry
              (newEntity "sketch" "草稿") {nePath = Just "drafts/我的草稿.md"}
        crPath r `shouldBe` "drafts/我的草稿.md"
        doesFileExist (vaultAbsPath v"drafts/我的草稿.md") `shouldReturn` True

    it "指定的路徑已經有檔案時回 FileAlreadyExists,不覆蓋" $
      withVaultIndex $ \v conn -> do
        writeVaultFile v "drafts/佔位.md" "原本的內容"
        r <-
          createEntityFile
            conn
            v
            testRegistry
            (newEntity "character" "x") {nePath = Just "drafts/佔位.md"}
        r `shouldBe` Left (FileAlreadyExists "drafts/佔位.md")
        readVaultFile v "drafts/佔位.md" `shouldReturn` "原本的內容"

    it "frontmatter 的每個欄位都寫得出來,而且讀得回來" $
      withVaultIndex $ \v conn -> do
        today <- utctDay <$> getCurrentTime
        r <-
          orDie
            =<< createEntityFile
              conn
              v
              testRegistry
              (newEntity "character" "琳達")
                { neSummary = "埃提亞的第七織手"
                , neBody = "# 琳達\n\n角色主體的概述寫在這裡。"
                , neTags = ["主角"]
                , neAliases = ["小琳", "第七織手"]
                , neStatus = Canon
                , neTimeline = Timeline (Just "埃提亞崩塌前") (Just 3)
                , neLinks = [Link References (refOf "ent-c41d") Nothing]
                , neSource = Agent "claude-code"
                }
        Just e <- lookupEntity conn (crId r)
        let m = entMeta e
        metaTitle m `shouldBe` "琳達"
        metaSummary m `shouldBe` "埃提亞的第七織手"
        metaTags m `shouldBe` ["主角"]
        metaAliases m `shouldBe` ["小琳", "第七織手"]
        metaStatus m `shouldBe` Canon
        metaTimeline m `shouldBe` Timeline (Just "埃提亞崩塌前") (Just 3)
        metaLinks m `shouldBe` [Link References (refOf "ent-c41d") Nothing]
        metaSource m `shouldBe` Agent "claude-code"
        metaRevision m `shouldBe` 1
        metaCreated m `shouldBe` today
        metaVault m `shouldBe` "liftgame"
        entBody e `shouldBe` "# 琳達\n\n角色主體的概述寫在這裡。"

    it "新檔一律用 LF" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" "琳達")
        txt <- readVaultFile v (crPath r)
        txt `shouldSatisfy` (not . T.isInfixOf "\r")

    it "索引跟著更新:一份檔案、一個 Entity" $
      withVaultIndex $ \v conn -> do
        r <- orDie =<< createEntityFile conn v testRegistry (newEntity "character" "琳達")
        countRows conn "files" `shouldReturn` 1
        textsOf conn "SELECT id FROM entities" () `shouldReturn` [idText r]
        today <- utctDay <$> getCurrentTime
        textsOf conn "SELECT created FROM entities" () `shouldReturn` [dayText today]

    it "註冊表沒宣告的自訂目錄會被建出來" $
      withVaultIndex $ \v conn -> do
        _ <-
          orDie
            =<< createEntityFile
              conn
              v
              testRegistry
              (newEntity "x" "y") {nePath = Just "深/一點/的/目錄.md"}
        doesFileExist (vaultAbsPath v"深/一點/的/目錄.md") `shouldReturn` True

  describe "T7 addFragment" $ do
    it "新片段出現在檔尾,revision = 1,主體 revision +1" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< addFragment conn v main_ 3 (newFragment "與議會的距離" "她不信議會")
        crPath r `shouldBe` linda

        Just f <- lookupEntity conn (crId r)
        metaTitle (entMeta f) `shouldBe` "與議會的距離"
        metaSummary (entMeta f) `shouldBe` "她不信議會"
        metaRevision (entMeta f) `shouldBe` 1
        -- 節層未寫的欄位繼承檔案層
        metaType (entMeta f) `shouldBe` "character"
        metaStatus (entMeta f) `shouldBe` Canon

        Just m <- lookupEntity conn main_
        metaRevision (entMeta m) `shouldBe` 4

        txt <- readVaultFile v linda
        txt `shouldSatisfy` T.isInfixOf "## 與議會的距離 {#"
        -- 真的在檔尾:最後一個節標題就是它
        last (sectionTitles txt) `shouldBe` "與議會的距離"

    it "只寫與檔案層不同的欄位,繼承得到的欄位不會被釘死在節上" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< addFragment conn v main_ 3 (newFragment "新節" "一句話")
        txt <- readVaultFile v linda
        let block = lastMetaBlock txt
        block `shouldSatisfy` T.isInfixOf "summary: 一句話"
        block `shouldSatisfy` T.isInfixOf "revision: 1"
        block `shouldSatisfy` (not . T.isInfixOf "type:")
        block `shouldSatisfy` (not . T.isInfixOf "status:")
        block `shouldSatisfy` (not . T.isInfixOf "vault:")
        crWarnings r `shouldBe` [EmptyBody (crId r)]

    it "給了型別 / 標籤 / 關聯時就寫出來" $
      withSampleIndex $ \v conn -> do
        r <-
          orDie
            =<< addFragment
              conn
              v
              main_
              3
              (newFragment "新節" "一句話")
                { nfType = Just "character-fragment"
                , nfTags = ["動機"]
                , nfLinks = [Link PartOf (refOf "ent-7f3a") Nothing]
                , nfBody = "正文在這裡。"
                }
        Just f <- lookupEntity conn (crId r)
        entBody f `shouldBe` "正文在這裡。"
        metaLinks (entMeta f) `shouldBe` [Link PartOf (refOf "ent-7f3a") Nothing]
        -- tags 是聯集:檔案層沒有 tags,所以就是節層那一個
        metaTags (entMeta f) `shouldBe` ["動機"]
        crWarnings r `shouldBe` []

    it "缺 summary 時警告一併帶出來" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< addFragment conn v main_ 3 (newFragment "新節" "")
        crWarnings r `shouldContain` [MissingSummary (crId r)]

    it "以過期的 revision 增節時回 StaleRevision,檔案位元組完全未變" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- addFragment conn v main_ 99 (newFragment "不該出現" "x")
        r `shouldBe` Left (StaleRevision main_ 99 3)
        readVaultFile v linda `shouldReturn` original

    it "對片段呼叫 addFragment 回 NotAFileMain" $
      withSampleIndex $ \v conn -> do
        r <- addFragment conn v frag 1 (newFragment "不該出現" "x")
        r `shouldBe` Left (NotAFileMain frag)

    it "既有的節逐字不變" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        _ <- orDie =<< addFragment conn v main_ 3 (newFragment "新節" "一句話")
        updated <- readVaultFile v linda
        let kept = fst (T.breakOn "## 新節" updated)
        -- frontmatter 的 revision 與 updated 變了,但兩個既有的節一個位元組都沒動
        -- (只多了插入點必然帶來的那一個空行)
        fromFirstSection kept `shouldBe` fromFirstSection original <> "\n"

    it "還沒有任何節的檔案也加得動(插在最前面)" $
      withVaultIndex $ \v conn -> do
        c <-
          orDie
            =<< createEntityFile
              conn
              v
              testRegistry
              (newEntity "character" "新角色") {neBody = "只有主體。"}
        r <- orDie =<< addFragment conn v (crId c) 1 (newFragment "第一節" "一句話")
        Just f <- lookupEntity conn (crId r)
        metaTitle (entMeta f) `shouldBe` "第一節"
        txt <- readVaultFile v (crPath r)
        txt `shouldSatisfy` T.isInfixOf "只有主體。\n\n## 第一節 {#"

    it "索引跟著更新:同一份檔案多一個 Entity" $
      withSampleIndex $ \v conn -> do
        n0 <- scalarInt conn "SELECT count(*) FROM entities WHERE file_path = ?" (Only linda)
        _ <- orDie =<< addFragment conn v main_ 3 (newFragment "新節" "一句話")
        scalarInt conn "SELECT count(*) FROM entities WHERE file_path = ?" (Only linda)
          `shouldReturn` (n0 + 1)
  where
    linda = "characters/琳達.md"
    main_ = idOf "ent-7f3a"
    frag = idOf "ent-7f3b"

-- 小工具 ----------------------------------------------------------------------

allDistinct :: (Eq a) => [a] -> Bool
allDistinct xs = length xs == length (foldr (\x acc -> if x `elem` acc then acc else x : acc) [] xs)

idText :: CreateResult -> Text
idText = renderId . crId

sectionTitles :: Text -> [Text]
sectionTitles txt =
  [ T.strip (T.takeWhile (/= '{') (T.drop 3 l))
  | l <- T.lines txt
  , "## " `T.isPrefixOf` l
  ]

-- | 檔案裡最後一個 @```meta@ 區塊的內容。
lastMetaBlock :: Text -> Text
lastMetaBlock txt = case reverse (T.splitOn "```meta" txt) of
  (t : _) -> T.takeWhile (/= '`') t
  [] -> ""

-- | 從第一個節標題開始到結尾的全部內容。用來斷言「既有的節逐字不變」。
fromFirstSection :: Text -> Text
fromFirstSection = snd . T.breakOn "## 外貌"
