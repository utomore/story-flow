-- | lawful 測試:P-006-workspace-doctor(qa 填入)。
--
-- 每條 law 一個 @describe "P-006#LAW-n"@ 的 property,每個 example 一個
-- @describe "P-006#EX-n"@。斷言逐字照 pipeline 文檔的 @|-@ 行翻譯。
--
-- 產生器只用型別層的建構入口('mkHub'、'VaultEntry' \/ 'VaultMarker' \/
-- 'MarkerWorld' \/ 'ToolWorld' \/ 'ToolSearchPlan' \/ 'ToolsConfig' \/
-- 'HubLocation' \/ 'Session' 的建構子、'VaultId' 與 'NamingVocab',以及
-- 'buildRegistry')組合法值,不引用任何受測模組的本體。
--
-- 尺寸全部有上限(vault 清單 ≤ 4、PATH 目錄 ≤ 3、內建候選 ≤ 3、可執行檔 ≤ 4,
-- 路徑與 id 取自固定池),每個項目另有 60 秒逾時。
--
-- @=@ 列 'doctor' 是 'Aapms.Workspace.Effect.Markers.Markers' 與
-- 'Aapms.Workspace.Effect.ToolProbe.ToolProbe' 兩個效果的程式,一律以觀察點
-- 'simulateDoctor'(兩個純解譯器跑到底)求值,測試不碰 IO。
module Aapms.Lawful.P006Spec (spec) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Data.List (find, isInfixOf, isPrefixOf, nub)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath ((</>))
import qualified System.Timeout as Timeout

import Test.Hspec
import Test.Hspec.Hedgehog
import qualified Hedgehog.Gen as Gen

