-- | 規則持久化與套用的測試。
--
-- 重點在**撞名**與**全有全無**:@logical_name@ 有 UNIQUE 約束,
-- 而半套用的命名比沒有命名更難收拾 —— 你不知道哪些是舊的、哪些是新的。
module AssetDB.Ingest.ClusterDbSpec (spec) where

import AssetDB.Ingest.Cluster
import AssetDB.Ingest.ClusterDb
import AssetDB.Naming (defaultVocab)
import AssetDB.Store
import AssetDB.Types (KindPrefix (..))
import Control.Monad (forM_, void)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = around withPack $ do
  describe "規則的存取" $ do
    it "存進去讀得回來" $ \st -> do
      let r = rule PUi "gui"
      saveCluster st r "sprites|U_W_WNa|.png"
      loaded <- loadRules st 1
      Map.lookup "sprites|U_W_WNa|.png" loaded `shouldBe` Just r

    it "同一個叢集重複確認是覆寫而非新增" $ \st -> do
      saveCluster st (rule PUi "gui") "sprites|U_W_WNa|.png"
      saveCluster st (rule PSpr "item") "sprites|U_W_WNa|.png"
      loaded <- loadRules st 1
      Map.size loaded `shouldBe` 1
      fmap nrKind (Map.lookup "sprites|U_W_WNa|.png" loaded) `shouldBe` Just PSpr

  describe "套用" $ do
    it "只套用已確認叢集,其餘跳過" $ \st -> do
      saveCluster st (rule PUi "gui") {nrDropTokens = [0]} "sprites|U_W_WNa|.png"
      r <- applyNames st defaultVocab 1 True
      anNamed r `shouldBe` 2
      anSkipped r `shouldBe` 2
      names st `shouldReturn` ["ui_gui_travel-book-alert_01a", "ui_gui_wizard-book-alert_01a"]

    it "沒有任何規則時什麼都不做" $ \st -> do
      r <- applyNames st defaultVocab 1 True
      anNamed r `shouldBe` 0
      anSkipped r `shouldBe` 4
      names st `shouldReturn` []

  describe "撞名" $ do
    it "在寫入之前攔下,並回報所有撞名而不是第一個" $ \st -> do
      -- 丟掉 0 與 1 兩個權杖之後,TravelBook 與 WizardBook 的區別消失,
      -- Alert01a 與 Alert01a 撞在一起。
      saveCluster st (rule PUi "gui") {nrDropTokens = [0, 1]} "sprites|U_W_WNa|.png"
      r <- applyNames st defaultVocab 1 True
      map fst (anCollisions r) `shouldBe` ["ui_gui_alert_01a"]
      length (snd (head (anCollisions r))) `shouldBe` 2

    it "有撞名就一筆都不寫" $ \st -> do
      -- 半套用比沒套用更難收拾。
      saveCluster st (rule PUi "gui") {nrDropTokens = [0, 1]} "sprites|U_W_WNa|.png"
      _ <- applyNames st defaultVocab 1 True
      anNamed <$> applyNames st defaultVocab 1 True `shouldReturn` 0
      names st `shouldReturn` []

  -- G-B001:logical_name 是 ADR-004 的對外命名契約,全域唯一、遊戲的
  -- Assets.hs 常數由它產生,而且寫入後沒有 undo 路徑。套用必須先預覽。
  describe "預覽閘門(G-B001)" $ do
    it "未確認時算得出會命名幾筆,但一個字都不寫進資料庫" $ \st -> do
      saveCluster st (rule PUi "gui") {nrDropTokens = [0]} "sprites|U_W_WNa|.png"
      r <- applyNames st defaultVocab 1 False
      anNamed r `shouldBe` 2
      names st `shouldReturn` []

    it "預覽帶得出實際會產生的名字,不只是數字" $ \st -> do
      saveCluster st (rule PUi "gui") {nrDropTokens = [0]} "sprites|U_W_WNa|.png"
      r <- applyNames st defaultVocab 1 False
      map snd (anNames r)
        `shouldMatchList` ["ui_gui_travel-book-alert_01a", "ui_gui_wizard-book-alert_01a"]

    it "確認後才真的寫入,且結果與預覽完全一致" $ \st -> do
      saveCluster st (rule PUi "gui") {nrDropTokens = [0]} "sprites|U_W_WNa|.png"
      preview <- applyNames st defaultVocab 1 False
      applied <- applyNames st defaultVocab 1 True
      -- 預覽與套用共用同一條計算路徑,所以連名字對應都必須逐筆相同。
      anNames applied `shouldBe` anNames preview
      anNamed applied `shouldBe` anNamed preview
      names st `shouldReturn` ["ui_gui_travel-book-alert_01a", "ui_gui_wizard-book-alert_01a"]

  describe "預覽" $
    it "不寫入任何東西" $ \st -> do
      let ps = previewCluster defaultVocab (rule PUi "gui") {nrDropTokens = [0]} ["P/Sprites/UI_A_Frame01a.png"]
      map npResult ps `shouldBe` [Right "ui_gui_a-frame_01a"]
      loadRules st 1 `shouldReturn` Map.empty
      names st `shouldReturn` []

--------------------------------------------------------------------------------

rule :: KindPrefix -> Text -> NameRule
rule k d = NameRule k d Nothing [] 0 NumAuto []

saveCluster :: Store -> NameRule -> Text -> IO ()
saveCluster st r shape =
  saveRule st 1 (Cluster (keyFromText shape) 0 []) r
  where
    -- saveRule 只用 clKey 的文字形式與 clCount,所以測試裡從一個
    -- 代表性路徑反推 key 就夠了。
    keyFromText s = case s of
      "sprites|U_W_WNa|.png" -> clusterKeyOf "P/Sprites/UI_A_B01a.png"
      _ -> clusterKeyOf "P/x.png"

names :: Store -> IO [Text]
names st =
  map fromOnly
    <$> query_
      (storeConn st)
      "SELECT logical_name FROM assets WHERE logical_name IS NOT NULL ORDER BY logical_name"

-- | 四筆資源:兩筆同形狀(會被命名),兩筆不同形狀(叢集未確認)。
withPack :: (Store -> IO ()) -> IO ()
withPack f = do
  st <- openStoreInMemory
  void (initSchema st)
  let conn = storeConn st
  execute_ conn "INSERT INTO roots (id,path,label,kind) VALUES (1,'/lib','lib','packs')"
  execute_
    conn
    "INSERT INTO packs (id,ulid,slug,name,root_id,rel_dir,created_at,updated_at) \
    \VALUES (1,'01P','demo','Demo',1,'v/demo','t','t')"
  execute_
    conn
    "INSERT INTO archives (id,ulid,pack_id,rel_path,format,sha256,bytes) \
    \VALUES (1,'01A',1,'demo.zip','zip','sha',1)"
  forM_ (zip [1 :: Int ..] entries) $ \(i, p) ->
    execute
      conn
      "INSERT INTO assets (ulid,kind,archive_id,entry_path,original_name,pack_id,created_at,updated_at) \
      \VALUES (?,'image',1,?,?,1,'t','t')"
      ("01B" <> show i, p, p)
  f st
  close conn

-- 兩筆 sprites 刻意用**相同的 variant**:丟掉書名權杖之後它們會撞名,
-- 這正是撞名測試需要的條件。保留書名時則各自唯一。
entries :: [Text]
entries =
  [ "P/Sprites/UI_TravelBook_Alert01a.png"
  , "P/Sprites/UI_WizardBook_Alert01a.png"
  , "P/Preview/Promo.png"
  , "P/Aseprite/Book.aseprite"
  ]
