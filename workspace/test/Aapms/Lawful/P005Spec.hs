-- | lawful 測試:P-005-vault-lifecycle(qa 填入)。
--
-- 每條 law 一個 @describe "P-005#LAW-n"@ 的 property,每個 example 一個
-- @describe "P-005#EX-n"@。全部斷言都跑在四個效果的純解譯器上
-- ('Aapms.Workspace.Lifecycle.Internal.simulateLifecycle'),__一行 IO 都沒有__。
--
-- 產生器只用 types 層的建構入口('mkHub'、'Aapms.Core.Id.newId' \/
-- 'Aapms.Core.Id.parseId'、'VaultEntry' \/ 'ProjectEntry' \/ 'VaultMarker' \/
-- 'HubWorld' \/ 'VaultWorld' 的建構子)組值;中樞文字一律由 P-028 的 'mkHub' 加
-- 'Aapms.Workspace.Hub.renderHub' 產,本模組不自己拼 TOML。尺寸全部有上限
-- (中樞列 ≤ 4、專案列 ≤ 2、路徑與名稱取自固定池),每個項目另有 60 秒逾時。
--
-- __世界的合法性__(qa 自己決定,見回報):'VaultWorld' 沒有 smart constructor。
-- 本模組的 'worldOf' 強制 P-029 決定裡那條世界不變量在 'VaultWorld' 上的對應:
-- __路徑不是既存目錄 ⇒ 那個路徑的 marker 讀數是 @Left@,而且它沒有 @.aapms@、
-- 沒有 @index.db@__。產生器與 example 的世界一律滿足這一條。
--
-- __路徑的接法__(qa 自己決定,見回報):契約沒有寫「目錄 + 第一層的名字」要用
-- 哪個分隔字元,所以 EX-8 \/ EX-15 不比對整串路徑,改以
-- 'System.FilePath.takeDirectory' \/ 'System.FilePath.takeFileName' 拆開比對。
module Aapms.Lawful.P005Spec (spec) where

import Control.Exception (evaluate)
import Data.Either (isLeft, isRight)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.FilePath (takeDirectory, takeFileName)
import qualified System.Timeout as Timeout

import Test.Hspec
import Test.Hspec.Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Aapms.Core.Id
  ( Id
  , IdPrefix (PPrj, PVlt)
  , VaultId (..)
  , idPrefix
  , newId
  , parseId
  , renderId
  )
-- 'StoreError' 只取這條 pipeline 用得到的兩個建構子:@VaultAlreadyInitialized@ 與
-- @VaultIdCollision@ 在 'Aapms.Store.Types' 與 'Aapms.Workspace.Types' 兩邊同名。
import Aapms.Store.Types
  ( StoreError (VaultMarkerInvalid, VaultMarkerMissing)
  , VaultKind (..)
  , VaultMarker (..)
  )
import Aapms.Workspace.Hub
  ( parseHubText
  , removeProject
  , removeVault
  , renderHub
  , upsertVault
  )
import Aapms.Workspace.Lifecycle.Internal (checkVaultsOf, simulateLifecycle)
import Aapms.Workspace.Lifecycle.Plan
  ( allocateProjectId
  , applyLifecycle
  , checkInit
  , entryOf
  , legacyMarkers
  , lookupProject
  , syncEntry
  )
