-- | F003:'Aapms.Workspace.Scope' 的三個裁決函式(resolveRead / resolveWrite /
-- resolvePipeline)、@refs@ 遞移展開與擋環、保序去重,以及依賴方向的 import 清單檢查
-- (LAW-25,__預期綠__——見 spec「紅綠預期」)。
--
-- 素材是 spec「數據」節「測試素材:一組固定的 vault 佈局」,由
-- 'Aapms.Workspace.Fixtures.withScopeVaults' 建出:A→B→C→A 三節點環、自環(另建)、
-- 菱形(另建)、未註冊的 E、壞 marker 的 M、路徑不存在的 P、id 漂移的 Z。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F003-scope-resolution.md@,
-- 預期欄依 spec「紅綠預期」:LAW-25 (a)–(f) 六條綠,其餘全紅——三個函式的本體全是
-- @undefined@):
--
-- @
-- STEP-1 walkAll(經 resolveRead)
-- LAW-1,LAW-6  / EX-1,EX-2,EX-14  -> test_resolve_read_all_registered_in_hub_order [紅]、test_resolve_read_independent_of_cwd [紅]、test_scope_dedupes_by_vmid_keeping_first [紅]
--
-- STEP-2 expandRefs(經 resolveRead 的 Just 分支)
-- LAW-20,LAW-21,LAW-22 / EX-8,EX-12,EX-34,EX-35,EX-36 -> test_refs_expansion_is_transitive_and_cycle_safe [紅]、test_refs_self_loop_terminates [紅]、test_refs_diamond_bfs_order [紅]、test_refs_unregistered_target_degrades [紅]、test_unreachable_node_refs_not_expanded [紅]、test_id_drift_node_refs_not_expanded [紅]
--
-- STEP-3 resolveRead
-- LAW-2,LAW-3,LAW-5,LAW-7,LAW-8,LAW-9 / EX-3-EX-5,EX-6,EX-7,EX-9-EX-11,EX-13,EX-15
--   -> test_resolve_read_selector_is_closure [紅]、test_resolve_read_selector_by_id_equals_by_name [紅]、
--      test_resolve_read_selector_not_found_passthrough [紅]、test_resolve_read_selector_ambiguous_passthrough [紅]、
--      test_resolve_read_seed_unreachable_still_right [紅]、test_resolve_read_no_selector_never_expands_refs [紅]、
--      test_resolve_read_marker_is_truth [紅]
--
-- STEP-4 resolveWrite(寫入目標)
-- LAW-12,LAW-13(a),LAW-13(b),LAW-14,LAW-15 / EX-17-EX-24
--   -> test_resolve_write_no_target_carries_canonical_start [紅]、test_resolve_write_target_marker_unreadable_is_hard_error [紅]、
--      test_resolve_write_id_drift_is_hard_error [紅]、test_resolve_write_unregistered_target_allowed [紅]、
--      test_resolve_write_selector_ignores_start [紅]
--
-- STEP-5 resolveWrite(wsRead / wsIssues)
-- LAW-10,LAW-11,LAW-13(c),LAW-23 / EX-16,EX-23,EX-25
--   -> test_resolve_write_target_never_from_refs [紅]、test_resolve_write_read_starts_with_target [紅]、
--      test_resolve_write_issues_never_describe_target [紅]
--
-- STEP-6 resolvePipeline
-- LAW-16,LAW-17,LAW-18,LAW-19 / EX-26-EX-31
--   -> test_resolve_pipeline_filters_by_kind [紅]、test_resolve_pipeline_kind_mismatch_is_silent_without_selector [紅]、
--      test_resolve_pipeline_selector_is_single_run [紅]、test_resolve_pipeline_kind_mismatch_carries_three_values [紅]、
--      test_resolve_pipeline_unreachable_is_right [紅]、test_resolve_pipeline_selector_not_found_passthrough(EX-31) [紅]
--
-- (全部) LAW-4,LAW-24 / EX-32,EX-33 -> test_scope_touches_no_files [紅]、test_scope_has_no_attach_limit [紅]
--
-- LAW-25(預期綠) 依賴方向與職責界線(以 import 行驗證)
-- (a) 只准 Types/Hub/Discovery                        -> test_scope_no_downstream_or_location_imports [綠]
-- (b) Aapms.Store.Marker 的 import(若有)逐字只拿三個欄位 -> test_scope_marker_import_is_three_fields_only [綠]
-- (c) Aapms.Store.Schema 的 import 逐字只拿 VaultKind  -> test_scope_schema_import_is_type_only [綠]
-- (d) 不得 import Store 門面/Atomic/Index/MultiVault/Query/Write/Create/Error 等 -> test_scope_never_imports_store_internals [綠]
-- (e) 不得 import System.Process                        -> test_scope_no_process_import [綠]
-- (f) System.Directory 的 import(若有)逐字只拿 canonicalizePath -> test_scope_directory_import_is_canonicalize_only [綠]
-- @
module Aapms.Workspace.ScopeSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.List as List
import Data.List (dropWhileEnd, isPrefixOf)
import qualified Data.Set as Set
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (canonicalizePath, createDirectoryIfMissing, withCurrentDirectory)
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Marker (VaultMarker (..), readMarker)
import Aapms.Store.Schema (VaultKind (..), renderVaultKind)
import Aapms.Workspace.Fixtures
import Aapms.Workspace.Scope (resolvePipeline, resolveRead, resolveWrite)
import Aapms.Workspace.Types

