-- | F006:'Aapms.Workspace.Tools' 的三層探測('detectSevenZipIn' 是主要受測對象——
-- 'detectSevenZip' 用內建常數,而這台機器上 @C:\\Program Files\\7-Zip\\7z.exe@ 實際
-- 存在,直接測它驗不到 'NotFound' 與 'FromCandidate')與依賴方向的 import 檢查(L15)。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F006-machine-tools.md@,
-- 預期依 spec-roles.md「qa 的交付判準」逐條標;骨架裡沒有任何不是 @undefined@ 的函數
-- 本體,所以除 L15(a)-(f) 與 'ToolSearchPlan' 型別本身的形狀外,__全部預期紅__):
--
-- @
-- L1  probe 前綴 \/ 命中在最後               -> prop_matches_spec_model                              [紅]
-- L2  覆寫合格時後兩層不參與                  -> test_x1_override_hit_short_circuits                  [紅]
--                                              -> test_x2_override_hit_ignores_plan                    [紅]
--                                              -> prop_l2_override_hit_ignores_arbitrary_plan           [紅]
-- L3  覆寫不合格時不中止                      -> test_x3_override_miss_continues_to_path              [紅]
--                                              -> prop_l3_override_miss_diffs_only_in_searched_prefix   [紅]
-- L4  三層都不合格 <=> NotFound                -> test_x7_not_found_when_all_layers_miss               [紅]
--                                              -> prop_matches_spec_model                               [紅]
-- L5  tsPath\/tsOrigin 不可能不一致            -> prop_l5_path_and_origin_consistent                    [紅]
--                                              -> prop_matches_spec_model                               [紅]
-- L6  tsOrigin 指得出哪一層(a\/b\/c)          -> test_x1.. (a) / test_x3,x4,x5 (b) / test_x6 (c)      [紅]
--                                              -> prop_matches_spec_model                               [紅]
-- L7  合格 = 存在且可執行,依此順序             -> test_x8_directory_never_qualifies (c)                [紅]
--                                              -> test_x9_non_executable_file_never_qualifies (b)       [紅]
--                                              -> test_x11_missing_path_dirs_do_not_throw_or_get_created (d) [紅]
--                                              -> prop_l7_non_executable_and_missing_never_qualify      [紅]
-- L8  逐字,不正規化                           -> test_x13_paths_are_verbatim_relative                  [紅]
--                                              -> test_x14_paths_are_verbatim_windows_absolute          [紅]
--                                              -> prop_l8_candidate_paths_are_verbatim                  [紅]
-- L9  依序、去重,跨層生效                      -> test_x10_same_path_across_layers_dedupes             [紅]
--                                              -> prop_matches_spec_model                               [紅]
-- L10 第二層展開式(名稱外層、目錄內層)        -> test_x4,x5,x6                                        [紅]
--                                              -> prop_matches_spec_model                               [紅]
-- L11 不執行、不動檔案系統                     -> test_x11,x12                                          [紅]
--                                              -> prop_l11_filesystem_untouched                         [紅]
-- L12 沒有失敗通道                             -> test_x7,x11                                           [紅]
--                                              -> prop_l12_missing_dirs_and_empty_string_do_not_throw   [紅]
-- L13 tsName 恒為 "7-Zip"                     -> test_x7 等多條 / prop_l13_tsname_constant             [紅]
-- L14 兩個入口一致                             -> test_x15,x16                                         [紅]
--                                              -> prop_l14_real_entry_matches_injected_plan_for_arbitrary_override [紅]
-- L15(預期綠) import 行(a)-(f)               -> test_tools_no_sibling_module_imports(a)               [綠]
--                                              -> test_tools_never_imports_process(b)                   [綠]
--                                              -> test_tools_never_imports_store_or_core(c)             [綠]
--                                              -> test_tools_directory_import_is_read_only(d)           [綠]
--                                              -> test_tools_environment_import_is_lookup_only(e)       [綠]
--                                              -> test_tools_filepath_import_is_whitelisted(f)          [綠]
-- X17 import 行滿足 L15(a)-(f)                -> 由上列六條 L15 測試涵蓋,不另立測試
--
-- ToolSearchPlan(預期綠) 骨架原文自身承載的型別事實
--                                              -> test_tool_search_plan_fields                          [綠]
--                                              -> test_tool_search_plan_eq_show                         [綠]
-- @
module Aapms.Workspace.ToolsSpec (spec) where

