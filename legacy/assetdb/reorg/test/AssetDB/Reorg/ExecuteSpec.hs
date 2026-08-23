-- | 執行器的端到端測試。
--
-- 在暫存目錄裡搭一個縮小版的素材庫,完整跑一次「掃描 → 規劃 → 執行 → 對帳 →
-- 刪除 → 回退」。**不碰任何真實素材。**
--
-- 這是驗證破壞性操作的唯一負責任方式:在真資料上「跑跑看」不叫測試。
module AssetDB.Reorg.ExecuteSpec (spec) where

import AssetDB.Archive (discoverTools)
import AssetDB.Ingest (defaultScanOptions, scanRoot)
import AssetDB.Reorg.Execute
import AssetDB.Reorg.Plan
import AssetDB.Reorg.Snapshot
import AssetDB.Store
import Codec.Archive.Zip qualified as Z
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.ByteString qualified as BS
import Data.Text.Encoding (decodeUtf8)
import Database.SQLite.Simple (close)
import System.Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "階段 A(搬移,可回退)" $ do
    it "壓縮檔搬到 library/packs/<vendor>/<slug>/" $ withLib $ \env -> do
      r <- runApply env False
      arErrors r `shouldBe` []
      arMoved r `shouldBe` 1 -- 只剩壓縮檔;散檔規則已退役(ingest/E003)
      doesFileExist (dst env </> "library/packs/unknown/demo/demo.zip") `shouldReturn` True

    it "寫出 pack.toml" $ withLib $ \env -> do
      _ <- runApply env False
      let toml = dst env </> "library/packs/unknown/demo/pack.toml"
      doesFileExist toml `shouldReturn` True
      -- 明確以 UTF-8 解碼:TIO.readFile 用 locale 編碼,在 Windows 上
      -- 解不出我們剛以 UTF-8 寫出去的位元組。讀與寫都必須明確。
      c <- decodeUtf8 <$> BS.readFile toml
      c `shouldSatisfy` T.isInfixOf "slug = \"demo\""
      c `shouldSatisfy` T.isInfixOf "[archive]"

    it "散檔(含工作室自有檔案)原地保留,不搬移" $ withLib $ \env -> do
      -- ingest/E003:一次性搬遷的頂層對應規則已退役。
      _ <- runApply env False
      doesFileExist (src env </> "GameProjects/Col/notes.md") `shouldReturn` True
      doesFileExist (dst env </> "projects/Col/notes.md") `shouldReturn` False

    it "**散檔原封不動**" $ withLib $ \env -> do
      r <- runApply env False
      arDeleted r `shouldBe` 0
      doesFileExist (src env </> "Game Assets itchio/extracted/a.png") `shouldReturn` True

    it "對帳通過:壓縮檔搬移後雜湊不變" $ withLib $ \env -> do
      r <- runApply env False
      arReconciled r `shouldBe` 1

  describe "階段 B(刪除,不可回退)" $ do
    it "即使加了 --delete-covered 也不再刪散檔 —— 刪除規則已退役" $ withLib $ \env -> do
      -- ingest/E003 防誤觸:誤跑 reorganize --apply --delete-covered 的
      -- 最壞結果是素材包被重組,散檔一根汗毛都不會少。
      r <- runApply env True
      arErrors r `shouldBe` []
      arDeleted r `shouldBe` 0
      doesFileExist (src env </> "Game Assets itchio/extracted/a.png") `shouldReturn` True

  describe "冪等性" $ do
    -- 兩階段設計要求這件事:階段 A 跑完、使用者確認結果無誤之後,
    -- 才會加上 --delete-covered 再跑一次執行階段 B。
    -- 第二次跑的時候目標目錄當然非空 —— 那是第一次的成果,不是障礙。
    it "階段 A 跑過之後,再跑一次會跳過已完成的搬移" $ withLib $ \env -> do
      r1 <- runApply env False
      arMoved r1 `shouldBe` 1
      r2 <- runApply env False
      arMoved r2 `shouldBe` 0
      arErrors r2 `shouldBe` []
      -- 對帳仍然執行,所以「已完成」不等於「不再驗證」
      arReconciled r2 `shouldBe` 1

  describe "前置檢查" $ do
    it "來源與目標都找不到時拒絕動作(計畫過期)" $ withLib $ \env -> do
      removeFile (src env </> "Game Assets itchio/Raw/demo.zip")
      r <- runApply env False
      arMoved r `shouldBe` 0
      arErrors r `shouldSatisfy` any (T.isInfixOf "都找不到")

    it "來源與目標同時存在時拒絕動作(上次中斷)" $ withLib $ \env -> do
      -- 曖昧狀態:不知道哪一份才是正確的,所以不猜。
      let to = dst env </> "library/packs/unknown/demo/demo.zip"
      createDirectoryIfMissing True (dst env </> "library/packs/unknown/demo")
      copyFile (src env </> "Game Assets itchio/Raw/demo.zip") to
      r <- runApply env False
      arErrors r `shouldSatisfy` any (T.isInfixOf "同時存在")
      doesFileExist (src env </> "Game Assets itchio/Raw/demo.zip") `shouldReturn` True

  describe "回退" $ do
    it "把搬移倒回原位" $ withLib $ \env -> do
      snap <- loadSnapshot (store env)
      let plan = buildPlan (T.pack (src env)) (T.pack (dst env)) snap
      _ <- applyPlan (store env) snap (defaultApplyOptions "b1") plan
      (ok, errs) <- undoBatch (store env) (src env) (dst env) "b1" (const (pure ()))
      errs `shouldBe` []
      ok `shouldSatisfy` (>= 1)
      doesFileExist (src env </> "Game Assets itchio/Raw/demo.zip") `shouldReturn` True
      doesFileExist (dst env </> "library/packs/unknown/demo/demo.zip") `shouldReturn` False

    it "刪除無法回退,而且會明講" $ withLib $ \env -> do
      -- 現行規劃器已不會產生 OpDelete(ingest/E003),但執行器與回退
      -- 機制對 Plan 是通用的 —— 手組一個帶刪除的計畫,驗證回退對刪除
      -- 的拒絕仍然有效。
      snap <- loadSnapshot (store env)
      let plan =
            Plan
              (T.pack (src env))
              (T.pack (dst env))
              [OpDelete "Game Assets itchio/extracted/a.png" "aaa" "Raw/demo.zip" 10]
              []
      _ <-
        applyPlan (store env) snap (defaultApplyOptions "b2") {aoDeleteCovered = True} plan
      (_, errs) <- undoBatch (store env) (src env) (dst env) "b2" (const (pure ()))
      errs `shouldSatisfy` any (T.isInfixOf "刪除無法回退")

    it "批次列得出來" $ withLib $ \env -> do
      _ <- runApply env False
      bs <- listBatches (store env)
      length bs `shouldBe` 1

  -- G-E003 指標 1 的三處。階段 A 的三個檔案系統動作原本都是裸的:
  -- 任何一個失敗,例外就飛出 applyPlan,而使用者只看到一個英文例外 ——
  -- 更糟的是不知道搬到一半停在哪裡。
  describe "檔案系統動作的錯誤出口(G-E003)" $ do
    it "建目錄、搬移、寫 pack.toml 三者失敗時各自進 arErrors" $ withLib $ \env -> do
      -- 在 library/ 該在的位置放一個**檔案**:三個動作都要先
      -- createDirectoryIfMissing 到它底下,於是三者一起失敗。
      -- 比起改 ACL,這個觸發條件在每個平台上都一樣。
      createDirectoryIfMissing True (dst env)
      BS.writeFile (dst env </> "library") "占位"

      r <- runApply env False

      arErrors r `shouldSatisfy` any (T.isInfixOf "建目錄失敗")
      arErrors r `shouldSatisfy` any (T.isInfixOf "建目標目錄失敗")
      arErrors r `shouldSatisfy` any (T.isInfixOf "寫入 pack.toml 失敗")
      -- library/ 底下一個目錄都建不出來(其餘不在它底下的目錄不受影響)。
      doesDirectoryExist (dst env </> "library" </> "packs") `shouldReturn` False
      arMoved r `shouldBe` 0
      arWritten r `shouldBe` 0

    it "失敗時一筆都不刪,來源原封不動" $ withLib $ \env -> do
      -- 這是既有的安全性質:對帳沒過就不刪。錯誤出口不得在任何情況下
      -- 讓刪除提前發生 —— 那是唯一不可回退的動作。
      createDirectoryIfMissing True (dst env)
      BS.writeFile (dst env </> "library") "占位"

      r <- runApply env True

      arDeleted r `shouldBe` 0
      doesFileExist (src env </> "Game Assets itchio/Raw/demo.zip") `shouldReturn` True
      doesFileExist (src env </> "Game Assets itchio/extracted/a.png") `shouldReturn` True

    it "對帳讀不到搬移後的檔案時回報不符,而不是拋例外" $ withLib $ \env -> do
      -- reconcile 的 doesFileExist 與 sha256File 之間是 TOCTOU 視窗,
      -- 而對帳的結論直接決定階段 B 要不要刪散檔。
      createDirectoryIfMissing True (dst env)
      BS.writeFile (dst env </> "library") "占位"
      r <- runApply env True
      arReconciled r `shouldBe` 0
      arErrors r `shouldSatisfy` (not . null)

