-- | lawful 測試:P-004-vault-scope(qa 填入)。
--
-- 每條 law 一個 @describe "P-004#LAW-n"@ 的 property,每個 example 一個
-- @describe "P-004#EX-n"@。里程碑的 @=@ 列 'openSession' 一律以觀察點
-- 'simulateSession'(HubFile + RegistryFs 兩個純解譯器)跑到底,每次操作的裁決
-- 'scopeOf' 以觀察點 'simulateScope'(Markers 的純解譯器)跑到底,測試不碰 IO。
--
-- 產生器只用型別層的建構入口組合法值:中樞文字一律由 P-028-hub-config 的
-- 'mkHub' 與 'renderHub' 產(不手寫合法的中樞 TOML);'HubWorld' \/
-- 'RegistryWorld' \/ 'MarkerWorld' \/ 'Session' 的建構子由型別層匯出,直接建構。
-- 尺寸全部有上限(vault ≤ 3、project ≤ 2、名稱 ≤ 8 字、註冊表檔 ≤ 6),每個項目
-- 另有 60 秒逾時上限。
--
-- 兩個地方無法「用型別層匯出反向產」,改用固定文字,已在回報中說明:
--
-- * __不合法__的中樞文字:'renderHub' 依定義只寫得出讀得回來的中樞
--   (P-028-hub-config 的 LAW-3),LAW-2 的定義域(@parseHubText@ 回 @Left@)
--   因此只能手寫;本模組用四段各自由 P-028 的 EX-2 \/ EX-4 \/ EX-5 \/ EX-6
--   點名為不合規的區塊,接在一份合法中樞之後。
-- * 型別註冊表的文字:types 層沒有匯出 'Aapms.Core.Registry.TypeDecl' 的序列化,
--   本模組直接採用專案自己的 @types\/registry\/*.toml@(逐字,去掉註解)當固定
--   文字,不合規的變體則依 'Aapms.Core.Registry.RegistryError' 明載的語意
--   (缺必填鍵、認不得的 @family@、TOML 解析失敗)構造。
module Aapms.Lawful.P004Spec (spec) where

import Control.Exception (evaluate)
import Data.Either (isRight)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified System.Timeout as Timeout

import Test.Hspec
import Test.Hspec.Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Aapms.Core.Id (Id, VaultId (..), parseId)
import Aapms.Core.Name (NamingVocab (..))
import Aapms.Core.Registry (TypeRegistry, buildRegistry, listTypes)
import Aapms.Store.Types (StoreError (..), VaultKind (..), VaultMarker (..))
import Aapms.Types.Parse (parseRegistryFiles)
import Aapms.Types.Source (RegistryWorld (..))
import qualified Aapms.Types.Source as Src

import Aapms.Service.Session (openSession, scopeOf)
import Aapms.Service.Session.Internal (simulateSession)
import Aapms.Service.Types
  ( ServiceError (..)
  , Session (..)
  , isRegistryUnavailable
  )
import Aapms.Workspace.Hub (parseHubText, renderHub)
import Aapms.Workspace.Resolve (resolveScope)
import Aapms.Workspace.Resolve.Internal (simulateScope)
import Aapms.Workspace.Types
  ( Hub
  , HubLocation (..)
  , HubSource (..)
  , HubWorld (..)
  , MarkerWorld (..)
  , ProjectEntry (..)
  , Scope (..)
  , ScopeKind (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , WorkspaceError (..)
  , hubConfigPath
  , hubVaults
  , mkHub
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
        ("P-004 測試項目超過 " <> show (itemTimeoutMicros `div` 1000000) <> " 秒未結束")

itemTimeoutMicros :: Int
itemTimeoutMicros = 60 * 1000 * 1000

--------------------------------------------------------------------------------
-- Laws
--------------------------------------------------------------------------------

lawsSpec :: Spec
lawsSpec = do
  describe "P-004#LAW-1" $
    it "relation:中樞檔不存在時,開場回 HubNotFound 原樣包成 WorkspaceFailed" $
      hedgehog $ do
        hw <- forAll genHubWorldNoText
        rw <- forAll genRegistryWorld
        sel <- forAll genSelector
        cwd <- forAll genCwd
        -- 前提由產生器直接建構,在這裡斷言出來,property 才不會恆真。
        assert (isNothing (hubTextIn hw))
        simulateSession hw rw (openSession sel cwd)
          === Left (WorkspaceFailed (HubNotFound (hubConfigPath (hubLocationIn hw))))

  describe "P-004#LAW-2" $
    it "relation:中樞格式錯時,parseHubText 回的錯誤原樣包成 WorkspaceFailed" $
      hedgehog $ do
        hw <- forAll genHubWorldBadText
        rw <- forAll genRegistryWorld
        sel <- forAll genSelector
        cwd <- forAll genCwd
        txt <- hubTextOf hw
        err <- case parseHubText (hlPath (hubLocationIn hw)) txt of
          Left e -> pure e
          Right _ -> do
            annotate "本產生器只產不合規的中樞文字,這裡應該是 Left"
            failure
        simulateSession hw rw (openSession sel cwd) === Left (WorkspaceFailed err)

  describe "P-004#LAW-3" $
    it "relation:註冊表三層都定位不到時,錯誤是 RegistryUnavailable" $
      hedgehog $ do
        hw <- forAll genHubWorldGoodText
        rw <- forAll genRegistryWorldNoDir
        sel <- forAll genSelector
        cwd <- forAll genCwd
        txt <- hubTextOf hw
        assert (isRight (parseHubText (hlPath (hubLocationIn hw)) txt))
        assert (isNothing (registryDirIn rw))
        assert
          (either isRegistryUnavailable (const False) (simulateSession hw rw (openSession sel cwd)))

  describe "P-004#LAW-4" $
    it "relation:註冊表目錄找到但內容不合規時,錯誤是 RegistryLoadFailed 且與 parseRegistryFiles 回的相同" $
      hedgehog $ do
        hw <- forAll genHubWorldGoodText
        rw <- forAll genRegistryWorldBadFiles
        sel <- forAll genSelector
        cwd <- forAll genCwd
        txt <- hubTextOf hw
        assert (isRight (parseHubText (hlPath (hubLocationIn hw)) txt))
        assert (isJust (registryDirIn rw))
        err <- case parseRegistryFiles (registryFilesIn rw) of
          Left e -> pure e
          Right _ -> do
            annotate "本產生器只產不合規的註冊表文字,這裡應該是 Left"
            failure
        simulateSession hw rw (openSession sel cwd) === Left (RegistryLoadFailed err)

  describe "P-004#LAW-5" $
    it "relation:成功時快照的七欄逐欄等於各步驟的結果" $
      hedgehog $ do
        hw <- forAll genHubWorldGoodText
        rw <- forAll genRegistryWorldOk
        sel <- forAll genSelector
        cwd <- forAll genCwd
        txt <- hubTextOf hw
        h <- case parseHubText (hlPath (hubLocationIn hw)) txt of
          Right x -> pure x
          Left e -> do
            annotate "本產生器只產合法中樞文字,這裡應該是 Right"
            annotateShow e
            failure
        (decls, vocab) <- case parseRegistryFiles (registryFilesIn rw) of
          Right x -> pure x
          Left e -> do
            annotate "本產生器只產合規的註冊表文字,這裡應該是 Right"
            annotateShow e
            failure
        reg <- case buildRegistry decls of
          Right x -> pure x
          Left e -> do
            annotate "本產生器的型別宣告來自專案自己的註冊表,這裡應該是 Right"
            annotateShow e
            failure
        src <- case registryDirIn rw of
          Just (_dir, s) -> pure s
          Nothing -> do
            annotate "本產生器一定給得出註冊表目錄"
            failure
        -- forall 的定義域:s in rights [...]。產生器把四個失敗路徑的前提全部反過來
        -- 建構(中樞文字讀得回來、註冊表定位得到、內容合規、建得起來),LAW-1 到
        -- LAW-4 已經涵蓋全部失敗路徑,所以這裡應該是 Right;是 Left 就不是空的
        -- 定義域而是矛盾,直接紅。
        s <- case simulateSession hw rw (openSession sel cwd) of
          Right x -> pure x
          Left e -> do
            annotate "四個失敗路徑的前提都不成立,開場應該成功"
            annotateShow e
            failure
        sessionHub s === h
        sessionLocation s === hubLocationIn hw
        listTypes (sessionRegistry s) === listTypes reg
        sessionNaming s === vocab
        sessionSource s === src
        sessionSelector s === sel
        sessionCwd s === cwd

  describe "P-004#LAW-6" $
    it "equiv:每次操作的裁決就是 P-029 的裁決,WorkspaceError 原樣包成 WorkspaceFailed" $
      hedgehog $ do
        w <- forAll genMarkerWorld
        s <- forAll genSession
        k <- forAll genScopeKind
        simulateScope w (scopeOf s k)
          === either
            (Left . WorkspaceFailed)
            Right
            (simulateScope w (resolveScope (sessionHub s) k (sessionSelector s) (sessionCwd s)))

  describe "P-004#LAW-7" $
    it "total:開場對任何世界與輸入都求值得到底,不拋例外" $
      hedgehog $ do
        hw <- forAll genHubWorldAny
        rw <- forAll genRegistryWorld
        sel <- forAll genSelector
        cwd <- forAll genCwd
        -- total:求值到正規形不拋例外(show 走遍整個結構)。
        n <- evalIO (evaluate (length (show (simulateSession hw rw (openSession sel cwd)))))
        assert (n >= 0)

--------------------------------------------------------------------------------
-- Examples
--------------------------------------------------------------------------------

examplesSpec :: Spec
examplesSpec = do
  describe "P-004#EX-1" $
    it "世界裡沒有中樞檔:回 HubNotFound,路徑是中樞位置底下的 config.toml" $
      simulateSession ex1HubWorld exRegistryWorldOk (openSession Nothing exCwd)
        `shouldBe` Left (WorkspaceFailed (HubNotFound (hubConfigPath (hubLocationIn ex1HubWorld))))

  describe "P-004#EX-2" $
    it "中樞文字的 id 不是字串:HubMalformed,與 parseHubText 回的逐欄相同" $ do
      let txt = "[[vaults]]\nid = 3\n"
          parsed = parseHubText exHubPath txt
          world = HubWorld (Just txt) (HubLocation exHubPath FromEnv) False []
      case parsed of
        Left err@(HubMalformed fp _) -> do
          fp `shouldBe` exHubPath
          simulateSession world exRegistryWorldOk (openSession Nothing exCwd)
            `shouldBe` Left (WorkspaceFailed err)
        other -> expectationFailure ("預期 parseHubText 回 HubMalformed,實際:" <> show other)

  describe "P-004#EX-3" $
    it "中樞正常但三層都沒有註冊表目錄:RegistryUnavailable,不是 RegistryLoadFailed" $
      case simulateSession ex5HubWorld (RegistryWorld Nothing []) (openSession Nothing exCwd) of
        Left (RegistryUnavailable _) -> pure ()
        other -> expectationFailure ("預期 Left (RegistryUnavailable …),實際:" <> show other)

  describe "P-004#EX-4" $
    it "註冊表目錄在 AAPMS_REGISTRY 但 character.toml 缺 family:RegistryLoadFailed,與 parseRegistryFiles 回的相同" $
      case parseRegistryFiles (registryFilesIn ex4RegistryWorld) of
        Left err ->
          simulateSession ex5HubWorld ex4RegistryWorld (openSession Nothing exCwd)
            `shouldBe` Left (RegistryLoadFailed err)
        Right _ ->
          expectationFailure "EX-4 的 character.toml 缺 family,parseRegistryFiles 應該回 Left"

  describe "P-004#EX-5" $
    it "中樞兩列、註冊表五份 TOML 完整:快照的五個投影逐欄如契約" $
      case simulateSession ex5HubWorld exRegistryWorldOk (openSession (Just "a") exCwd) of
        Right s -> do
          length (hubVaults (sessionHub s)) `shouldBe` 2
          length (listTypes (sessionRegistry s)) `shouldBe` 5
          sessionSource s `shouldBe` Src.FromEnv
          sessionSelector s `shouldBe` Just "a"
          sessionCwd s `shouldBe` exCwd
        other -> expectationFailure ("預期 Right,實際:" <> show other)

  describe "P-004#EX-6" $
    it "同 EX-5 的 Session 跑 ForRead:與 resolveScope 的裁決相同的 ReadScope" $ do
      let lhs = simulateScope exMarkerWorld (scopeOf ex5Session ForRead)
          rhs =
            either
              (Left . WorkspaceFailed)
              Right
              (simulateScope exMarkerWorld (resolveScope ex5Hub ForRead (Just "a") exCwd))
      lhs `shouldBe` rhs
      case lhs of
        Right (SRead _) -> pure ()
        other -> expectationFailure ("預期 Right (SRead …),實際:" <> show other)

  describe "P-004#EX-7" $
    it "同 EX-5 的 Session 跑 ForPipeline AssetVault 而 a 是 story:VaultKindMismatch 包成 WorkspaceFailed" $
      simulateScope exMarkerWorld (scopeOf ex5Session (ForPipeline AssetVault))
        `shouldBe` Left (WorkspaceFailed (VaultKindMismatch vaultIdA AssetVault StoryVault))

  describe "P-004#EX-8" $
    it "任意亂造的兩個世界與輸入:求值到底不拋例外" $
      mapM_ evaluateFully ex8Cases

-- | EX-8:把結果求值到正規形(show 走遍整個結構)。
evaluateFully :: (HubWorld, RegistryWorld, Maybe Text, FilePath) -> Expectation
evaluateFully (hw, rw, sel, cwd) = do
  n <- evaluate (length (show (simulateSession hw rw (openSession sel cwd))))
  n `shouldSatisfy` (>= 0)

--------------------------------------------------------------------------------
-- Example 的固定值
--------------------------------------------------------------------------------

-- | 中樞__根目錄__(不是 config.toml 的路徑);'hlPath' 就是這一段。
exHubPath :: FilePath
exHubPath = "C:/aapms"

-- | EX-1 的中樞根目錄 @%APPDATA%\/aapms@;實際被讀的檔是它底下的
-- @config.toml@('hubConfigPath')。
ex1HubRoot :: FilePath
ex1HubRoot = "C:/Users/u/AppData/Roaming/aapms"

ex1HubWorld :: HubWorld
ex1HubWorld = HubWorld Nothing (HubLocation ex1HubRoot FromPlatformDefault) False []

exCwd :: FilePath
exCwd = "T/x"

vaultIdA, vaultIdB :: VaultId
vaultIdA = VaultId "vlt-7f3b2a91"
vaultIdB = VaultId "vlt-a0c4e1f8"

vaultPathA, vaultPathB :: FilePath
vaultPathA = "D:/vaults/a"
vaultPathB = "D:/vaults/b"

-- | EX-5 的中樞:兩列,@a@ 是 story、@b@ 是 asset。
ex5Hub :: Hub
ex5Hub =
  mkHub
    [ VaultEntry vaultIdA "a" StoryVault vaultPathA
    , VaultEntry vaultIdB "b" AssetVault vaultPathB
    ]
    []
    Nothing
    (ToolsConfig Nothing)
    ""

ex5HubWorld :: HubWorld
ex5HubWorld = HubWorld (Just (renderHub ex5Hub)) (HubLocation exHubPath FromEnv) False []

-- | EX-6 \/ EX-7 的「同 EX-5 的 Session」:中樞、位置、selector 與 cwd 逐欄同
-- EX-5;'scopeOf' 只用得到這四欄,註冊表與命名詞彙因此取空值('buildRegistry' 對
-- 空宣告清單一定成功)。
ex5Session :: Session
ex5Session =
  Session
    { sessionHub = ex5Hub
    , sessionLocation = HubLocation exHubPath FromEnv
    , sessionRegistry = emptyRegistry
    , sessionNaming = emptyVocab
    , sessionSource = Src.FromEnv
    , sessionSelector = Just "a"
    , sessionCwd = exCwd
    }

-- | EX-6 \/ EX-7 的 marker 世界:兩個 vault 的 marker 都讀得到,身分與中樞一致。
exMarkerWorld :: MarkerWorld
exMarkerWorld =
  MarkerWorld
    { mwMarkers =
        M.fromList
          [ (vaultPathA, Right (VaultMarker vaultIdA StoryVault "a" []))
          , (vaultPathB, Right (VaultMarker vaultIdB AssetVault "b" []))
          ]
    , worldDirs = [vaultPathA, vaultPathB, exCwd]
    }

exRegistryWorldOk :: RegistryWorld
exRegistryWorldOk = RegistryWorld (Just (registryDirPath, Src.FromEnv)) goodRegistryFiles

-- | EX-4:目錄找得到(@AAPMS_REGISTRY@ 那一層),但 @character.toml@ 缺 @family@。
ex4RegistryWorld :: RegistryWorld
ex4RegistryWorld =
  RegistryWorld
    (Just (registryDirPath, Src.FromEnv))
    [namingFile, (registryDirPath <> "/character.toml", tomlMissingFamily)]

ex8Cases :: [(HubWorld, RegistryWorld, Maybe Text, FilePath)]
ex8Cases =
  [ (HubWorld Nothing (HubLocation "" FromEnv) False [], RegistryWorld Nothing [], Nothing, "")
  , ( HubWorld (Just "\SOH\n[[vaults") (HubLocation "?" FromPlatformDefault) True ["\SOH.png"]
    , RegistryWorld (Just ("", Src.FromDataDir)) [("", "= =")]
    , Just ""
    , "\SOH"
    )
  , ( HubWorld (Just (renderHub ex5Hub)) (HubLocation exHubPath FromEnv) False []
    , RegistryWorld (Just (registryDirPath, Src.BesideExecutable)) [namingFile]
    , Just "沒有這個 vault"
    , "D:/vaults/a/deep/deeper"
    )
  , ( HubWorld (Just "") (HubLocation exHubPath FromEnv) True ["a.png", "b.png"]
    , exRegistryWorldOk
    , Nothing
    , exCwd
    )
  ]

emptyRegistry :: TypeRegistry
emptyRegistry = case buildRegistry [] of
  Right r -> r
  Left e -> error ("P-004 測試:空的型別宣告清單應該建得起來:" <> show e)

emptyVocab :: NamingVocab
emptyVocab = NamingVocab [] [] []

--------------------------------------------------------------------------------
-- 產生器
--------------------------------------------------------------------------------

-- 尺寸上限 -------------------------------------------------------------------

maxNameLen :: Int
maxNameLen = 8

maxPathSegLen :: Int
maxPathSegLen = 6

maxJunkTextLen :: Int
maxJunkTextLen = 40

-- 中樞 -----------------------------------------------------------------------

-- | 中樞內容用的 vault id 池(固定 4 個,取子集後洗牌 ⇒ 唯一且保序可控)。
vaultIdPool :: [VaultId]
vaultIdPool =
  map (VaultId . ("vlt-" <>)) ["7f3b2a91", "a0c4e1f8", "33334444", "5a5b5c5d"]

projectIdPool :: [Text]
projectIdPool = map ("prj-" <>) ["91c0aa12", "0000abcd"]

nameChars :: String
nameChars = "abcdefgHIJK_-.0123中文名稱"

pathChars :: String
pathChars = "abcXYZ_0-9"

-- | 非空、且沒有前後空白的名稱(P-028-hub-config:去前後空白後為空一律
-- HubMalformed)。
genName :: Gen Text
genName = do
  c <- Gen.element nameChars
  rest <- Gen.text (Range.linear 0 maxNameLen) (Gen.element (nameChars <> " "))
  pure (T.stripEnd (T.cons c rest))

-- | 絕對路徑(P-028-hub-config:相對路徑一律 HubMalformed)。
genAbsPath :: Gen FilePath
genAbsPath = do
  drive <- Gen.element ["C:", "D:", "E:"]
  segs <- Gen.list (Range.linear 1 3) (Gen.text (Range.linear 1 maxPathSegLen) (Gen.element pathChars))
  pure (T.unpack (drive <> "/" <> T.intercalate "/" segs))

genVaultEntries :: Gen [VaultEntry]
genVaultEntries = do
  ids <- Gen.subsequence vaultIdPool >>= Gen.shuffle
  traverse (\i -> VaultEntry i <$> genName <*> Gen.element [AssetVault, StoryVault] <*> genAbsPath) ids

genProjectEntries :: Gen [ProjectEntry]
genProjectEntries = do
  ids <- Gen.subsequence projectIdPool >>= Gen.shuffle
  traverse (\i -> ProjectEntry (mkProjectId i) <$> genName <*> genAbsPath) ids

-- | 只用型別層的 smart constructor 取得 'Aapms.Core.Id.Id'(建構子不匯出)。
mkProjectId :: Text -> Id
mkProjectId t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("P-004 測試的專案 id 字面值不合法:" <> show e)

-- | 合法的 'Hub' 值:'mkHub' 是唯一建構入口,底稿留空字串(全新中樞,尚無檔案)。
genHub :: Gen Hub
genHub = do
  vs <- genVaultEntries
  ps <- genProjectEntries
  pure (mkHub vs ps Nothing (ToolsConfig Nothing) "")

-- | 合法的中樞文字:一律由 P-028-hub-config 的 'renderHub' 產。
genGoodHubText :: Gen Text
genGoodHubText = renderHub <$> genHub

-- | 不合法的中樞文字:合法中樞後面接一段 P-028-hub-config 明載為不合規的區塊。
genBadHubText :: Gen Text
genBadHubText = do
  base <- genGoodHubText
  broken <- Gen.element brokenBlocks
  pure (T.stripEnd base <> "\n\n" <> broken)

-- | 四段各自不合規的理由:缺 id、TOML 語法錯、名稱去空白後為空、kind 不合法
-- (P-028-hub-config 的 EX-4 \/ EX-2 \/ EX-6 \/ EX-5)。
brokenBlocks :: [Text]
brokenBlocks =
  [ T.unlines ["[[vaults]]", "name = \"x\"", "kind = \"asset\"", "path = \"D:/vaults/x\""]
  , "[[vaults\n"
  , T.unlines ["[[projects]]", "id = \"prj-deadbeef\"", "name = \"   \"", "path = \"D:/p\""]
  , T.unlines
      [ "[[vaults]]"
      , "id = \"vlt-99998888\""
      , "name = \"x\""
      , "kind = \"media\""
      , "path = \"D:/vaults/x\""
      ]
  ]

genJunkText :: Gen Text
genJunkText = Gen.text (Range.linear 0 maxJunkTextLen) Gen.unicode

-- | 中樞__根目錄__(不是 config.toml 的路徑);'hlPath' 就是這一段,實際被讀的
-- 檔是它底下的 @config.toml@('hubConfigPath')。
genHubLocation :: Gen HubLocation
genHubLocation =
  HubLocation
    <$> Gen.element
      [ "C:/aapms"
      , "D:/somewhere/else"
      , "C:/使用者/中樞"
      ]
    <*> Gen.element [FromEnv, FromPlatformDefault]

-- | REV-2:縮圖快取目錄下的檔案池(固定 3 個),取子集即涵蓋「零到多張」,結構
-- 有界。
thumbFilePool :: [FilePath]
thumbFilePool = ["D:/cache/a.png", "D:/cache/b.png", "D:/cache/c.png"]

-- | REV-2:世界裡縮圖快取目錄存不存在。
genCacheDirIn :: Gen Bool
genCacheDirIn = Gen.bool

-- | REV-2:世界裡快取目錄下的縮圖檔;固定小池取子集,結構有界。
genThumbsIn :: Gen [FilePath]
genThumbsIn = Gen.subsequence thumbFilePool

genHubWorldNoText :: Gen HubWorld
genHubWorldNoText = HubWorld Nothing <$> genHubLocation <*> genCacheDirIn <*> genThumbsIn

genHubWorldGoodText :: Gen HubWorld
genHubWorldGoodText =
  HubWorld <$> (Just <$> genGoodHubText) <*> genHubLocation <*> genCacheDirIn <*> genThumbsIn

genHubWorldBadText :: Gen HubWorld
genHubWorldBadText =
  HubWorld <$> (Just <$> genBadHubText) <*> genHubLocation <*> genCacheDirIn <*> genThumbsIn

-- | LAW-7 的定義域:任何中樞世界。
genHubWorldAny :: Gen HubWorld
genHubWorldAny =
  Gen.frequency
    [ (2, genHubWorldNoText)
    , (2, genHubWorldGoodText)
    , (2, genHubWorldBadText)
    , (1, HubWorld <$> (Just <$> genJunkText) <*> genHubLocation <*> genCacheDirIn <*> genThumbsIn)
    ]

-- | 取出世界裡的中樞文字;產生器保證有,沒有就是產生器壞了。
hubTextOf :: (MonadTest m) => HubWorld -> m Text
hubTextOf hw = case hubTextIn hw of
  Just t -> pure t
  Nothing -> do
    annotate "本產生器一定給得出中樞文字"
    failure

-- 註冊表 ---------------------------------------------------------------------

registryDirPath :: FilePath
registryDirPath = "D:/aapms/types/registry"

genRegistrySource :: Gen Src.RegistrySource
genRegistrySource = Gen.element [Src.FromEnv, Src.BesideExecutable, Src.FromDataDir]

-- | 目錄定位得到、內容全部合規。
genRegistryWorldOk :: Gen RegistryWorld
genRegistryWorldOk = do
  src <- genRegistrySource
  types <- Gen.subsequence goodTypeFiles
  pure (RegistryWorld (Just (registryDirPath, src)) (namingFile : types))

-- | 三層都定位不到。
genRegistryWorldNoDir :: Gen RegistryWorld
genRegistryWorldNoDir =
  RegistryWorld Nothing <$> Gen.element [[], goodRegistryFiles]

-- | 目錄定位得到,但至少一份 TOML 不合規。
genRegistryWorldBadFiles :: Gen RegistryWorld
genRegistryWorldBadFiles = do
  src <- genRegistrySource
  types <- Gen.subsequence goodTypeFiles
  bad <- Gen.element badTypeFiles
  pure (RegistryWorld (Just (registryDirPath, src)) (namingFile : types <> [bad]))

genRegistryWorld :: Gen RegistryWorld
genRegistryWorld =
  Gen.frequency
    [ (2, genRegistryWorldOk)
    , (1, genRegistryWorldNoDir)
    , (2, genRegistryWorldBadFiles)
    ]

-- Markers 與 Session -----------------------------------------------------------

genMarkerWorld :: Gen MarkerWorld
genMarkerWorld = do
  ms <- Gen.subsequence markerCandidates
  ds <- Gen.subsequence (map fst markerCandidates <> ["T/x", "C:/work"])
  pure (MarkerWorld (M.fromList ms) ds)

markerCandidates :: [(FilePath, Either StoreError VaultMarker)]
markerCandidates =
  [ ("C:/v1", Right (VaultMarker (vaultIdPool !! 0) StoryVault "a" []))
  , ("C:/v2", Right (VaultMarker (vaultIdPool !! 1) AssetVault "b" []))
  , ("C:/v3", Right (VaultMarker (vaultIdPool !! 2) StoryVault "c" [vaultIdPool !! 0]))
  , ("C:/v4", Left (VaultMarkerMissing "C:/v4"))
  ]

-- | 'Session' 的建構子由型別層匯出,直接建構。'scopeOf' 只用得到中樞、selector
-- 與 cwd,註冊表與命名詞彙因此取空值。
genSession :: Gen Session
genSession = do
  h <- genHub
  loc <- genHubLocation
  src <- genRegistrySource
  sel <- genSelector
  cwd <- genCwd
  pure (Session h loc emptyRegistry emptyVocab src sel cwd)

genScopeKind :: Gen ScopeKind
genScopeKind = Gen.element [ForRead, ForWrite, ForPipeline AssetVault, ForPipeline StoryVault]

-- | 原樣捧著的 @--vault@;本層不解讀,所以池子含比得到與比不到的兩種。
genSelector :: Gen (Maybe Text)
genSelector =
  Gen.maybe (Gen.element ["a", "b", "c", "vlt-7f3b2a91", "沒有這個 vault"])

genCwd :: Gen FilePath
genCwd = Gen.element ["T/x", "C:/v1/sub", "C:/work", ""]

--------------------------------------------------------------------------------
-- 型別註冊表的固定文字
--
-- types 層沒有匯出 'Aapms.Core.Registry.TypeDecl' 的序列化,所以這裡逐字採用專案
-- 自己的 @types\/registry\/*.toml@(去掉註解)。不合規的三個變體依
-- 'Aapms.Core.Registry.RegistryError' 明載的語意構造:缺必填鍵、認不得的
-- @family@、TOML 解析失敗。
--------------------------------------------------------------------------------

namingFile :: (FilePath, Text)
namingFile = (registryDirPath <> "/naming.toml", namingToml)

goodRegistryFiles :: [(FilePath, Text)]
goodRegistryFiles = namingFile : goodTypeFiles

-- | EX-5 的「五份 TOML」:五份型別宣告(@naming.toml@ 不是型別宣告,另計)。
goodTypeFiles :: [(FilePath, Text)]
goodTypeFiles =
  [ (registryDirPath <> "/asset-image.toml", tomlAssetImage)
  , (registryDirPath <> "/asset-audio.toml", tomlAssetAudio)
  , (registryDirPath <> "/character-fragment.toml", tomlCharacterFragment)
  , (registryDirPath <> "/dialogue.toml", tomlDialogue)
  , (registryDirPath <> "/lore-fragment.toml", tomlLoreFragment)
  ]

badTypeFiles :: [(FilePath, Text)]
badTypeFiles =
  [ (registryDirPath <> "/character.toml", tomlMissingFamily)
  , (registryDirPath <> "/creature.toml", tomlUnknownFamily)
  , (registryDirPath <> "/broken.toml", tomlSyntaxError)
  ]

namingToml :: Text
namingToml =
  T.unlines
    [ "kinds   = [\"spr\", \"tex\", \"atlas\", \"ui\", \"fnt\", \"sfx\", \"bgm\", \"vo\", \"lvl\", \"shd\", \"src\", \"doc\"]"
    , "domains = []"
    , "states  = [\"idle\", \"open\", \"walk\", \"up\", \"day\"]"
    ]

tomlAssetImage :: Text
tomlAssetImage =
  T.unlines
    [ "key    = \"asset-image\""
    , "name   = \"圖片素材\""
    , "family = \"asset\""
    , ""
    , "allowed_links = []"
    , ""
    , "name_kinds = [\"spr\", \"tex\", \"atlas\", \"ui\"]"
    , ""
    , "[[fields]]"
    , "name     = \"summary\""
    , "required = true"
    , "hint     = \"一句話說明這個素材的用途或畫面內容\""
    ]

tomlAssetAudio :: Text
tomlAssetAudio =
  T.unlines
    [ "key    = \"asset-audio\""
    , "name   = \"音訊素材\""
    , "family = \"asset\""
    , ""
    , "allowed_links = []"
    , ""
    , "name_kinds = [\"sfx\", \"bgm\", \"vo\"]"
    , ""
    , "[[fields]]"
    , "name     = \"summary\""
    , "required = true"
    , "hint     = \"一句話說明這段音訊的用途或內容\""
    ]

tomlCharacterFragment :: Text
tomlCharacterFragment =
  T.unlines
    [ "key    = \"character-fragment\""
    , "name   = \"角色片段\""
    , "family = \"entity\""
    , ""
    , "dir        = \"characters\""
    , "owner_type = \"character\""
    , ""
    , "allowed_links = [\"partOf\", \"occursIn\", \"involves\", \"contradicts\", \"supersedes\", \"references\"]"
    , "stages = [\"定位\", \"外貌與舉止\", \"動機與過往\", \"關係網\"]"
    , ""
    , "[[fields]]"
    , "name = \"summary\""
    , "required = true"
    , "hint = \"一句話說明這個片段講角色的哪一面\""
    , ""
    , "[[fields]]"
    , "name = \"tags\""
    , "required = false"
    , "hint = \"分組用的自由標籤\""
    ]

tomlDialogue :: Text
tomlDialogue =
  T.unlines
    [ "key    = \"dialogue\""
    , "name   = \"對話\""
    , "family = \"entity\""
    , ""
    , "dir  = \"dialogues\""
    , ""
    , "allowed_links = [\"involves\", \"occursIn\", \"references\", \"contradicts\", \"supersedes\"]"
    , "stages = [\"情境與目的\", \"雙方立場\", \"台詞\", \"收尾與後果\"]"
    , ""
    , "[[fields]]"
    , "name = \"summary\""
    , "required = true"
    , "hint = \"一句話說明這段對話在講什麼、誰對誰說\""
    , ""
    , "[[fields]]"
    , "name = \"timeline\""
    , "required = false"
    , "hint = \"這段對話發生在故事內的哪個時間點\""
    ]

tomlLoreFragment :: Text
tomlLoreFragment =
  T.unlines
    [ "key    = \"lore-fragment\""
    , "name   = \"世界觀片段\""
    , "family = \"entity\""
    , ""
    , "dir        = \"lore\""
    , "owner_type = \"lore\""
    , ""
    , "allowed_links = [\"partOf\", \"occursIn\", \"derivedFrom\", \"contradicts\", \"supersedes\", \"references\"]"
    , "stages = [\"定位\", \"樣貌與規則\", \"歷史脈絡\", \"與其他設定的關係\"]"
    , ""
    , "[[fields]]"
    , "name = \"summary\""
    , "required = true"
    , "hint = \"一句話說明這個片段描述世界的哪一塊\""
    , ""
    , "[[fields]]"
    , "name = \"aliases\""
    , "required = false"
    , "hint = \"地名舊稱、勢力的別名\""
    ]

-- | EX-4:缺必填鍵 @family@('Aapms.Core.Registry.MissingField')。
tomlMissingFamily :: Text
tomlMissingFamily =
  T.unlines
    [ "key  = \"character\""
    , "name = \"角色\""
    ]

-- | 認不得的 @family@ 值,只接受 @entity@ 或 @asset@
-- ('Aapms.Core.Registry.UnknownFamily')。
tomlUnknownFamily :: Text
tomlUnknownFamily =
  T.unlines
    [ "key    = \"creature\""
    , "name   = \"生物\""
    , "family = \"creature\""
    ]

-- | TOML 解析失敗('Aapms.Core.Registry.TomlParseError')。
tomlSyntaxError :: Text
tomlSyntaxError = "[[fields\nkey = \n"
