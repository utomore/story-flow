-- | graph-core/F002 T12(naming.toml \/ family 整合)與 T13(專案實檔)的對照測試。
--
-- 沿用 graph-core/F001 之前(entity-graph-core/F002、F005、service-and-
-- interfaces/F001、G-E002)留下的既有涵蓋範圍,改吃新簽名
-- (@'Either' 'RegistryError' ('TypeRegistry', 'NamingVocab')@)與新欄位名
-- (@td*@ 取代 @ets*@)。
module Aapms.Types.LoaderSpec (spec) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Core.Link (LinkKind (..))
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Types.Loader
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

--------------------------------------------------------------------------------
-- 臨時目錄輔助

-- | 在臨時目錄裡放好 (檔名, 內容) 後執行動作;__自動補上一份預設的
-- @naming.toml@__(除非呼叫端自己給了一份),讓不是專門測 @naming.toml@ 的
-- 測試不必逐一補它。內容一律以 UTF-8 寫入——Windows 的預設 code page 會把
-- 繁中內容寫壞,這是測試自己的坑。
withRegistryDir :: [(FilePath, Text)] -> (FilePath -> IO a) -> IO a
withRegistryDir files
  | any ((== "naming.toml") . fst) files = withRegistryDirRaw files
  | otherwise = withRegistryDirRaw (files ++ [("naming.toml", defaultNamingToml)])

-- | 'withRegistryDir' 不自動補 @naming.toml@ 的版本,給專門測它的測試用。
withRegistryDirRaw :: [(FilePath, Text)] -> (FilePath -> IO a) -> IO a
withRegistryDirRaw files act =
  withSystemTempDirectory "aapms-registry" $ \dir -> do
    createDirectoryIfMissing True dir
    mapM_ (\(n, c) -> BS.writeFile (dir </> n) (TE.encodeUtf8 c)) files
    act dir

-- | 與專案 @types\/registry\/naming.toml@ 相同的 12 個 kind、37 個 state。
defaultNamingToml :: Text
defaultNamingToml =
  T.unlines
    [ "kinds   = [\"spr\", \"tex\", \"atlas\", \"ui\", \"fnt\", \"sfx\", \"bgm\", \"vo\", \"lvl\", \"shd\", \"src\", \"doc\"]"
    , "domains = []"
    , "states  = ["
    , "  \"idle\", \"hover\", \"pressed\", \"disabled\", \"active\", \"selected\", \"focus\","
    , "  \"open\", \"closed\", \"empty\", \"full\", \"on\", \"off\","
    , "  \"walk\", \"run\", \"attack\", \"dash\", \"death\", \"hurt\", \"cast\","
    , "  \"up\", \"down\", \"left\", \"right\", \"front\", \"back\", \"north\", \"south\", \"east\", \"west\","
    , "  \"day\", \"night\", \"dawn\", \"dusk\", \"intro\", \"loop\", \"outro\""
    , "]"
    ]

-- | 注意鍵的順序:allowed_links 與 stages 必須在 [[fields]] __之前__,
-- 否則依 TOML 的表頭語意它們會變成該 field 的子鍵。
goodToml :: Text -> Text -> Text
goodToml key name =
  T.unlines
    [ "key    = \"" <> key <> "\""
    , "name   = \"" <> name <> "\""
    , "family = \"entity\""
    , ""
    , "allowed_links = [\"partOf\", \"contradicts\"]"
    , "stages = [\"定位\", \"細節\"]"
    , ""
    , "[[fields]]"
    , "name = \"summary\""
    , "required = true"
    , "hint = \"一句話說明這個片段講什麼\""
    ]

-- | asset 族的最小合法宣告。
assetToml :: Text -> [Text] -> Text
assetToml key kinds =
  T.unlines
    [ "key    = \"" <> key <> "\""
    , "name   = \"" <> key <> " 素材\""
    , "family = \"asset\""
    , "allowed_links = []"
    , "name_kinds = [" <> T.intercalate ", " (map quoted kinds) <> "]"
    ]
  where
    quoted t = "\"" <> t <> "\""

--------------------------------------------------------------------------------
-- 結果拆解輔助