--------------------------------------------------------------------------------

data Env = Env {store :: Store, src :: FilePath, dst :: FilePath}

runApply :: Env -> Bool -> IO ApplyReport
runApply env del = do
  snap <- loadSnapshot (store env)
  let plan = buildPlan (T.pack (src env)) (T.pack (dst env)) snap
  applyPlan (store env) snap (defaultApplyOptions "batch") {aoDeleteCovered = del} plan

-- | 縮小版的素材庫,結構與真實情況同形:
--
-- * 一個壓縮檔,內含兩個檔案
-- * 那兩個檔案的解壓副本散在 @Game Assets itchio\/@ 底下
-- * 一個工作室自有檔案
--
-- 散檔如今一律保留(ingest/E003)—— 沿用舊搬遷時期的目錄名,
-- 正是為了驗證那些路徑不再觸發任何搬移或刪除。
withLib :: (Env -> IO ()) -> IO ()
withLib f =
  withSystemTempDirectory "assetdb-reorg" $ \root -> do
    let s = root </> "src"
        d = root </> "dst"
    createDirectoryIfMissing True (s </> "Game Assets itchio" </> "Raw")
    createDirectoryIfMissing True (s </> "Game Assets itchio" </> "extracted")
    createDirectoryIfMissing True (s </> "GameProjects" </> "Col")

    Z.createArchive (s </> "Game Assets itchio" </> "Raw" </> "demo.zip") $
      forM_ entries $ \(p, c) -> do
        sel <- Z.mkEntrySelector (T.unpack p)
        Z.addEntry Z.Deflate c sel

    forM_ entries $ \(p, c) ->
      BC.writeFile (s </> "Game Assets itchio" </> "extracted" </> T.unpack (leaf p)) c
    BC.writeFile (s </> "GameProjects" </> "Col" </> "notes.md") "設計筆記"

    st <- openStore (root </> "db.sqlite")
    void (initSchema st)
    tools <- discoverTools
    void (scanRoot st tools (defaultScanOptions s))
    f (Env st s d)
    close (storeConn st)
  where
    leaf = last . T.splitOn "/"

entries :: [(Text, ByteString)]
entries =
  [ ("Sprites/a.png", BC.pack "\137PNG\r\n\26\n" <> "aaa")
  , ("Sprites/b.png", BC.pack "\137PNG\r\n\26\n" <> "bbb")
  ]