import Aapms.Workspace.Resolve (lookupSelector)
import Aapms.Workspace.Types
  ( AdoptNotice (..)
  , DeleteIndex (..)
  , Hub
  , HubLocation (..)
  , HubSource (..)
  , HubWorld (..)
  , InitMode (..)
  , LifecycleOp (..)
  , LifecycleOutcome (..)
  , LifecycleRun (..)
  , ProjectEntry (..)
  , PurgeReport (..)
  , PurgeScope (..)
  , ScopeIssue (..)
  , SetupReport (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , VaultWorld (..)
  , WorkspaceError (..)
  , hubLlm
  , hubProjects
  , hubTools
  , hubVaults
  , isRefNotRegistered
  , mkHub
  , vwDirExists
  , vwEntries
  , vwHasIndex
  , vwMarker
  , vwMarkerDir
  , vwWithout
  )

-- 進入點 ---------------------------------------------------------------------

spec :: Spec
spec = modifyMaxSuccess (const 100) $ around_ withItemTimeout $ do
  lawsSpec
  examplesSpec

-- | 整個模組的逾時上限:每個項目 60 秒。產生器的尺寸全部有界,正常情況遠低於此。
withItemTimeout :: IO () -> IO ()
withItemTimeout act = do
  r <- Timeout.timeout itemTimeoutMicros act
  case r of
    Just () -> pure ()
    Nothing ->
      expectationFailure
        ("P-005 測試項目超過 " <> show (itemTimeoutMicros `div` 1000000) <> " 秒未結束")

itemTimeoutMicros :: Int
itemTimeoutMicros = 60 * 1000 * 1000

-- | 一次請求在純世界裡跑到底。
runOp
  :: UTCTime
  -> HubWorld
  -> VaultWorld
  -> Hub
  -> LifecycleOp
  -> LifecycleRun (Either WorkspaceError LifecycleOutcome)
runOp t hw vw h op = simulateLifecycle t hw vw h (applyLifecycle h op)

--------------------------------------------------------------------------------
-- Laws
--------------------------------------------------------------------------------

lawsSpec :: Spec
lawsSpec = do
  describe "P-005#LAW-1" $
    it "identity:setup 冪等,第二次兩個 Bool 都是 False,中樞文字與目錄樹不變" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        let vw = scWorld s
            h = scHub s
            run1 = runOp t hw vw h SetupHub
            hw2 = hubWorldAfter run1
            run2 = runOp t hw2 (lcVaults run1) h SetupHub
        annotateShow (lcResult run1)
        assert (isRight (lcResult run1))
        fmap outcomeSetup (lcResult run2)
          === Right (Just (SetupReport (hlPath (hubLocationIn hw)) False False))
        lcHubText run2 === lcHubText run1
        lcVaults run2 === lcVaults run1

  describe "P-005#LAW-2" $
    it "invariant:setup 完全不碰既有中樞檔,一個位元組都不改也不解析" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorldWithText s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h SetupHub
        -- given:isJust (hubTextIn hw)(產生器直接建構,不過濾)。
        assert (isJustText (hubTextIn hw))
        lcHubText run === hubTextIn hw
        annotateShow (lcResult run)
        assert (isRight (lcResult run))

  describe "P-005#LAW-3" $
    it "relation:init 的前置檢查任一失敗就是 checkInit 的錯誤,且零副作用" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        (d, k, name, mode) <- forAll (genInitAnyArgs s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (InitVault d k name mode)
            chk = checkInit name mode d (vwMarkerDir vw d) (vwDirExists vw d) (vwEntries vw d)
        cover 20 "前置檢查不通過" (isLeft chk)
        case chk of
          Right _ -> success
          Left err -> do
            lcResult run === Left err
            lcHubText run === hubTextIn hw
            lcVaults run === vw

  describe "P-005#LAW-4" $
    it "relation:init 成功時那一列逐欄來自 marker,索引已建,中樞只多這一列" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        (d, k, name, mode) <- forAll (genInitOkArgs s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (InitVault d k name mode)
        cover 20 "init 成功" (isRight (lcResult run))
        case lcResult run of
          Left _ -> success
          Right o -> case (outcomeEntry o, outcomeHub o, vwMarker (lcVaults run) d) of
            (Just e, Just h2, Just (Right m)) -> do
              veId e === vmId m
              veKind e === k
              veName e === vmName m
              vePath e === d
              assert (vwHasIndex (lcVaults run) d)
              hubVaults h2 === hubVaults h <> [e]
              hubProjects h2 === hubProjects h
              hubLlm h2 === hubLlm h
              hubTools h2 === hubTools h
            _ -> success

  describe "P-005#LAW-5" $
    it "relation:id 決定性且可算,等於 newId PVlt(去空白後的名稱)t 0" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        (d, k, name, mode) <- forAll (genInitOkArgs s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (InitVault d k name mode)
            chk = checkInit name mode d (vwMarkerDir vw d) (vwDirExists vw d) (vwEntries vw d)
        cover 20 "init 成功" (isRight (lcResult run))
        case (lcResult run, chk) of
          (Right o, Right stripped) -> case outcomeEntry o of
            Just e -> veId e === VaultId (renderId (newId PVlt stripped t 0))
            Nothing -> success
          _ -> success

  describe "P-005#LAW-6" $
    it "relation:撞號回 VaultIdCollision 三個值,剛建的 .aapms 回滾,中樞不動" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        (d, k, name, mode) <- forAll (genInitOkArgs s)
        oldPath <- forAll (genOtherPath s d)
        oldName <- forAll genName
        oldKind <- forAll genKind
        let vw = scWorld s
            chk = checkInit name mode d (vwMarkerDir vw d) (vwDirExists vw d) (vwEntries vw d)
        stripped <- expectRight "checkInit(前提:前置檢查要通過)" chk
        let collId = VaultId (renderId (newId PVlt stripped t 0))
            old = VaultEntry collId oldName oldKind oldPath
            h = upsertVault old (scHub s)
            run = runOp t hw vw h (InitVault d k name mode)
        -- given:old 在中樞裡、它的 id 就是這次會建出來的 id、它的路徑不是 d。
        assert (old `elem` hubVaults h)
        veId old === collId
        assert (vePath old /= d)
        lcResult run === Left (VaultIdCollision (veId old) (vePath old) d)
        assert (not (vwMarkerDir (lcVaults run) d))
        lcHubText run === hubTextIn hw

  describe "P-005#LAW-7" $
    it "relation:AdoptExisting 不動既有內容,AdoptNotice 恰是第一層的舊 marker 目錄" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        d <- forAll (genExistingDir s)
        k <- forAll genKind
        name <- forAll genName
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (InitVault d k name AdoptExisting)
        cover 20 "adopt 成功" (isRight (lcResult run))
        case lcResult run of
          Left _ -> success
          Right o -> case outcomeNotice o of
            Nothing -> success
            Just n -> do
              anLegacyMarkers n === legacyMarkers d (vwEntries vw d)
              vwWithout [d] (lcVaults run) === vwWithout [d] vw
              vwEntries (lcVaults run) d === vwEntries vw d <> [".aapms"]

  describe "P-005#LAW-8" $
    it "relation:add 的身分一律來自 marker,以 id 為鍵 upsert,vault 目錄不動" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        d <- forAll (genAnyDir s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (AddVault d)
        cover 20 "那個路徑讀得到 marker" (readableAt vw d)
        case vwMarker vw d of
          Just (Right m) -> do
            fmap (fmap hubVaults . outcomeHub) (lcResult run)
              === Right (Just (hubVaults (upsertVault (entryOf m d) h)))
            fmap outcomeEntry (lcResult run) === Right (Just (entryOf m d))
            lcVaults run === vw
          _ -> success

  describe "P-005#LAW-20" $
    it "relation:add 讀不到 marker 是 MarkerUnreadable 原件,零副作用" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        d <- forAll (genUnreadableBiasedDir s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (AddVault d)
        -- REV-2:產生器把「讀不到 marker」那一支拉到實測約六成,門檻取 20% 的一半。
        cover 10 "那個路徑讀不到 marker" (unreadableAt vw d)
        case vwMarker vw d of
          Just (Left err) -> do
            lcResult run === Left (MarkerUnreadable d err)
            lcHubText run === hubTextIn hw
            lcVaults run === vw
          _ -> success

  describe "P-005#LAW-9" $
    it "relation:forget 的 selector 規則同 lookupSelector,成功時只少那一列" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        sel <- forAll (genVaultSel s)
        _di <- forAll genDeleteIndex
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (ForgetVault sel _di)
        cover 20 "selector 解得開" (isRight (lookupSelector h sel))
        annotateShow (lookupSelector h sel)
        case lookupSelector h sel of
          Left _ -> do
            fmap (const ()) (lcResult run) === fmap (const ()) (lookupSelector h sel)
            lcHubText run === hubTextIn hw
            lcVaults run === vw
          Right _ -> do
            fmap outcomeEntry (lcResult run) === fmap Just (lookupSelector h sel)
            fmap (fmap hubVaults . outcomeHub) (lcResult run)
              === fmap (Just . hubVaults . flip removeVault h . veId) (lookupSelector h sel)

  describe "P-005#LAW-10" $
    it "relation:DeleteIndex 只刪那個 vault 的 index.db,KeepIndex 連它也不動" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        sel <- forAll (genGoodVaultSel s)
        let vw = scWorld s
            h = scHub s
            runK = runOp t hw vw h (ForgetVault sel KeepIndex)
            runD = runOp t hw vw h (ForgetVault sel DeleteIndex)
        case lookupSelector h sel of
          Left _ -> success
          Right e -> do
            lcVaults runK === vw
            assert (not (vwHasIndex (lcVaults runD) (vePath e)))
            vwWithout [vePath e] (lcVaults runD) === vwWithout [vePath e] vw
            vwMarker (lcVaults runD) (vePath e) === vwMarker vw (vePath e)

  describe "P-005#LAW-11" $
    it "equiv:checkVaults 等於中樞順序逐列重讀 marker 的降級清單,不寫任何東西" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h CheckVaults
        annotateShow (lcResult run)
        case lcResult run of
          Left _ -> success
          Right o -> do
            outcomeIssues o === checkVaultsOf vw h
            assert (all (not . isRefNotRegistered) (outcomeIssues o))
            lcHubText run === hubTextIn hw
            lcVaults run === vw

  describe "P-005#LAW-12" $
    it "relation:syncHub 只以 marker 修 name / kind,沒有漂移就不寫檔,vault 目錄永不動" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        e <- forAll (genSyncableEntry s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h SyncHub
        case vwMarker vw (vePath e) of
          Just (Right m)
            | vmId m == veId e -> case lcResult run of
                Left _ -> success
                Right o -> case outcomeHub o of
                  Nothing -> success
                  Just h2 -> do
                    annotateShow (syncEntry e m)
                    assert (syncEntry e m `elem` hubVaults h2)
                    outcomeIssues o === checkVaultsOf vw h
                    lcVaults run === vw
                    assert ((h2 == h) `implies` (lcHubText run == hubTextIn hw))
          _ -> success

  describe "P-005#LAW-13" $
    it "relation:purge 只清中樞與(AllVaults 時)各 vault 的 index.db,再跑一次全 False" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        scope <- forAll genPurgeScope
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (Purge scope)
            -- 逐字照 law(REV-1):第二次從跑完之後的中樞世界與目錄樹起跑。
            run2 = runOp t (hubWorldAfter run) (lcVaults run) h (Purge scope)
            paths = map vePath (hubVaults h)
        assert (isNothing (lcHubText run))
        fmap outcomePurge (lcResult run2) === Right (Just (PurgeReport False 0 []))
        case lcResult run of
          Left _ -> success
          Right o -> case outcomePurge o of
            Nothing -> success
            Just rep -> do
              prHubRemoved rep === isJustText (hubTextIn hw)
              assert
                ( (scope == PurgeHubOnly)
                    `implies` (lcVaults run == vw && prVaultIndexesRemoved rep == [])
                )
              assert
                ( (scope == PurgeAllVaults)
                    `implies` ( vwWithout paths (lcVaults run) == vwWithout paths vw
                                  && all (not . vwHasIndex (lcVaults run)) paths
                              )
                )

  describe "P-005#LAW-14" $
    it "relation:專案登錄的三種失敗零副作用,成功只多一列專案" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        d <- forAll genProjectDir
        name <- forAll genMaybeBlankName
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (RegisterProject d name)
        cover 10 "登錄成功" (isRight (lcResult run))
        annotateShow (lcResult run)
        assert (null (T.words name) `implies` (lcResult run == Left (InvalidName name)))
        assert
          ( not (vwDirExists vw d)
              `implies` (isLeft (lcResult run) && lcHubText run == hubTextIn hw)
          )
        assert (elem d (map pePath (hubProjects h)) `implies` isLeft (lcResult run))
        case lcResult run of
          Left _ -> success
          Right o -> case (outcomeProject o, outcomeHub o) of
            (Just p, Just h2) -> do
              pePath p === d
              hubProjects h2 === hubProjects h <> [p]
              hubVaults h2 === hubVaults h
            _ -> success

  describe "P-005#LAW-15" $
    it "invariant:專案 id 前綴是 prj、不撞既有、同輸入同結果" $
      hedgehog $ do
        existing <- forAll genProjectEntries
        nm <- forAll genName
        t <- forAll genTime
        idPrefix (allocateProjectId existing nm t) === PPrj
        assert (allocateProjectId existing nm t `notElem` map peId existing)
        allocateProjectId existing nm t === allocateProjectId existing nm t

  describe "P-005#LAW-16" $
    it "relation:專案撤除的 selector 規則同 lookupProject,成功只少那一列,目錄不動" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        sel <- forAll (genProjectSel s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h (ForgetProject sel)
        case lookupProject h sel of
          Left _ -> do
            fmap (const ()) (lcResult run) === fmap (const ()) (lookupProject h sel)
            lcHubText run === hubTextIn hw
          Right _ -> do
            fmap outcomeProject (lcResult run) === fmap Just (lookupProject h sel)
            fmap (fmap hubProjects . outcomeHub) (lcResult run)
              === fmap (Just . hubProjects . flip removeProject h . peId) (lookupProject h sel)
        lcVaults run === vw

  describe "P-005#LAW-17" $
    it "invariant:任何 Left 都不動中樞檔" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        op <- forAll (genOp s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h op
        cover 20 "請求失敗" (isLeft (lcResult run))
        case lcResult run of
          Right _ -> success
          Left _ -> lcHubText run === hubTextIn hw

  describe "P-005#LAW-18" $
    it "relation:寫回的中樞讀得回來,三段逐欄相等" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genScenario
        hw <- forAll (genHubWorld s)
        op <- forAll (genOp s)
        let vw = scWorld s
            h = scHub s
            run = runOp t hw vw h op
        case lcResult run of
          Left _ -> success
          Right o -> case (outcomeHub o, lcHubText run) of
            (Just h2, Just txt) -> case parseHubText (hlPath (hubLocationIn hw)) txt of
              Left _ -> success
              Right h3 -> do
                annotate (T.unpack txt)
                hubVaults h3 === hubVaults h2
                hubProjects h3 === hubProjects h2
                hubTools h3 === hubTools h2
            _ -> success

  describe "P-005#LAW-19" $
    it "total:對任何世界與請求都有值" $
      hedgehog $ do
        t <- forAll genTime
        s <- forAll genWildScenario
        hw <- forAll (genHubWorld s)
        op <- forAll (genOp s)
        -- total:求值到正規形不拋例外(show 走遍整個結構)。
        n <- evalIO (evaluate (length (show (runOp t hw (scWorld s) (scHub s) op))))
        assert (n >= 0)

--------------------------------------------------------------------------------
-- Examples
--------------------------------------------------------------------------------

examplesSpec :: Spec
examplesSpec = do
  describe "P-005#EX-1" $ do
    let run1 = runOp fixedT emptyHubWorld setupWorld emptyHub SetupHub
        run2 = runOp fixedT (hubWorldAfter run1) (lcVaults run1) emptyHub SetupHub
    it "空的中樞目錄第一次 setup:兩個 Bool 都是 True" $
      fmap outcomeSetup (lcResult run1)
        `shouldBe` Right (Just (SetupReport hubDir True True))
    it "第二次 setup:兩個 Bool 都是 False,中樞文字與目錄樹不變" $ do
      fmap outcomeSetup (lcResult run2)
        `shouldBe` Right (Just (SetupReport hubDir False False))
      lcHubText run2 `shouldBe` lcHubText run1
      lcVaults run2 `shouldBe` lcVaults run1

  describe "P-005#EX-2" $ do
    let hw = brokenHubWorld
        run = runOp fixedT hw setupWorld emptyHub SetupHub
    it "解不開的 config.toml:setup 仍是 Right,不是 HubUnreadable" $
      case lcResult run of
        Right _ -> pure ()
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "spHubCreated 是 False,該檔逐位元組不變" $ do
      fmap (fmap spHubCreated . outcomeSetup) (lcResult run) `shouldBe` Right (Just False)
      lcHubText run `shouldBe` Just brokenHubText

  describe "P-005#EX-3" $ do
    let run = runOp fixedT exHubWorld exWorld exHub (InitVault goneDir AssetVault "   " FreshVault)
    it "全空白的名稱是 InvalidName,帶原始字串" $
      lcResult run `shouldBe` Left (InvalidName "   ")
    it "目標目錄仍不存在,中樞文字不變" $ do
      vwDirExists (lcVaults run) goneDir `shouldBe` False
      lcHubText run `shouldBe` hubTextIn exHubWorld

  describe "P-005#EX-4" $ do
    let runF = runOp fixedT exHubWorld exWorld exHub (InitVault busyDir AssetVault "x" FreshVault)
        runA = runOp fixedT exHubWorld exWorld exHub (InitVault busyDir AssetVault "x" AdoptExisting)
    it "已有 .aapms 時 Fresh 與 Adopt 都是 VaultAlreadyInitialized" $ do
      lcResult runF `shouldBe` Left (VaultAlreadyInitialized busyDir)
      lcResult runA `shouldBe` Left (VaultAlreadyInitialized busyDir)
    it ".aapms 不變、目錄樹一個位元組都不動" $ do
      vwMarkerDir (lcVaults runF) busyDir `shouldBe` True
      lcVaults runF `shouldBe` exWorld
      lcVaults runA `shouldBe` exWorld

  describe "P-005#EX-5" $ do
    let runNE = runOp fixedT exHubWorld exWorld exHub (InitVault fullDir AssetVault "x" FreshVault)
        runMissing =
          runOp fixedT exHubWorld exWorld exHub (InitVault goneDir AssetVault "x" AdoptExisting)
    it "Fresh 對非空目錄是 VaultDirNotEmpty,零副作用" $ do
      lcResult runNE `shouldBe` Left (VaultDirNotEmpty fullDir)
      lcVaults runNE `shouldBe` exWorld
      lcHubText runNE `shouldBe` hubTextIn exHubWorld
    it "Adopt 對不存在的目錄是 VaultDirMissing,零副作用" $ do
      lcResult runMissing `shouldBe` Left (VaultDirMissing goneDir)
      lcVaults runMissing `shouldBe` exWorld
      lcHubText runMissing `shouldBe` hubTextIn exHubWorld

  describe "P-005#EX-6" $ do
    it "marker 的 name 去空白、kind 照給的" $
      case vwMarker (lcVaults ex6Run) freshDir of
        Just (Right m) -> do
          vmName m `shouldBe` "Lore"
          vmKind m `shouldBe` StoryVault
        other -> expectationFailure ("預期讀得到 marker,實際:" <> show other)
    it "veId 等於 newId PVlt \"Lore\" t 0,索引已建" $
      case lcResult ex6Run of
        Right o -> case outcomeEntry o of
          Just e -> do
            veId e `shouldBe` VaultId (renderId (newId PVlt "Lore" fixedT 0))
            vwHasIndex (lcVaults ex6Run) freshDir `shouldBe` True
          Nothing -> expectationFailure "預期 outcomeEntry 是 Just"
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "hubVaults 多這一列,其餘三段不變" $
      case lcResult ex6Run of
        Right o -> case (outcomeHub o, outcomeEntry o) of
          (Just h2, Just e) -> do
            hubVaults h2 `shouldBe` hubVaults ex6Hub <> [e]
            hubProjects h2 `shouldBe` hubProjects ex6Hub
            hubLlm h2 `shouldBe` hubLlm ex6Hub
            hubTools h2 `shouldBe` hubTools ex6Hub
          _ -> expectationFailure "預期 outcomeHub 與 outcomeEntry 都是 Just"
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)

  describe "P-005#EX-7" $ do
    let collId = VaultId (renderId (newId PVlt "Lore" fixedT 0))
        old = VaultEntry collId "old" AssetVault occupiedOther
        h = mkHub [old] [] Nothing (ToolsConfig Nothing) ""
        hw = hubWorldOf h
        run = runOp fixedT hw exWorld h (InitVault freshDir StoryVault "  Lore  " FreshVault)
    it "同 t 同名撞到既有列:VaultIdCollision 三個值" $
      lcResult run `shouldBe` Left (VaultIdCollision collId occupiedOther freshDir)
    it "剛建的 .aapms 回滾,中樞文字不變" $ do
      vwMarkerDir (lcVaults run) freshDir `shouldBe` False
      lcHubText run `shouldBe` hubTextIn hw

  describe "P-005#EX-8" $ do
    let run =
          runOp
            fixedT
            exHubWorld
            exWorld
            exHub
            (InitVault legacyDir AssetVault "adopted" AdoptExisting)
    it "AdoptNotice 只列第一層的 .assetdb,子目錄裡的不算" $
      case lcResult run of
        Right o -> case outcomeNotice o of
          Just n -> do
            map takeFileName (anLegacyMarkers n) `shouldBe` [".assetdb"]
            map takeDirectory (anLegacyMarkers n) `shouldBe` [legacyDir]
          Nothing -> expectationFailure "預期 outcomeNotice 是 Just"
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "其餘檔案不變,只多 .aapms" $ do
      vwEntries (lcVaults run) legacyDir
        `shouldBe` ["library", "notes.md", ".assetdb", "sub", ".aapms"]
      vwWithout [legacyDir] (lcVaults run) `shouldBe` vwWithout [legacyDir] exWorld

  describe "P-005#EX-9" $ do
    let m = VaultMarker ex9Id AssetVault "real" []
        expected = VaultEntry ex9Id "real" AssetVault ex9New
        run1 = runOp fixedT ex9EmptyHubWorld ex9World emptyHub (AddVault ex9New)
    it "第一次 add:中樞多一列,身分逐欄來自 marker" $
      case lcResult run1 of
        Right o -> do
          outcomeEntry o `shouldBe` Just (entryOf m ex9New)
          fmap hubVaults (outcomeHub o) `shouldBe` Just [expected]
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "第二次 add 同一個路徑:仍是一列" $
      case lcResult run1 of
        Right o1 -> case outcomeHub o1 of
          Just h1 ->
            let run2 = runOp fixedT (hubWorldAfter run1) (lcVaults run1) h1 (AddVault ex9New)
            in case lcResult run2 of
                Right o2 -> fmap hubVaults (outcomeHub o2) `shouldBe` Just [expected]
                Left e -> expectationFailure ("預期 Right,實際:" <> show e)
          Nothing -> expectationFailure "預期 outcomeHub 是 Just"
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "中樞裡同 id 但在舊位置的那一列被換成新位置" $
      let hOld = mkHub [VaultEntry ex9Id "old" StoryVault ex9Old] [] Nothing (ToolsConfig Nothing) ""
          hwOld = hubWorldOf hOld
          run = runOp fixedT hwOld ex9World hOld (AddVault ex9New)
      in case lcResult run of
          Right o -> fmap hubVaults (outcomeHub o) `shouldBe` Just [expected]
          Left e -> expectationFailure ("預期 Right,實際:" <> show e)

  describe "P-005#EX-10" $ do
    let run = runOp fixedT exHubWorld exWorld exHub (AddVault goneDir)
    it "路徑不存在的 add 是 MarkerUnreadable,捧著 StoreError 原件" $
      lcResult run `shouldBe` Left (MarkerUnreadable goneDir (VaultMarkerMissing goneDir))
    it "中樞與目錄樹都不變" $ do
      lcHubText run `shouldBe` hubTextIn exHubWorld
      lcVaults run `shouldBe` exWorld

  describe "P-005#EX-11" $ do
    let runAmb = runOp fixedT dupHubWorld exWorld dupHub (ForgetVault "lore" KeepIndex)
        runMiss = runOp fixedT dupHubWorld exWorld dupHub (ForgetVault "nope" DeleteIndex)
    it "兩列同名是 VaultSelectorAmbiguous,逐列列出" $
      lcResult runAmb `shouldBe` Left (VaultSelectorAmbiguous "lore" [dupEntry1, dupEntry2])
    it "比不到任何列是 VaultSelectorNotFound" $
      lcResult runMiss `shouldBe` Left (VaultSelectorNotFound "nope")
    it "沒有任何檔被刪" $ do
      lcVaults runAmb `shouldBe` exWorld
      lcVaults runMiss `shouldBe` exWorld

  describe "P-005#EX-12" $ do
    let runK = runOp fixedT threeHubWorld threeWorld threeHub (ForgetVault "m1" KeepIndex)
        runD = runOp fixedT threeHubWorld threeWorld threeHub (ForgetVault "m1" DeleteIndex)
        runNoDb = runOp fixedT threeHubWorld threeWorldNoDb threeHub (ForgetVault "m1" DeleteIndex)
    it "KeepIndex:中樞剩兩列順序不變,index.db 還在" $ do
      fmap (fmap hubVaults . outcomeHub) (lcResult runK)
        `shouldBe` Right (Just [three0, three2])
      vwHasIndex (lcVaults runK) three1Path `shouldBe` True
      lcVaults runK `shouldBe` threeWorld
    it "DeleteIndex:index.db 不在,其餘目錄樹不動" $ do
      vwHasIndex (lcVaults runD) three1Path `shouldBe` False
      vwWithout [three1Path] (lcVaults runD) `shouldBe` vwWithout [three1Path] threeWorld
      vwMarker (lcVaults runD) three1Path `shouldBe` vwMarker threeWorld three1Path
    it "index.db 事先不在時 DeleteIndex 仍是 Right" $
      case lcResult runNoDb of
        Right _ -> pure ()
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)

  describe "P-005#EX-13" $
    it "正常 / 路徑不見 / id 漂移三列:issues 依中樞順序,不產生 RefVaultNotRegistered" $
      case lcResult checkRun of
        Right o -> do
          outcomeIssues o
            `shouldBe` [VaultPathMissing chkE2 chkP2, VaultIdDrift chkE3 chkDriftId]
          filter isRefNotRegistered (outcomeIssues o) `shouldBe` []
          lcHubText checkRun `shouldBe` hubTextIn chkHubWorld
          lcVaults checkRun `shouldBe` chkWorld
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)

  describe "P-005#EX-14" $ do
    it "漂移的那一列以 marker 修 name / kind,id 與 path 不變" $
      case lcResult syncRun of
        Right o -> case outcomeHub o of
          Just h2 -> hubVaults h2 `shouldBe` [VaultEntry syncId "real" AssetVault syncPath]
          Nothing -> expectationFailure "預期 outcomeHub 是 Just"
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "全一致時中樞文字不變、issues 空" $
      case lcResult syncCleanRun of
        Right o -> do
          outcomeIssues o `shouldBe` []
          lcHubText syncCleanRun `shouldBe` hubTextIn syncCleanHubWorld
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)

  describe "P-005#EX-15" $ do
    let runHubOnly = runOp fixedT purgeHubWorld purgeWorld purgeHub (Purge PurgeHubOnly)
        runAll = runOp fixedT purgeHubWorld purgeWorld purgeHub (Purge PurgeAllVaults)
        run2 = runOp fixedT (hubWorldAfter runAll) (lcVaults runAll) purgeHub (Purge PurgeAllVaults)
    it "HubOnly 的報告逐字是 PurgeReport True 2 []" $
      fmap outcomePurge (lcResult runHubOnly) `shouldBe` Right (Just (PurgeReport True 2 []))
    it "HubOnly:中樞檔沒了、vault 目錄樹一個位元組都不動" $ do
      lcHubText runHubOnly `shouldBe` Nothing
      fmap (fmap prHubRemoved . outcomePurge) (lcResult runHubOnly) `shouldBe` Right (Just True)
      fmap (fmap prVaultIndexesRemoved . outcomePurge) (lcResult runHubOnly)
        `shouldBe` Right (Just [])
      lcVaults runHubOnly `shouldBe` purgeWorld
    it "AllVaults:只多刪兩個 <vault 根>/.aapms/index.db,library 與 .md 不變" $ do
      case fmap (fmap prVaultIndexesRemoved . outcomePurge) (lcResult runAll) of
        Right (Just ps) -> do
          -- REV-2:路徑逐字是 @<vault 根>/.aapms/index.db@,拆成三層比對
          -- (分隔字元契約沒定,見模組頭)。
          map takeFileName ps `shouldBe` ["index.db", "index.db"]
          map (takeFileName . takeDirectory) ps `shouldBe` [".aapms", ".aapms"]
          map (takeDirectory . takeDirectory) ps `shouldBe` [purgeV1, purgeV2]
        other -> expectationFailure ("預期兩個 index.db,實際:" <> show other)
      map (vwHasIndex (lcVaults runAll)) [purgeV1, purgeV2] `shouldBe` [False, False]
      vwWithout [purgeV1, purgeV2] (lcVaults runAll)
        `shouldBe` vwWithout [purgeV1, purgeV2] purgeWorld
      map (vwEntries (lcVaults runAll)) [purgeV1, purgeV2]
        `shouldBe` map (vwEntries purgeWorld) [purgeV1, purgeV2]
    it "再跑一次是 PurgeReport False 0 []" $
      fmap outcomePurge (lcResult run2) `shouldBe` Right (Just (PurgeReport False 0 []))

  describe "P-005#EX-16" $ do
    let run1 = runOp fixedT projHubWorld projWorld projHub (RegisterProject projP "demo")
    it "第一次登錄成功,中樞多一列" $
      case lcResult run1 of
        Right o -> case (outcomeProject o, outcomeHub o) of
          (Just p, Just h2) -> do
            pePath p `shouldBe` projP
            peName p `shouldBe` "demo"
            hubProjects h2 `shouldBe` hubProjects projHub <> [p]
          _ -> expectationFailure "預期 outcomeProject 與 outcomeHub 都是 Just"
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "同一個路徑第二次登錄是 ProjectAlreadyRegistered" $
      case lcResult run1 of
        Right o -> case (outcomeProject o, outcomeHub o) of
          (Just p, Just h2) ->
            let run2 =
                  runOp
                    fixedT
                    (hubWorldAfter run1)
                    (lcVaults run1)
                    h2
                    (RegisterProject projP "demo2")
            in lcResult run2 `shouldBe` Left (ProjectAlreadyRegistered (peId p) projP)
          _ -> expectationFailure "預期 outcomeProject 與 outcomeHub 都是 Just"
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "路徑不是目錄是 ProjectPathMissing,帶名稱與路徑" $
      lcResult (runOp fixedT projHubWorld projWorld projHub (RegisterProject projQ "x"))
        `shouldBe` Left (ProjectPathMissing "x" projQ)
    it "全空白的名稱是 InvalidName" $
      lcResult (runOp fixedT projHubWorld projWorld projHub (RegisterProject projP "  "))
        `shouldBe` Left (InvalidName "  ")

  describe "P-005#EX-17" $
    it "prj- 加八位十六進位;既有列含它時再算一次不等於第一次" $ do
      let first = allocateProjectId [] "demo" fixedT
          existing = [ProjectEntry first "demo" projP]
          second = allocateProjectId existing "demo" fixedT
      idPrefix first `shouldBe` PPrj
      T.length (renderId first) `shouldBe` 12
      T.isPrefixOf "prj-" (renderId first) `shouldBe` True
      T.all isHexLower (T.drop 4 (renderId first)) `shouldBe` True
      (second == first) `shouldBe` False

  describe "P-005#EX-18" $ do
    it "解得開的 selector 少那一列,專案目錄不動" $
      let run = runOp fixedT projHubWorld projWorld projDupHub (ForgetProject "demo")
      in case lcResult run of
          Right o -> do
            outcomeProject o `shouldBe` Just projDemo
            fmap hubProjects (outcomeHub o) `shouldBe` Just [projDup1, projDup2]
            lcVaults run `shouldBe` projWorld
          Left e -> expectationFailure ("預期 Right,實際:" <> show e)
    it "比不到任何列是 ProjectSelectorNotFound" $
      lcResult (runOp fixedT projHubWorld projWorld projDupHub (ForgetProject "nope"))
        `shouldBe` Left (ProjectSelectorNotFound "nope")
    it "兩列同名是 ProjectSelectorAmbiguous,逐列列出" $
      lcResult (runOp fixedT projHubWorld projWorld projDupHub (ForgetProject "dup"))
        `shouldBe` Left (ProjectSelectorAmbiguous "dup" [projDup1, projDup2])

  describe "P-005#EX-19" $
    it "任一 Left 的請求:中樞文字與起始相同" $
      mapM_
        ( \op ->
            let run = runOp fixedT exHubWorld exWorld exHub op
            in case lcResult run of
                Left _ -> lcHubText run `shouldBe` hubTextIn exHubWorld
                Right o -> expectationFailure ("預期 Left,實際:" <> show o)
        )
        leftOps

  describe "P-005#EX-20" $
    it "EX-6 成功後的中樞文字 parseHubText,三段等於回傳的 Hub" $
      case (lcResult ex6Run, lcHubText ex6Run) of
        (Right o, Just txt) -> case outcomeHub o of
          Just h2 -> case parseHubText hubDir txt of
            Right h3 -> do
              hubVaults h3 `shouldBe` hubVaults h2
              hubProjects h3 `shouldBe` hubProjects h2
              hubTools h3 `shouldBe` hubTools h2
            Left e -> expectationFailure ("預期 Right,實際:" <> show e)
          Nothing -> expectationFailure "預期 outcomeHub 是 Just"
        other -> expectationFailure ("預期 Right 且有中樞文字,實際:" <> show other)

  describe "P-005#EX-21" $
    it "亂造的世界與請求:求值到底不拋例外、終止" $
      mapM_
        ( \(hw, vw, h, op) -> do
            n <- evaluate (length (show (runOp fixedT hw vw h op)))
            n `shouldSatisfy` (>= (0 :: Int))
        )
        chaosCases

--------------------------------------------------------------------------------
-- 世界的建構
--------------------------------------------------------------------------------

-- | 一個路徑在世界裡的樣子。'worldOf' 由這些描述組出 'VaultWorld',並強制
-- 「不是既存目錄 ⇒ marker 讀不到、沒有 @.aapms@、沒有 @index.db@」。
data DirSpec = DirSpec
  { dsPath :: FilePath
  , dsExists :: Bool
  , dsEntries :: [FilePath]
  , dsMarker :: Maybe (Either StoreError VaultMarker)
  , dsMarkerDir :: Bool
  , dsIndex :: Bool
  }
  deriving stock (Show, Eq)

-- | 一般目錄:沒有 marker、沒有 @.aapms@、沒有索引。
plainDir :: FilePath -> [FilePath] -> DirSpec
plainDir p es = DirSpec p True es Nothing False False

-- | 不存在的路徑。
missingDir :: FilePath -> DirSpec
missingDir p = DirSpec p False [] Nothing False False

-- | 已經是 vault 的目錄:有 @.aapms@、有 marker 讀數、有 @index.db@。
vaultDir :: FilePath -> Either StoreError VaultMarker -> DirSpec
vaultDir p m = DirSpec p True [".aapms", "library"] (Just m) True True

worldOf :: [DirSpec] -> VaultWorld
worldOf ds =
  VaultWorld
    { vwTree = M.fromList [(dsPath d, dsEntries d) | d <- ds, dsExists d]
    , vwMarkers = M.fromList [(dsPath d, markerRow d) | d <- ds, hasMarkerRow d]
    , vwMarkerDirs = S.fromList [dsPath d | d <- ds, dsExists d, dsMarkerDir d]
    , vwIndexDbs = S.fromList [dsPath d | d <- ds, dsExists d, dsIndex d]
    }
  where
    hasMarkerRow d = not (dsExists d) || dsMarker d /= Nothing
    markerRow d = case (dsExists d, dsMarker d) of
      (True, Just m) -> m
      _ -> Left (VaultMarkerMissing (dsPath d))

hubDir :: FilePath
hubDir = "C:/H"

hubLoc :: HubLocation
hubLoc = HubLocation hubDir FromEnv

-- | 中樞檔不存在、快取目錄也還沒建的世界(EX-1 的第一次 setup 兩個 Bool 都 True)。
emptyHubWorld :: HubWorld
emptyHubWorld = HubWorld Nothing hubLoc False []

-- | 中樞檔是這個 Hub 的渲染結果;快取目錄與縮圖不參與這些例子。
hubWorldOf :: Hub -> HubWorld
hubWorldOf h = HubWorld (Just (renderHub h)) hubLoc False []

-- | 中樞檔存在但解不開(EX-2 與產生器共用)。
brokenHubWorld :: HubWorld
brokenHubWorld = HubWorld (Just brokenHubText) hubLoc False []

-- | 產生器用的縮圖固定小池('thumbsIn' 取它的子序列)。
thumbPool :: [FilePath]
thumbPool =
  ["C:/H/cache/thumbs/t1.png", "C:/H/cache/thumbs/t2.png", "C:/H/cache/thumbs/t3.png"]

emptyHub :: Hub
emptyHub = mkHub [] [] Nothing (ToolsConfig Nothing) ""

brokenHubText :: Text
brokenHubText = "id = \"vlt-"

--------------------------------------------------------------------------------
-- 固定的路徑、id 與時間
--------------------------------------------------------------------------------

-- __路徑一律是絕對路徑__(REV-2):中樞的 @path@ 會被 'renderHub' 寫出去再由
-- 'parseHubText' 讀回來(LAW-18、EX-20),而 P-028-hub-config 的 'parseHubText'
-- 只收絕對 @path@;Windows 上 @C:\/...@ 也算絕對。世界裡的目錄樹用同一組路徑,
-- 才不會有一半絕對一半相對的世界。
freshDir, goneDir, busyDir, fullDir, legacyDir, occupiedOther :: FilePath
freshDir = "C:/T/fresh"
goneDir = "C:/T/gone"
busyDir = "C:/T/busy"
fullDir = "C:/T/full"
legacyDir = "C:/T/legacy"
occupiedOther = "C:/T/elsewhere"

-- | 世界裡那兩個根目錄(第一層的名字掛在它們底下)。
vaultRootDir, projRootDir :: FilePath
vaultRootDir = "C:/T"
projRootDir = "C:/P"

slotPaths :: [FilePath]
slotPaths = ["C:/T/v0", "C:/T/v1", "C:/T/v2", "C:/T/v3"]

idPool :: [VaultId]
idPool = map (VaultId . ("vlt-" <>)) ["aaaa1111", "bbbb2222", "cccc3333", "dddd4444"]

spareId :: VaultId
spareId = VaultId "vlt-ffff0000"

namePool :: [Text]
namePool = ["a", "b", "dup", "lore"]

projPathPool :: [FilePath]
projPathPool = ["C:/P/demo", "C:/P/other", "C:/P/dup1", "C:/P/dup2"]

projIdPool :: [Id]
projIdPool = map (mkPid . ("prj-" <>)) ["91c0aa12", "0000abcd", "7777feed"]

-- | 只用 types 層的 smart constructor 取得 'Id'(建構子不匯出)。
mkPid :: Text -> Id
mkPid t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("P-005 測試的專案 id 字面值不合法:" <> show e)

timePool :: [UTCTime]
timePool =
  [ UTCTime (fromGregorian 2026 9 6) (secondsToDiffTime 0)
  , UTCTime (fromGregorian 2026 1 2) (secondsToDiffTime 3600)
  , UTCTime (fromGregorian 2025 12 31) (secondsToDiffTime 86399)
  ]

fixedT :: UTCTime
fixedT = UTCTime (fromGregorian 2026 9 6) (secondsToDiffTime 0)

--------------------------------------------------------------------------------
-- Example 的固定值
--------------------------------------------------------------------------------

-- | EX-3 \/ EX-4 \/ EX-5 \/ EX-7 \/ EX-8 \/ EX-10 \/ EX-11 \/ EX-19 共用的世界。
exWorld :: VaultWorld
exWorld =
  worldOf
    [ plainDir vaultRootDir ["fresh", "busy", "full", "legacy", "elsewhere"]
    , plainDir freshDir []
    , missingDir goneDir
    , vaultDir busyDir (Right (VaultMarker spareId AssetVault "busy" []))
    , plainDir fullDir ["a.md"]
    , plainDir legacyDir ["library", "notes.md", ".assetdb", "sub"]
    , vaultDir occupiedOther (Right (VaultMarker (idPool !! 0) AssetVault "elsewhere" []))
    ]

exHub :: Hub
exHub =
  mkHub
    [VaultEntry (idPool !! 0) "elsewhere" AssetVault occupiedOther]
    []
    Nothing
    (ToolsConfig Nothing)
    ""

exHubWorld :: HubWorld
exHubWorld = hubWorldOf exHub

-- | EX-1 \/ EX-2:setup 只碰中樞。
setupWorld :: VaultWorld
setupWorld = worldOf [plainDir vaultRootDir []]

-- | EX-6 \/ EX-20:空目錄上建全新 vault。
--
-- 'ToolsConfig' 留空是為了讓這個快照__合法__:'Aapms.Workspace.Types.Hub' 的
-- 不變量是「'hubSourceText' 與四段結構化內容出自同一次載入」,而空的
-- 'hubSourceText' 依型別層的註解代表「全新中樞(尚無檔案)」——那樣的中樞不可能
-- 帶著使用者寫在 @[tools]@ 裡的 7-Zip 路徑。EX-20 的「三段相等」照原文比對,
-- 只是 @tools@ 這一段在這個例子裡兩邊都是空的(見回報的 GAP-2)。
ex6Hub :: Hub
ex6Hub =
  mkHub
    [VaultEntry (idPool !! 1) "other" AssetVault occupiedOther]
    [ProjectEntry (head projIdPool) "Circle" projP]
    Nothing
    (ToolsConfig Nothing)
    ""

ex6HubWorld :: HubWorld
ex6HubWorld = hubWorldOf ex6Hub

ex6Run :: LifecycleRun (Either WorkspaceError LifecycleOutcome)
ex6Run =
  runOp fixedT ex6HubWorld exWorld ex6Hub (InitVault freshDir StoryVault "  Lore  " FreshVault)

-- | EX-9:同一個 vault 的舊位置與新位置。
ex9Id :: VaultId
ex9Id = VaultId "vlt-7f3b2a91"

ex9Old, ex9New :: FilePath
ex9Old = "C:/T/old"
ex9New = "C:/T/new"

ex9World :: VaultWorld
ex9World =
  worldOf
    [ plainDir vaultRootDir ["new"]
    , missingDir ex9Old
    , vaultDir ex9New (Right (VaultMarker ex9Id AssetVault "real" []))
    ]

ex9EmptyHubWorld :: HubWorld
ex9EmptyHubWorld = hubWorldOf emptyHub

-- | EX-11:兩列同名 lore。
dupEntry1, dupEntry2 :: VaultEntry
dupEntry1 = VaultEntry (idPool !! 0) "lore" AssetVault occupiedOther
dupEntry2 = VaultEntry (idPool !! 1) "lore" StoryVault busyDir

dupHub :: Hub
dupHub = mkHub [dupEntry1, dupEntry2] [] Nothing (ToolsConfig Nothing) ""

dupHubWorld :: HubWorld
dupHubWorld = hubWorldOf dupHub

-- | EX-12:三列,forget 中間那一列。
three0Path, three1Path, three2Path :: FilePath
three0Path = "C:/T/w0"
three1Path = "C:/T/w1"
three2Path = "C:/T/w2"

three0, three1, three2 :: VaultEntry
three0 = VaultEntry (idPool !! 0) "m0" AssetVault three0Path
three1 = VaultEntry (idPool !! 1) "m1" AssetVault three1Path
three2 = VaultEntry (idPool !! 2) "m2" StoryVault three2Path

threeHub :: Hub
threeHub = mkHub [three0, three1, three2] [] Nothing (ToolsConfig Nothing) ""

threeHubWorld :: HubWorld
threeHubWorld = hubWorldOf threeHub

markerFor :: VaultEntry -> VaultMarker
markerFor e = VaultMarker (veId e) (veKind e) (veName e) []

threeWorld :: VaultWorld
threeWorld =
  worldOf
    ( plainDir vaultRootDir ["w0", "w1", "w2"]
        : [vaultDir (vePath e) (Right (markerFor e)) | e <- [three0, three1, three2]]
    )

-- | EX-12 的第三次:@T\/w1@ 的 @index.db@ 事先不在。
threeWorldNoDb :: VaultWorld
threeWorldNoDb =
  worldOf
    ( plainDir vaultRootDir ["w0", "w1", "w2"]
        : [ (vaultDir (vePath e) (Right (markerFor e))) {dsIndex = vePath e /= three1Path}
          | e <- [three0, three1, three2]
          ]
    )

-- | EX-13:正常、路徑不見、id 漂移。
chkP2 :: FilePath
chkP2 = "C:/T/c2"

chkP1, chkP3 :: FilePath
chkP1 = "C:/T/c1"
chkP3 = "C:/T/c3"

chkE1, chkE2, chkE3 :: VaultEntry
chkE1 = VaultEntry (idPool !! 0) "c1" AssetVault chkP1
chkE2 = VaultEntry (idPool !! 1) "c2" AssetVault chkP2
chkE3 = VaultEntry (idPool !! 2) "c3" StoryVault chkP3

chkDriftId :: VaultId
chkDriftId = VaultId "vlt-99998888"

chkHub :: Hub
chkHub = mkHub [chkE1, chkE2, chkE3] [] Nothing (ToolsConfig Nothing) ""

chkHubWorld :: HubWorld
chkHubWorld = hubWorldOf chkHub

chkWorld :: VaultWorld
chkWorld =
  worldOf
    [ plainDir vaultRootDir ["c1", "c3"]
    , -- c1 的 refs 指向一個中樞裡沒有的 id:checkVaults 不展開 refs
      vaultDir chkP1 (Right (VaultMarker (idPool !! 0) AssetVault "c1" [spareId]))
    , missingDir chkP2
    , vaultDir chkP3 (Right (VaultMarker chkDriftId StoryVault "c3" []))
    ]

checkRun :: LifecycleRun (Either WorkspaceError LifecycleOutcome)
checkRun = runOp fixedT chkHubWorld chkWorld chkHub CheckVaults

-- | EX-14:中樞的 name \/ kind 過時,marker 是真相。
syncId :: VaultId
syncId = idPool !! 0

syncPath :: FilePath
syncPath = "C:/T/s0"

syncStaleHub :: Hub
syncStaleHub =
  mkHub [VaultEntry syncId "stale" StoryVault syncPath] [] Nothing (ToolsConfig Nothing) ""

syncWorld :: VaultWorld
syncWorld =
  worldOf
    [ plainDir vaultRootDir ["s0"]
    , vaultDir syncPath (Right (VaultMarker syncId AssetVault "real" []))
    ]

syncRun :: LifecycleRun (Either WorkspaceError LifecycleOutcome)
syncRun = runOp fixedT (hubWorldOf syncStaleHub) syncWorld syncStaleHub SyncHub

syncCleanHub :: Hub
syncCleanHub =
  mkHub [VaultEntry syncId "real" AssetVault syncPath] [] Nothing (ToolsConfig Nothing) ""

syncCleanHubWorld :: HubWorld
syncCleanHubWorld = hubWorldOf syncCleanHub

syncCleanRun :: LifecycleRun (Either WorkspaceError LifecycleOutcome)
syncCleanRun = runOp fixedT syncCleanHubWorld syncWorld syncCleanHub SyncHub

-- | EX-15:中樞列兩個 vault。
purgeV1, purgeV2 :: FilePath
purgeV1 = "C:/T/p1"
purgeV2 = "C:/T/p2"

purgeHub :: Hub
purgeHub =
  mkHub
    [ VaultEntry (idPool !! 0) "p1" AssetVault purgeV1
    , VaultEntry (idPool !! 1) "p2" StoryVault purgeV2
    ]
    []
    Nothing
    (ToolsConfig Nothing)
    ""

-- | EX-15 的中樞:config.toml 加兩張縮圖(notes.txt 不是縮圖,purge 不碰)。
purgeThumbs :: [FilePath]
purgeThumbs = ["C:/H/cache/thumbs/p1.png", "C:/H/cache/thumbs/p2.png"]

purgeHubWorld :: HubWorld
purgeHubWorld = HubWorld (Just (renderHub purgeHub)) hubLoc True purgeThumbs

purgeWorld :: VaultWorld
purgeWorld =
  worldOf
    [ plainDir vaultRootDir ["p1", "p2"]
    , (vaultDir purgeV1 (Right (VaultMarker (idPool !! 0) AssetVault "p1" [])))
        {dsEntries = [".aapms", "library", "notes.md"]}
    , (vaultDir purgeV2 (Right (VaultMarker (idPool !! 1) StoryVault "p2" [])))
        {dsEntries = [".aapms", "library", "lore.md"]}
    ]

-- | EX-16 \/ EX-18:專案。
projP, projQ :: FilePath
projP = "C:/P/demo"
projQ = "C:/P/gone"

projWorld :: VaultWorld
projWorld =
  worldOf
    [ plainDir projRootDir ["demo", "other", "dup1", "dup2"]
    , plainDir projP []
    , plainDir "C:/P/other" []
    , plainDir "C:/P/dup1" []
    , plainDir "C:/P/dup2" []
    , missingDir projQ
    ]

projHub :: Hub
projHub = mkHub [] [] Nothing (ToolsConfig Nothing) ""

projHubWorld :: HubWorld
projHubWorld = hubWorldOf projHub

projDemo, projDup1, projDup2 :: ProjectEntry
projDemo = ProjectEntry (projIdPool !! 0) "demo" projP
projDup1 = ProjectEntry (projIdPool !! 1) "dup" "C:/P/dup1"
projDup2 = ProjectEntry (projIdPool !! 2) "dup" "C:/P/dup2"

projDupHub :: Hub
projDupHub = mkHub [] [projDemo, projDup1, projDup2] Nothing (ToolsConfig Nothing) ""

-- | EX-19:一定是 Left 的請求。
leftOps :: [LifecycleOp]
leftOps =
  [ InitVault goneDir AssetVault "   " FreshVault
  , InitVault busyDir AssetVault "x" FreshVault
  , InitVault fullDir AssetVault "x" FreshVault
  , InitVault goneDir StoryVault "x" AdoptExisting
  , AddVault goneDir
  , ForgetVault "nope" KeepIndex
  , ForgetVault "nope" DeleteIndex
  , RegisterProject goneDir "x"
  , RegisterProject projP "  "
  , ForgetProject "nope"
  ]

-- | EX-21:亂造的世界與請求。
chaosCases :: [(HubWorld, VaultWorld, Hub, LifecycleOp)]
chaosCases =
  [ (emptyHubWorld, worldOf [], emptyHub, SetupHub)
  , (emptyHubWorld, worldOf [], emptyHub, CheckVaults)
  , (brokenHubWorld, exWorld, exHub, SyncHub)
  , (exHubWorld, exWorld, exHub, InitVault "" AssetVault "" FreshVault)
  , (exHubWorld, worldOf [], dupHub, ForgetVault "" DeleteIndex)
  , (emptyHubWorld, exWorld, chkHub, Purge PurgeAllVaults)
  , (chkHubWorld, chkWorld, emptyHub, AddVault chkP2)
  , (projHubWorld, projWorld, projDupHub, RegisterProject "" "")
  , (projHubWorld, worldOf [], projDupHub, ForgetProject "dup")
  , (threeHubWorld, threeWorld, threeHub, InitVault legacyDir StoryVault "  " AdoptExisting)
  ]

--------------------------------------------------------------------------------
-- 產生器
--------------------------------------------------------------------------------

-- | 中樞裡一列 vault 的四種狀態。__SMissing 同時代表「路徑不是既存目錄」與
-- 「那個路徑的 marker 讀不到」__(見模組頭的世界合法性)。
data SlotState = SOk | SMissing | SBroken | SDrift
  deriving stock (Show, Eq)

data Slot = Slot
  { slotIndex :: Int
  , slotId :: VaultId
  , slotName :: Text
  , slotKind :: VaultKind
  , slotPath :: FilePath
  , slotState :: SlotState
  }
  deriving stock (Show, Eq)

data Scenario = Scenario
  { scSlots :: [Slot]
  , scWorld :: VaultWorld
  , scHub :: Hub
  }
  deriving stock (Show, Eq)

entryOfSlot :: Slot -> VaultEntry
entryOfSlot s = VaultEntry (slotId s) (slotName s) (slotKind s) (slotPath s)

driftIdOf :: Slot -> VaultId
driftIdOf s = VaultId ("vlt-dd00000" <> T.pack (show (slotIndex s)))

slotDir :: Slot -> DirSpec
slotDir s = case slotState s of
  SOk -> vaultDir (slotPath s) (Right (VaultMarker (slotId s) (slotKind s) (slotName s) []))
  SMissing -> missingDir (slotPath s)
  SBroken -> vaultDir (slotPath s) (Left (VaultMarkerInvalid (slotPath s) "marker 欄位不合法"))
  SDrift -> vaultDir (slotPath s) (Right (VaultMarker (driftIdOf s) (slotKind s) (slotName s) []))

-- | 每個情境都有的固定目錄:空目錄、不存在的、已被佔用的、非空的、有舊 marker 的,
-- 以及專案用的那幾個。
fixedDirs :: [DirSpec]
fixedDirs =
  [ plainDir vaultRootDir ["fresh", "busy", "full", "legacy", "elsewhere"]
  , plainDir freshDir []
  , missingDir goneDir
  , vaultDir busyDir (Right (VaultMarker spareId AssetVault "busy" []))
  , plainDir fullDir ["a.md"]
  , plainDir legacyDir ["library", "notes.md", ".assetdb", "sub"]
  , vaultDir occupiedOther (Right (VaultMarker spareId AssetVault "elsewhere" []))
  , plainDir projRootDir ["demo", "other", "dup1", "dup2"]
  , plainDir projP []
  , plainDir "C:/P/other" []
  , plainDir "C:/P/dup1" []
  , plainDir "C:/P/dup2" []
  , missingDir projQ
  ]

scenarioOf :: [Slot] -> [ProjectEntry] -> Scenario
scenarioOf slots ps = Scenario slots world hub
  where
    world = worldOf (map slotDir slots <> fixedDirs)
    hub = mkHub (map entryOfSlot slots) ps Nothing (ToolsConfig Nothing) ""

genScenario :: Gen Scenario
genScenario = do
  n <- Gen.int (Range.linear 1 4)
  slots <- traverse genSlot (zip3 [0 ..] (take n idPool) (take n slotPaths))
  ps <- genProjectEntries
  pure (scenarioOf slots ps)

genSlot :: (Int, VaultId, FilePath) -> Gen Slot
genSlot (i, vid, p) = do
  nm <- Gen.element namePool
  kd <- genKind
  st <- Gen.frequency [(6, pure SOk), (1, pure SMissing), (1, pure SBroken), (1, pure SDrift)]
  pure (Slot i vid nm kd p st)

-- | LAW-19 的定義域:另含空中樞與整批不可達的世界。
genWildScenario :: Gen Scenario
genWildScenario =
  Gen.frequency
    [ (4, genScenario)
    , (1, pure (scenarioOf [] []))
    , (1, genAllMissingScenario)
    ]

genAllMissingScenario :: Gen Scenario
genAllMissingScenario = do
  n <- Gen.int (Range.linear 1 4)
  slots <- traverse genMissingSlot (zip3 [0 ..] (take n idPool) (take n slotPaths))
  pure (scenarioOf slots [])

genMissingSlot :: (Int, VaultId, FilePath) -> Gen Slot
genMissingSlot (i, vid, p) = do
  nm <- Gen.element namePool
  kd <- genKind
  pure (Slot i vid nm kd p SMissing)

genProjectEntries :: Gen [ProjectEntry]
genProjectEntries = do
  n <- Gen.int (Range.linear 0 2)
  traverse genProjectEntryFor (zip (take n projIdPool) (take n projPathPool))

genProjectEntryFor :: (Id, FilePath) -> Gen ProjectEntry
genProjectEntryFor (pid, p) = do
  nm <- Gen.element namePool
  pure (ProjectEntry pid nm p)

genKind :: Gen VaultKind
genKind = Gen.element [AssetVault, StoryVault]

genMode :: Gen InitMode
genMode = Gen.element [FreshVault, AdoptExisting]

genDeleteIndex :: Gen DeleteIndex
genDeleteIndex = Gen.element [KeepIndex, DeleteIndex]

genPurgeScope :: Gen PurgeScope
genPurgeScope = Gen.element [PurgeHubOnly, PurgeAllVaults]

genTime :: Gen UTCTime
genTime = Gen.element timePool

-- | 去前後空白後非空的名稱。
genName :: Gen Text
genName = Gen.element ["Lore", "  Lore  ", "real", "a", "中文名稱"]

-- | 另含全空白的名稱(InvalidName 的分支)。
genMaybeBlankName :: Gen Text
genMaybeBlankName = Gen.frequency [(3, genName), (1, Gen.element ["", "  ", "\t"])]

-- | 中樞世界:沒有檔、有一份與這個中樞一致的檔、有一份解不開的檔;快取目錄與
-- 縮圖另外抽。
genHubWorld :: Scenario -> Gen HubWorld
genHubWorld s = do
  txt <-
    Gen.frequency
      [ (1, pure Nothing)
      , (4, pure (Just (renderHub (scHub s))))
      , (1, pure (Just brokenHubText))
      ]
  genHubWorldWith txt

-- | LAW-2 的定義域:中樞檔一定存在。
genHubWorldWithText :: Scenario -> Gen HubWorld
genHubWorldWithText s = do
  txt <-
    Gen.frequency
      [ (3, pure (renderHub (scHub s)))
      , (1, pure brokenHubText)
      ]
  genHubWorldWith (Just txt)

-- | 中樞檔以外的兩欄:快取目錄在不在、快取裡有哪幾張縮圖。
--
-- __世界的合法性__(qa 自己決定,見回報):縮圖住在快取目錄底下,所以快取目錄不
-- 存在的世界一律零張縮圖。
genHubWorldWith :: Maybe Text -> Gen HubWorld
genHubWorldWith txt = do
  cache <- Gen.bool
  thumbs <- if cache then Gen.subsequence thumbPool else pure []
  pure (HubWorld txt hubLoc cache thumbs)

-- | 世界裡任何一個路徑(含不存在的)。
genAnyDir :: Scenario -> Gen FilePath
genAnyDir s =
  Gen.element (map slotPath (scSlots s) <> [freshDir, goneDir, busyDir, fullDir, legacyDir])

-- | LAW-20 的定義域:同 'genAnyDir',但一半的機率直接抽「marker 讀不到」的那些
-- 路徑(不存在的 @goneDir@ 與 SMissing \/ SBroken 的 slot),把該分支的實測覆蓋率
-- 從約兩成拉到約六成,'cover' 的門檻才不會貼著實測值隨種子翻紅(REV-2)。
genUnreadableBiasedDir :: Scenario -> Gen FilePath
genUnreadableBiasedDir s =
  Gen.frequency
    [ (1, genAnyDir s)
    , (1, Gen.element (goneDir : unreadableSlotPaths s))
    ]

-- | 世界裡 marker 讀數是 @Left@ 的那些 slot 路徑。
unreadableSlotPaths :: Scenario -> [FilePath]
unreadableSlotPaths s =
  [slotPath sl | sl <- scSlots s, slotState sl == SMissing || slotState sl == SBroken]

-- | 一定是既存目錄的路徑。
genExistingDir :: Scenario -> Gen FilePath
genExistingDir s = Gen.element ([freshDir, busyDir, fullDir, legacyDir] <> okSlotPaths s)

okSlotPaths :: Scenario -> [FilePath]
okSlotPaths s = [slotPath sl | sl <- scSlots s, slotState sl /= SMissing]

-- | LAW-3 的定義域:任何 init 參數組合。
genInitAnyArgs :: Scenario -> Gen (FilePath, VaultKind, Text, InitMode)
genInitAnyArgs s = (,,,) <$> genAnyDir s <*> genKind <*> genMaybeBlankName <*> genMode

-- | LAW-4 \/ LAW-5 \/ LAW-6 的定義域:前置檢查會通過的組合(空目錄配 Fresh、
-- 既存目錄配 Adopt),名稱去前後空白後非空。
genInitOkArgs :: Scenario -> Gen (FilePath, VaultKind, Text, InitMode)
genInitOkArgs _s = do
  (d, mode) <-
    Gen.element
      [ (freshDir, FreshVault)
      , (freshDir, AdoptExisting)
      , (legacyDir, AdoptExisting)
      , (fullDir, AdoptExisting)
      ]
  k <- genKind
  nm <- genName
  pure (d, k, nm, mode)

-- | LAW-6 的既有列放在別的路徑上。
genOtherPath :: Scenario -> FilePath -> Gen FilePath
genOtherPath s d =
  Gen.element (filter (/= d) (occupiedOther : busyDir : map slotPath (scSlots s)))

-- | 中樞裡的 selector(id 或 name)加上比不到的。
genVaultSel :: Scenario -> Gen Text
genVaultSel s =
  Gen.element
    (map (idText . slotId) (scSlots s) <> map slotName (scSlots s) <> ["nope", ""])

-- | LAW-10 的定義域:一定解得開的 selector(逐列的 id 唯一)。
genGoodVaultSel :: Scenario -> Gen Text
genGoodVaultSel s = Gen.element (map (idText . slotId) (scSlots s))

-- | LAW-12 的定義域:中樞裡「marker 讀得到而且 id 相符」的那些列。
genSyncableEntry :: Scenario -> Gen VaultEntry
genSyncableEntry s = case [entryOfSlot sl | sl <- scSlots s, slotState sl == SOk] of
  [] -> pure (entryOfSlot (head (scSlots s)))
  es -> Gen.element es

genProjectSel :: Scenario -> Gen Text
genProjectSel s =
  Gen.element
    ( map (renderId . peId) (hubProjects (scHub s))
        <> map peName (hubProjects (scHub s))
        <> ["nope", ""]
    )

genProjectDir :: Gen FilePath
genProjectDir = Gen.element (projQ : projPathPool)

genOp :: Scenario -> Gen LifecycleOp
genOp s =
  Gen.choice
    [ pure SetupHub
    , InitVault <$> genAnyDir s <*> genKind <*> genMaybeBlankName <*> genMode
    , AddVault <$> genAnyDir s
    , ForgetVault <$> genVaultSel s <*> genDeleteIndex
    , pure CheckVaults
    , pure SyncHub
    , Purge <$> genPurgeScope
    , RegisterProject <$> genProjectDir <*> genMaybeBlankName
    , ForgetProject <$> genProjectSel s
    ]

--------------------------------------------------------------------------------
-- 斷言輔助
--------------------------------------------------------------------------------

implies :: Bool -> Bool -> Bool
implies a b = not a || b

idText :: VaultId -> Text
idText (VaultId t) = t

isJustText :: Maybe Text -> Bool
isJustText = maybe False (const True)

isHexLower :: Char -> Bool
isHexLower c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

readableAt :: VaultWorld -> FilePath -> Bool
readableAt vw d = case vwMarker vw d of
  Just (Right _) -> True
  _ -> False

unreadableAt :: VaultWorld -> FilePath -> Bool
unreadableAt vw d = case vwMarker vw d of
  Just (Left _) -> True
  _ -> False

expectRight :: Show e => String -> Either e a -> PropertyT IO a
expectRight what r = case r of
  Right a -> pure a
  Left e -> do
    annotate ("預期 Right:" <> what)
    annotateShow e
    failure
