-- | 專案增量同步(delivery/F006)。
--
-- 對帳是純查詢,所以四類判定可以對著**真實的 SQLite 暫存庫**與**真實的暫存
-- 目錄**直接驅動 —— 而「該不該覆蓋一個使用者可能已經手改過的檔案」正是這個
-- 功能最容易寫錯的地方。
--
-- @--confirm@ 的寫入路徑以「新增項的來源壓縮檔讀不到」佈置:壓縮檔一律是
-- @.rar@ 而 'ArchiveTools' 明確給 'Nothing',所以 'readEntry' 必然失敗,
-- 不依賴這台機器上有沒有 7-Zip。真的複製成功的路徑沿用 @project@ 套件既有
-- 風格不直接測(F006 D4 / A3),但**寫入邊界**(不覆蓋、不刪除、不多登記)
-- 在這裡是被鎖住的。
module AssetDB.Project.SyncSpec (spec) where

import AssetDB.Archive (ArchiveTools (..))
import AssetDB.Guard (guardedTry)
import AssetDB.Ingest.Hash (sha256Bytes, unSha256)
import AssetDB.Manifest
import AssetDB.Naming (logicalNameText)
import AssetDB.Project.Sync
import AssetDB.Store
import Data.Aeson (eitherDecodeStrict)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Database.SQLite.Simple
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  , removeFile
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callCommand)
import Test.Hspec