--------------------------------------------------------------------------------
-- 本檔專用 helper(不匯出)

-- | 一個骨架檔案裡,去除前導空白、去除行尾 @\\r@(CRLF checkout 的產物)之後、以
-- @import@ 起頭的行。判準只看 import 行,不做全檔字串搜尋(LAW-25 明文;做法對照
-- "Aapms.Workspace.DiscoverySpec.importLinesOf" / F002 LAW-18)。
importLinesOf :: FilePath -> IO [String]
importLinesOf rel = do
  src <- readWorkspaceSource rel
  let stripLine = dropWhile (== ' ') . dropWhileEnd (== '\r')
  pure (filter ("import" `isPrefixOf`) (map stripLine (lines (T.unpack src))))

-- | 從一行 import 取出被 import 的模組全名(不含子句清單)。
moduleNameOf :: String -> String
moduleNameOf l = takeWhile (\c -> c /= ' ' && c /= '(') (drop (length ("import " :: String)) l)

scopeImportLines :: IO [String]
scopeImportLines = importLinesOf "Aapms/Workspace/Scope.hs"

-- | 取一個 'VaultRef' 的權威 id(恆來自 marker,不來自 'vrEntry')。
vmidOf :: VaultRef -> VaultId
vmidOf = vmId . vrMarker

vmidsOf :: [VaultRef] -> [VaultId]
vmidsOf = map vmidOf