-- | 'loadRegistry' \/ 'loadRegistryFrom' 的失敗一律攤平成一份列表:單一錯誤
-- 攤成單元素、'RegistryErrors' 攤成原始清單——讓斷言不必分兩種情況寫。
errsOf :: Either RegistryError a -> [RegistryError]
errsOf (Left (RegistryErrors es)) = es
errsOf (Left e) = [e]
errsOf (Right _) = []

fieldOf :: RegistryError -> Text
fieldOf = \case
  MissingField _ k -> k
  BadFieldType _ k _ -> k
  UnknownKey _ k -> k
  TomlParseError _ m -> m
  RegistryDirMissing fp -> T.pack fp
  NamingFileMissing fp -> T.pack fp
  UnknownFamily _ v -> v
  e -> T.pack (show e)

regOf :: Either RegistryError (TypeRegistry, NamingVocab) -> Maybe TypeRegistry
regOf = either (const Nothing) (Just . fst)

vocabOf :: Either RegistryError (TypeRegistry, NamingVocab) -> Maybe NamingVocab
vocabOf = either (const Nothing) (Just . snd)

typeKeys :: TypeRegistry -> [Text]
typeKeys reg = [k | TypeKey k <- map tdKey (listTypes reg)]

-- | 專案實際的型別註冊表目錄。測試由套件根目錄(types/)執行。
projectRegistryDir :: FilePath
projectRegistryDir = "registry"

entityFixtureKeys :: [Text]
entityFixtureKeys = ["character-fragment", "dialogue", "item-fragment", "lore-fragment", "plot-fragment"]

-- | 對照 F002 文檔「相依性查證」讀出的 legacy KindPrefix 對應表。
assetFixtureSpecs :: [(Text, [Text])]
assetFixtureSpecs =
  [ ("asset-image", ["spr", "tex", "atlas", "ui"])
  , ("asset-audio", ["sfx", "bgm", "vo"])
  , ("asset-font", ["fnt"])
  , ("asset-level", ["lvl"])
  , ("asset-shader", ["shd"])
  , ("asset-doc", ["doc"])
  , ("asset-source", ["src"])
  , ("asset-archive", [])
  ]

