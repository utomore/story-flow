-- | 重構規劃的測試。
--
-- 規劃器是純函數,所以刪除閘門的每一條規則都能在這裡完整驗證,
-- 不必對著真實素材庫跑一次看結果 —— 那是**不可逆操作**,
-- 「跑跑看」不是可接受的驗證方式。
module AssetDB.Reorg.PlanSpec (spec) where

import AssetDB.Reorg.Plan
import AssetDB.Reorg.Snapshot
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "目標路徑" $ do
    it "商業素材包依 vendor 分組" $
      -- vendor 永遠不變;分類(GUI / Ground / Book)是多值且會被重新歸類的,
      -- 那些屬於資料庫,不屬於資料夾。
      targetDirFor (pack "animal-icons" `withVendor` "Kibyra")
        `shouldBe` "library/packs/kibyra/animal-icons"

    it "沒有 vendor 時落在 unknown/,而不是散在頂層" $
      targetDirFor (pack "magic-shader-all")
        `shouldBe` "library/packs/unknown/magic-shader-all"

    it "vendor 名稱會 slug 化" $
      targetDirFor (pack "x" `withVendor` "BDragon1727")
        `shouldBe` "library/packs/bdragon1727/x"

    it "vendor 全是非 ASCII 時退回 unknown,不是空目錄名" $
      -- slugify 對純中文會產生空字串。若不處理,路徑會變成
      -- library/packs//x —— 一個空的路徑分段。
      targetDirFor (pack "x" `withVendor` "廠商")
        `shouldBe` "library/packs/unknown/x"

    it "參考資料不進 packs/" $
      targetDirFor (pack "jinmen") {prKind = "reference"}
        `shouldBe` "library/reference/jinmen"

  describe "頂層資料夾對應" $ do
    it "中文資料夾名改成 ASCII" $ do
      mapTopLevel "行銷/2024-ebook.pdf" `shouldBe` Just "marketing/2024-ebook.pdf"
      mapTopLevel "Papers/apecs.pdf" `shouldBe` Just "knowledge/papers/apecs.pdf"
      mapTopLevel "GameProjects/Col/gdd.md" `shouldBe` Just "projects/Col/gdd.md"

    it "不在規則內的路徑回 Nothing —— 由規劃器決定保留" $
      mapTopLevel "SomethingElse/x.txt" `shouldBe` Nothing

  describe "刪除閘門" $ do
    -- 這是整個重構最危險的部分。三條規則,每一條都獨立測。

    it "雜湊存在於壓縮檔內的廠商散檔會被刪除,且記錄證據" $ do
      let p = buildPlan "src" "dst" (snapshotWith [loose "Game Assets itchio/a/x.png" (Just "aaa")] (Map.fromList [("aaa", "Game Assets itchio/Raw/pack.zip")]))
      [o | o@OpDelete {} <- planOps p]
        `shouldBe` [OpDelete "Game Assets itchio/a/x.png" "aaa" "Game Assets itchio/Raw/pack.zip" 10]

    it "雜湊不在任何壓縮檔內就不刪 —— 即使路徑看起來像廠商素材" $ do
      let p = buildPlan "src" "dst" (snapshotWith [loose "Game Assets itchio/a/x.png" (Just "zzz")] (Map.fromList [("aaa", "pack.zip")]))
      [o | o@OpDelete {} <- planOps p] `shouldBe` []
      [opWhy o | o@OpKeep {} <- planOps p] `shouldBe` ["不在已知的頂層對應規則內,需要人工決定"]

    it "沒有雜湊的檔案永遠不刪" $ do
      -- 掃描時讀不到內容的項目。沒有證據就不動它。
      let p = buildPlan "src" "dst" (snapshotWith [loose "Game Assets itchio/a/x.png" Nothing] (Map.fromList [("aaa", "pack.zip")]))
      [o | o@OpDelete {} <- planOps p] `shouldBe` []
      [opWhy o | o@OpKeep {} <- planOps p] `shouldBe` ["掃描時讀不到內容,沒有雜湊可證明"]

    it "工作室自有檔案即使雜湊碰巧命中也不刪,而是搬移" $ do
      -- 這條規則保護的是「我自己畫的圖剛好與某個素材包內容相同」
      -- 這種罕見但災難性的情況。刪除只針對 Game Assets itchio/ 底下的解壓副本。
      let p = buildPlan "src" "dst" (snapshotWith [loose "GameProjects/Col/icon.png" (Just "aaa")] (Map.fromList [("aaa", "pack.zip")]))
      [o | o@OpDelete {} <- planOps p] `shouldBe` []
      [opTo o | o@OpMove {} <- planOps p, opFrom o == "GameProjects/Col/icon.png"]
        `shouldBe` ["projects/Col/icon.png"]

  describe "素材包搬移" $ do
    it "壓縮檔保留廠商原始檔名" $ do
      -- 原檔不改名是溯源的基礎:重新下載、廠商更新、授權爭議都倚賴它。
      let snap = (snapshotWith [] Map.empty) {snPacks = [pk]}
          pk = (pack "complete-ui-book-styles" `withVendor` "Crusenho") {prArchiveRel = "Raw/[GUI] Complete_UI_Book_Styles_Pack_Full.7z"}
          p = buildPlan "src" "dst" snap
      [opTo o | o@OpMove {} <- planOps p]
        `shouldBe` ["library/packs/crusenho/complete-ui-book-styles/[GUI] Complete_UI_Book_Styles_Pack_Full.7z"]
      [opTo o | o@OpWrite {} <- planOps p]
        `shouldBe` ["library/packs/crusenho/complete-ui-book-styles/pack.toml"]

  describe "警告" $ do
    it "draft 的素材包會被點名" $ do
      let snap = (snapshotWith [] Map.empty) {snPacks = [(pack "x") {prStatus = "draft"}]}
      planWarnings (buildPlan "src" "dst" snap) `shouldSatisfy` any (elem' "draft")

    it "全部就緒時沒有警告" $ do
      let snap = (snapshotWith [] Map.empty) {snPacks = [pack "x" `withVendor` "V"]}
      planWarnings (buildPlan "src" "dst" snap) `shouldBe` []

  describe "統計" $
    it "刪除的位元組數是釋出空間" $ do
      let snap = snapshotWith [loose "Game Assets itchio/a.png" (Just "aaa")] (Map.fromList [("aaa", "p.zip")])
      psBytesFreed (planStats (buildPlan "src" "dst" snap)) `shouldBe` 10

--------------------------------------------------------------------------------

pack :: Text -> PackRow
pack slug =
  PackRow
    { prSlug = slug
    , prName = slug
    , prVendor = Nothing
    , prAuthor = Just "A"
    , prLicense = Just "L"
    , prKind = "packs"
    , prStatus = "ready"
    , prAi = "none"
    , prSourceUrl = Nothing
    , prVersion = Nothing
    , prNotes = Nothing
    , prArchiveRel = "Raw/" <> slug <> ".zip"
    , prArchiveSha = "sha"
    , prArchiveBytes = 100
    , prEntryCount = 1
    }

withVendor :: PackRow -> Text -> PackRow
withVendor p v = p {prVendor = Just v}

loose :: Text -> Maybe Text -> LooseRow
loose p sha = LooseRow p sha 10

snapshotWith :: [LooseRow] -> Map.Map Text Text -> Snapshot
snapshotWith ls m = Snapshot {snPacks = [], snLoose = ls, snArchivedBy = m}

elem' :: Text -> Text -> Bool
elem' = T.isInfixOf
