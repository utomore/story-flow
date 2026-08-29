-- | F002:'Aapms.Workspace.Discovery' 的向上探測('detectVault',L1-L5\/X1-X7)、
-- selector 解析('lookupSelector',L6-L9\/X8-X13)、重讀 marker('readVaultRef'\/
-- 'readVaultRefAt',L10-L17\/X14-X24)與依賴方向的 import 清單檢查
-- (L18,__預期綠__——見 spec「紅綠預期」)。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F002-vault-discovery.md@):
--
-- @
-- T1 detectVault
-- L1  命中的是最近的那一層                    -> test_detect_vault_from_nested_child / test_detect_vault_picks_nearest
-- L2  到根仍沒有就是 Nothing,而且一定終止      -> test_detect_vault_outside_returns_nothing
-- L3  自身也算、深度不敏感                      -> test_detect_vault_at_root_itself / test_detect_vault_from_nested_child
-- L4  detectVault 不動檔案系統                  -> test_detect_vault_creates_nothing
-- L5  .aapms 必須是目錄                         -> test_detect_vault_ignores_marker_file
-- X1-X7                                          -> 對應各 test_detect_vault_*
--
-- T2 lookupSelector
-- L6  兩階段,id 絕對優先                        -> test_lookup_selector_id_beats_name
-- L7  命中集合 -> 結果,兩階段同一套規則          -> test_lookup_selector_ambiguous_lists_all / test_lookup_selector_not_found
-- L8  逐字精確比對                                -> test_lookup_selector_is_case_sensitive / test_lookup_selector_does_not_trim
-- L9  只看 [[vaults]]                             -> test_lookup_selector_ignores_other_sections
-- X8-X13                                          -> 對應各 test_lookup_selector_*
--
-- T3 readVaultRef
-- L10 marker 是真相                              -> test_read_vault_ref_marker_is_truth
-- L11 成功時的三個欄位                            -> test_read_vault_ref_fields_on_success
-- L12 三種降級互斥且依序判定                      -> test_read_vault_ref_path_missing / test_read_vault_ref_marker_broken_carries_original / test_read_vault_ref_id_drift
-- L13 readVaultRef 不動檔案系統                   -> test_read_vault_ref_creates_nothing
-- X14-X18                                         -> 對應各 test_read_vault_ref_*
--
-- T4 readVaultRefAt
-- L14 readVaultRefAt 的身分回填                   -> test_read_vault_ref_at_fills_entry_by_id / test_read_vault_ref_at_unregistered_is_nothing / test_read_vault_ref_at_ignores_path_match
-- L15 readVaultRefAt 的失敗一律是 MarkerUnreadable -> test_read_vault_ref_at_marker_unreadable
-- X19-X22                                         -> 對應各 test_read_vault_ref_at_*
--
-- T5 兩者一致、refs 原樣捧著
-- L16 兩個函式對同一個 vault 一致                 -> test_two_readers_agree
-- L17 不展開 refs                                 -> test_refs_carried_verbatim_not_expanded
-- X23/X24                                         -> test_two_readers_agree / test_refs_carried_verbatim_not_expanded
--
-- L18(預期綠) 依賴方向與職責界線(以 import 行驗證)
-- (a) 無 Location/Scope/Lifecycle/Projects/Tools,只准 Types/Hub -> test_discovery_no_downstream_or_location_imports
-- (b) Aapms.Store.Marker 的 import(若有)逐字只拿 VaultMarker (vmId)/markerDir/readMarker(守「只讀 id」) -> test_discovery_marker_import_is_id_reader_only
-- (c) 不得 import Aapms.Store.Atomic                -> test_discovery_never_imports_atomic
-- (d) 不得 import Store 門面/Schema/Index/MultiVault/Query/Write/Create -> test_discovery_never_imports_index_modules
-- (e) 不得 import System.Process                    -> test_discovery_no_process_import
-- @
module Aapms.Workspace.DiscoverySpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.List (dropWhileEnd, isPrefixOf)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Error (renderStoreError)
import Aapms.Store.Marker (VaultMarker (..), readMarker)
import Aapms.Store.Schema (VaultKind (..), renderVaultKind)
import Aapms.Workspace.Discovery (detectVault, lookupSelector, readVaultRef, readVaultRefAt)
import Aapms.Workspace.Fixtures
import Aapms.Workspace.Types