--------------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "loadRegistry —— 正常載入" $ do
    it "三個檔載入成功,typeKeys 得三筆" $
      withRegistryDir
        [ ("a.toml", goodToml "a-fragment" "甲片段")
        , ("b.toml", goodToml "b-fragment" "乙片段")
        , ("c.toml", goodToml "c-fragment" "丙片段")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          fmap typeKeys (regOf r) `shouldBe` Just ["a-fragment", "b-fragment", "c-fragment"]

    it "欄位、關聯、階段都完整讀進來" $
      withRegistryDir [("a.toml", goodToml "a-fragment" "甲片段")] $ \dir -> do
        r <- loadRegistry dir
        case fmap listTypes (regOf r) of
          Just [d] -> do
            tdName d `shouldBe` "甲片段"
            tdFamily d `shouldBe` FEntity
            tdFields d `shouldBe` [FieldDecl "summary" True "一句話說明這個片段講什麼"]
            tdAllowedLinks d `shouldBe` [PartOf, Contradicts]
            tdStages d `shouldBe` ["定位", "細節"]
          other -> expectationFailure ("預期一個型別,卻得到:" <> show other)

    it "空目錄回空註冊表,不是錯誤(naming.toml 仍要有)" $
      withRegistryDir [] $ \dir -> do
        r <- loadRegistry dir
        fmap typeKeys (regOf r) `shouldBe` Just []

    it "非 .toml 的檔案被忽略" $
      withRegistryDir
        [ ("a.toml", goodToml "a-fragment" "甲片段")
        , ("README.md", "這不是型別宣告")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          fmap (length . typeKeys) (regOf r) `shouldBe` Just 1

    it "目錄不存在時回 RegistryDirMissing" $ do
      r <- loadRegistry "no-such-directory-here"
      errsOf r `shouldBe` [RegistryDirMissing "no-such-directory-here"]

  describe "loadRegistry —— naming.toml" $ do
    it "缺少 naming.toml 回 NamingFileMissing" $
      withRegistryDirRaw [("a.toml", goodToml "a-fragment" "甲")] $ \dir -> do
        r <- loadRegistry dir
        case errsOf r of
          [NamingFileMissing fp] -> fp `shouldSatisfy` isInfixOf "naming.toml"
          other -> expectationFailure ("預期 NamingFileMissing,卻得到:" <> show other)

    it "kinds 不是字串陣列時回 BadFieldType" $
      withRegistryDirRaw
        [ ("a.toml", goodToml "a-fragment" "甲")
        , ("naming.toml", "kinds = [1, 2]\ndomains = []\n")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["kinds"]

    it "kinds 內有分段格式不合法的值時回 BadFieldType" $
      withRegistryDirRaw
        [ ("a.toml", goodToml "a-fragment" "甲")
        , ("naming.toml", "kinds = [\"UPPER\"]\ndomains = []\n")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["kinds"]

    it "認不得的鍵時回 UnknownKey" $
      withRegistryDirRaw
        [ ("a.toml", goodToml "a-fragment" "甲")
        , ("naming.toml", "kinds = []\ndomains = []\nfoo = 1\n")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["foo"]

    it "kinds / domains / states 都能正確讀出(對照專案的 naming.toml 內容)" $
      withRegistryDir [] $ \dir -> do
        r <- loadRegistry dir
        case vocabOf r of
          Just vocab -> do
            length (nvKinds vocab) `shouldBe` 12
            nvDomains vocab `shouldBe` []
            length (nvStates vocab) `shouldBe` 37
          Nothing -> expectationFailure ("載入失敗:" <> show (errsOf r))

    it "states 不是字串陣列時回 BadFieldType" $
      withRegistryDirRaw
        [ ("a.toml", goodToml "a-fragment" "甲")
        , ("naming.toml", "kinds = []\ndomains = []\nstates = [1, 2]\n")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["states"]

  describe "loadRegistry —— family" $ do
    it "缺少 family 回 MissingField" $
      withRegistryDir [("nofamily.toml", "key = \"a-fragment\"\nname = \"甲\"\n")] $ \dir -> do
        r <- loadRegistry dir
        map fieldOf (errsOf r) `shouldBe` ["family"]

    it "family 不是 entity / asset 時回 UnknownFamily" $
      withRegistryDir
        [("badfamily.toml", "key = \"a-fragment\"\nname = \"甲\"\nfamily = \"weird\"\n")]
        $ \dir -> do
          r <- loadRegistry dir
          case errsOf r of
            [UnknownFamily fp v] -> do
              fp `shouldSatisfy` isInfixOf "badfamily.toml"
              v `shouldBe` "weird"
            other -> expectationFailure ("預期 UnknownFamily,卻得到:" <> show other)

    it "asset 族沒明寫 depicts 時載入器自動補上" $
      withRegistryDir [("a.toml", assetToml "asset-thing" ["spr"])] $ \dir -> do
        r <- loadRegistry dir
        case regOf r >>= \reg -> lookupType reg (TypeKey "asset-thing") of
          Just d -> tdAllowedLinks d `shouldBe` [Depicts]
          Nothing -> expectationFailure "應能查到 asset-thing"

    it "asset 族已明寫 depicts 時不重複" $
      withRegistryDir
        [ ( "a.toml"
          , T.unlines
              [ "key = \"asset-thing\""
              , "name = \"測試素材\""
              , "family = \"asset\""
              , "allowed_links = [\"depicts\"]"
              , "name_kinds = [\"spr\"]"
              ]
          )
        ]
        $ \dir -> do
          r <- loadRegistry dir
          case regOf r >>= \reg -> lookupType reg (TypeKey "asset-thing") of
            Just d -> tdAllowedLinks d `shouldBe` [Depicts]
            Nothing -> expectationFailure "應能查到 asset-thing"

    it "entity 族不會被自動加上 depicts" $
      withRegistryDir [("a.toml", goodToml "a-fragment" "甲片段")] $ \dir -> do
        r <- loadRegistry dir
        case regOf r >>= \reg -> lookupType reg (TypeKey "a-fragment") of
          Just d -> tdAllowedLinks d `shouldBe` [PartOf, Contradicts]
          Nothing -> expectationFailure "應能查到 a-fragment"

  describe "loadRegistry —— 錯誤一次回報,且一律帶檔名" $ do
    it "某檔語法錯誤回 TomlParseError 並帶該檔名" $
      withRegistryDir
        [ ("bad.toml", "key = = \"壞掉的語法\"")
        , ("good.toml", goodToml "a-fragment" "甲片段")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          case errsOf r of
            [TomlParseError fp _] -> fp `shouldSatisfy` isInfixOf "bad.toml"
            other -> expectationFailure ("預期一個解析錯誤,卻得到:" <> show other)

    it "某檔壞掉時其餘檔案仍被讀取,錯誤一次回報" $
      withRegistryDir
        [ ("bad1.toml", "key = = \"壞\"")
        , ("bad2.toml", "name = = \"也壞\"")
        , ("good.toml", goodToml "a-fragment" "甲片段")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          length (errsOf r) `shouldBe` 2

    it "缺少 key 回 MissingField 並帶檔名" $
      withRegistryDir [("nokey.toml", "name = \"沒有 key\"\nfamily = \"entity\"\n")] $ \dir -> do
        r <- loadRegistry dir
        case errsOf r of
          [MissingField fp k] -> do
            fp `shouldSatisfy` isInfixOf "nokey.toml"
            k `shouldBe` "key"
          other -> expectationFailure ("預期 MissingField,卻得到:" <> show other)

    it "同一個檔缺多個必填鍵時全部都回報" $
      withRegistryDir [("empty.toml", "stages = []")] $ \dir -> do
        r <- loadRegistry dir
        sort (map fieldOf (errsOf r)) `shouldBe` ["family", "key", "name"]

    it "欄位型別不對回 BadFieldType 並帶檔名與欄位名" $
      withRegistryDir
        [("badtype.toml", "key = \"a-fragment\"\nname = 42\nfamily = \"entity\"\n")]
        $ \dir -> do
          r <- loadRegistry dir
          case errsOf r of
            [BadFieldType fp k want] -> do
              fp `shouldSatisfy` isInfixOf "badtype.toml"
              k `shouldBe` "name"
              want `shouldBe` "字串"
            other -> expectationFailure ("預期 BadFieldType,卻得到:" <> show other)

    -- 這是實作時真的踩到的坑:allowed_links 寫在 [[fields]] 之後,
    -- 依 TOML 語意會變成該 field 的子鍵,於是型別的關聯清單靜默變成空的。
    -- 不容忍未知鍵就是為了讓它當場爆掉,而不是少一半設定還載入成功。
    it "allowed_links 誤寫在 [[fields]] 之後時回 UnknownKey 而非靜默忽略" $
      withRegistryDir
        [ ( "misplaced.toml"
          , T.unlines
              [ "key    = \"a-fragment\""
              , "name   = \"甲片段\""
              , "family = \"entity\""
              , ""
              , "[[fields]]"
              , "name = \"summary\""
              , "required = true"
              , "hint = \"說明\""
              , ""
              , "allowed_links = [\"partOf\"]"
              ]
          )
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["fields[].allowed_links"]

    it "最上層出現認不得的鍵時回 UnknownKey" $
      withRegistryDir
        [ ( "typo.toml"
          , "key = \"a-fragment\"\nname = \"甲\"\nfamily = \"entity\"\nallowd_links = []\n"
          )
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["allowd_links"]

    it "重複型別鍵回 DuplicateTypeKey" $
      withRegistryDir
        [ ("a.toml", goodToml "same-key" "甲")
        , ("b.toml", goodToml "same-key" "乙")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          errsOf r `shouldBe` [DuplicateTypeKey (TypeKey "same-key")]

    it "asset-pack / asset-license / level 出現在註冊表是載入錯誤" $
      withRegistryDir
        [ ("bad1.toml", goodToml "level" "關卡")
        , ("bad2.toml", goodToml "asset-pack" "包")
        , ("bad3.toml", goodToml "asset-license" "授權")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          let ks = sort [k | ReservedTypeKey (TypeKey k) <- errsOf r]
          ks `shouldBe` ["asset-license", "asset-pack", "level"]

    it "renderRegistryError 的訊息一定含檔名" $
      withRegistryDir [("nokey.toml", "name = \"沒有 key\"\nfamily = \"entity\"\n")] $ \dir -> do
        r <- loadRegistry dir
        let msgs = map renderRegistryError (errsOf r)
        msgs `shouldSatisfy` all (T.isInfixOf "nokey.toml")

  describe "T12 —— naming.toml 與 family 的整合" $ do
    it "缺 naming.toml 回 NamingFileMissing(與上方一致,單獨掛在驗收清單下)" $
      withRegistryDirRaw [("a.toml", goodToml "a-fragment" "甲")] $ \dir -> do
        r <- loadRegistry dir
        case errsOf r of
          [NamingFileMissing _] -> pure ()
          other -> expectationFailure ("預期 NamingFileMissing,卻得到:" <> show other)

    it "13 份 fixture TOML(5 entity + 8 asset)整批可載入,TypeRegistry 含全部鍵" $
      withRegistryDir
        ( [(T.unpack k <> ".toml", goodToml k (k <> " 型別")) | k <- entityFixtureKeys]
            ++ [(T.unpack k <> ".toml", assetToml k ks) | (k, ks) <- assetFixtureSpecs]
        )
        $ \dir -> do
          r <- loadRegistry dir
          case regOf r of
            Just reg ->
              sort (typeKeys reg) `shouldBe` sort (entityFixtureKeys ++ map fst assetFixtureSpecs)
            Nothing -> expectationFailure ("載入失敗:" <> show (errsOf r))

    it "locateRegistry 環境變數指向不存在的目錄時回 RegistryNotFound 並列出查過的路徑" $
      withSystemTempDirectory "aapms-noreg" $ \dir -> do
        let missing = dir </> "不存在"
        withEnvVar registryEnvVar (Just missing) $
          locateRegistryWith (pure (dir </> "aapms.exe"))
            `shouldReturn` Left (RegistryNotFound [missing])

  describe "T13 —— 專案實際的 types/registry/" $ do
    it "loadRegistry 對真實目錄成功,13 個型別鍵(5 entity + 8 asset)" $ do
      r <- loadRegistry projectRegistryDir
      case regOf r of
        Just reg -> do
          let ks = typeKeys reg
          length ks `shouldBe` 13
          sort ks
            `shouldBe` sort (entityFixtureKeys ++ map fst assetFixtureSpecs)
        Nothing -> expectationFailure ("專案實檔載入失敗:" <> show (errsOf r))

    it "NamingVocab 的 nvKinds 恰好 12 個,nvDomains 為空,nvStates 恰好 37 個" $ do
      r <- loadRegistry projectRegistryDir
      case vocabOf r of
        Just vocab -> do
          length (nvKinds vocab) `shouldBe` 12
          nvDomains vocab `shouldBe` []
          length (nvStates vocab) `shouldBe` 37
        Nothing -> expectationFailure ("專案實檔載入失敗:" <> show (errsOf r))

    it "沒有型別佔用保留鍵 level / asset-pack / asset-license" $ do
      r <- loadRegistry projectRegistryDir
      case regOf r of
        Just reg -> typeKeys reg `shouldSatisfy` all (`notElem` ["level", "asset-pack", "asset-license"])
        Nothing -> expectationFailure ("專案實檔載入失敗:" <> show (errsOf r))

    it "5 個 entity 族的 dir / owner_type 與既有規格相符" $ do
      r <- loadRegistry projectRegistryDir
      case regOf r of
        Just reg ->
          [(k, lookupType reg (TypeKey k) >>= tdDir, lookupType reg (TypeKey k) >>= tdOwnerType) | k <- entityFixtureKeys]
            `shouldBe` [ ("character-fragment", Just "characters", Just (TypeKey "character"))
                       , ("dialogue", Just "dialogues", Nothing)
                       , ("item-fragment", Just "items", Just (TypeKey "item"))
                       , ("lore-fragment", Just "lore", Just (TypeKey "lore"))
                       , ("plot-fragment", Just "lore", Just (TypeKey "plot"))
                       ]
        Nothing -> expectationFailure ("專案實檔載入失敗:" <> show (errsOf r))

    it "8 個 asset 族的 tdFamily = FAsset、tdDir = Nothing、name_kinds 與對照表相符" $ do
      r <- loadRegistry projectRegistryDir
      case regOf r of
        Just reg ->
          mapM_
            ( \(k, kinds) -> case lookupType reg (TypeKey k) of
                Just d -> do
                  tdFamily d `shouldBe` FAsset
                  tdDir d `shouldBe` Nothing
                  map segmentText (tdNameKinds d) `shouldBe` kinds
                Nothing -> expectationFailure ("查不到 " <> T.unpack k)
            )
            assetFixtureSpecs
        Nothing -> expectationFailure ("專案實檔載入失敗:" <> show (errsOf r))

    it "8 個 asset 族的 allowed_links 都含 depicts(載入器自動補上)" $ do
      r <- loadRegistry projectRegistryDir
      case regOf r of
        Just reg ->
          mapM_
            ( \(k, _) -> case lookupType reg (TypeKey k) of
                Just d -> tdAllowedLinks d `shouldSatisfy` (Depicts `elem`)
                Nothing -> expectationFailure ("查不到 " <> T.unpack k)
            )
            assetFixtureSpecs
        Nothing -> expectationFailure ("專案實檔載入失敗:" <> show (errsOf r))

  describe "defaultRegistryDir" $ do
    it "環境變數優先" $
      withRegistryDir [("a.toml", goodToml "a-fragment" "甲")] $ \dir ->
        withEnvVar registryEnvVar (Just dir) $
          defaultRegistryDir `shouldReturn` Just dir

    it "環境變數指向不存在的目錄時回 Nothing,不偷偷退回 data-files" $
      withSystemTempDirectory "aapms-noreg" $ \dir ->
        withEnvVar registryEnvVar (Just (dir </> "不存在")) $
          defaultRegistryDir `shouldReturn` Nothing

    it "沒設環境變數時走 cabal 的 data-files,而且那裡有專案的 13 份宣告" $
      withEnvVar registryEnvVar Nothing $
        defaultRegistryDir >>= \case
          Nothing -> expectationFailure "data-files 的 registry/ 應該找得到"
          Just dir -> do
            r <- loadRegistry dir
            case regOf r of
              Nothing -> expectationFailure ("專案實檔載入失敗:" <> show (errsOf r))
              Just reg -> length (listTypes reg) `shouldBe` 13

  -- G-E002 T1:三層查找,並說出是哪一層。執行檔路徑用 locateRegistryWith 注入——
  -- 測試執行檔旁邊不會真的有 registry/。
  describe "locateRegistry(G-E002)" $ do
    it "環境變數優先,連執行檔旁都不看" $
      withRegistryDir [("a.toml", goodToml "a-fragment" "甲")] $ \envDir ->
        withSystemTempDirectory "aapms-exe" $ \exeDir -> do
          createDirectoryIfMissing True (exeDir </> "registry")
          withEnvVar registryEnvVar (Just envDir) $
            locateRegistryWith (pure (exeDir </> "aapms.exe"))
              `shouldReturn` Right (envDir, FromEnv)

    it "沒設環境變數時,執行檔旁的 registry/ 先於 data-files" $
      withSystemTempDirectory "aapms-exe" $ \exeDir -> do
        createDirectoryIfMissing True (exeDir </> "registry")
        withEnvVar registryEnvVar Nothing $
          locateRegistryWith (pure (exeDir </> "aapms.exe"))
            `shouldReturn` Right (exeDir </> "registry", BesideExecutable)

    it "執行檔旁沒有 registry/ 就退到 data-files" $
      withSystemTempDirectory "aapms-exe" $ \exeDir ->
        withEnvVar registryEnvVar Nothing $
          locateRegistryWith (pure (exeDir </> "aapms.exe")) >>= \case
            Right (_, FromDataDir) -> pure ()
            other -> expectationFailure ("應退到 data-files,實得 " <> show other)

    it "環境變數指向不存在的目錄時回 RegistryNotFound,不往執行檔旁退" $
      withSystemTempDirectory "aapms-exe" $ \exeDir -> do
        createDirectoryIfMissing True (exeDir </> "registry")
        let missing = exeDir </> "不存在"
        withEnvVar registryEnvVar (Just missing) $
          locateRegistryWith (pure (exeDir </> "aapms.exe"))
            `shouldReturn` Left (RegistryNotFound [missing])

-- | 設定(或清掉)一個環境變數跑一段,結束後還原。
withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar name mv act = bracket save restore (const act)
  where
    save = do
      old <- lookupEnv name
      maybe (unsetEnv name) (setEnv name) mv
      pure old
    restore = maybe (unsetEnv name) (setEnv name)