spec :: Spec
spec = do
  describe "專案定位" $ do
    it "未登記的 --name 回 ProjectNotRegistered" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      r <- planSync st defOpts {soName = "nosuchproject"}
      r `shouldBe` Left (ProjectNotRegistered "nosuchproject")

    it "登記了但目錄不存在時回 ProjectDirMissing" $ withFixture $ \st proj -> do
      let gone = proj </> "moved-away"
      registerProjectRow (conn st) gone
      r <- planSync st defOpts
      r `shouldBe` Left (ProjectDirMissing gone)

    it "兩種失敗都不建立任何檔案、不改資料庫" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      snapBefore <- snapshot proj
      beforeDb <- dbState (conn st)

      _ <- planSync st defOpts {soName = "nosuchproject"}
      _ <- syncProject st noTools defOpts {soName = "nosuchproject", soConfirm = True}
      -- 目錄不存在的那一條:改掉登記路徑再跑
      execute (conn st) "UPDATE projects SET path = ? WHERE id = 1" (Only (T.pack (proj </> "gone")))
      _ <- syncProject st noTools defOpts {soConfirm = True}
      execute (conn st) "UPDATE projects SET path = ? WHERE id = 1" (Only (T.pack proj))

      snapshot proj `shouldReturn` snapBefore
      dbState (conn st) `shouldReturn` beforeDb

  describe "四類判定" $ do
    it "未登記的候選素材是 SyncNew" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncNew]

    it "三個雜湊相同時是 SyncUnchanged" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncUnchanged]

    it "來源 sha 改變時是 SyncSourceUpdated" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      -- 來源壓縮檔更新了:assets.sha256 指向新內容,專案裡的仍是舊的
      newSourceSha (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "alpha-v2"
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncSourceUpdated]

    it "磁碟檔案被改(大小相同)時是 SyncLocallyModified" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      -- 內容不同、長度刻意相同,逼對帳真的去算雜湊而不是只看大小
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (tweak (blobContent "alpha"))
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncLocallyModified]

    it "磁碟檔案被刪時是 SyncLocallyModified,而不是被當成新增" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      removeFile (proj </> "assets/sprites/ui_gui_alpha_01.png")
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncLocallyModified]

    -- G-E003 T10。doesFileExist 與 sha256File 之間是 TOCTOU 視窗:檔案可能
    -- 被刪掉、改名或被其他程式鎖住。契約 §6 已經把「檔案已不在」歸進
    -- SyncLocallyModified(不覆蓋、請人來看),讀不到雜湊落在同一類 ——
    -- 沒有比對基準時保守處理,而不是讓一個 IOException 炸掉整次 sync。
    it "對帳途中讀不到檔案時是 SyncLocallyModified,不是拋例外" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      let rel = "assets/sprites/ui_gui_alpha_01.png"
          dest = proj </> rel
      writeAsset proj rel (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" (T.pack rel) (Just (shaOf "alpha"))
      -- 只拒絕**讀取內容**(RD),不動屬性 —— doesFileExist 與 getFileSize
      -- 照樣成功,失敗的正好是 sha256File 那一步。
      denyReadData dest
      blocked <- isUnreadable dest
      if not blocked
        then do
          allowReadData dest
          pendingWith "這個環境的 ACL 沒有生效,製造不出讀不到的檔案"
        else do
          plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
          classOf plan "ui_gui_alpha_01" `shouldBe` [SyncLocallyModified]
          allowReadData dest

    -- D3:大小不同必然內容不同,所以先比 blobs.bytes 就能短路掉整批讀檔。
    it "大小與 blobs.bytes 不同時判為 SyncLocallyModified" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha" <> "TRAILING")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncLocallyModified]

    -- blobs 查不到 copied_sha256 對應的列時(理論上不會發生),短路失效,
    -- 但不該因為缺一筆中繼資料就誤判成「本地已修改」而讓使用者以為檔案被動過。
    it "blobs 查不到期望大小時退回讀檔,不因為缺中繼資料就誤判" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      -- copied_sha256 指向一份沒有 blobs 列的內容,而磁碟上的檔案正是它
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "orphan")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "orphan"))
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      -- 磁碟 = copied_sha256 ≠ 來源 sha:是「來源已更新」,不是「本地已修改」
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncSourceUpdated]

    it "copied_sha256 為 NULL 時退回與來源比對" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" Nothing
      plan <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan "ui_gui_alpha_01" `shouldBe` [SyncUnchanged]

      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (tweak (blobContent "alpha"))
      plan2 <- mustPlan (planSync st defOpts {soQuery = Just "alpha"})
      classOf plan2 "ui_gui_alpha_01" `shouldBe` [SyncLocallyModified]

  describe "授權閘門" $ do
    it "不可商用的新增項被擋下並列入 spBlocked" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      plan <- mustPlan (planSync st defOpts {soPacks = ["noncomm"]})
      spBlocked plan `shouldBe` ["noncomm"]
      spEntries plan `shouldBe` []

    it "授權未查證(NULL)的新增項同樣被擋下" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      plan <- mustPlan (planSync st defOpts {soPacks = ["unlicensed"]})
      spBlocked plan `shouldBe` ["unlicensed"]
      spEntries plan `shouldBe` []

    it "--allow-non-commercial 才放行" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      plan <-
        mustPlan
          (planSync st defOpts {soPacks = ["noncomm", "unlicensed"], soAllowNonCommercial = True})
      spBlocked plan `shouldBe` []
      map seName (spEntries plan) `shouldBe` ["ui_gui_delta_01", "ui_gui_gamma_01"]

    -- V8:閘門只擋新增,不回溯既有。既有素材靜靜消失的話,
    -- 遊戲端已經 import 的 AssetKey 常數會編不過。
    it "既有登記素材的素材包降級時仍留在 entries、不進 spBlocked,只逐包警告" $
      withFixture $ \st proj -> do
        registerProjectRow (conn st) proj
        writeAsset proj "assets/sprites/ui_gui_gamma_01.png" (blobContent "gamma")
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA3" "assets/sprites/ui_gui_gamma_01.png" (Just (shaOf "gamma"))
        (plan, events) <- withEvents $ \onEvent ->
          mustPlan (planSync st defOpts {soPacks = ["noncomm"], soOnEvent = onEvent})
        map seName (spEntries plan) `shouldBe` ["ui_gui_gamma_01"]
        classOf plan "ui_gui_gamma_01" `shouldBe` [SyncUnchanged]
        spBlocked plan `shouldBe` []
        events `shouldSatisfy` any (T.isInfixOf "noncomm")
        events `shouldSatisfy` any (T.isInfixOf "既有登記素材")

    -- B006:重寫的 manifest 涵蓋登記全集,警告就必須跟著全集。只查本次
    -- --pack / --match 命中的那些,等於讓不在篩選條件內的授權問題靜靜通過。
    it "警告涵蓋登記的全集,不受 --pack / --match 篩選限制" $
      withFixture $ \st proj -> do
        registerProjectRow (conn st) proj
        -- gamma 屬於 noncomm 包,已登記在專案裡
        writeAsset proj "assets/sprites/ui_gui_gamma_01.png" (blobContent "gamma")
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA3" "assets/sprites/ui_gui_gamma_01.png" (Just (shaOf "gamma"))
        -- 本次只挑 comm 包:noncomm 完全不在候選裡
        plan <- mustPlan (planSync st defOpts {soPacks = ["comm"]})
        map seName (spEntries plan) `shouldSatisfy` all (/= "ui_gui_gamma_01")
        spWarnedPacks plan `shouldBe` ["noncomm"]

    it "授權未查證(NULL)的既有素材包同樣進 spWarnedPacks" $
      withFixture $ \st proj -> do
        registerProjectRow (conn st) proj
        writeAsset proj "assets/sprites/ui_gui_delta_01.png" (blobContent "delta")
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA4" "assets/sprites/ui_gui_delta_01.png" (Just (shaOf "delta"))
        plan <- mustPlan (planSync st defOpts {soPacks = ["comm"]})
        spWarnedPacks plan `shouldBe` ["unlicensed"]

    it "可商用的既有素材包不進 spWarnedPacks" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      plan <- mustPlan (planSync st defOpts {soQuery = Just "beta"})
      spWarnedPacks plan `shouldBe` []

    -- A7:放行旗標一開,警告一併關掉。
    it "--allow-non-commercial 時 spWarnedPacks 為空" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_gamma_01.png" (blobContent "gamma")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA3" "assets/sprites/ui_gui_gamma_01.png" (Just (shaOf "gamma"))
      plan <- mustPlan (planSync st defOpts {soPacks = ["comm"], soAllowNonCommercial = True})
      spWarnedPacks plan `shouldBe` []

    -- 「被擋下、不會加入」與「既有素材仍留著、但授權有問題」是兩件事。
    it "spBlocked 與 spWarnedPacks 語意不同不可合併" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      -- 既有:unlicensed 包的 delta(留著,只警告)
      writeAsset proj "assets/sprites/ui_gui_delta_01.png" (blobContent "delta")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA4" "assets/sprites/ui_gui_delta_01.png" (Just (shaOf "delta"))
      -- 本次候選:noncomm 包的 gamma(新增,被擋下)
      plan <- mustPlan (planSync st defOpts {soPacks = ["noncomm"]})
      spBlocked plan `shouldBe` ["noncomm"]
      spWarnedPacks plan `shouldBe` ["unlicensed"]

  describe "預覽" $ do
    it "soConfirm=False 時不動磁碟、不動資料庫" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      snapBefore <- snapshot proj
      beforeDb <- dbState (conn st)

      r <- syncProject st noTools defOpts
      case r of
        Right res -> do
          syCopied res `shouldBe` 0
          sySkipped res `shouldBe` []
        Left e -> expectationFailure ("預期成功,收到 " <> show e)

      snapshot proj `shouldReturn` snapBefore
      dbState (conn st) `shouldReturn` beforeDb

    it "連跑兩次 planSync 得到相同的 SyncPlan" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      a <- planSync st defOpts
      b <- planSync st defOpts
      a `shouldBe` b

  describe "confirm 的寫入邊界" $ do
    it "既有檔案一個位元組都沒變,既有登記列也沒變、沒多出新列" $
      withFixture $ \st proj -> do
        registerProjectRow (conn st) proj
        -- 三類既有素材:已存在 / 來源已更新 / 本地已修改
        writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
        writeAsset proj "assets/sprites/ui_gui_gamma_01.png" (blobContent "gamma")
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA3" "assets/sprites/ui_gui_gamma_01.png" (Just (shaOf "gamma"))
        newSourceSha (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA3" "gamma-v2"
        writeAsset proj "assets/sprites/ui_gui_travel-book_01.png" (tweak (blobContent "tb1"))
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA5" "assets/sprites/ui_gui_travel-book_01.png" (Just (shaOf "tb1"))

        assetFiles <- snapshotOnly proj ["ui_gui_alpha_01.png", "ui_gui_gamma_01.png", "ui_gui_travel-book_01.png"]
        beforeRows <- registrationRows (conn st)
        beforeUpdated <- projectUpdatedAt (conn st)

        r <- syncProject st noTools defOpts {soAllowNonCommercial = True, soConfirm = True}
        case r of
          Left e -> expectationFailure ("預期成功,收到 " <> show e)
          Right res -> do
            -- 新增項的來源讀不到,所以一筆都沒複製
            syCopied res `shouldBe` 0
            sySkipped res `shouldSatisfy` (not . null)
            let plan = syPlan res
            classOf plan "ui_gui_alpha_01" `shouldBe` [SyncUnchanged]
            classOf plan "ui_gui_gamma_01" `shouldBe` [SyncSourceUpdated]
            classOf plan "ui_gui_travel-book_01" `shouldBe` [SyncLocallyModified]

        -- 既有檔案的位元組完全不變
        snapshotOnly proj ["ui_gui_alpha_01.png", "ui_gui_gamma_01.png", "ui_gui_travel-book_01.png"]
          `shouldReturn` assetFiles
        -- 既有登記列完全不變,而且沒有多出新列
        registrationRows (conn st) `shouldReturn` beforeRows
        -- projects.updated_at 已更新
        afterUpdated <- projectUpdatedAt (conn st)
        afterUpdated `shouldNotBe` beforeUpdated

  describe "重寫全集" $ do
    it "manifest.json 含全部登記素材,path 取 dest_rel_path、sha256 取 copied_sha256" $
      withFixture $ \st proj -> do
        registerProjectRow (conn st) proj
        writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
        -- 這一筆不符合本次的 --match 條件,但仍然屬於重寫 manifest 的全集
        writeAsset proj "assets/sprites/ui_gui_beta_01.png" (blobContent "beta")
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA2" "assets/sprites/ui_gui_beta_01.png" (Just (shaOf "beta"))
        -- 來源已更新:manifest 要描述磁碟上的那一份,不是來源的最新版
        newSourceSha (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA2" "beta-v2"

        _ <- syncProject st noTools defOpts {soQuery = Just "alpha", soConfirm = True}

        raw <- BS.readFile (proj </> "assets" </> "manifest.json")
        case eitherDecodeStrict raw :: Either String Manifest of
          Left e -> expectationFailure ("manifest.json 解不開:" <> e)
          Right m -> do
            mSchemaVersion m `shouldBe` currentSchemaVersion
            mProject m `shouldBe` "game"
            sort (map (logicalNameText . maKey) (mAssets m))
              `shouldBe` ["ui_gui_alpha_01", "ui_gui_beta_01"]
            [maPath a | a <- mAssets m, logicalNameText (maKey a) == "ui_gui_beta_01"]
              `shouldBe` ["assets/sprites/ui_gui_beta_01.png"]
            [maSha256 a | a <- mAssets m, logicalNameText (maKey a) == "ui_gui_beta_01"]
              `shouldBe` [shaOf "beta"]
            map mpName (mPacks m) `shouldBe` ["comm"]

    it "Assets.hs 每筆一個常數,識別字撞名時去重" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      -- travel-book 與 travel_book 轉出同一個 Haskell 識別字
      writeAsset proj "assets/sprites/ui_gui_travel-book_01.png" (blobContent "tb1")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA5" "assets/sprites/ui_gui_travel-book_01.png" (Just (shaOf "tb1"))
      writeAsset proj "assets/sprites/ui_gui_travel_book_01.png" (blobContent "tb2")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA6" "assets/sprites/ui_gui_travel_book_01.png" (Just (shaOf "tb2"))

      _ <- syncProject st noTools defOpts {soQuery = Just "alpha", soConfirm = True}

      src <- readUtf8 (proj </> "assets" </> "Assets.hs")
      countOf "uiGuiAlpha01 :: AssetKey" src `shouldBe` 1
      -- 撞名的兩筆只留一個常數,否則產生的模組有重複定義、根本編不過
      countOf "uiGuiTravelBook01 :: AssetKey" src `shouldBe` 1

    -- B007:兩個產物必須用同一個集合。集合不同會產生「Assets.hs 有這個
    -- AssetKey 常數,但 manifest 查不到」的組合 —— 編譯得過、執行期查表落空,
    -- 正是產生 Assets.hs 的全部理由要消滅的失敗模式。
    it "manifest.json 與 Assets.hs 涵蓋同一組 key" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      -- 不合命名文法(含大寫與空白):toFullManifest 必然 Left
      insertBadName (conn st)
      addReg (conn st) badUlid badDest (Just (shaOf "bad"))

      _ <- syncProject st noTools defOpts {soQuery = Just "alpha", soConfirm = True}

      mKeys <- manifestKeys proj
      aKeys <- assetsModuleKeys proj
      sort aKeys `shouldBe` sort mKeys
      -- 而且被排除的那一筆兩邊都不在
      mKeys `shouldBe` ["ui_gui_alpha_01"]

    it "被排除的列必須經事件回呼出聲,附邏輯名稱與原因" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      writeAsset proj "assets/sprites/ui_gui_alpha_01.png" (blobContent "alpha")
      addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA1" "assets/sprites/ui_gui_alpha_01.png" (Just (shaOf "alpha"))
      insertBadName (conn st)
      addReg (conn st) badUlid badDest (Just (shaOf "bad"))

      (_, events) <- withEvents $ \onEvent ->
        syncProject st noTools defOpts {soQuery = Just "alpha", soConfirm = True, soOnEvent = onEvent}

      events `shouldSatisfy` any (T.isInfixOf badName)
      events `shouldSatisfy` any (T.isInfixOf badDest)

    -- logical_name 為空的列沒有名字可指,定位資訊只剩 ULID 與落點。
    it "logical_name 為空的登記列被排除時同樣出聲,並附 ULID 與落點" $
      withFixture $ \st proj -> do
        registerProjectRow (conn st) proj
        execute
          (conn st)
          "UPDATE assets SET logical_name = '' WHERE ulid = ?"
          (Only ("01ARZ3NDEKTSV4RRFFQ69G5FA2" :: Text))
        addReg (conn st) "01ARZ3NDEKTSV4RRFFQ69G5FA2" "assets/sprites/ui_gui_beta_01.png" (Just (shaOf "beta"))

        (_, events) <- withEvents $ \onEvent ->
          syncProject st noTools defOpts {soQuery = Just "alpha", soConfirm = True, soOnEvent = onEvent}

        events `shouldSatisfy` any (T.isInfixOf "01ARZ3NDEKTSV4RRFFQ69G5FA2")
        events `shouldSatisfy` any (T.isInfixOf "assets/sprites/ui_gui_beta_01.png")
        -- 兩邊都不列入,不是只從 manifest 消失
        manifestKeys proj `shouldReturn` []
        assetsModuleKeys proj `shouldReturn` []

    it "SKILL.md / README.md / <NAME>.cabal 一個位元組都不重寫" $ withFixture $ \st proj -> do
      registerProjectRow (conn st) proj
      mapM_
        (\(p, c) -> writeAsset proj p c)
        [ ("SKILL.md", "手改過的 SKILL")
        , ("README.md", "手改過的 README")
        , ("game.cabal", "手改過的 cabal")
        ]
      snapBefore <- snapshotOnly proj ["SKILL.md", "README.md", "game.cabal"]
      _ <- syncProject st noTools defOpts {soConfirm = True, soAllowNonCommercial = True}
      snapshotOnly proj ["SKILL.md", "README.md", "game.cabal"] `shouldReturn` snapBefore

--------------------------------------------------------------------------------

conn :: Store -> Connection
conn = storeConn

-- | 7-Zip 明確不可用。素材庫裡的壓縮檔一律是 @.rar@,所以 'readEntry' 必然
-- 回 'SidecarNotFound' —— 讀取失敗的路徑因此與這台機器的環境無關。
noTools :: ArchiveTools
noTools = ArchiveTools Nothing

defOpts :: SyncOptions
defOpts =
  SyncOptions
    { soName = "game"
    , soLibraryRoot = "library-does-not-exist"
    , soPacks = []
    , soQuery = Nothing
    , soAllowNonCommercial = False
    , soConfirm = False
    , soOnEvent = \_ -> pure ()
    }

mustPlan :: IO (Either SyncError SyncPlan) -> IO SyncPlan
mustPlan act = act >>= either (\e -> fail ("預期成功,收到 " <> show e)) pure

classOf :: SyncPlan -> Text -> [SyncClass]
classOf plan n = [seClass e | e <- spEntries plan, seName e == n]

withEvents :: ((Text -> IO ()) -> IO a) -> IO (a, [Text])
withEvents f = do
  ref <- newIORef []
  a <- f (\t -> modifyIORef' ref (<> [t]))
  (,) a <$> readIORef ref

countOf :: Text -> Text -> Int
countOf needle hay = length (T.breakOnAll needle hay)

readUtf8 :: FilePath -> IO Text
readUtf8 p = decodeUtf8 <$> BS.readFile p

--------------------------------------------------------------------------------
-- 兩個產物的 key 集合(B007)

manifestKeys :: FilePath -> IO [Text]
manifestKeys proj = do
  raw <- BS.readFile (proj </> "assets" </> "manifest.json")
  case eitherDecodeStrict raw :: Either String Manifest of
    Left e -> fail ("manifest.json 解不開:" <> e)
    Right m -> pure (sort (map (logicalNameText . maKey) (mAssets m)))

-- | @Assets.hs@ 裡每個常數的查表 key,取自 @= AssetKey "…"@ 那一行。
--
-- 讀渲染出來的字串而不是重跑 'renderAssetsModule':這條測試要驗的正是
-- 「寫進磁碟的兩個產物涵蓋同一組 key」。
assetsModuleKeys :: FilePath -> IO [Text]
assetsModuleKeys proj = do
  src <- readUtf8 (proj </> "assets" </> "Assets.hs")
  pure (sort [k | l <- T.lines src, Just k <- [keyOf l]])
  where
    keyOf l = case T.breakOn "= AssetKey \"" l of
      (_, rest)
        | T.null rest -> Nothing
        | otherwise -> Just (T.takeWhile (/= '"') (T.drop (T.length "= AssetKey \"") rest))

--------------------------------------------------------------------------------
-- 固定資料

-- | 每筆素材的內容由邏輯名稱決定,雜湊因此可以在測試裡算出來 ——
-- 「磁碟上的檔案與 @copied_sha256@ 相符」不必靠寫死的十六進位字串。
blobContent :: Text -> ByteString
blobContent name = encodeUtf8 ("content-of-" <> name)

shaOf :: Text -> Text
shaOf = unSha256 . sha256Bytes . blobContent

-- | 改內容但**不改長度**,逼對帳真的去算雜湊。
tweak :: ByteString -> ByteString
tweak bs = case BS.unsnoc bs of
  Just (rest, w) -> BS.snoc rest (if w == 88 then 89 else 88)
  Nothing -> "X"

-- | (ulid, logical_name, archive_id, entry_path, 內容來源名稱)
fixtureAssets :: [(Text, Text, Int, Text, Text)]
fixtureAssets =
  [ ("01ARZ3NDEKTSV4RRFFQ69G5FA1", "ui_gui_alpha_01", 1, "a.png", "alpha")
  , ("01ARZ3NDEKTSV4RRFFQ69G5FA2", "ui_gui_beta_01", 1, "b.png", "beta")
  , ("01ARZ3NDEKTSV4RRFFQ69G5FA3", "ui_gui_gamma_01", 2, "g.png", "gamma")
  , ("01ARZ3NDEKTSV4RRFFQ69G5FA4", "ui_gui_delta_01", 3, "d.png", "delta")
  , ("01ARZ3NDEKTSV4RRFFQ69G5FA5", "ui_gui_travel-book_01", 1, "tb1.png", "tb1")
  , ("01ARZ3NDEKTSV4RRFFQ69G5FA6", "ui_gui_travel_book_01", 1, "tb2.png", "tb2")
  ]

withFixture :: (Store -> FilePath -> IO a) -> IO a
withFixture f = withSystemTempDirectory "assetdb-sync" $ \dir -> do
  let proj = dir </> "game"
  createDirectoryIfMissing True (proj </> "assets" </> "sprites")
  st <- openStoreInMemory
  _ <- initSchema st
  seed (storeConn st)
  r <- f st proj
  close (storeConn st)
  pure r

seed :: Connection -> IO ()
seed c = do
  execute_ c "INSERT INTO roots (id, path, label, kind) VALUES (1, '/tmp/lib', 'lib', 'packs')"
  -- 900 起跳:migration 001 已經種了八筆查證過的授權(id 1..8)。
  execute_
    c
    "INSERT INTO licenses (id, name, commercial, attribution_required) VALUES \
    \  (901, 'Commercial OK', 1, 0), (902, 'Non-Commercial', 0, 0)"
  execute_
    c
    "INSERT INTO packs (id, ulid, slug, name, root_id, rel_dir, license_id, created_at, updated_at) VALUES \
    \  (1, '01pcomm', 'comm', 'comm', 1, 'v/comm', 901, 't', 't'), \
    \  (2, '01pnc',   'noncomm', 'noncomm', 1, 'v/nc', 902, 't', 't'), \
    \  (3, '01pun',   'unlicensed', 'unlicensed', 1, 'v/un', NULL, 't', 't')"
  -- 一律 .rar:配上 ArchiveTools Nothing,讀取必然失敗。
  execute_
    c
    "INSERT INTO archives (id, ulid, pack_id, rel_path, format, sha256, bytes) VALUES \
    \  (1, '01ar1', 1, 'comm/pack.rar', 'rar', 'aa', 1), \
    \  (2, '01ar2', 2, 'nc/pack.rar',   'rar', 'bb', 1), \
    \  (3, '01ar3', 3, 'un/pack.rar',   'rar', 'cc', 1)"
  mapM_ (insertAsset c) fixtureAssets

insertAsset :: Connection -> (Text, Text, Int, Text, Text) -> IO ()
insertAsset c (ulid, name, archiveId, entry, content) = do
  let sha = shaOf content
      bytes = fromIntegral (BS.length (blobContent content)) :: Int
      packId = archiveId
  execute
    c
    "INSERT OR IGNORE INTO blobs (sha256, bytes, kind, first_seen) VALUES (?, ?, 'image', 't')"
    (sha, bytes)
  execute
    c
    "INSERT INTO assets \
    \  (ulid, logical_name, kind, archive_id, entry_path, original_name, ext, sha256, \
    \   pack_id, status, meta_json, created_at, updated_at) \
    \VALUES (?, ?, 'image', ?, ?, ?, '.png', ?, ?, 'active', NULL, 't', 't')"
    (ulid, name, archiveId, entry, entry, sha, packId)

-- | 一筆邏輯名稱不合命名文法的素材(含大寫與空白),'toFullManifest' 必然 Left。
--
-- 刻意不放進 'fixtureAssets':它會多出一筆候選,影響其他案例的筆數斷言。
badUlid, badName, badDest :: Text
badUlid = "01ARZ3NDEKTSV4RRFFQ69G5FB1"
badName = "UI Gui Bad 01"
badDest = "assets/sprites/UI Gui Bad 01.png"

insertBadName :: Connection -> IO ()
insertBadName c = insertAsset c (badUlid, badName, 1, "bad.png", "bad")

registerProjectRow :: Connection -> FilePath -> IO ()
registerProjectRow c path =
  execute
    c
    "INSERT INTO projects (id, ulid, name, path, template, created_at, updated_at) \
    \VALUES (1, '01proj', 'game', ?, 'haskell-raylib-2d', '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')"
    (Only (T.pack path))

addReg :: Connection -> Text -> Text -> Maybe Text -> IO ()
addReg c ulid dest sha =
  execute
    c
    "INSERT INTO project_assets (project_id, asset_id, dest_rel_path, copy_mode, copied_sha256, added_at) \
    \SELECT 1, a.id, ?, 'copy', ?, '2020-01-01T00:00:00Z' FROM assets a WHERE a.ulid = ?"
    (dest, sha, ulid)

-- | 模擬「來源壓縮檔更新了」:同一筆素材指向新的內容雜湊。
newSourceSha :: Connection -> Text -> Text -> IO ()
newSourceSha c ulid content = do
  execute
    c
    "INSERT OR IGNORE INTO blobs (sha256, bytes, kind, first_seen) VALUES (?, ?, 'image', 't')"
    (shaOf content, fromIntegral (BS.length (blobContent content)) :: Int)
  execute c "UPDATE assets SET sha256 = ? WHERE ulid = ?" (shaOf content, ulid)

--------------------------------------------------------------------------------
-- 觀測

writeAsset :: FilePath -> FilePath -> ByteString -> IO ()
writeAsset root rel content = BS.writeFile (root </> rel) content

-- | 整棵樹的相對路徑與內容。「一個位元組都沒變」靠它比較。
snapshot :: FilePath -> IO [(FilePath, ByteString)]
snapshot root = do
  present <- doesDirectoryExist root
  if not present then pure [] else go ""
  where
    go rel = do
      names <- listDirectory (root </> rel)
      fmap (sort . concat) . mapM (one rel) $ sort names
    one rel n = do
      let r = if null rel then n else rel </> n
      isDir <- doesDirectoryExist (root </> r)
      if isDir then go r else (\bs -> [(r, bs)]) <$> BS.readFile (root </> r)

snapshotOnly :: FilePath -> [FilePath] -> IO [(FilePath, ByteString)]
snapshotOnly root names = do
  full <- snapshot root
  pure [e | e@(p, _) <- full, any (`endsWithName` p) names]
  where
    endsWithName n p = n == p || ("/" <> n) `isSuffix` p || ("\\" <> n) `isSuffix` p
    isSuffix s p = length p >= length s && drop (length p - length s) p == s

registrationRows :: Connection -> IO [(Int, Text, Maybe Text, Text)]
registrationRows c =
  query_
    c
    "SELECT asset_id, dest_rel_path, copied_sha256, added_at FROM project_assets \
    \ORDER BY asset_id"

projectUpdatedAt :: Connection -> IO [Only Text]
projectUpdatedAt c = query_ c "SELECT updated_at FROM projects ORDER BY id"

-- | 同步不該碰到的資料庫狀態。
dbState :: Connection -> IO ([(Int, Text, Maybe Text, Text)], [Text])
dbState c = do
  rows <- registrationRows c
  ups <- projectUpdatedAt c
  pure (rows, map fromOnly ups)

-- | 只拒絕讀取檔案內容(@RD@),屬性照樣讀得到。
--
-- Windows 上沒有 @chmod@,而「讀不到的檔案」是這條測試唯一能製造的真實
-- 觸發條件。用 @R@ 會連屬性一起擋掉,那樣 'doesFileExist' 就先失敗了,
-- 測不到 'sha256File' 那一步。
denyReadData :: FilePath -> IO ()
denyReadData p = ignoring (callCommand ("icacls \"" <> p <> "\" /deny *S-1-1-0:(RD) >nul 2>&1"))

-- | 還原。**必須在暫存目錄被刪掉之前跑**。
allowReadData :: FilePath -> IO ()
allowReadData p = ignoring (callCommand ("icacls \"" <> p <> "\" /remove:d *S-1-1-0 >nul 2>&1"))

isUnreadable :: FilePath -> IO Bool
isUnreadable p = either (const True) (const False) <$> guardedTry (BS.readFile p)

-- | icacls 在不同環境上可能不存在或無效。真正的判準是 'isUnreadable',
-- 不是 icacls 的結束碼。
ignoring :: IO () -> IO ()
ignoring act = () <$ guardedTry act
