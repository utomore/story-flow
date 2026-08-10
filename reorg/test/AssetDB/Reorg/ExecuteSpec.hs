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
import Data.Text.IO qualified as TIO
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
      arMoved r `shouldBe` 2 -- 壓縮檔 + 工作室文件
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

    it "工作室自有檔案搬移而非刪除" $ withLib $ \env -> do
      _ <- runApply env False
      doesFileExist (dst env </> "projects/Col/notes.md") `shouldReturn` True

    it "**不加旗標時散檔原封不動**" $ withLib $ \env -> do
      r <- runApply env False
      arDeleted r `shouldBe` 0
      doesFileExist (src env </> "Game Assets itchio/extracted/a.png") `shouldReturn` True

    it "對帳通過:壓縮檔搬移後雜湊不變" $ withLib $ \env -> do
      r <- runApply env False
      arReconciled r `shouldBe` 1

  describe "階段 B(刪除,不可回退)" $ do
    it "加了 --delete-covered 才刪" $ withLib $ \env -> do
      r <- runApply env True
      arDeleted r `shouldBe` 2
      doesFileExist (src env </> "Game Assets itchio/extracted/a.png") `shouldReturn` False

    it "刪除後清掉空目錄" $ withLib $ \env -> do
      _ <- runApply env True
      doesDirectoryExist (src env </> "Game Assets itchio/extracted") `shouldReturn` False

  describe "前置檢查" $ do
    it "目標目錄非空時拒絕動作" $ withLib $ \env -> do
      createDirectoryIfMissing True (dst env)
      writeFile (dst env </> "squatter.txt") "x"
      r <- runApply env False
      arMoved r `shouldBe` 0
      arErrors r `shouldSatisfy` any (T.isInfixOf "已存在且非空")
      -- 沒有動任何來源檔案
      doesFileExist (src env </> "Game Assets itchio/Raw/demo.zip") `shouldReturn` True

    it "來源檔案消失時拒絕動作(計畫過期)" $ withLib $ \env -> do
      removeFile (src env </> "Game Assets itchio/Raw/demo.zip")
      r <- runApply env False
      arMoved r `shouldBe` 0
      arErrors r `shouldSatisfy` any (T.isInfixOf "已經不存在")

  describe "回退" $ do
    it "把搬移倒回原位" $ withLib $ \env -> do
      snap <- loadSnapshot (store env)
      let plan = buildPlan (T.pack (src env)) (T.pack (dst env)) snap
      _ <- applyPlan (store env) snap (defaultApplyOptions "b1") plan
      (ok, errs) <- undoBatch (store env) (src env) (dst env) "b1" (const (pure ()))
      errs `shouldBe` []
      ok `shouldSatisfy` (>= 2)
      doesFileExist (src env </> "Game Assets itchio/Raw/demo.zip") `shouldReturn` True
      doesFileExist (dst env </> "library/packs/unknown/demo/demo.zip") `shouldReturn` False

    it "刪除無法回退,而且會明講" $ withLib $ \env -> do
      snap <- loadSnapshot (store env)
      let plan = buildPlan (T.pack (src env)) (T.pack (dst env)) snap
      _ <-
        applyPlan (store env) snap (defaultApplyOptions "b2") {aoDeleteCovered = True} plan
      (_, errs) <- undoBatch (store env) (src env) (dst env) "b2" (const (pure ()))
      errs `shouldSatisfy` any (T.isInfixOf "刪除無法回退")

    it "批次列得出來" $ withLib $ \env -> do
      _ <- runApply env False
      bs <- listBatches (store env)
      length bs `shouldBe` 1

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
-- * 那兩個檔案的解壓副本散在 @Game Assets itchio\/@ 底下(會被刪)
-- * 一個工作室自有檔案(會被搬移,絕不刪除)
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