import Aapms.Core.Id (VaultId (..))
import Aapms.Core.Name (NamingVocab (..))
import Aapms.Core.Registry (TypeRegistry, buildRegistry)
import Aapms.Service.Machine.Internal (markerIssues, simulateDoctor)
import Aapms.Service.Machine.View (doctor)
import Aapms.Service.Types (DoctorView (..), Session (..), VaultView (..))
import Aapms.Store.Types (StoreError (..), VaultKind (..), VaultMarker (..))
import qualified Aapms.Types.Source as Src
import Aapms.Workspace.Resolve.Internal (nearestRoot)
import Aapms.Workspace.Tools.Plan (detectTool, probes)
import Aapms.Workspace.Types
  ( Hub
  , HubLocation (..)
  , HubSource (..)
  , LlmSection (..)
  , MarkerWorld (..)
  , ScopeIssue (..)
  , ToolOrigin (..)
  , ToolSearchPlan (..)
  , ToolStatus (..)
  , ToolWorld (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , hubLlm
  , hubVaults
  , mkHub
  , unreachableIds
  , worldMarker
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
        ("P-006 測試項目超過 " <> show (itemTimeoutMicros `div` 1000000) <> " 秒未結束")

itemTimeoutMicros :: Int
itemTimeoutMicros = 60 * 1000 * 1000

--------------------------------------------------------------------------------
-- 尺寸上限常數
--------------------------------------------------------------------------------

-- | 一份中樞最多幾列 @[[vaults]]@。
maxVaults :: Int
maxVaults = 4

-- | 一份計畫最多幾個 PATH 目錄。
maxPathDirs :: Int
maxPathDirs = 3

-- | 一份計畫最多幾個內建候選。
maxCandidates :: Int
maxCandidates = 3

-- | 一個世界最多幾個可執行檔。
maxExecutables :: Int
maxExecutables = 4

--------------------------------------------------------------------------------
-- Laws
--------------------------------------------------------------------------------

lawsSpec :: Spec
lawsSpec = do
  describe "P-006#LAW-1" $
    it "relation:六欄的來源——hub 路徑與來源、註冊表來源、issues、llm 有無、tools 恰一筆" $
      hedgehog $ do
        (w, tw, s, plan) <- forAll genDoctorInputs
        let dv = simulateDoctor w tw (doctor s plan)
        dvHubPath dv === hlPath (sessionLocation s)
        dvHubSource dv === hlSource (sessionLocation s)
        dvRegistry dv === sessionSource s
        dvScopeIssues dv === markerIssues w (sessionHub s)
        dvLlmConfigured dv === isJust (hubLlm (sessionHub s))
        length (dvTools dv) === 1

  describe "P-006#LAW-2" $
    it "relation:前 n 筆 vault 逐列對應中樞,registered 恒真,reachable 當且僅當沒有 PathMissing / MarkerBroken 點到它" $
      hedgehog $ do
        (w, tw, s, plan) <- forAll genDoctorInputs
        let dv = simulateDoctor w tw (doctor s plan)
            n = length (hubVaults (sessionHub s))
            pairs = zip (take n (dvVaults dv)) (hubVaults (sessionHub s))
        annotateShow (length pairs)
        mapM_
          ( \(v, e) -> do
              vvId v === veId e
              vvName v === veName e
              vvKind v === veKind e
              vvPath v === vePath e
              assert (vvRegistered v)
              vvReachable v === notElem (veId e) (unreachableIds (dvScopeIssues dv))
          )
          pairs

  describe "P-006#LAW-3" $
    it "relation:未註冊那一筆——起點探測命中一個中樞沒有的 vault 時恰多一筆,否則沒有" $
      hedgehog $ do
        (w, tw, s, plan) <- forAll genDoctorInputs
        let dv = simulateDoctor w tw (doctor s plan)
            n = length (hubVaults (sessionHub s))
            extra = drop n (dvVaults dv)
            expectExtra =
              maybe
                False
                ( either
                    (const False)
                    (flip notElem (map veId (hubVaults (sessionHub s))) . vmId)
                )
                (maybe Nothing (worldMarker w) (nearestRoot w (sessionCwd s)))
        assert (length extra <= 1)
        assert (all (not . vvRegistered) extra)
        assert (all vvReachable extra)
        (length extra == 1) === expectExtra

  describe "P-006#LAW-4" $
    it "invariant:診斷不外洩 [llm] 內容,只有一個 Bool 說有沒有" $
      hedgehog $ do
        (w, tw, s, plan) <- forAll genDoctorInputs
        let dv = simulateDoctor w tw (doctor s plan)
        dvLlmConfigured dv === isJust (hubLlm (sessionHub s))

  describe "P-006#LAW-5" $
    it "relation:tsSearched 是候選清單的前綴,命中的在最後且是第一個可執行的;三層都不合格時走完整清單" $
      hedgehog $ do
        (plan, cfg, tw) <- forAll genToolScenario
        let ts = simulateDoctor mempty tw (detectTool plan cfg)
            ps = probes plan cfg
        annotateShow ps
        assert (isPrefixOf (tsSearched ts) ps)
        tsPath ts === find (flip elem (executables tw)) ps
        isNothing (tsPath ts) === (tsOrigin ts == NotFound)
        -- @isNothing (tsPath ts) => tsSearched ts == ps@
        assert (not (isNothing (tsPath ts)) || tsSearched ts == ps)
        assert (maybe True (== last (tsSearched ts)) (tsPath ts))

  describe "P-006#LAW-6" $
    it "relation:覆寫合格時後兩層完全不參與,結果與 plan 無關" $
      hedgehog $ do
        (plan, plan2, p, tw) <- forAll genOverrideScenario
        -- 前提由產生器直接建構,在這裡斷言出來,property 才不會恆真。
        assert (elem p (executables tw))
        let want = ToolStatus "7-Zip" (Just p) FromToolsConfig [p]
        simulateDoctor mempty tw (detectTool plan (ToolsConfig (Just p))) === want
        simulateDoctor mempty tw (detectTool plan2 (ToolsConfig (Just p))) === want

  describe "P-006#LAW-7" $
    it "invariant:候選清單跨層去重,覆寫那一筆是整份清單的前綴" $
      hedgehog $ do
        plan <- forAll genToolSearchPlan
        cfg <- forAll genToolsConfig
        let ps = probes plan cfg
        annotateShow ps
        nub ps === ps
        assert (isPrefixOf (maybe [] pure (tcSevenZip cfg)) ps)

  describe "P-006#LAW-8" $
    it "total:診斷唯讀,對任何輸入都求值得出來且不拋例外" $
      hedgehog $ do
        (w, tw, s, plan) <- forAll genDoctorInputs
        mustBeTotal (simulateDoctor w tw (doctor s plan))

--------------------------------------------------------------------------------
-- Examples
--------------------------------------------------------------------------------

examplesSpec :: Spec
examplesSpec = do
  describe "P-006#EX-1" $
    it "example:中樞 VA(story)與 VB(asset)都讀得到、起點在外面時兩筆皆 registered 且 reachable" $
      hedgehog $ do
        let h = mkHub [exVa, exVb] [] Nothing (ToolsConfig Nothing) ""
            w =
              markerWorldOf
                [ (exVaRoot, Right (markerFor exVa))
                , (exVbRoot, Right (markerFor exVb))
                ]
                []
            dv = simulateDoctor w emptyToolWorld (doctor (exSession h exOutside) exPlan)
        length (dvVaults dv) === 2
        map vvRegistered (dvVaults dv) === [True, True]
        map vvReachable (dvVaults dv) === [True, True]
        dvScopeIssues dv === []
        dvLlmConfigured dv === False

  describe "P-006#EX-2" $
    it "example:多一列 VC 指向不存在的路徑時,VC 那筆不可達且恰一則 VaultPathMissing" $
      hedgehog $ do
        let h = mkHub [exVa, exVb, exVc] [] Nothing (ToolsConfig Nothing) ""
            w =
              markerWorldOf
                [ (exVaRoot, Right (markerFor exVa))
                , (exVbRoot, Right (markerFor exVb))
                ]
                []
            dv = simulateDoctor w emptyToolWorld (doctor (exSession h exOutside) exPlan)
        map vvReachable (dvVaults dv) === [True, True, False]
        dvScopeIssues dv === [VaultPathMissing exVc exVcRoot]

  describe "P-006#EX-3" $
    it "example:VA 的 marker id 改成別的值時恰一則 VaultIdDrift,VA 那筆仍為可達" $
      hedgehog $ do
        let h = mkHub [exVa, exVb] [] Nothing (ToolsConfig Nothing) ""
            w =
              markerWorldOf
                [ (exVaRoot, Right ((markerFor exVa) {vmId = exOtherId}))
                , (exVbRoot, Right (markerFor exVb))
                ]
                []
            dv = simulateDoctor w emptyToolWorld (doctor (exSession h exOutside) exPlan)
        dvScopeIssues dv === [VaultIdDrift exVa exOtherId]
        map vvReachable (dvVaults dv) === [True, True]

  describe "P-006#EX-4" $
    it "example:中樞沒有 VA 而起點在 VA 底下時多一筆未註冊的 VA,起點在外面時沒有這一筆" $
      hedgehog $ do
        let h = mkHub [exVb] [] Nothing (ToolsConfig Nothing) ""
            w =
              markerWorldOf
                [ (exVaRoot, Right (markerFor exVa))
                , (exVbRoot, Right (markerFor exVb))
                ]
                [exVaSub]
            inside = simulateDoctor w emptyToolWorld (doctor (exSession h exVaSub) exPlan)
            outside = simulateDoctor w emptyToolWorld (doctor (exSession h exOutside) exPlan)
        length (dvVaults inside) === 2
        map vvRegistered (dvVaults inside) === [True, False]
        vvId (dvVaults inside !! 1) === exVaId
        vvReachable (dvVaults inside !! 1) === True
        length (dvVaults outside) === 1

  describe "P-006#EX-5" $
    it "example:中樞有 [llm] 時 dvLlmConfigured 為真,而診斷輸出不含哨兵字串" $
      hedgehog $ do
        let h =
              mkHub
                [exVa]
                []
                (Just (LlmSection mempty))
                (ToolsConfig Nothing)
                ("[llm]\napi_key = \"" <> sentinelText <> "\"\n")
            w = markerWorldOf [(exVaRoot, Right (markerFor exVa))] []
            dv = simulateDoctor w emptyToolWorld (doctor (exSession h exOutside) exPlan)
        dvLlmConfigured dv === True
        annotate (show dv)
        assert (not (isInfixOf sentinel (show dv)))

  describe "P-006#EX-6" $
    it "example:[tools] 未設、只有內建第二個可執行時走到它為止;全部不可執行時走完整份清單" $
      hedgehog $ do
        let plan = ToolSearchPlan ".exe" [exD1, exD2] [exC1, exC2]
            cfg = ToolsConfig Nothing
            ps = probes plan cfg
            hitWorld = ToolWorld [exC2] [exD1, exD2]
            missWorld = ToolWorld [] [exD1, exD2]
            tsHit = simulateDoctor mempty hitWorld (detectTool plan cfg)
            tsMiss = simulateDoctor mempty missWorld (detectTool plan cfg)
        annotateShow ps
        tsPath tsHit === Just exC2
        tsOrigin tsHit === FromCandidate
        tsSearched tsHit === takeThrough exC2 ps
        tsPath tsMiss === Nothing
        tsOrigin tsMiss === NotFound
        tsSearched tsMiss === ps

  describe "P-006#EX-7" $
    it "example:[tools] seven_zip 可執行時,兩份不同的 plan 給出同一筆 FromToolsConfig" $
      hedgehog $ do
        let p = "C:/x/7z.exe"
            cfg = ToolsConfig (Just p)
            plan = ToolSearchPlan ".exe" [exD1] [exC1]
            plan2 = ToolSearchPlan "" [] ["C:/other/7z"]
            tw = ToolWorld [p] []
            want = ToolStatus "7-Zip" (Just p) FromToolsConfig [p]
        simulateDoctor mempty tw (detectTool plan cfg) === want
        simulateDoctor mempty tw (detectTool plan2 cfg) === want

  describe "P-006#EX-8" $
    it "example:PATH 兩個目錄時第二段是 7z 全部再 7zz 全部,與內建候選重複的只留第一次" $
      hedgehog $ do
        let dup = exD1 </> "7z.exe"
            c = "C:/cand/7z.exe"
            plan = ToolSearchPlan ".exe" [exD1, exD2] [dup, c]
            cfg = ToolsConfig Nothing
        probes plan cfg
          === [ exD1 </> "7z.exe"
              , exD2 </> "7z.exe"
              , exD1 </> "7zz.exe"
              , exD2 </> "7zz.exe"
              , c
              ]

  describe "P-006#EX-9" $
    it "example:亂造的世界與快照不拋例外" $
      hedgehog $ do
        let h =
              mkHub
                [exVa, VaultEntry exVaId "" StoryVault ""]
                []
                (Just (LlmSection mempty))
                (ToolsConfig (Just ""))
                "亂"
            w =
              MarkerWorld
                ( M.fromList
                    [ ("", Left (VaultMarkerMissing ""))
                    , (exVaRoot, Right (VaultMarker exOtherId AssetVault "" [exVbId]))
                    ]
                )
                ["", exVaRoot]
            tw = ToolWorld ["", "C:/"] [""]
            plan = ToolSearchPlan "" [""] [""]
        mustBeTotal (simulateDoctor w tw (doctor (exSession h "") plan))

--------------------------------------------------------------------------------
-- total 的斷言
--------------------------------------------------------------------------------

-- | @total x@:把 @x@ 求值到正規形(以 'show' 逐字元展開)且不拋例外。
mustBeTotal :: Show a => a -> PropertyT IO ()
mustBeTotal x = do
  r <- evalIO (try (evaluate (length (show x))) :: IO (Either SomeException Int))
  case r of
    Left e -> do
      annotate (displayException e)
      failure
    Right _ -> success

--------------------------------------------------------------------------------
-- 產生器
--------------------------------------------------------------------------------

-- | 中樞每一列在世界裡的四種狀態。
data MarkerStatus
  = -- | marker 讀得到且 id 與中樞相符
    MOk
  | -- | marker 讀得到但 id 不同(仍可達)
    MDrift
  | -- | 路徑在、marker 讀不開
    MBroken
  | -- | 路徑不存在
    MMissing
  deriving stock (Show, Eq)

genMarkerStatus :: Gen MarkerStatus
genMarkerStatus = Gen.element [MOk, MOk, MDrift, MBroken, MMissing]

-- | 起點向上探測到的那個 vault 的三種可能。
data ExtraKind
  = -- | 探測不到任何東西
    ExtraAbsent
  | -- | 探測到一個中樞沒有的 vault
    ExtraUnregistered
  | -- | 探測到的其實是中樞裡的第一列
    ExtraRegistered
  deriving stock (Show, Eq)

genExtraKind :: Gen ExtraKind
genExtraKind = Gen.element [ExtraAbsent, ExtraUnregistered, ExtraRegistered]

namePool :: [Text]
namePool = ["alpha", "beta", "gamma", "delta"]

-- | 第 i 個 vault 的 id:@vlt-@ 加 8 位小寫十六進位。
idAt :: Int -> VaultId
idAt i = VaultId (T.pack ("vlt-0000000" <> show i))

-- | 第 i 個 vault 的根目錄。
rootAt :: Int -> FilePath
rootAt i = "C:/vaults/v" <> show i

genVaultEntryAt :: Int -> Gen VaultEntry
genVaultEntryAt i = do
  nm <- Gen.element namePool
  k <- Gen.element [AssetVault, StoryVault]
  pure VaultEntry {veId = idAt i, veName = nm, veKind = k, vePath = rootAt i}

genHubVaults :: Gen [VaultEntry]
genHubVaults = do
  ixs <- take maxVaults <$> Gen.subsequence [0 .. 7 :: Int]
  traverse genVaultEntryAt ixs

genHub :: Gen Hub
genHub = do
  vs <- genHubVaults
  llm <- Gen.maybe (pure (LlmSection mempty))
  tools <- genToolsConfig
  txt <- Gen.element ["", "# 中樞\n"]
  pure (mkHub vs [] llm tools txt)

-- | 空註冊表:'buildRegistry' 對空宣告清單恒為 'Right'。
emptyRegistry :: TypeRegistry
emptyRegistry = case buildRegistry [] of
  Right r -> r
  Left _ -> error "P-006 測試夾具:空的型別註冊表建不起來"

genSession :: Hub -> FilePath -> Gen Session
genSession h cwd = do
  hp <- Gen.element ["C:/hub", "D:/aapms"]
  hs <- Gen.element [FromEnv, FromPlatformDefault]
  rs <- Gen.element [Src.FromEnv, Src.BesideExecutable, Src.FromDataDir]
  sel <- Gen.maybe (Gen.element ["alpha", "vlt-00000001"])
  pure
    Session
      { sessionHub = h
      , sessionLocation = HubLocation {hlPath = hp, hlSource = hs}
      , sessionRegistry = emptyRegistry
      , sessionNaming = NamingVocab [] [] []
      , sessionSource = rs
      , sessionSelector = sel
      , sessionCwd = cwd
      }

-- | 探測到的那個 vault 的根目錄與 id(不在中樞的 id 池裡)。
probeRoot :: FilePath
probeRoot = "C:/vaults/v9"

probeId :: VaultId
probeId = VaultId "vlt-00000009"

-- | 漂移後的 id(不在中樞的 id 池裡)。
driftId :: VaultId
driftId = VaultId "vlt-000000ff"

-- | 世界裡一定存在的幾個祖先目錄。
baseDirs :: [FilePath]
baseDirs = ["C:/", "C:/vaults", exOutside]

markerFor :: VaultEntry -> VaultMarker
markerFor e = VaultMarker {vmId = veId e, vmKind = veKind e, vmName = veName e, vmRefs = []}

-- | 一個既存 vault 根目錄在世界裡佔的兩個目錄。
presentDirs :: FilePath -> [FilePath]
presentDirs p = [p, p </> ".aapms"]

-- | 從「路徑 → marker 讀數」的表組出世界:表上的路徑一律算既存目錄。
markerWorldOf :: [(FilePath, Either StoreError VaultMarker)] -> [FilePath] -> MarkerWorld
markerWorldOf rows extra =
  MarkerWorld
    { mwMarkers = M.fromList rows
    , worldDirs = baseDirs <> concatMap (presentDirs . fst) rows <> extra
    }

genDoctorInputs :: Gen (MarkerWorld, ToolWorld, Session, ToolSearchPlan)
genDoctorInputs = do
  h <- genHub
  let vs = hubVaults h
  sts <- traverse (const genMarkerStatus) vs
  ek <- genExtraKind
  let hubRows = concat (zipWith markerRowFor vs sts)
      probeRows = case ek of
        ExtraAbsent -> []
        ExtraUnregistered ->
          [(probeRoot, Right (VaultMarker probeId StoryVault "probe" []))]
        ExtraRegistered -> case vs of
          [] -> []
          (e : _) -> [(probeRoot, Right (markerFor e))]
  cwd <- Gen.element (exOutside : (probeRoot </> "sub") : map ((</> "sub") . vePath) vs)
  s <- genSession h cwd
  plan <- genToolSearchPlan
  tw <- genToolWorld (toolUniverse plan (ToolsConfig Nothing))
  pure (markerWorldOf (hubRows <> probeRows) [cwd], tw, s, plan)

markerRowFor :: VaultEntry -> MarkerStatus -> [(FilePath, Either StoreError VaultMarker)]
markerRowFor e st = case st of
  MOk -> [(vePath e, Right (markerFor e))]
  MDrift -> [(vePath e, Right ((markerFor e) {vmId = driftId}))]
  MBroken -> [(vePath e, Left (VaultMarkerInvalid (vePath e) "marker 欄位不合法"))]
  MMissing -> []

pathDirPool :: [FilePath]
pathDirPool = ["C:/bin", "C:/tools", "D:/apps"]

candidatePool :: [FilePath]
candidatePool = ["C:/Program Files/7-Zip/7z.exe", "C:/cand/7zz.exe", "C:/cand2/7z.exe"]

overridePool :: [FilePath]
overridePool = ["C:/x/7z.exe", "C:/y/7zz.exe", "D:/apps/7z.exe"]

genToolSearchPlan :: Gen ToolSearchPlan
genToolSearchPlan = do
  ext <- Gen.element [".exe", ""]
  ds <- take maxPathDirs <$> Gen.subsequence pathDirPool
  cs <- take maxCandidates <$> Gen.subsequence candidatePool
  pure ToolSearchPlan {tspExeExtension = ext, tspPathDirs = ds, tspCandidates = cs}

genToolsConfig :: Gen ToolsConfig
genToolsConfig = ToolsConfig <$> Gen.maybe (Gen.element overridePool)

-- | 產生器抽可執行檔的母體:偏向計畫裡真的會被探到的那些路徑,免得整條 law 都
-- 退化成 @NotFound@ 那一支。
toolUniverse :: ToolSearchPlan -> ToolsConfig -> [FilePath]
toolUniverse plan cfg =
  nub $
    maybe [] pure (tcSevenZip cfg)
      <> tspCandidates plan
      <> [d </> (nm <> tspExeExtension plan) | nm <- ["7z", "7zz"], d <- tspPathDirs plan]
      <> ["C:/junk/other.exe"]

genToolWorld :: [FilePath] -> Gen ToolWorld
genToolWorld universe = do
  exes <- take maxExecutables <$> Gen.subsequence universe
  ds <- Gen.subsequence pathDirPool
  pure ToolWorld {executables = exes, twPathDirs = ds}

genToolScenario :: Gen (ToolSearchPlan, ToolsConfig, ToolWorld)
genToolScenario = do
  plan <- genToolSearchPlan
  cfg <- genToolsConfig
  tw <- genToolWorld (toolUniverse plan cfg)
  pure (plan, cfg, tw)

-- | LAW-6 的前提 @elem p (executables tw)@ 由產生器直接建構,不用過濾。
genOverrideScenario :: Gen (ToolSearchPlan, ToolSearchPlan, FilePath, ToolWorld)
genOverrideScenario = do
  plan <- genToolSearchPlan
  plan2 <- genToolSearchPlan
  p <- Gen.element overridePool
  rest <- take maxExecutables <$> Gen.subsequence (toolUniverse plan (ToolsConfig (Just p)))
  ds <- Gen.subsequence pathDirPool
  pure (plan, plan2, p, ToolWorld {executables = nub (p : rest), twPathDirs = ds})

--------------------------------------------------------------------------------
-- Examples 的夾具
--------------------------------------------------------------------------------

exVaRoot, exVbRoot, exVcRoot, exVaSub, exOutside :: FilePath
exVaRoot = "C:/vaults/va"
exVbRoot = "C:/vaults/vb"
exVcRoot = "C:/vaults/vc"
exVaSub = exVaRoot </> "sub"
exOutside = "C:/outside"

exVaId, exVbId, exVcId, exOtherId :: VaultId
exVaId = VaultId "vlt-000000aa"
exVbId = VaultId "vlt-000000bb"
exVcId = VaultId "vlt-000000cc"
exOtherId = VaultId "vlt-000000ee"

exVa, exVb, exVc :: VaultEntry
exVa = VaultEntry {veId = exVaId, veName = "va", veKind = StoryVault, vePath = exVaRoot}
exVb = VaultEntry {veId = exVbId, veName = "vb", veKind = AssetVault, vePath = exVbRoot}
exVc = VaultEntry {veId = exVcId, veName = "vc", veKind = StoryVault, vePath = exVcRoot}

-- | 例子一律用不含任何工具的世界與空計畫:EX-1 到 EX-5 講的是 vault 那幾欄。
emptyToolWorld :: ToolWorld
emptyToolWorld = ToolWorld {executables = [], twPathDirs = []}

exPlan :: ToolSearchPlan
exPlan = ToolSearchPlan {tspExeExtension = ".exe", tspPathDirs = [], tspCandidates = []}

exSession :: Hub -> FilePath -> Session
exSession h cwd =
  Session
    { sessionHub = h
    , sessionLocation = HubLocation {hlPath = "C:/hub", hlSource = FromPlatformDefault}
    , sessionRegistry = emptyRegistry
    , sessionNaming = NamingVocab [] [] []
    , sessionSource = Src.BesideExecutable
    , sessionSelector = Nothing
    , sessionCwd = cwd
    }

-- | EX-5 的哨兵字串。
sentinel :: String
sentinel = "SENTINEL"

sentinelText :: Text
sentinelText = T.pack sentinel

exD1, exD2, exC1, exC2 :: FilePath
exD1 = "C:/d1"
exD2 = "C:/d2"
exC1 = "C:/cand1/7z.exe"
exC2 = "C:/cand2/7z.exe"

-- | 取到 @x@ 為止(含 @x@)的前綴;@x@ 不在清單裡時就是整份清單。
takeThrough :: Eq a => a -> [a] -> [a]
takeThrough x xs = takeWhile (/= x) xs <> take 1 (dropWhile (/= x) xs)
