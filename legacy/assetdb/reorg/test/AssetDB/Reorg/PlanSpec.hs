-- | 重構規劃的測試。
--
-- 規劃器是純函數,所以每一條規則都能在這裡完整驗證,
-- 不必對著真實素材庫跑一次看結果 —— 那是**不可逆操作**,
-- 「跑跑看」不是可接受的驗證方式。
--
-- 2026-08-09 一次性搬遷的規則(刪除閘門、頂層對應)已於 ingest/E003
-- 退役,對應的測試一併移除;取而代之的是「散檔一律保留」的防誤觸測試。
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

  describe "散檔" $ do
    -- ingest/E003:一次性搬遷的規則退役後,散檔一律保留。
    -- 這條測試是防誤觸的迴歸保證 —— 誤跑 reorganize --apply 的最壞結果
    -- 是素材包被重組,而不是散檔被搬移或刪除。
    it "一律 OpKeep,不產生任何搬移或刪除" $ do
      let p =
            buildPlan
              "src"
              "dst"
              ( snapshotWith
                  [ loose "Game Assets itchio/a/x.png" (Just "aaa") -- 舊廠商前綴,雜湊也命中壓縮檔
                  , loose "GameProjects/Col/icon.png" (Just "aaa") -- 舊頂層對應規則的路徑
                  , loose "unknown/y.txt" Nothing -- 沒有雜湊
                  ]
                  (Map.fromList [("aaa", "Game Assets itchio/Raw/pack.zip")])
              )
      [o | o@OpDelete {} <- planOps p] `shouldBe` []
      [o | o@OpMove {} <- planOps p] `shouldBe` []
      length [o | o@OpKeep {} <- planOps p] `shouldBe` 3

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
      -- 現行規劃器不再產生 OpDelete,但統計對 Plan 是通用的,
      -- 直接以手組的 Plan 驗證。
      let p = Plan "src" "dst" [OpDelete "a.png" "aaa" "p.zip" 10] []
      psBytesFreed (planStats p) `shouldBe` 10

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