import Hedgehog (Gen)
import System.Directory (canonicalizePath, createDirectoryIfMissing)
import System.FilePath ((</>))

--------------------------------------------------------------------------------
-- 本檔專用 helper(不匯出)

-- | 一個骨架檔案裡,去除前導空白、去除行尾 @\\r@(CRLF checkout 的產物)之後、以
-- @import@ 起頭的行。判準只看 import 行,不做全檔字串搜尋(L18 明文;做法對照
-- "Aapms.Workspace.TypesSpec.importLinesOf",F001 L17 用的是同一套邏輯)。
importLinesOf :: FilePath -> IO [String]
importLinesOf rel = do
  src <- readWorkspaceSource rel
  let stripLine = dropWhile (== ' ') . dropWhileEnd (== '\r')
  pure (filter ("import" `isPrefixOf`) (map stripLine (lines (T.unpack src))))

-- | 從一行 import 取出被 import 的模組全名(不含子句清單),例如
-- @"import Aapms.Store.Marker (markerDir, readMarker)"@ -> @"Aapms.Store.Marker"@、
-- @"import Aapms.Workspace.Types"@ -> @"Aapms.Workspace.Types"@。用來把「模組名字串
-- 相等」與「模組名是另一個模組名的字首」分開(@Aapms.Store@ 門面與
-- @Aapms.Store.Marker@ 不能被同一個 `isInfixOf` 判準搞混)。
moduleNameOf :: String -> String
moduleNameOf l = takeWhile (\c -> c /= ' ' && c /= '(') (drop (length ("import " :: String)) l)

discoveryImportLines :: IO [String]
discoveryImportLines = importLinesOf "Aapms/Workspace/Discovery.hs"

-- | 任意長度的路徑片段(英數字,1-6 字),給向上探測的巢狀深度用。
genSegment :: Gen String
genSegment = T.unpack <$> Gen.text (Range.linear 1 6) (Gen.choice [Gen.alpha, Gen.digit])

-- | n 個兩兩相異的 'VaultId'(id 空間是 16^8,篩選幾乎不會重試)。
genDistinctVaultIds :: Int -> Gen [VaultId]
genDistinctVaultIds = go []
  where
    go acc 0 = pure (reverse acc)
    go acc n = do
      vid <- Gen.filter (`notElem` acc) genVaultId
      go (vid : acc) (n - 1)

