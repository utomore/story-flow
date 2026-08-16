-- | func-0002 T10(載入與錯誤彙整)與 T11(專案實檔)的對照測試。
module StoryFlow.Types.LoaderSpec (spec) where

import qualified Data.ByteString as BS
import Data.Either (isRight)
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Core.Link (LinkKind (..))
import StoryFlow.Core.Registry
import StoryFlow.Types.Loader
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | 在臨時目錄裡放好 (檔名, 內容) 後執行動作。內容一律以 UTF-8 寫入——
-- Windows 的預設 code page 會把繁中內容寫壞,這是測試自己的坑。
withRegistryDir :: [(FilePath, Text)] -> (FilePath -> IO a) -> IO a
withRegistryDir files act =
  withSystemTempDirectory "storyflow-registry" $ \dir -> do
    createDirectoryIfMissing True dir
    mapM_ (\(n, c) -> BS.writeFile (dir </> n) (TE.encodeUtf8 c)) files
    act dir

-- | 注意鍵的順序:allowed_links 與 stages 必須在 [[fields]] __之前__,
-- 否則依 TOML 的表頭語意它們會變成該 field 的子鍵。
goodToml :: Text -> Text -> Text
goodToml key name =
  T.unlines
    [ "key  = \"" <> key <> "\""
    , "name = \"" <> name <> "\""
    , ""
    , "allowed_links = [\"partOf\", \"contradicts\"]"
    , "stages = [\"定位\", \"細節\"]"
    , ""
    , "[[fields]]"
    , "name = \"summary\""
    , "required = true"
    , "hint = \"一句話說明這個片段講什麼\""
    ]

errsOf :: Either [LoadError] TypeRegistry -> [LoadError]
errsOf = either id (const [])

-- | 專案實際的型別註冊表目錄。測試由套件根目錄(types/)執行。
projectRegistryDir :: FilePath
projectRegistryDir = "registry"