isRefVaultNotRegistered :: ScopeIssue -> Bool
isRefVaultNotRegistered (RefVaultNotRegistered _ _) = True
isRefVaultNotRegistered _ = False

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F003 Aapms.Workspace.Scope" $ do
  --------------------------------------------------------------------------
  describe "STEP-1/LAW-1,LAW-6/EX-1,EX-2,EX-14: resolveRead 無 selector = 全部已註冊" $ do
    it "test_resolve_read_all_registered_in_hub_order (EX-1, LAW-3, LAW-6): rsVaults 依中樞順序,rsIssues 逐一列出不可達的三個" $
      withScopeVaults $ \sv -> do
        canonM <- canonicalizePath (svPathM sv)
        canonGone <- canonicalizePath (svPathGone sv)
        expectedM <- readMarker canonM
        errM <- either pure (const (expectationFailure "M 的 marker 不應該讀得到" >> fail "unreachable")) expectedM
        result <- resolveRead (svHub sv) Nothing
        case result of
          Right rs -> do
            vmidsOf (rsVaults rs)
              `shouldBe` map VaultId ["vlt-aaaa1111", "vlt-bbbb2222", "vlt-cccc3333", "vlt-dddd4444"]
            rsIssues rs
              `shouldBe` [ VaultMarkerBroken (svEntryM sv) errM
                         , VaultPathMissing (svEntryP sv) canonGone
                         , VaultIdDrift (svEntryZ sv) (VaultId "vlt-99998888")
                         ]
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_resolve_read_independent_of_cwd (EX-2, LAW-6): 在 vault 內外各跑一次,結果逐欄相同" $
      withScopeVaults $ \sv ->
        withTempHubDir $ \outside -> do
          base <- resolveRead (svHub sv) Nothing
          inA <- withCurrentDirectory (svPathA sv) $ resolveRead (svHub sv) Nothing
          outOfAll <- withCurrentDirectory outside $ resolveRead (svHub sv) Nothing
          inA `shouldBe` base
          outOfAll `shouldBe` base

    it "test_scope_dedupes_by_vmid_keeping_first (EX-14, LAW-1): 重複 id 只出現一次,位置是第一次出現的位置" $
      hedgehog $ do
        extraCopies <- forAll (Gen.int (Range.linear 1 3))
        result <- liftIO $ withScopeVaults $ \sv -> do
          let base = [svEntryA sv, svEntryB sv, svEntryC sv, svEntryD sv]
              withDups = base ++ replicate extraCopies (svEntryD sv)
              hub = mkHub withDups [] Nothing (ToolsConfig Nothing) ""
          resolveRead hub Nothing
        case result of
          Right rs -> do
            let ids = vmidsOf (rsVaults rs)
            length (filter (== VaultId "vlt-dddd4444") ids) === 1
            List.elemIndex (VaultId "vlt-dddd4444") ids === Just 3
          Left err -> annotate (show err) >> failure

  --------------------------------------------------------------------------
  describe "STEP-2/LAW-20,LAW-21,LAW-22/EX-8,EX-12,EX-34,EX-35,EX-36: refs 遞移展開(walkAll/expandRefs)" $ do
    it "test_refs_expansion_is_transitive_and_cycle_safe (LAW-20, property): 對任意小型 refs 圖,展開結果的 id 集合等於圖上可達集合,且不重複" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 2 5))
        let idxs = [0 .. n - 1]
        edges <- forAll (mapM (\i -> (,) i <$> Gen.subsequence idxs) idxs)
        let idOfIdx :: Int -> T.Text
            idOfIdx i = "vlt-" <> T.justifyRight 8 '0' (T.pack (show i))
            pathOfIdx root i = root </> ("v" <> show i)
            bfsReachable :: Set.Set Int -> [Int] -> Set.Set Int
            bfsReachable visited [] = visited
            bfsReachable visited (x : xs) =
              let outs = maybe [] id (lookup x edges)
                  new = filter (`Set.notMember` visited) outs
                  visited' = foldr Set.insert visited new
               in bfsReachable visited' (xs ++ new)
            want = Set.map (VaultId . idOfIdx) (bfsReachable (Set.singleton 0) [0])
        result <- liftIO $ withTempHubDir $ \root -> do
          mapM_
            (\(i, outs) -> writeVaultMarker (pathOfIdx root i) (markerTomlText (idOfIdx i) "asset" (idOfIdx i) (map idOfIdx outs)))
            edges
          let entries = [VaultEntry (VaultId (idOfIdx i)) (idOfIdx i) AssetVault (pathOfIdx root i) | (i, _) <- edges]
              hub = mkHub entries [] Nothing (ToolsConfig Nothing) ""
          resolveRead hub (Just (idOfIdx 0))
        case result of
          Right rs -> do
            let got = vmidsOf (rsVaults rs)
            Set.fromList got === want
            length got === Set.size (Set.fromList got)
          Left err -> annotate (show err) >> failure

    it "test_refs_self_loop_terminates (EX-12, LAW-20): 自環 refs = [自己] 仍終止,結果恰好一個" $
      withTempHubDir $ \root -> do
        let pathF = root </> "f"
        writeVaultMarker pathF (markerTomlText "vlt-ffff1111" "asset" "f" ["vlt-ffff1111"])
        let entryF = VaultEntry (VaultId "vlt-ffff1111") "f" AssetVault pathF
            hub = mkHub [entryF] [] Nothing (ToolsConfig Nothing) ""
        result <- resolveRead hub (Just "f")
        case result of
          Right rs -> vmidsOf (rsVaults rs) `shouldBe` [VaultId "vlt-ffff1111"]
          Left err -> expectationFailure (show err)

    it "test_refs_diamond_bfs_order (EX-34, LAW-1, LAW-7, LAW-20): 菱形 A->[B,C],B->[D],C->[D],D 只出現一次,BFS 順序 [A,B,C,D]" $
      withTempHubDir $ \root -> do
        let pathA = root </> "a"
            pathB = root </> "b"
            pathC = root </> "c"
            pathD = root </> "d"
        writeVaultMarker pathA (markerTomlText "vlt-aaaa1111" "asset" "a" ["vlt-bbbb2222", "vlt-cccc3333"])
        writeVaultMarker pathB (markerTomlText "vlt-bbbb2222" "asset" "b" ["vlt-dddd4444"])
        writeVaultMarker pathC (markerTomlText "vlt-cccc3333" "asset" "c" ["vlt-dddd4444"])
        writeVaultMarker pathD (markerTomlText "vlt-dddd4444" "asset" "d" [])
        let entries =
              [ VaultEntry (VaultId "vlt-aaaa1111") "a" AssetVault pathA
              , VaultEntry (VaultId "vlt-bbbb2222") "b" AssetVault pathB
              , VaultEntry (VaultId "vlt-cccc3333") "c" AssetVault pathC
              , VaultEntry (VaultId "vlt-dddd4444") "d" AssetVault pathD
              ]
            hub = mkHub entries [] Nothing (ToolsConfig Nothing) ""
        result <- resolveRead hub (Just "a")
        case result of
          Right rs ->
            vmidsOf (rsVaults rs)
              `shouldBe` map VaultId ["vlt-aaaa1111", "vlt-bbbb2222", "vlt-cccc3333", "vlt-dddd4444"]
          Left err -> expectationFailure (show err)

    it "test_refs_unregistered_target_degrades (EX-8, LAW-21): refs 指向中樞查不到的 id,產生 RefVaultNotRegistered,其餘照常展開" $
      withScopeVaults $ \sv -> do
        writeVaultMarker (svPathA sv) (markerTomlText "vlt-aaaa1111" "asset" "a" ["vlt-bbbb2222", "vlt-ffff0000"])
        result <- resolveRead (svHub sv) (Just "a")
        case result of
          Right rs -> do
            vmidsOf (rsVaults rs) `shouldBe` map VaultId ["vlt-aaaa1111", "vlt-bbbb2222", "vlt-cccc3333"]
            rsIssues rs `shouldBe` [RefVaultNotRegistered (VaultId "vlt-aaaa1111") (VaultId "vlt-ffff0000")]
          Left err -> expectationFailure (show err)

    it "test_unreachable_node_refs_not_expanded (EX-35, LAW-22): refs 指向 marker 壞的 M,M 不進結果集,也不展開它自己的 refs" $
      withTempHubDir $ \root -> do
        let pathA = root </> "a"
            pathM = root </> "m"
        -- 注意:ref 目標 id 必須是合法十六進位(F002「數據」節:parseId 只收 1-8 位小寫
        -- 十六進位),因為它會被寫進 A 的 marker 檔、由 readMarker 剖析——"vlt-mmmm1111"
        -- 這個佔位 id(spec 表格裡 M 在中樞的 veId,從不進 TOML)拿來當 refs 內容會讓
        -- A 自己的 marker 變成解不開,不是這條 law 要驗的東西。改用合法 id "vlt-1111dead"。
        writeVaultMarker pathA (markerTomlText "vlt-aaaa1111" "asset" "a" ["vlt-1111dead"])
        createDirectoryIfMissing True (pathM </> ".aapms")
        let entryA = VaultEntry (VaultId "vlt-aaaa1111") "a" AssetVault pathA
            entryM = VaultEntry (VaultId "vlt-1111dead") "m" AssetVault pathM
            hub = mkHub [entryA, entryM] [] Nothing (ToolsConfig Nothing) ""
        canonM <- canonicalizePath pathM
        expectedM <- readMarker canonM
        errM <- either pure (const (expectationFailure "M 的 marker 不應該讀得到" >> fail "unreachable")) expectedM
        result <- resolveRead hub (Just "a")
        case result of
          Right rs -> do
            vmidsOf (rsVaults rs) `shouldBe` [VaultId "vlt-aaaa1111"]
            rsIssues rs `shouldBe` [VaultMarkerBroken entryM errM]
          Left err -> expectationFailure (show err)

    it "test_id_drift_node_refs_not_expanded (EX-36, LAW-22): refs 指向 id 漂移的 Z,Z 與它的 refs 目標(D)都不進結果集" $
      withTempHubDir $ \root -> do
        let pathA = root </> "a"
            pathZ = root </> "z"
            pathD = root </> "d"
        writeVaultMarker pathA (markerTomlText "vlt-aaaa1111" "asset" "a" ["vlt-77776666"])
        writeVaultMarker pathZ (markerTomlText "vlt-99998888" "asset" "z" ["vlt-dddd4444"])
        writeVaultMarker pathD (markerTomlText "vlt-dddd4444" "asset" "d" [])
        let entryA = VaultEntry (VaultId "vlt-aaaa1111") "a" AssetVault pathA
            entryZ = VaultEntry (VaultId "vlt-77776666") "z" AssetVault pathZ
            entryD = VaultEntry (VaultId "vlt-dddd4444") "d" AssetVault pathD
            hub = mkHub [entryA, entryZ, entryD] [] Nothing (ToolsConfig Nothing) ""
        result <- resolveRead hub (Just "a")
        case result of
          Right rs -> do
            vmidsOf (rsVaults rs) `shouldBe` [VaultId "vlt-aaaa1111"]
            rsIssues rs `shouldBe` [VaultIdDrift entryZ (VaultId "vlt-99998888")]
          Left err -> expectationFailure (show err)

  --------------------------------------------------------------------------
  describe "STEP-3/LAW-2,LAW-3,LAW-5,LAW-7,LAW-8,LAW-9/EX-3-EX-5,EX-6,EX-7,EX-9-EX-11,EX-13,EX-15: resolveRead 有 selector" $ do
    it "test_resolve_read_selector_is_closure (EX-3, EX-5, LAW-7, LAW-20): {X} ∪ refs*(X),環終止不重複;無 refs 時恰好一個" $
      withScopeVaults $ \sv -> do
        r3 <- resolveRead (svHub sv) (Just "a")
        r5 <- resolveRead (svHub sv) (Just "d")
        case (r3, r5) of
          (Right rs3, Right rs5) -> do
            vmidsOf (rsVaults rs3) `shouldBe` map VaultId ["vlt-aaaa1111", "vlt-bbbb2222", "vlt-cccc3333"]
            rsIssues rs3 `shouldBe` []
            vmidsOf (rsVaults rs5) `shouldBe` [VaultId "vlt-dddd4444"]
            rsIssues rs5 `shouldBe` []
          other -> expectationFailure (show other)

    it "test_resolve_read_selector_by_id_equals_by_name (EX-4): 用 id 字串與用 name 字串查同一個 vault,結果逐欄相同" $
      withScopeVaults $ \sv -> do
        byName <- resolveRead (svHub sv) (Just "a")
        byId <- resolveRead (svHub sv) (Just "vlt-aaaa1111")
        byId `shouldBe` byName

    it "test_resolve_read_selector_not_found_passthrough (EX-6, LAW-8): 兩階段都沒命中,原樣透傳 VaultSelectorNotFound" $
      withScopeVaults $ \sv -> do
        result <- resolveRead (svHub sv) (Just "nope")
        result `shouldBe` Left (VaultSelectorNotFound "nope")

    it "test_resolve_read_selector_ambiguous_passthrough (EX-7, LAW-8): 撞名原樣透傳 VaultSelectorAmbiguous,帶全部候選" $
      withScopeVaults $ \sv -> do
        let dup1 = (svEntryA sv) {veName = "dup"}
            dup2 = (svEntryB sv) {veName = "dup"}
            h' = mkHub [dup1, dup2] [] Nothing (ToolsConfig Nothing) ""
        result <- resolveRead h' (Just "dup")
        result `shouldBe` Left (VaultSelectorAmbiguous "dup" [dup1, dup2])

    it "test_resolve_read_seed_unreachable_still_right (EX-9, EX-10, EX-11, LAW-3, LAW-9): 種子路徑不見/marker壞/id漂移時仍是 Right,空清單、恰一則 issue、不展開" $
      withScopeVaults $ \sv -> do
        canonM <- canonicalizePath (svPathM sv)
        expectedM <- readMarker canonM
        errM <- either pure (const (expectationFailure "M 的 marker 不應該讀得到" >> fail "unreachable")) expectedM
        canonGone <- canonicalizePath (svPathGone sv)
        rM <- resolveRead (svHub sv) (Just "m")
        rP <- resolveRead (svHub sv) (Just "p")
        rZ <- resolveRead (svHub sv) (Just "z")
        rM `shouldBe` Right (ReadScope [] [VaultMarkerBroken (svEntryM sv) errM])
        rP `shouldBe` Right (ReadScope [] [VaultPathMissing (svEntryP sv) canonGone])
        case rZ of
          Right rs -> do
            rsVaults rs `shouldBe` []
            rsIssues rs `shouldBe` [VaultIdDrift (svEntryZ sv) (VaultId "vlt-99998888")]
            rsIssues rs `shouldSatisfy` not . any isRefVaultNotRegistered
          Left err -> expectationFailure (show err)

    it "test_resolve_read_no_selector_never_expands_refs (EX-13, LAW-5): 無 selector 時即使某 vault 的 refs 指向未註冊 id,也不產生 RefVaultNotRegistered" $
      withScopeVaults $ \sv -> do
        writeVaultMarker (svPathA sv) (markerTomlText "vlt-aaaa1111" "asset" "a" ["vlt-bbbb2222", "vlt-ffff0000"])
        result <- resolveRead (svHub sv) Nothing
        case result of
          Right rs -> rsIssues rs `shouldSatisfy` not . any isRefVaultNotRegistered
          Left err -> expectationFailure (show err)

    it "test_resolve_read_marker_is_truth (EX-15, LAW-2): 中樞那一列的 veName/veKind 換掉,vrMarker 與 vmId 集合、issues 逐欄不變" $
      withScopeVaults $ \sv -> do
        let staleA = (svEntryA sv) {veName = "stale", veKind = StoryVault}
            hub' =
              mkHub
                [staleA, svEntryB sv, svEntryC sv, svEntryD sv, svEntryM sv, svEntryP sv, svEntryZ sv]
                []
                Nothing
                (ToolsConfig Nothing)
                ""
        r4 <- resolveRead (svHub sv) (Just "vlt-aaaa1111")
        r15 <- resolveRead hub' (Just "vlt-aaaa1111")
        case (r4, r15) of
          (Right rs4, Right rs15) -> do
            map vrMarker (rsVaults rs15) `shouldBe` map vrMarker (rsVaults rs4)
            vmidsOf (rsVaults rs15) `shouldBe` vmidsOf (rsVaults rs4)
            rsIssues rs15 `shouldBe` rsIssues rs4
          other -> expectationFailure (show other)

  --------------------------------------------------------------------------
  describe "STEP-4/LAW-12,LAW-13(a),LAW-13(b),LAW-14,LAW-15/EX-17-EX-24: resolveWrite 的寫入目標" $ do
    it "test_resolve_write_no_target_carries_canonical_start (EX-17, LAW-12): 探測不到 .aapms/ 時回 NoWriteTarget,訊息含正規化後的起點" $
      withTempHubDir $ \t2 ->
        withScopeVaults $ \sv -> do
          canonT2 <- canonicalizePath t2
          result <- resolveWrite (svHub sv) Nothing t2
          case result of
            Left err@(NoWriteTarget s') -> do
              s' `shouldBe` canonT2
              renderWorkspaceError err `shouldSatisfy` T.isInfixOf (T.pack canonT2)
            other -> expectationFailure (show other)

    it "test_resolve_write_target_marker_unreadable_is_hard_error (EX-20, EX-21, EX-22, LAW-13a): 目標路徑不見/marker壞(含探測命中後才發現壞)都是硬失敗 MarkerUnreadable" $
      withScopeVaults $ \sv -> do
        canonGone <- canonicalizePath (svPathGone sv)
        expectedGone <- readMarker canonGone
        canonM <- canonicalizePath (svPathM sv)
        expectedM <- readMarker canonM
        rP <- resolveWrite (svHub sv) (Just "p") (svPathA sv)
        rM <- resolveWrite (svHub sv) (Just "m") (svPathA sv)
        let startInM = svPathM sv </> "deep"
        createDirectoryIfMissing True startInM
        rDetectM <- resolveWrite (svHub sv) Nothing startInM
        case (rP, expectedGone) of
          (Left (MarkerUnreadable p err), Left expectedErr) -> do
            p `shouldBe` canonGone
            err `shouldBe` expectedErr
          other -> expectationFailure ("EX-20: " <> show other)
        case (rM, expectedM) of
          (Left (MarkerUnreadable p err), Left expectedErr) -> do
            p `shouldBe` canonM
            err `shouldBe` expectedErr
          other -> expectationFailure ("EX-21: " <> show other)
        case (rDetectM, expectedM) of
          (Left (MarkerUnreadable p err), Left expectedErr) -> do
            p `shouldBe` canonM
            err `shouldBe` expectedErr
          other -> expectationFailure ("EX-22: " <> show other)

    it "test_resolve_write_id_drift_is_hard_error (EX-19, LAW-13b): selector 指到 id 漂移的 Z,回 WriteTargetIdDrift 三個值,訊息含全部三個" $
      withScopeVaults $ \sv -> do
        canonZ <- canonicalizePath (svPathZ sv)
        result <- resolveWrite (svHub sv) (Just "z") (svPathA sv)
        case result of
          Left err@(WriteTargetIdDrift regId path markerIdV) -> do
            regId `shouldBe` VaultId "vlt-77776666"
            path `shouldBe` canonZ
            markerIdV `shouldBe` VaultId "vlt-99998888"
            let msg = renderWorkspaceError err
            msg `shouldSatisfy` T.isInfixOf "vlt-77776666"
            msg `shouldSatisfy` T.isInfixOf (T.pack canonZ)
            msg `shouldSatisfy` T.isInfixOf "vlt-99998888"
          other -> expectationFailure (show other)

    it "test_resolve_write_unregistered_target_allowed (EX-18, LAW-14): 探測命中未註冊的 E 時 vrEntry 是 Nothing,wsRead 恰一個" $
      withScopeVaults $ \sv -> do
        let start = svPathE sv </> "x"
        createDirectoryIfMissing True start
        result <- resolveWrite (svHub sv) Nothing start
        case result of
          Right ws -> do
            vrEntry (wsTarget ws) `shouldBe` Nothing
            length (wsRead ws) `shouldBe` 1
            vmidOf (wsTarget ws) `shouldBe` VaultId "vlt-eeee5555"
          Left err -> expectationFailure (show err)

    it "test_resolve_write_selector_ignores_start (EX-23, EX-24, LAW-10, LAW-15, LAW-23): selector 指定 B 時,結果與起點無關;A 只以唯讀身分經 refs 進來" $
      withScopeVaults $ \sv ->
        withTempHubDir $ \t2 -> do
          let startInA = svPathA sv </> "deep"
          createDirectoryIfMissing True startInA
          rInA <- resolveWrite (svHub sv) (Just "b") startInA
          rOutside <- resolveWrite (svHub sv) (Just "b") t2
          case (rInA, rOutside) of
            (Right wsInA, Right wsOutside) -> do
              vmidOf (wsTarget wsInA) `shouldBe` VaultId "vlt-bbbb2222"
              vmidsOf (wsRead wsInA) `shouldBe` map VaultId ["vlt-bbbb2222", "vlt-cccc3333", "vlt-aaaa1111"]
              wsOutside `shouldBe` wsInA
            other -> expectationFailure (show other)

  --------------------------------------------------------------------------
  describe "STEP-5/LAW-10,LAW-11,LAW-13(c),LAW-23/EX-16,EX-23,EX-25: resolveWrite 的 wsRead/wsIssues" $ do
    it "test_resolve_write_target_never_from_refs (EX-16, EX-23, LAW-10, LAW-23): wsTarget 恒不來自 refs 展開,把__其他__ vault 的 refs 任意改寫也不換人、目標本身逐欄不變" $
      withScopeVaults $ \sv -> do
        let start = svPathA sv </> "deep" </> "deeper"
        createDirectoryIfMissing True start
        rBefore <- resolveWrite (svHub sv) Nothing start
        -- 目標是 A;改寫的是「其他」vault(B)的 refs,不是目標自己的 marker——
        -- LAW-10 驗的是「wsTarget 不會因為別的 vault 怎麼引用而換人」,不是「目標自己的
        -- marker 內容不會變」(那違反 LAW-2「marker 是真相」)。
        writeVaultMarker (svPathB sv) (markerTomlText "vlt-bbbb2222" "story" "b" [])
        rAfter <- resolveWrite (svHub sv) Nothing start
        case (rBefore, rAfter) of
          (Right wsBefore, Right wsAfter) -> do
            vmidOf (wsTarget wsBefore) `shouldBe` VaultId "vlt-aaaa1111"
            wsTarget wsAfter `shouldBe` wsTarget wsBefore
          other -> expectationFailure (show other)

    it "test_resolve_write_read_starts_with_target (EX-16, EX-23, LAW-11): wsRead 的第一個元素就是 wsTarget,其餘是 refs* 展開" $
      withScopeVaults $ \sv -> do
        let start = svPathA sv </> "deep" </> "deeper"
        createDirectoryIfMissing True start
        result <- resolveWrite (svHub sv) Nothing start
        case result of
          Right ws -> do
            vmidsOf (wsRead ws) `shouldBe` map VaultId ["vlt-aaaa1111", "vlt-bbbb2222", "vlt-cccc3333"]
            case vmidsOf (wsRead ws) of
              (firstId : _) -> firstId `shouldBe` vmidOf (wsTarget ws)
              [] -> expectationFailure "wsRead 不應為空(LAW-11)"
            wsIssues ws `shouldBe` []
          Left err -> expectationFailure (show err)

    it "test_resolve_write_issues_never_describe_target (EX-25, LAW-13c, LAW-21): wsIssues 只裝 refs 展開的降級,不含描述 wsTarget 的任何一則" $
      withScopeVaults $ \sv -> do
        writeVaultMarker (svPathA sv) (markerTomlText "vlt-aaaa1111" "asset" "a" ["vlt-bbbb2222", "vlt-ffff0000"])
        result <- resolveWrite (svHub sv) (Just "a") (svPathA sv)
        case result of
          Right ws ->
            wsIssues ws `shouldBe` [RefVaultNotRegistered (VaultId "vlt-aaaa1111") (VaultId "vlt-ffff0000")]
          Left err -> expectationFailure (show err)

  --------------------------------------------------------------------------
  describe "STEP-6/LAW-16,LAW-17,LAW-18,LAW-19/EX-26-EX-31: resolvePipeline" $ do
    it "test_resolve_pipeline_filters_by_kind (EX-26, EX-27, LAW-16): 無 selector 時只跑 vmKind 相符者,psIssues 與 resolveRead 的 rsIssues 逐欄相同" $
      withScopeVaults $ \sv -> do
        canonM <- canonicalizePath (svPathM sv)
        expectedM <- readMarker canonM
        errM <- either pure (const (expectationFailure "M 的 marker 不應該讀得到" >> fail "unreachable")) expectedM
        canonGone <- canonicalizePath (svPathGone sv)
        rAsset <- resolvePipeline (svHub sv) AssetVault Nothing
        rStory <- resolvePipeline (svHub sv) StoryVault Nothing
        case (rAsset, rStory) of
          (Right psAsset, Right psStory) -> do
            vmidsOf (psRuns psAsset) `shouldBe` map VaultId ["vlt-aaaa1111", "vlt-cccc3333", "vlt-dddd4444"]
            psIssues psAsset
              `shouldBe` [ VaultMarkerBroken (svEntryM sv) errM
                         , VaultPathMissing (svEntryP sv) canonGone
                         , VaultIdDrift (svEntryZ sv) (VaultId "vlt-99998888")
                         ]
            vmidsOf (psRuns psStory) `shouldBe` [VaultId "vlt-bbbb2222"]
          other -> expectationFailure (show other)

    it "test_resolve_pipeline_kind_mismatch_is_silent_without_selector (EX-26 續, LAW-16): kind 不符的 B 被靜默排除,不產生任何 ScopeIssue" $
      withScopeVaults $ \sv -> do
        result <- resolvePipeline (svHub sv) AssetVault Nothing
        case result of
          Right ps -> do
            vmidsOf (psRuns ps) `shouldNotContain` [VaultId "vlt-bbbb2222"]
            psIssues ps `shouldSatisfy` all (/= VaultIdDrift (svEntryB sv) (VaultId "vlt-bbbb2222"))
          Left err -> expectationFailure (show err)

    it "test_resolve_pipeline_selector_is_single_run (EX-28, LAW-17): 有 selector 且 kind 相符時恰好一個,不展開 refs" $
      withScopeVaults $ \sv -> do
        result <- resolvePipeline (svHub sv) AssetVault (Just "a")
        case result of
          Right ps -> do
            vmidsOf (psRuns ps) `shouldBe` [VaultId "vlt-aaaa1111"]
            psIssues ps `shouldBe` []
          Left err -> expectationFailure (show err)

    it "test_resolve_pipeline_kind_mismatch_carries_three_values (EX-29, LAW-18): kind 不符回 VaultKindMismatch,帶 id、要求的 kind、實際的 kind" $
      withScopeVaults $ \sv -> do
        result <- resolvePipeline (svHub sv) AssetVault (Just "b")
        case result of
          Left err@(VaultKindMismatch vid want got) -> do
            vid `shouldBe` VaultId "vlt-bbbb2222"
            want `shouldBe` AssetVault
            got `shouldBe` StoryVault
            let msg = renderWorkspaceError err
            msg `shouldSatisfy` T.isInfixOf "vlt-bbbb2222"
            msg `shouldSatisfy` T.isInfixOf (renderVaultKind AssetVault)
            msg `shouldSatisfy` T.isInfixOf (renderVaultKind StoryVault)
          other -> expectationFailure (show other)

    it "test_resolve_pipeline_unreachable_is_right (EX-30, LAW-19): 有 selector 但該 vault 不可達時回 Right + issue,不是 VaultKindMismatch" $
      withScopeVaults $ \sv -> do
        canonM <- canonicalizePath (svPathM sv)
        expectedM <- readMarker canonM
        errM <- either pure (const (expectationFailure "M 的 marker 不應該讀得到" >> fail "unreachable")) expectedM
        result <- resolvePipeline (svHub sv) AssetVault (Just "m")
        result `shouldBe` Right (PipelineScope [] [VaultMarkerBroken (svEntryM sv) errM])

    it "test_resolve_pipeline_selector_not_found_passthrough (EX-31, LAW-8): selector 解不開時原樣透傳 VaultSelectorNotFound" $
      withScopeVaults $ \sv -> do
        result <- resolvePipeline (svHub sv) AssetVault (Just "nope")
        result `shouldBe` Left (VaultSelectorNotFound "nope")

  --------------------------------------------------------------------------
  describe "(全部)/LAW-4,LAW-24/EX-32,EX-33: 不動檔案系統、不判 ATTACH 上限" $ do
    it "test_scope_touches_no_files (EX-33, LAW-4): 三個函式呼叫前後,T 底下整棵目錄樹逐位元組相同" $
      withScopeVaults $ \sv -> do
        let start = svPathA sv </> "deep" </> "deeper"
        createDirectoryIfMissing True start
        snapBefore <- snapshotTree (svRoot sv)
        _ <- resolveRead (svHub sv) Nothing
        _ <- resolveWrite (svHub sv) Nothing start
        _ <- resolvePipeline (svHub sv) AssetVault Nothing
        snapAfter <- snapshotTree (svRoot sv)
        snapAfter `shouldBe` snapBefore

    it "test_scope_has_no_attach_limit (EX-32, LAW-24): 11 個讀得到 marker 的 vault 仍全部回 Right,沒有任何數量上限錯誤" $
      withTempHubDir $ \root -> do
        let n = 11 :: Int
            idOfIdx i = "vlt-" <> T.justifyRight 8 '0' (T.pack (show i))
            pathOfIdx i = root </> ("v" <> show i)
            entries = [VaultEntry (VaultId (idOfIdx i)) (idOfIdx i) AssetVault (pathOfIdx i) | i <- [1 .. n]]
        mapM_ (\i -> writeVaultMarker (pathOfIdx i) (markerTomlText (idOfIdx i) "asset" (idOfIdx i) [])) [1 .. n]
        let hub = mkHub entries [] Nothing (ToolsConfig Nothing) ""
        rRead <- resolveRead hub Nothing
        rPipe <- resolvePipeline hub AssetVault Nothing
        case (rRead, rPipe) of
          (Right rs, Right ps) -> do
            length (rsVaults rs) `shouldBe` 11
            rsIssues rs `shouldBe` []
            length (psRuns ps) `shouldBe` 11
            psIssues ps `shouldBe` []
          other -> expectationFailure (show other)

  --------------------------------------------------------------------------
  describe "LAW-25(預期綠): 依賴方向與職責界線,以 import 行驗證" $ do
    it "test_scope_no_downstream_or_location_imports(a): 本套件內的 import 只能是 \
       \Aapms.Workspace.Types / Aapms.Workspace.Hub / Aapms.Workspace.Discovery" $ do
      importLines <- scopeImportLines
      let sibling = filter (\l -> "Aapms.Workspace." `isPrefixOf` moduleNameOf l) importLines
      mapM_
        (\l -> moduleNameOf l `shouldSatisfy` (`elem` ["Aapms.Workspace.Types", "Aapms.Workspace.Hub", "Aapms.Workspace.Discovery"]))
        sibling

    it "test_scope_marker_import_is_three_fields_only(b): 若有 import Aapms.Store.Marker,必須逐字是 \
       \\"import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmRefs))\"" $ do
      importLines <- scopeImportLines
      let markerLines = filter (\l -> moduleNameOf l == "Aapms.Store.Marker") importLines
      markerLines `shouldSatisfy` all (== "import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmRefs))")

    it "test_scope_schema_import_is_type_only(c): import Aapms.Store.Schema 必須逐字是 \
       \\"import Aapms.Store.Schema (VaultKind)\"(骨架階段就有這一行)" $ do
      importLines <- scopeImportLines
      let schemaLines = filter (\l -> moduleNameOf l == "Aapms.Store.Schema") importLines
      schemaLines `shouldSatisfy` all (== "import Aapms.Store.Schema (VaultKind)")

    it "test_scope_never_imports_store_internals(d): 完全不得 import Store 門面/Atomic/Error/Index/MultiVault/Query/Write/Create" $ do
      importLines <- scopeImportLines
      let forbidden =
            [ "Aapms.Store"
            , "Aapms.Store.Atomic"
            , "Aapms.Store.Error"
            , "Aapms.Store.Index"
            , "Aapms.Store.MultiVault"
            , "Aapms.Store.Query"
            , "Aapms.Store.Write"
            , "Aapms.Store.Create"
            , "Aapms.Store.Edit"
            , "Aapms.Store.Walk"
            , "Aapms.Store.Node"
            , "Aapms.Store.Row"
            , "Aapms.Store.Tokenize"
            ]
      mapM_ (\l -> moduleNameOf l `shouldSatisfy` (`notElem` forbidden)) importLines

    it "test_scope_no_process_import(e): 完全不得 import System.Process" $ do
      importLines <- scopeImportLines
      mapM_ (\l -> moduleNameOf l `shouldNotBe` "System.Process") importLines

    it "test_scope_directory_import_is_canonicalize_only(f): 若有 import System.Directory,必須逐字是 \
       \\"import System.Directory (canonicalizePath)\";System.FilePath 完全不需要出現" $ do
      importLines <- scopeImportLines
      let dirLines = filter (\l -> moduleNameOf l == "System.Directory") importLines
      dirLines `shouldSatisfy` all (== "import System.Directory (canonicalizePath)")
      mapM_ (\l -> moduleNameOf l `shouldNotBe` "System.FilePath") importLines