-- | 把一連串路徑片段接在某個根目錄後面。
joinSegs :: FilePath -> [String] -> FilePath
joinSegs = foldl (</>)

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 Aapms.Workspace.Discovery" $ do
  --------------------------------------------------------------------------
  describe "T1/L1-L5/X1-X7: detectVault 向上探測" $ do
    it "test_detect_vault_from_nested_child (X1, L1, L3): 從 vault 內任意深度的子目錄回最近一層含 .aapms/ 的正規化路徑" $
      hedgehog $ do
        segs <- forAll (Gen.list (Range.linear 1 4) genSegment)
        (result, canonRoot) <- liftIO $ withTempHubDir $ \root -> do
          writeVaultMarker root (markerTomlText "vlt-7f3b2a91" "asset" "alchbees-assets" [])
          canonRoot <- canonicalizePath root
          let start = joinSegs root segs
          createDirectoryIfMissing True start
          r <- detectVault start
          pure (r, canonRoot)
        result === Just canonRoot

    it "test_detect_vault_at_root_itself (X2, L3): 起點就是 vault 根,回自己" $
      withTempHubDir $ \root -> do
        writeVaultMarker root (markerTomlText "vlt-7f3b2a91" "asset" "alchbees-assets" [])
        canonRoot <- canonicalizePath root
        r <- detectVault root
        r `shouldBe` Just canonRoot

    it "test_detect_vault_normalizes_dotdot (X3, L1): 起點含 ../ 之後正規化,不多走一層" $
      withTempHubDir $ \root -> do
        writeVaultMarker root (markerTomlText "vlt-7f3b2a91" "asset" "alchbees-assets" [])
        createDirectoryIfMissing True (root </> "a" </> "b")
        canonRoot <- canonicalizePath root
        r <- detectVault (root </> "a" </> ".." </> "a" </> "b")
        r `shouldBe` Just canonRoot

    it "test_detect_vault_outside_returns_nothing (X4, L2): 沒有任何祖先含 .aapms/ 時回 Nothing \
       \(前提同 spec X4:暫存目錄的祖先鏈本身沒有 .aapms/)" $
      hedgehog $ do
        segs <- forAll (Gen.list (Range.linear 0 3) genSegment)
        result <- liftIO $ withTempHubDir $ \root -> do
          let start = joinSegs root segs
          createDirectoryIfMissing True start
          detectVault start
        result === Nothing

    it "test_detect_vault_picks_nearest (X5, L1(d)): 兩層都有 marker 時回最近的那一層" $
      hedgehog $ do
        extraSegs <- forAll (Gen.list (Range.linear 0 3) genSegment)
        (result, canonInner) <- liftIO $ withTempHubDir $ \root -> do
          writeVaultMarker root (markerTomlText "vlt-7f3b2a91" "asset" "outer" [])
          let inner = root </> "inner"
          writeVaultMarker inner (markerTomlText "vlt-a0c4e1f8" "asset" "inner-vault" [])
          canonInner <- canonicalizePath inner
          let start = joinSegs inner extraSegs
          createDirectoryIfMissing True start
          r <- detectVault start
          pure (r, canonInner)
        result === Just canonInner

    it "test_detect_vault_ignores_marker_file (X6, L5): .aapms 是普通檔案時不算命中,一路到根都沒有 -> Nothing" $
      withTempHubDir $ \root -> do
        createDirectoryIfMissing True (root </> "a")
        writeFile (root </> ".aapms") "not a directory"
        r <- detectVault (root </> "a")
        r `shouldBe` Nothing

    it "L5(續): .aapms 是檔案時越過它,繼續往上找到再上一層真正的 marker" $
      withTempHubDir $ \root -> do
        writeVaultMarker root (markerTomlText "vlt-7f3b2a91" "asset" "outer" [])
        createDirectoryIfMissing True (root </> "inner")
        writeFile (root </> "inner" </> ".aapms") "not a directory"
        canonRoot <- canonicalizePath root
        r <- detectVault (root </> "inner")
        r `shouldBe` Just canonRoot

    it "test_detect_vault_creates_nothing (X7, L4): 呼叫前後整棵目錄樹逐位元組相同" $
      withTempHubDir $ \root -> do
        writeVaultMarker root (markerTomlText "vlt-7f3b2a91" "asset" "alchbees-assets" [])
        createDirectoryIfMissing True (root </> "a" </> "b" </> "c")
        snapBefore <- snapshotTree root
        _ <- detectVault (root </> "a" </> "b" </> "c")
        snapAfter <- snapshotTree root
        snapAfter `shouldBe` snapBefore

  --------------------------------------------------------------------------
  describe "T2/L6-L9/X8-X13: lookupSelector selector 解析" $ do
    it "test_lookup_selector_id_beats_name (X8, L6): id 命中時 name 完全不參與" $ do
      let e1 = VaultEntry (VaultId "vlt-7f3b2a91") "alchbees-assets" AssetVault "C:/a"
          e2 = VaultEntry (VaultId "vlt-a0c4e1f8") "vlt-7f3b2a91" StoryVault "C:/b"
          h = mkHub [e1, e2] [] Nothing (ToolsConfig Nothing) ""
      lookupSelector h "vlt-7f3b2a91" `shouldBe` Right e1

    it "L6(property): byId 非空時,把 byName 那些列的 veName 任意換掉,結果不變" $
      hedgehog $ do
        others <- forAll (Gen.list (Range.linear 0 3) genVaultEntry)
        targetId <- forAll genVaultId
        targetName <- forAll genName
        colliderId <- forAll (Gen.filter (/= targetId) genVaultId)
        changedName <- forAll (Gen.filter (/= vaultIdText targetId) genName)
        let s = vaultIdText targetId
            target = VaultEntry targetId targetName AssetVault "C:/target"
            collider0 = VaultEntry colliderId s StoryVault "C:/collider"
            rest = filter ((/= targetId) . veId) . filter ((/= colliderId) . veId) $ others
            h0 = mkHub (target : collider0 : rest) [] Nothing (ToolsConfig Nothing) ""
            collider1 = collider0 {veName = changedName}
            h1 = mkHub (target : collider1 : rest) [] Nothing (ToolsConfig Nothing) ""
        lookupSelector h0 s === Right target
        lookupSelector h1 s === Right target

    it "test_lookup_selector_ambiguous_lists_all (X9, L7): 撞名回全部候選列,順序同中樞" $ do
      let e3 = VaultEntry (VaultId "vlt-11112222") "lore" AssetVault "C:/e3"
          e4 = VaultEntry (VaultId "vlt-33334444") "lore" StoryVault "C:/e4"
          h = mkHub [e3, e4] [] Nothing (ToolsConfig Nothing) ""
      lookupSelector h "lore" `shouldBe` Left (VaultSelectorAmbiguous "lore" [e3, e4])

    it "L7(property): 任意 n>=2 列撞同一個 veName 時,Ambiguous 的清單逐列等於全部撞名列、順序不變" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 2 5))
        name <- forAll genName
        ids <- forAll (genDistinctVaultIds n)
        kinds <- forAll (Gen.list (Range.singleton n) genVaultKind)
        paths <- forAll (Gen.list (Range.singleton n) genAbsPath)
        let vs = zipWith3 (\i k p -> VaultEntry i name k p) ids kinds paths
            h = mkHub vs [] Nothing (ToolsConfig Nothing) ""
        lookupSelector h name === Left (VaultSelectorAmbiguous name vs)

    it "test_lookup_selector_not_found (X10, L7): 兩階段都沒命中回 NotFound" $ do
      let h = mkHub [sampleVault1] [] Nothing (ToolsConfig Nothing) ""
      lookupSelector h "nope" `shouldBe` Left (VaultSelectorNotFound "nope")

    it "L7(property): 任意 hub 與任意兩階段都不命中的 s,回 VaultSelectorNotFound s" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 0 5) genVaultEntry)
        s <-
          forAll
            ( Gen.filter
                (\s' -> notElem s' (map (vaultIdText . veId) vs) && notElem s' (map veName vs))
                genName
            )
        let h = mkHub vs [] Nothing (ToolsConfig Nothing) ""
        lookupSelector h s === Left (VaultSelectorNotFound s)

    it "test_lookup_selector_is_case_sensitive (X11, L8): 大小寫不同時視為不同字串" $ do
      let h = mkHub [sampleVault1] [] Nothing (ToolsConfig Nothing) ""
      lookupSelector h "ALCHBEES-ASSETS" `shouldBe` Left (VaultSelectorNotFound "ALCHBEES-ASSETS")

    it "L8(property): 任意 entry,veId 的大寫翻轉版本(vlt- 前綴保證與原字串不同)一律 NotFound" $
      hedgehog $ do
        e <- forAll genVaultEntry
        let idFlipped = T.toUpper (vaultIdText (veId e))
            h = mkHub [e] [] Nothing (ToolsConfig Nothing) ""
        (idFlipped /= vaultIdText (veId e)) === True
        lookupSelector h idFlipped === Left (VaultSelectorNotFound idFlipped)

    it "test_lookup_selector_does_not_trim (X12, L8): 前後空白不去除" $ do
      let h = mkHub [sampleVault1] [] Nothing (ToolsConfig Nothing) ""
      lookupSelector h " alchbees-assets " `shouldBe` Left (VaultSelectorNotFound " alchbees-assets ")

    it "L8(property): 任意 entry,veName 前後加空白後查詢一律 NotFound" $
      hedgehog $ do
        e <- forAll genVaultEntry
        pad <- forAll (Gen.text (Range.linear 1 2) (pure ' '))
        let padded = pad <> veName e <> pad
            h = mkHub [e] [] Nothing (ToolsConfig Nothing) ""
        lookupSelector h padded === Left (VaultSelectorNotFound padded)

    it "test_lookup_selector_ignores_other_sections (X13, L9): 換掉 projects/llm/tools/原始文字,結果不變" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 0 5) genVaultEntry)
        s <- forAll genName
        ps1 <- forAll (Gen.list (Range.linear 0 3) genProjectEntry)
        ps2 <- forAll (Gen.list (Range.linear 0 3) genProjectEntry)
        llm1 <- forAll (Gen.maybe genLlmSection)
        llm2 <- forAll (Gen.maybe genLlmSection)
        tools1 <- forAll genToolsConfig
        tools2 <- forAll genToolsConfig
        txt1 <- forAll genHubSourceText
        txt2 <- forAll genHubSourceText
        let h1 = mkHub vs ps1 llm1 tools1 txt1
            h2 = mkHub vs ps2 llm2 tools2 txt2
        lookupSelector h1 s === lookupSelector h2 s

  --------------------------------------------------------------------------
  describe "T3/L10-L13/X14-X18: readVaultRef 重讀 marker(已註冊的一列)" $ do
    it "test_read_vault_ref_marker_is_truth (X14, L10): vrMarker 一律來自檔案,中樞欄位換掉不影響" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        let e = VaultEntry (VaultId "vlt-7f3b2a91") "stale" StoryVault v
        r <- readVaultRef e v
        canonV <- canonicalizePath v
        case r of
          Right ref -> do
            vmName (vrMarker ref) `shouldBe` "real"
            vmKind (vrMarker ref) `shouldBe` AssetVault
            vrEntry ref `shouldBe` Just e
            vrPath ref `shouldBe` canonV
          Left issue -> expectationFailure ("預期 Right,得到 " <> show issue)

    it "L10(property): 把 e 的 veName/veKind 換成與 marker 不同的任何值後重跑,vrMarker 逐欄不變" $
      hedgehog $ do
        vid <- forAll genVaultId
        markerName <- forAll genName
        markerKind <- forAll genVaultKind
        entryName1 <- forAll (Gen.filter (/= markerName) genName)
        entryName2 <- forAll (Gen.filter (\n -> n /= markerName && n /= entryName1) genName)
        let entryKind = if markerKind == AssetVault then StoryVault else AssetVault
        refs <- forAll genRefIds
        result <- liftIO $ withTempHubDir $ \v -> do
          writeVaultMarker v (markerTomlText (vaultIdText vid) (renderVaultKind markerKind) markerName refs)
          let e1 = VaultEntry vid entryName1 entryKind v
              e2 = VaultEntry vid entryName2 entryKind v
          r1 <- readVaultRef e1 v
          r2 <- readVaultRef e2 v
          pure (r1, r2)
        case result of
          (Right ref1, Right ref2) -> vrMarker ref1 === vrMarker ref2
          other -> annotate (show other) >> failure

    it "test_read_vault_ref_fields_on_success (L11): 成功時 vrEntry == Just e、vrPath 是正規化路徑、vmId == veId e" $
      hedgehog $ do
        e <- forAll genVaultEntry
        markerName <- forAll genName
        markerKind <- forAll genVaultKind
        refs <- forAll genRefIds
        (result, canonV) <- liftIO $ withTempHubDir $ \v -> do
          writeVaultMarker v (markerTomlText (vaultIdText (veId e)) (renderVaultKind markerKind) markerName refs)
          canonV <- canonicalizePath v
          r <- readVaultRef e v
          pure (r, canonV)
        case result of
          Right ref -> do
            vrEntry ref === Just e
            vrPath ref === canonV
            vmId (vrMarker ref) === veId e
          Left issue -> annotate (show issue) >> failure

    it "test_read_vault_ref_path_missing (X15, L12a): 路徑不存在回 VaultPathMissing e (正規化後的路徑)" $
      withTempHubDir $ \parent -> do
        let x = parent </> "does-not-exist"
            e = sampleVault1 {vePath = x}
        canonX <- canonicalizePath x
        r <- readVaultRef e x
        r `shouldBe` Left (VaultPathMissing e canonX)

    it "L12a(property): 任意 e 與任意不存在的路徑,回 VaultPathMissing e (p 的正規化)" $
      hedgehog $ do
        e <- forAll genVaultEntry
        segs <- forAll (Gen.list (Range.linear 1 3) genSegment)
        (result, canonX) <- liftIO $ withTempHubDir $ \parent -> do
          let x = joinSegs parent segs
          canonX <- canonicalizePath x
          r <- readVaultRef e x
          pure (r, canonX)
        result === Left (VaultPathMissing e canonX)

    it "test_read_vault_ref_marker_broken_carries_original (X16, L12b): .aapms/ 在但沒有 config.toml" $
      withTempHubDir $ \v -> do
        createDirectoryIfMissing True (v </> ".aapms")
        let e = sampleVault1 {vePath = v}
        canonV <- canonicalizePath v
        expected <- readMarker canonV
        r <- readVaultRef e v
        case (r, expected) of
          (Left (VaultMarkerBroken e' err), Left expectedErr) -> do
            e' `shouldBe` e
            err `shouldBe` expectedErr
          other -> expectationFailure ("預期兩者都失敗且相符,得到 " <> show other)

    it "X17/L12b: kind 欄位不合規時,VaultMarkerBroken 捧著與 readMarker 逐欄相同的 StoreError" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (T.unlines ["id = \"vlt-7f3b2a91\"", "kind = \"media\"", "name = \"a\"", "refs = []"])
        let e = sampleVault1 {vePath = v}
        canonV <- canonicalizePath v
        expected <- readMarker canonV
        r <- readVaultRef e v
        case (r, expected) of
          (Left (VaultMarkerBroken e' err), Left expectedErr) -> do
            e' `shouldBe` e
            err `shouldBe` expectedErr
          other -> expectationFailure ("預期兩者都失敗且相符,得到 " <> show other)

    it "test_read_vault_ref_id_drift (X18, L12c): marker 的 id 與中樞不符時回 VaultIdDrift,帶 marker 裡的 id" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (markerTomlText "vlt-aaaa1111" "asset" "a" [])
        let e = sampleVault1 {veId = VaultId "vlt-bbbb2222", vePath = v}
        r <- readVaultRef e v
        r `shouldBe` Left (VaultIdDrift e (VaultId "vlt-aaaa1111"))

    it "L12c(property): 任意兩個不同 id,marker 用其一、中樞用另一,回 VaultIdDrift e (marker 的 id)" $
      hedgehog $ do
        markerId <- forAll genVaultId
        entryId <- forAll (Gen.filter (/= markerId) genVaultId)
        e0 <- forAll genVaultEntry
        markerName <- forAll genName
        markerKind <- forAll genVaultKind
        (result, e') <- liftIO $ withTempHubDir $ \v -> do
          writeVaultMarker v (markerTomlText (vaultIdText markerId) (renderVaultKind markerKind) markerName [])
          let e = e0 {veId = entryId, vePath = v}
          r <- readVaultRef e v
          pure (r, e)
        result === Left (VaultIdDrift e' markerId)

    it "test_read_vault_ref_creates_nothing (L13): 無論成功或失敗,呼叫前後目錄樹逐位元組相同" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (markerTomlText "vlt-7f3b2a91" "asset" "a" [])
        let e = sampleVault1 {vePath = v}
        snapBefore <- snapshotTree v
        _ <- readVaultRef e v
        snapAfter <- snapshotTree v
        snapAfter `shouldBe` snapBefore

    it "L13(續): marker 讀不到(路徑不存在)時,readVaultRef 也不會把它建出來" $
      withTempHubDir $ \parent -> do
        let v = parent </> "missing-vault"
            e = sampleVault1 {vePath = v}
        snapBefore <- snapshotTree parent
        _ <- readVaultRef e v
        snapAfter <- snapshotTree parent
        snapAfter `shouldBe` snapBefore

  --------------------------------------------------------------------------
  describe "T4/L14-L15/X19-X22: readVaultRefAt 重讀 marker(只知道路徑)" $ do
    it "test_read_vault_ref_at_fills_entry_by_id (X19, L14): 中樞有 veId 等於 marker id 的列時 vrEntry 是 Just 那一列" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (markerTomlText "vlt-7f3b2a91" "asset" "a" [])
        let e = sampleVault1 {veId = VaultId "vlt-7f3b2a91", vePath = v}
            h = mkHub [e] [] Nothing (ToolsConfig Nothing) ""
        canonV <- canonicalizePath v
        r <- readVaultRefAt h v
        case r of
          Right ref -> do
            vrEntry ref `shouldBe` Just e
            vrPath ref `shouldBe` canonV
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "L14(property): 多列同一個 veId 時,回中樞裡第一列滿足條件的那一列" $
      hedgehog $ do
        vid <- forAll genVaultId
        e1raw <- forAll genVaultEntry
        e2raw <- forAll genVaultEntry
        others <- forAll (Gen.list (Range.linear 0 3) genVaultEntry)
        markerName <- forAll genName
        markerKind <- forAll genVaultKind
        let first = e1raw {veId = vid}
            second = e2raw {veId = vid}
            vs = first : second : filter ((/= vid) . veId) others
            h = mkHub vs [] Nothing (ToolsConfig Nothing) ""
        result <- liftIO $ withTempHubDir $ \v -> do
          writeVaultMarker v (markerTomlText (vaultIdText vid) (renderVaultKind markerKind) markerName [])
          readVaultRefAt h v
        case result of
          Right ref -> vrEntry ref === Just first
          Left err -> annotate (show err) >> failure

    it "test_read_vault_ref_at_unregistered_is_nothing (X20, L14): 中樞沒有任何列符合時 vrEntry 是 Nothing,vrMarker 仍來自檔案" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (markerTomlText "vlt-7f3b2a91" "asset" "a" [])
        let h = mkHub [] [] Nothing (ToolsConfig Nothing) ""
        r <- readVaultRefAt h v
        case r of
          Right ref -> do
            vrEntry ref `shouldBe` Nothing
            vmId (vrMarker ref) `shouldBe` VaultId "vlt-7f3b2a91"
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_read_vault_ref_at_ignores_path_match (X21, L14): 中樞的 vePath 等於 V 但 veId 不同時,vrEntry 仍是 Nothing" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (markerTomlText "vlt-7f3b2a91" "asset" "a" [])
        let e = sampleVault1 {veId = VaultId "vlt-deadbeef", vePath = v}
            h = mkHub [e] [] Nothing (ToolsConfig Nothing) ""
        r <- readVaultRefAt h v
        case r of
          Right ref -> vrEntry ref `shouldBe` Nothing
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_read_vault_ref_at_marker_unreadable (X22, L15): 路徑不存在時回 MarkerUnreadable,renderWorkspaceError 含路徑與原因" $
      withTempHubDir $ \parent -> do
        let x = parent </> "does-not-exist"
            h = mkHub [] [] Nothing (ToolsConfig Nothing) ""
        canonX <- canonicalizePath x
        expected <- readMarker canonX
        r <- readVaultRefAt h x
        case (r, expected) of
          (Left issue@(MarkerUnreadable p err), Left expectedErr) -> do
            p `shouldBe` canonX
            err `shouldBe` expectedErr
            let msg = renderWorkspaceError issue
            msg `shouldSatisfy` T.isInfixOf (T.pack canonX)
            msg `shouldSatisfy` T.isInfixOf (renderStoreError expectedErr)
          other -> expectationFailure ("預期兩者都失敗,得到 " <> show other)

  --------------------------------------------------------------------------
  describe "T5/L16-L17/X23-X24: 兩個讀取函式一致、refs 原樣捧著" $ do
    it "test_two_readers_agree (L16 前半): readVaultRefAt 命中的那一列餵回 readVaultRef,兩者逐欄相同" $
      hedgehog $ do
        e <- forAll genVaultEntry
        markerName <- forAll genName
        markerKind <- forAll genVaultKind
        result <- liftIO $ withTempHubDir $ \v -> do
          writeVaultMarker v (markerTomlText (vaultIdText (veId e)) (renderVaultKind markerKind) markerName [])
          let h = mkHub [e] [] Nothing (ToolsConfig Nothing) ""
          atRef <- orDie =<< readVaultRefAt h v
          refRef <- orDie =<< readVaultRef e v
          pure (atRef, refRef)
        let (atRef, refRef) = result
        vrEntry atRef === Just e
        refRef === atRef

    it "test_two_readers_agree (X23, L16 後半): readVaultRefAt 的 MarkerUnreadable 與 readVaultRef 的 VaultMarkerBroken 捧著同一個 err" $
      withTempHubDir $ \v -> do
        writeVaultMarker v (T.unlines ["id = \"vlt-7f3b2a91\"", "kind = \"media\"", "name = \"a\"", "refs = []"])
        let e = sampleVault1 {veId = VaultId "vlt-7f3b2a91", vePath = v}
            h = mkHub [e] [] Nothing (ToolsConfig Nothing) ""
        atResult <- readVaultRefAt h v
        refResult <- readVaultRef e v
        case (atResult, refResult) of
          (Left (MarkerUnreadable _ err1), Left (VaultMarkerBroken e' err2)) -> do
            e' `shouldBe` e
            err2 `shouldBe` err1
          other -> expectationFailure ("預期 (MarkerUnreadable, VaultMarkerBroken) 成對,得到 " <> show other)

    it "X24(字面例子): refs = [vlt-11112222, vlt-33334444] 時 vmRefs 逐項相符" $
      withTempHubDir $ \v -> do
        let e = sampleVault1 {vePath = v}
        writeVaultMarker
          v
          ( markerTomlText
              (vaultIdText (veId sampleVault1))
              (renderVaultKind (veKind sampleVault1))
              (veName sampleVault1)
              ["vlt-11112222", "vlt-33334444"]
          )
        r <- orDie =<< readVaultRef e v
        vmRefs (vrMarker r) `shouldBe` [VaultId "vlt-11112222", VaultId "vlt-33334444"]

    it "test_refs_carried_verbatim_not_expanded (L17): vmRefs 逐項等於檔案裡的 refs,且不影響 vrEntry" $
      hedgehog $ do
        e <- forAll genVaultEntry
        markerName <- forAll genName
        markerKind <- forAll genVaultKind
        refs <- forAll genRefIds
        withRefs <- liftIO $ withTempHubDir $ \v -> do
          writeVaultMarker v (markerTomlText (vaultIdText (veId e)) (renderVaultKind markerKind) markerName refs)
          orDie =<< readVaultRef e v
        withoutRefs <- liftIO $ withTempHubDir $ \v -> do
          writeVaultMarker v (markerTomlText (vaultIdText (veId e)) (renderVaultKind markerKind) markerName [])
          orDie =<< readVaultRef e v
        vmRefs (vrMarker withRefs) === map VaultId refs
        vrEntry withRefs === Just e
        vrEntry withoutRefs === Just e

  --------------------------------------------------------------------------
  describe "L18(預期綠): 依賴方向與職責界線,以 import 行驗證" $ do
    it "test_discovery_no_downstream_or_location_imports(a): 本套件內的 import 只能是 \
       \Aapms.Workspace.Types 或 Aapms.Workspace.Hub" $ do
      importLines <- discoveryImportLines
      let sibling = filter (\l -> "Aapms.Workspace." `isPrefixOf` moduleNameOf l) importLines
      mapM_ (\l -> moduleNameOf l `shouldSatisfy` (`elem` ["Aapms.Workspace.Types", "Aapms.Workspace.Hub"])) sibling

    it "test_discovery_marker_import_is_id_reader_only(b): 若有 import Aapms.Store.Marker,\
       \必須逐字是 \"import Aapms.Store.Marker (VaultMarker (vmId), markerDir, readMarker)\" \
       \(守「Discovery 只讀 id」:VaultMarker (..) 或多列 vmKind/vmName/vmRefs 任何一個都要紅)" $ do
      importLines <- discoveryImportLines
      let markerLines = filter (\l -> moduleNameOf l == "Aapms.Store.Marker") importLines
      markerLines `shouldSatisfy` all (== "import Aapms.Store.Marker (VaultMarker (vmId), markerDir, readMarker)")

    it "test_discovery_never_imports_atomic(c): 完全不得 import Aapms.Store.Atomic" $ do
      importLines <- discoveryImportLines
      mapM_ (\l -> moduleNameOf l `shouldNotBe` "Aapms.Store.Atomic") importLines

    it "test_discovery_never_imports_index_modules(d): 完全不得 import Aapms.Store 門面 / Schema / \
       \Index / MultiVault / Query / Write / Create" $ do
      importLines <- discoveryImportLines
      let forbidden =
            [ "Aapms.Store"
            , "Aapms.Store.Schema"
            , "Aapms.Store.Index"
            , "Aapms.Store.MultiVault"
            , "Aapms.Store.Query"
            , "Aapms.Store.Write"
            , "Aapms.Store.Create"
            ]
      mapM_ (\l -> moduleNameOf l `shouldSatisfy` (`notElem` forbidden)) importLines

    it "test_discovery_no_process_import(e): 完全不得 import System.Process" $ do
      importLines <- discoveryImportLines
      mapM_ (\l -> moduleNameOf l `shouldNotBe` "System.Process") importLines