spec :: Spec
spec = do
  describe "loadRegistry —— 正常載入" $ do
    it "三個檔載入成功,listTypes 得三筆" $
      withRegistryDir
        [ ("a.toml", goodToml "a-fragment" "甲片段")
        , ("b.toml", goodToml "b-fragment" "乙片段")
        , ("c.toml", goodToml "c-fragment" "丙片段")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          fmap (map etsKey . listTypes) r
            `shouldBe` Right ["a-fragment", "b-fragment", "c-fragment"]

    it "欄位、關聯、階段都完整讀進來" $
      withRegistryDir [("a.toml", goodToml "a-fragment" "甲片段")] $ \dir -> do
        r <- loadRegistry dir
        case fmap listTypes r of
          Right [s] -> do
            etsName s `shouldBe` "甲片段"
            etsFields s
              `shouldBe` [FieldSpec "summary" True "一句話說明這個片段講什麼"]
            etsAllowedLinks s `shouldBe` [PartOf, Contradicts]
            etsStages s `shouldBe` ["定位", "細節"]
          other -> expectationFailure ("預期一個型別,卻得到:" <> show other)

    it "空目錄回空註冊表,不是錯誤" $
      withRegistryDir [] $ \dir -> do
        r <- loadRegistry dir
        fmap listTypes r `shouldBe` Right []

    it "非 .toml 的檔案被忽略" $
      withRegistryDir
        [ ("a.toml", goodToml "a-fragment" "甲片段")
        , ("README.md", "這不是型別宣告")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          fmap (length . listTypes) r `shouldBe` Right 1

    it "目錄不存在時回 RegistryDirMissing" $ do
      r <- loadRegistry "no-such-directory-here"
      errsOf r `shouldBe` [RegistryDirMissing "no-such-directory-here"]

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
      withRegistryDir [("nokey.toml", "name = \"沒有 key\"")] $ \dir -> do
        r <- loadRegistry dir
        case errsOf r of
          [MissingField fp k] -> do
            fp `shouldSatisfy` isInfixOf "nokey.toml"
            k `shouldBe` "key"
          other -> expectationFailure ("預期 MissingField,卻得到:" <> show other)

    it "缺少 name 回 MissingField" $
      withRegistryDir [("noname.toml", "key = \"a-fragment\"")] $ \dir -> do
        r <- loadRegistry dir
        map fieldOf (errsOf r) `shouldBe` ["name"]

    it "同一個檔缺兩個必填鍵時兩個都回報" $
      withRegistryDir [("empty.toml", "stages = []")] $ \dir -> do
        r <- loadRegistry dir
        sort (map fieldOf (errsOf r)) `shouldBe` ["key", "name"]

    it "欄位型別不對回 BadFieldType 並帶檔名與欄位名" $
      withRegistryDir
        [("badtype.toml", "key = \"a-fragment\"\nname = 42\n")]
        $ \dir -> do
          r <- loadRegistry dir
          case errsOf r of
            [BadFieldType fp k want] -> do
              fp `shouldSatisfy` isInfixOf "badtype.toml"
              k `shouldBe` "name"
              want `shouldBe` "字串"
            other -> expectationFailure ("預期 BadFieldType,卻得到:" <> show other)

    it "stages 不是字串陣列時回 BadFieldType" $
      withRegistryDir
        [ ( "badstages.toml"
          , "key = \"a-fragment\"\nname = \"甲\"\nstages = [1, 2]\n"
          )
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["stages"]

    -- 這是實作時真的踩到的坑:allowed_links 寫在 [[fields]] 之後,
    -- 依 TOML 語意會變成該 field 的子鍵,於是型別的關聯清單靜默變成空的。
    -- 不容忍未知鍵就是為了讓它當場爆掉,而不是少一半設定還載入成功。
    it "allowed_links 誤寫在 [[fields]] 之後時回 UnknownKey 而非靜默忽略" $
      withRegistryDir
        [ ( "misplaced.toml"
          , T.unlines
              [ "key  = \"a-fragment\""
              , "name = \"甲片段\""
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
          , "key = \"a-fragment\"\nname = \"甲\"\nallowd_links = []\n"
          )
        ]
        $ \dir -> do
          r <- loadRegistry dir
          map fieldOf (errsOf r) `shouldBe` ["allowd_links"]

    it "型別宣告本身不合法時回 RegistryInvalid" $
      withRegistryDir
        [ ("a.toml", goodToml "same-key" "甲")
        , ("b.toml", goodToml "same-key" "乙")
        ]
        $ \dir -> do
          r <- loadRegistry dir
          errsOf r `shouldBe` [RegistryInvalid (DuplicateTypeKey "same-key")]

    it "renderLoadError 的訊息一定含檔名" $
      withRegistryDir [("nokey.toml", "name = \"沒有 key\"")] $ \dir -> do
        r <- loadRegistry dir
        let msgs = map renderLoadError (errsOf r)
        msgs `shouldSatisfy` all (T.isInfixOf "nokey.toml")

  describe "T11 —— 專案實際的 types/registry/" $ do
    it "載入成功,得到五個型別" $ do
      r <- loadRegistry projectRegistryDir
      fmap (map etsKey . listTypes) r
        `shouldBe` Right
          [ "character-fragment"
          , "dialogue"
          , "item-fragment"
          , "lore-fragment"
          , "plot-fragment"
          ]

    it "全部通過 validateRegistry(loadRegistry 成功即代表通過)" $ do
      r <- loadRegistry projectRegistryDir
      isRight r `shouldBe` True

    it "每個型別都有 name、都有必填的 summary 欄位" $ do
      r <- loadRegistry projectRegistryDir
      case fmap listTypes r of
        Right ts -> do
          length ts `shouldBe` 5
          mapM_ (\s -> etsName s `shouldNotBe` "") ts
          mapM_
            ( \s ->
                filter fsRequired (etsFields s)
                  `shouldSatisfy` any ((== "summary") . fsName)
            )
            ts
        Left es -> expectationFailure (show es)

    it "每個型別都宣告了 allowed_links 與 stages" $ do
      r <- loadRegistry projectRegistryDir
      case fmap listTypes r of
        Right ts -> do
          mapM_ (\s -> etsAllowedLinks s `shouldNotBe` []) ts
          mapM_ (\s -> etsStages s `shouldNotBe` []) ts
        Left es -> expectationFailure (show es)

    it "沒有型別佔用保留鍵 level" $ do
      r <- loadRegistry projectRegistryDir
      fmap (filter (== "level") . map etsKey . listTypes) r `shouldBe` Right []

fieldOf :: LoadError -> Text
fieldOf = \case
  MissingField _ k -> k
  BadFieldType _ k _ -> k
  UnknownKey _ k -> k
  TomlParseError _ m -> m
  RegistryDirMissing fp -> T.pack fp
  RegistryInvalid e -> T.pack (show e)