import Control.Monad (forM, forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.List (dropWhileEnd, isPrefixOf, nub)
import qualified Data.Text as T
import Hedgehog (Gen, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Workspace.Fixtures (readWorkspaceSource)
import Aapms.Workspace.Tools (ToolSearchPlan (..), detectSevenZip, detectSevenZipIn)
import Aapms.Workspace.Types
  ( ToolOrigin (FromCandidate, FromPath, FromToolsConfig, NotFound)
  , ToolStatus (ToolStatus, tsName, tsOrigin, tsPath, tsSearched)
  , ToolsConfig (ToolsConfig)
  )

import System.Directory
  ( createDirectory
  , doesDirectoryExist
  , doesFileExist
  , executable
  , exeExtension
  , getPermissions
  , listDirectory
  , setOwnerExecutable
  , setPermissions
  )
import System.Environment (lookupEnv)
import System.FilePath (splitSearchPath, (<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)

--------------------------------------------------------------------------------
-- 本檔專用 fixture helper(不匯出;不碰 Fixtures.hs)

-- | 一個空的臨時目錄,測完自動整個刪除。__不碰__真實的 @%APPDATA%\\aapms@。
withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "aapms-tools"

-- | 在指定路徑寫出一個「存在且可執行」的檔案(spec「數據 › 測試素材」的可攜作法:
-- 檔案本身的內容不重要——本 feature 承諾不執行任何找到的檔案,'setOwnerExecutable'
-- 在兩個平台上都是「讓它看起來可執行」的合法操作,Windows 上是否生效不影響判準,因為
-- Windows 的 'executable' 只看副檔名)。
mkQualifyingFileAt :: FilePath -> IO ()
mkQualifyingFileAt p = do
  writeFile p "not a real executable; this feature never runs what it finds"
  perms <- getPermissions p
  setPermissions p (setOwnerExecutable True perms)

-- | 在 @dir@ 下建一個檔名為 @name <.> exeExtension@ 的合格檔,回傳完整路徑。
mkQualifying :: FilePath -> String -> IO FilePath
mkQualifying dir name = do
  let p = dir </> (name <.> exeExtension)
  mkQualifyingFileAt p
  pure p

-- | 寫出一個存在、但**沒有**設任何執行權限的檔案。
mkNonExecutable :: FilePath -> IO FilePath
mkNonExecutable p = writeFile p "not executable" >> pure p

-- | 遞迴列出一個目錄底下所有檔案的相對路徑與內容(不含權限),按路徑排序——L11
-- 「呼叫前後檔案清單與內容相同」斷言的基礎。本檔的 fixture 一律是純文字,足夠使用。
snapshotFiles :: FilePath -> IO [(FilePath, String)]
snapshotFiles root = go ""
  where
    go rel = do
      let full = if null rel then root else root </> rel
      isDir <- doesDirectoryExist full
      if isDir
        then do
          entries <- listDirectory full
          concat <$> mapM (\e -> go (if null rel then e else rel </> e)) entries
        else do
          content <- readFile full
          pure [(rel, content)]

--------------------------------------------------------------------------------
-- 「數據」節的字面常數(逐字抄自 spec,獨立於任何實作)

-- | spec「數據 › 內建候選清單」的七條,逐字抄錄(L14\/X15 的比對基準;本檔__不__從
-- production 碼匯出這份清單來比,那會讓「impl 改了清單」變成恆真斷言)。
builtinCandidates :: [FilePath]
builtinCandidates =
  [ "C:\\Program Files\\7-Zip\\7z.exe"
  , "C:\\Program Files (x86)\\7-Zip\\7z.exe"
  , "/usr/bin/7z"
  , "/usr/local/bin/7z"
  , "/opt/homebrew/bin/7z"
  , "/usr/bin/7zz"
  , "/opt/homebrew/bin/7zz"
  ]

--------------------------------------------------------------------------------
-- 獨立於實作的「模型」:純粹翻譯 spec 的 Laws\/「三層探測的資料流」段落,
-- __不是__從 Tools.hs 讀來的——qa 不得讀那個檔案的本體,這裡只是把已經讀過的
-- spec 文字轉成可執行的判準,用來當 property test 的獨立 oracle。

-- | L7:「存在且可執行」判準,依此順序;對不存在的路徑不呼叫 'getPermissions'。
modelQualifies :: FilePath -> IO Bool
modelQualifies p = do
  exists <- doesFileExist p
  if exists then executable <$> getPermissions p else pure False

-- | L1\/L9\/L10:三層依序串起來、保序去重(跨層)。
modelProbes :: ToolSearchPlan -> ToolsConfig -> [FilePath]
modelProbes plan (ToolsConfig mOverride) = nub (l1 ++ l2 ++ l3)
  where
    l1 = maybe [] (: []) mOverride
    l2 = [d </> (n <.> exeExtension) | n <- ["7z", "7zz"], d <- tspPathDirs plan]
    l3 = tspCandidates plan

-- | L6:命中的路徑屬於哪一層,判定順序恒為覆寫 -> PATH -> 候選清單。
modelOrigin :: ToolSearchPlan -> ToolsConfig -> FilePath -> ToolOrigin
modelOrigin plan (ToolsConfig mOverride) p
  | mOverride == Just p = FromToolsConfig
  | p `elem` [d </> (n <.> exeExtension) | n <- ["7z", "7zz"], d <- tspPathDirs plan] = FromPath
  | otherwise = FromCandidate

-- | 依序對候選路徑問 'modelQualifies',命中即停;回傳「被問過的那段前綴」與命中的路徑。
modelFirstQualifying :: [FilePath] -> IO (Maybe FilePath, [FilePath])
modelFirstQualifying = go []
  where
    go acc [] = pure (Nothing, reverse acc)
    go acc (p : ps) = do
      ok <- modelQualifies p
      let acc' = p : acc
      if ok then pure (Just p, reverse acc') else go acc' ps

-- | 把 'modelProbes' \/ 'modelFirstQualifying' \/ 'modelOrigin' 組成完整的期望
-- 'ToolStatus'——這是 spec 全部 Laws(除 L2\/L3\/L7\/L8\/L11\/L12\/L14\/L15 的邊界情況外)
-- 的唯一真相翻譯。
modelDetect :: ToolSearchPlan -> ToolsConfig -> IO ToolStatus
modelDetect plan cfg = do
  let probes = modelProbes plan cfg
  (hit, searched) <- modelFirstQualifying probes
  pure $ case hit of
    Just p -> ToolStatus "7-Zip" (Just p) (modelOrigin plan cfg p) searched
    Nothing -> ToolStatus "7-Zip" Nothing NotFound searched

--------------------------------------------------------------------------------
-- hedgehog 產生器(本檔專用)

-- | 任意長度的路徑片段(英數字,1-6 字)。
genSegment :: Gen String
genSegment = T.unpack <$> Gen.text (Range.linear 1 6) (Gen.choice [Gen.alpha, Gen.digit])

-- | 一個隨機的探測「世界」:0-3 個 PATH 目錄(各自可能放合格的 7z\/7zz)、0-3 個候選檔
-- (各自可能合格)、可能有一個覆寫(可能合格)。合格與否只有兩種狀態:「合格」或「完全
-- 不存在」——「存在但不可執行」的情形由專門的 L7 property 覆蓋,不必混進通用模型。
data World = World
  { wDirs :: [(String, Bool, Bool)]
  , wCands :: [(String, Bool)]
  , wOverride :: Maybe (String, Bool)
  }
  deriving stock (Show)

genWorld :: Gen World
genWorld =
  World
    <$> Gen.list (Range.linear 0 3) ((,,) <$> genSegment <*> Gen.bool <*> Gen.bool)
    <*> Gen.list (Range.linear 0 3) ((,) <$> genSegment <*> Gen.bool)
    <*> Gen.maybe ((,) <$> genSegment <*> Gen.bool)

-- | 把 'World' 實際建到臨時目錄 @t@ 底下,回傳可以直接餵給 'detectSevenZipIn' 的
-- 'ToolSearchPlan' 與 'ToolsConfig'。
buildWorld :: FilePath -> World -> IO (ToolSearchPlan, ToolsConfig)
buildWorld t (World dirs cands mOverride) = do
  dirPaths <- forM (zip [0 :: Int ..] dirs) $ \(i, (name, has7z, has7zz)) -> do
    let d = t </> ("dir-" <> show i <> "-" <> name)
    createDirectory d
    when has7z (mkQualifyingFileAt (d </> ("7z" <.> exeExtension)))
    when has7zz (mkQualifyingFileAt (d </> ("7zz" <.> exeExtension)))
    pure d
  candPaths <- forM (zip [0 :: Int ..] cands) $ \(i, (name, ok)) -> do
    let p = t </> ("cand-" <> show i <> "-" <> name)
    when ok (mkQualifyingFileAt p)
    pure p
  overridePath <- case mOverride of
    Nothing -> pure Nothing
    Just (name, ok) -> do
      let p = t </> ("override-" <> name)
      when ok (mkQualifyingFileAt p)
      pure (Just p)
  pure (ToolSearchPlan dirPaths candPaths, ToolsConfig overridePath)

--------------------------------------------------------------------------------
-- L15:import 行(判準只看 import 行,不做全檔字串搜尋;比對前先去除行尾 \r)

-- | 一個骨架檔案裡,去除前導空白、去除行尾 @\\r@(CRLF checkout 的產物)之後、以
-- @import@ 起頭的行(做法對照 "Aapms.Workspace.DiscoverySpec.importLinesOf")。
importLinesOf :: FilePath -> IO [String]
importLinesOf rel = do
  src <- readWorkspaceSource rel
  let stripLine = dropWhile (== ' ') . dropWhileEnd (== '\r')
  pure (filter ("import" `isPrefixOf`) (map stripLine (lines (T.unpack src))))

-- | 從一行 import 取出被 import 的模組全名(不含子句清單)。
moduleNameOf :: String -> String
moduleNameOf l = takeWhile (\c -> c /= ' ' && c /= '(') (drop (length ("import " :: String)) l)

-- | 從一行 import 取出括號內的匯入清單,依「頂層逗號」切開(深度感知,運算子如
-- @(<.>)@ 的內部逗號——其實沒有逗號,但保守起見一樣不會被誤切)並去除前後空白。
-- 沒有括號(整個模組原樣 import,等同全面開放)回 'Nothing'。
importListOf :: String -> Maybe [String]
importListOf l = case break (== '(') l of
  (_, []) -> Nothing
  (_, _ : rest) -> case reverse rest of
    ')' : revBody -> Just (splitTopLevel (reverse revBody))
    _ -> Nothing
  where
    splitTopLevel s = map trim (go (0 :: Int) "" s)
      where
        go _ cur [] = [reverse cur]
        go depth cur (c : cs)
          | c == '(' = go (depth + 1) (c : cur) cs
          | c == ')' = go (depth - 1) (c : cur) cs
          | c == ',' && depth == (0 :: Int) = reverse cur : go depth "" cs
          | otherwise = go depth (c : cur) cs
    trim = dropWhile (== ' ') . dropWhileEnd (== ' ')

toolsImportLines :: IO [String]
toolsImportLines = importLinesOf "Aapms/Workspace/Tools.hs"

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F006 Aapms.Workspace.Tools" $ do
  --------------------------------------------------------------------------
  describe "Examples (X1-X16): detectSevenZipIn / detectSevenZip" $ do
    it "test_x1_override_hit_short_circuits (X1; L1,L2,L5,L6a,L13)" $
      withTempDir $ \t -> do
        e1 <- mkQualifying t "seven"
        let d = t </> "d"
        createDirectory d
        _ <- mkQualifying d "7z"
        c <- mkQualifying t "cand"
        result <- detectSevenZipIn (ToolSearchPlan [d] [c]) (ToolsConfig (Just e1))
        result `shouldBe` ToolStatus "7-Zip" (Just e1) FromToolsConfig [e1]

    it "test_x2_override_hit_ignores_plan (X2; L2)" $
      withTempDir $ \t -> do
        e1 <- mkQualifying t "seven"
        result <- detectSevenZipIn (ToolSearchPlan [] []) (ToolsConfig (Just e1))
        result `shouldBe` ToolStatus "7-Zip" (Just e1) FromToolsConfig [e1]

    it "test_x3_override_miss_continues_to_path (X3; L1,L3,L6b,L7a)" $
      withTempDir $ \t -> do
        let d = t </> "d"
        createDirectory d
        s <- mkQualifying d "7z"
        let p = t </> "nope.exe"
        result <- detectSevenZipIn (ToolSearchPlan [d] []) (ToolsConfig (Just p))
        result `shouldBe` ToolStatus "7-Zip" (Just s) FromPath [p, s]

    it "test_x4_path_layer_hit_second_dir (X4; L1,L6b,L10)" $
      withTempDir $ \t -> do
        let d1 = t </> "d1"
            d2 = t </> "d2"
        createDirectory d1
        createDirectory d2
        s2 <- mkQualifying d2 "7z"
        result <- detectSevenZipIn (ToolSearchPlan [d1, d2] []) (ToolsConfig Nothing)
        tsPath result `shouldBe` Just s2
        tsOrigin result `shouldBe` FromPath
        tsSearched result `shouldBe` [d1 </> ("7z" <.> exeExtension), s2]

    it "test_x5_probe_order_name_outer_dir_inner (X5; L1,L10)" $
      withTempDir $ \t -> do
        let d1 = t </> "d1"
            d2 = t </> "d2"
        createDirectory d1
        createDirectory d2
        _ <- mkQualifying d1 "7zz"
        s2 <- mkQualifying d2 "7z"
        result <- detectSevenZipIn (ToolSearchPlan [d1, d2] []) (ToolsConfig Nothing)
        tsPath result `shouldBe` Just s2
        tsOrigin result `shouldBe` FromPath
        tsSearched result `shouldBe` [d1 </> ("7z" <.> exeExtension), s2]

    it "test_x6_candidate_layer_hit (X6; L1,L6c,L10)" $
      withTempDir $ \t -> do
        let d = t </> "d"
        createDirectory d
        let c1 = t </> "c1-missing"
        c2 <- mkQualifying t "c2"
        result <- detectSevenZipIn (ToolSearchPlan [d] [c1, c2]) (ToolsConfig Nothing)
        tsOrigin result `shouldBe` FromCandidate
        tsPath result `shouldBe` Just c2
        tsSearched result
          `shouldBe` [ d </> ("7z" <.> exeExtension)
                     , d </> ("7zz" <.> exeExtension)
                     , c1
                     , c2
                     ]

    it "test_x7_not_found_when_all_layers_miss (X7; L4,L5,L12,L13)" $
      withTempDir $ \t -> do
        let d = t </> "d"
        createDirectory d
        let c1 = t </> "c1-missing"
        result <- detectSevenZipIn (ToolSearchPlan [d] [c1]) (ToolsConfig Nothing)
        result
          `shouldBe` ToolStatus
            "7-Zip"
            Nothing
            NotFound
            [ d </> ("7z" <.> exeExtension)
            , d </> ("7zz" <.> exeExtension)
            , c1
            ]

    it "test_x8_directory_never_qualifies (X8; L7c,L9)" $
      withTempDir $ \t -> do
        let b = t </> ("bogus" <.> exeExtension)
        createDirectory b
        result <- detectSevenZipIn (ToolSearchPlan [] [b]) (ToolsConfig (Just b))
        result `shouldBe` ToolStatus "7-Zip" Nothing NotFound [b]

    it "test_x9_non_executable_file_never_qualifies (X9; L7b,L9)" $
      withTempDir $ \t -> do
        let n = t </> "seven.txt"
        _ <- mkNonExecutable n
        result <- detectSevenZipIn (ToolSearchPlan [] [n]) (ToolsConfig (Just n))
        result `shouldBe` ToolStatus "7-Zip" Nothing NotFound [n]

    it "test_x10_same_path_across_layers_dedupes (X10; L9)" $
      withTempDir $ \t -> do
        let c1 = t </> "c1-missing"
        result <- detectSevenZipIn (ToolSearchPlan [] [c1, c1]) (ToolsConfig (Just c1))
        result `shouldBe` ToolStatus "7-Zip" Nothing NotFound [c1]

    it "test_x11_missing_path_dirs_do_not_throw_or_get_created (X11; L11a,L12)" $
      withTempDir $ \t -> do
        let x = t </> "gone"
            alsoGone = t </> "also-gone.exe"
        result <- detectSevenZipIn (ToolSearchPlan [x] [alsoGone]) (ToolsConfig Nothing)
        result
          `shouldBe` ToolStatus
            "7-Zip"
            Nothing
            NotFound
            [ x </> ("7z" <.> exeExtension)
            , x </> ("7zz" <.> exeExtension)
            , alsoGone
            ]
        existsAfter <- doesDirectoryExist x
        existsAfter `shouldBe` False

    it "test_x12_never_executes_the_found_file (X12; L11)" $
      withTempDir $ \t -> do
        let d = t </> "d"
        createDirectory d
        let r = d </> ("7z" <.> exeExtension)
            ran = d </> "RAN"
        mkQualifyingFileAt r
        before <- snapshotFiles t
        result <- detectSevenZipIn (ToolSearchPlan [d] []) (ToolsConfig Nothing)
        after <- snapshotFiles t
        tsOrigin result `shouldBe` FromPath
        tsPath result `shouldBe` Just r
        ranExists <- doesFileExist ran
        ranExists `shouldBe` False
        after `shouldBe` before

    it "test_x13_paths_are_verbatim_relative (X13; L8)" $ do
      result <- detectSevenZipIn (ToolSearchPlan [] ["relative/7z.exe"]) (ToolsConfig (Just "sub dir/7z.exe"))
      tsSearched result `shouldBe` ["sub dir/7z.exe", "relative/7z.exe"]

    it "test_x14_paths_are_verbatim_windows_absolute (X14; L8)" $ do
      result <- detectSevenZipIn (ToolSearchPlan [] ["C:\\Program Files\\7-Zip\\7z.exe"]) (ToolsConfig Nothing)
      tsSearched result `shouldBe` ["C:\\Program Files\\7-Zip\\7z.exe"]

    it "test_x15_real_entry_matches_injected_plan (X15; L14)" $ do
      let cfg = ToolsConfig Nothing
      pathEnv <- lookupEnv "PATH"
      let dirs = maybe [] splitSearchPath pathEnv
      real <- detectSevenZip cfg
      injected <- detectSevenZipIn (ToolSearchPlan dirs builtinCandidates) cfg
      real `shouldBe` injected

    it "test_x16_real_entry_config_override_short_circuits (X16; L2,L14)" $
      withTempDir $ \t -> do
        e <- mkQualifying t "seven"
        result <- detectSevenZip (ToolsConfig (Just e))
        result `shouldBe` ToolStatus "7-Zip" (Just e) FromToolsConfig [e]

  --------------------------------------------------------------------------
  describe "Laws (property tests)" $ do
    it "prop_matches_spec_model(L1,L4,L5,L6,L9,L10,L13): 任意 world,detectSevenZipIn 與\
       \獨立翻譯 spec 的模型逐欄相同" $
      hedgehog $ do
        world <- forAll genWorld
        (actual, expected) <- liftIO $ withTempDir $ \t -> do
          (plan, cfg) <- buildWorld t world
          actual <- detectSevenZipIn plan cfg
          expected <- modelDetect plan cfg
          pure (actual, expected)
        actual === expected

    it "prop_l2_override_hit_ignores_arbitrary_plan(L2): 覆寫合格時,任意 plan(含另一個\
       \合格的競爭者)都不影響結果" $
      hedgehog $ do
        dirNames <- forAll (Gen.list (Range.linear 0 3) genSegment)
        candNames <- forAll (Gen.list (Range.linear 0 3) genSegment)
        (withPlan, withoutPlan) <- liftIO $ withTempDir $ \t -> do
          e <- mkQualifying t "override"
          dirs <- forM (zip [0 :: Int ..] dirNames) $ \(i, n) -> do
            let d = t </> ("d-" <> show i <> "-" <> n)
            createDirectory d
            _ <- mkQualifying d "7z"
            pure d
          cands <- forM (zip [0 :: Int ..] candNames) $ \(i, n) -> mkQualifying t ("c-" <> show i <> "-" <> n)
          r1 <- detectSevenZipIn (ToolSearchPlan dirs cands) (ToolsConfig (Just e))
          r2 <- detectSevenZipIn (ToolSearchPlan [] []) (ToolsConfig (Just e))
          pure (r1, r2)
        withPlan === withoutPlan

    it "prop_l3_override_miss_diffs_only_in_searched_prefix(L3): 覆寫不合格時不中止,\
       \結果除了 tsSearched 多了開頭的覆寫路徑外,其餘與沒有覆寫時逐欄相同" $
      hedgehog $ do
        world <- forAll genWorld
        overrideName <- forAll genSegment
        (withOverride, without, overridePath) <- liftIO $ withTempDir $ \t -> do
          (plan, _) <- buildWorld t world
          let overridePath = t </> ("bad-override-" <> overrideName)
          r1 <- detectSevenZipIn plan (ToolsConfig (Just overridePath))
          r2 <- detectSevenZipIn plan (ToolsConfig Nothing)
          pure (r1, r2, overridePath)
        tsPath withOverride === tsPath without
        tsOrigin withOverride === tsOrigin without
        tsName withOverride === tsName without
        tsSearched withOverride === overridePath : tsSearched without

    it "prop_l5_path_and_origin_consistent(L5): 任意 world,tsPath == Nothing 恰好\
       \對應 tsOrigin == NotFound" $
      hedgehog $ do
        world <- forAll genWorld
        result <- liftIO $ withTempDir $ \t -> do
          (plan, cfg) <- buildWorld t world
          detectSevenZipIn plan cfg
        (tsPath result == Nothing) === (tsOrigin result == NotFound)

    it "prop_l7_non_executable_and_missing_never_qualify(L7b,L7d): 任意存在但不可執行的\
       \檔案、任意不存在的路徑,一律不合格且不拋例外" $
      hedgehog $ do
        nameA <- forAll genSegment
        nameB <- forAll genSegment
        (nonExecResult, missingResult) <- liftIO $ withTempDir $ \t -> do
          let nonExec = t </> ("ne-" <> nameA)
              missing = t </> ("missing-" <> nameB)
          _ <- mkNonExecutable nonExec
          r1 <- detectSevenZipIn (ToolSearchPlan [] [nonExec]) (ToolsConfig Nothing)
          r2 <- detectSevenZipIn (ToolSearchPlan [] [missing]) (ToolsConfig Nothing)
          pure (r1, r2)
        tsOrigin nonExecResult === NotFound
        tsOrigin missingResult === NotFound

    it "prop_l8_candidate_paths_are_verbatim(L8): 任意字串當候選路徑,tsSearched 對應項\
       \逐字不變(不正規化)" $
      hedgehog $ do
        raw <- forAll (Gen.text (Range.linear 1 20) (Gen.choice [Gen.alpha, Gen.digit, Gen.element (" /\\.:-_" :: String)]))
        let p = T.unpack raw
        result <- liftIO $ detectSevenZipIn (ToolSearchPlan [] [p]) (ToolsConfig Nothing)
        tsSearched result === [p]

    it "prop_l11_filesystem_untouched(L11): 任意 world,呼叫前後暫存目錄的檔案清單與\
       \內容逐位元組相同" $
      hedgehog $ do
        world <- forAll genWorld
        (before, after) <- liftIO $ withTempDir $ \t -> do
          (plan, cfg) <- buildWorld t world
          before <- snapshotFiles t
          _ <- detectSevenZipIn plan cfg
          after <- snapshotFiles t
          pure (before, after)
        before === after

    it "prop_l12_missing_dirs_and_empty_string_do_not_throw(L12): 任意由亂數片段組成的\
       \路徑(含空字串目錄),即使都不存在,也不拋例外、回 NotFound" $
      hedgehog $ do
        segs <- forAll (Gen.list (Range.linear 0 3) genSegment)
        candSegs <- forAll (Gen.list (Range.linear 0 3) genSegment)
        result <- liftIO $ withTempDir $ \t -> do
          let dirs = "" : map (\s -> t </> ("missing-" <> s)) segs
              cands = map (\s -> t </> ("missing-cand-" <> s)) candSegs
          detectSevenZipIn (ToolSearchPlan dirs cands) (ToolsConfig Nothing)
        tsOrigin result === NotFound
        tsPath result === Nothing

    it "prop_l13_tsname_constant(L13): 任意 world,tsName 恒為 \"7-Zip\"" $
      hedgehog $ do
        world <- forAll genWorld
        result <- liftIO $ withTempDir $ \t -> do
          (plan, cfg) <- buildWorld t world
          detectSevenZipIn plan cfg
        tsName result === "7-Zip"

    it "prop_l14_real_entry_matches_injected_plan_for_arbitrary_override(L14): 任意\
       \(必不合格的)覆寫路徑,detectSevenZip 與注入相同 plan 的 detectSevenZipIn 逐欄相同" $
      hedgehog $ do
        name <- forAll genSegment
        (real, injected) <- liftIO $ withTempDir $ \t -> do
          let cfg = ToolsConfig (Just (t </> name))
          pathEnv <- lookupEnv "PATH"
          let dirs = maybe [] splitSearchPath pathEnv
          r <- detectSevenZip cfg
          i <- detectSevenZipIn (ToolSearchPlan dirs builtinCandidates) cfg
          pure (r, i)
        real === injected

  --------------------------------------------------------------------------
  describe "L15(預期綠): 依賴方向與職責界線,以 import 行驗證" $ do
    it "test_tools_no_sibling_module_imports(a): 本套件內的 import 只能是 \
       \Aapms.Workspace.Types 或 Aapms.Workspace.Hub;若有 Hub,匯入清單必須是 \
       \{hubTools} 的子集合" $ do
      importLines <- toolsImportLines
      let sibling = filter (\l -> "Aapms.Workspace." `isPrefixOf` moduleNameOf l) importLines
      mapM_ (\l -> moduleNameOf l `shouldSatisfy` (`elem` ["Aapms.Workspace.Types", "Aapms.Workspace.Hub"])) sibling
      let hubLines = filter (\l -> moduleNameOf l == "Aapms.Workspace.Hub") importLines
      forM_ hubLines $ \l -> case importListOf l of
        Nothing -> expectationFailure ("import Aapms.Workspace.Hub 必須帶明確的匯入清單:" <> l)
        Just names -> names `shouldSatisfy` all (`elem` ["hubTools"])

    it "test_tools_never_imports_process(b): 完全不得 import System.Process / \
       \System.Process.Typed / System.Posix.Process,或任何以 System.Process 開頭的模組" $ do
      importLines <- toolsImportLines
      forM_ importLines $ \l -> do
        let m = moduleNameOf l
        m `shouldNotSatisfy` ("System.Process" `isPrefixOf`)
        m `shouldNotBe` "System.Posix.Process"

    it "test_tools_never_imports_store_or_core(c): 完全不得 import 任何 Aapms.Store.* \
       \或 Aapms.Core.* 模組" $ do
      importLines <- toolsImportLines
      forM_ importLines $ \l -> do
        let m = moduleNameOf l
        (("Aapms.Store" `isPrefixOf` m) || ("Aapms.Core" `isPrefixOf` m)) `shouldBe` False

    it "test_tools_directory_import_is_read_only(d): 若有 import System.Directory,\
       \匯入清單必須是 {doesFileExist, executable, exeExtension, getPermissions} 的子集合\
       \(2026-08-29 編排者裁決 spec-gaps G3:exeExtension 由 directory-1.3.10.0 的 \
       \System.Directory 匯出,不是 filepath;白名單已由 spec 修正移入這裡)" $ do
      importLines <- toolsImportLines
      let dirLines = filter (\l -> moduleNameOf l == "System.Directory") importLines
      forM_ dirLines $ \l -> case importListOf l of
        Nothing -> expectationFailure ("import System.Directory 必須帶明確的匯入清單:" <> l)
        Just names -> names `shouldSatisfy` all (`elem` ["doesFileExist", "executable", "exeExtension", "getPermissions"])

    it "test_tools_environment_import_is_lookup_only(e): 若有 import System.Environment,\
       \匯入清單必須是 {lookupEnv} 的子集合" $ do
      importLines <- toolsImportLines
      let envLines = filter (\l -> moduleNameOf l == "System.Environment") importLines
      forM_ envLines $ \l -> case importListOf l of
        Nothing -> expectationFailure ("import System.Environment 必須帶明確的匯入清單:" <> l)
        Just names -> names `shouldSatisfy` all (`elem` ["lookupEnv"])

    it "test_tools_filepath_import_is_whitelisted(f): 若有 import System.FilePath,\
       \匯入清單必須是 {(</>), (<.>), splitSearchPath} 的子集合(2026-08-29 編排者裁決 \
       \spec-gaps G3:exeExtension 不屬於 filepath 的 System.FilePath,白名單已由 spec \
       \修正移出這裡)" $ do
      importLines <- toolsImportLines
      let fpLines = filter (\l -> moduleNameOf l == "System.FilePath") importLines
      forM_ fpLines $ \l -> case importListOf l of
        Nothing -> expectationFailure ("import System.FilePath 必須帶明確的匯入清單:" <> l)
        Just names -> names `shouldSatisfy` all (`elem` ["(</>)", "(<.>)", "splitSearchPath"])

  --------------------------------------------------------------------------
  describe "ToolSearchPlan(預期綠): 骨架原文自身承載的型別事實" $ do
    it "test_tool_search_plan_fields: 建構子與兩個欄位的存取子" $ do
      let plan = ToolSearchPlan {tspPathDirs = ["a"], tspCandidates = ["b"]}
      tspPathDirs plan `shouldBe` ["a"]
      tspCandidates plan `shouldBe` ["b"]

    it "test_tool_search_plan_eq_show: 有 Eq 與 Show 實例" $ do
      (ToolSearchPlan [] [] == ToolSearchPlan [] []) `shouldBe` True
      (ToolSearchPlan ["x"] [] == ToolSearchPlan [] ["x"]) `shouldBe` False
      show (ToolSearchPlan [] []) `shouldSatisfy` (not . null)
