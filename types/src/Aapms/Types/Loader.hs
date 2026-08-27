-- | 型別註冊表的載入層。__本套件唯一的 IO 就是讀檔__。
--
-- 掃描目錄下所有 @*.toml@(排除 @naming.toml@,那份是命名文法詞彙表,不是型別
-- 宣告),逐檔解析,彙整後交給 "Aapms.Core.Registry" 的純驗證函式。單檔解析
-- 失敗__不中斷__,繼續讀其餘檔案,最後一次回報全部問題——作者一次改好幾份
-- 型別宣告時,修一個跑一次太慢。
--
-- 所有錯誤訊息一律帶檔名。ADR-005 明說型別宣告寫錯只能在載入時檢查並報錯,
-- 而沒有檔名的錯誤訊息在多個型別檔時等於沒有。
--
-- __套件歸屬__(design.md 契約 C,2026-08-23 釐清):純型別('Family' /
-- 'TypeDecl' / 'TypeRegistry' / 'NamingVocab' / 'lookupType' 與純驗證錯誤)定義
-- 在 "Aapms.Core.Registry" / "Aapms.Core.Naming",本模組只有 'locateRegistry' \/
-- 'loadRegistry' 兩個 IO 入口與 TOML 解析,並 re-export 上述型別。
module Aapms.Types.Loader
  ( -- * 執行期定位
    RegistrySource (..)
  , locateRegistry
  , locateRegistryWith
  , registryBesideExecutable
  , defaultRegistryDir
  , registryEnvVar

    -- * 載入
  , loadRegistry
  , loadRegistryFrom

    -- * re-export:aapms-core 的純型別與純驗證(契約 C)
  , module Aapms.Core.Registry
  , module Aapms.Core.Naming
  ) where

import Aapms.Core.Link (LinkKind (Depicts), parseLinkKind)
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Naming
import Aapms.Core.Registry
import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.Either (partitionEithers)
import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, takeExtension, (</>))
import qualified TOML

import Paths_aapms_types (getDataDir)

-- 執行期定位 -----------------------------------------------------------------

-- | 覆寫註冊表位置的環境變數名。
--
-- 常數放在這裡而不是各呼叫端各寫一份字串:錯字不會被編譯器擋下來,而
-- 「設了環境變數卻沒生效」是最難查的那種設定問題。
--
-- __不改名__:P0 進度明寫 @STORYFLOW_*@ 環境變數是刻意留到 P3 由 @workspace@
-- 依 ADR-017 改的執行期名稱,graph-core 不碰。
registryEnvVar :: String
registryEnvVar = "STORYFLOW_REGISTRY"

-- | 註冊表是從哪一層找到的。
--
-- @doctor@ 要說得出來,找不到時的錯誤訊息也要列得出找過哪裡(G-E002)。
data RegistrySource
  = -- | 'registryEnvVar' 指到的目錄
    FromEnv
  | -- | 執行檔所在目錄底下的 @registry\/@ ——zip 解開就能跑靠的是這一層
    BesideExecutable
  | -- | cabal 的 @data-files@,@cabal install@ 之後才存在
    FromDataDir
  deriving stock (Show, Eq)

-- | 型別註冊表在執行期的目錄,連同它是從哪一層找到的。
--
-- 三層,順序固定:
--
-- 1. 'registryEnvVar' ——開發時指向工作目錄的 @types\/registry\/@,作者要自訂型別
--    時也不必重編譯
-- 2. 執行檔旁的 @registry\/@ ——只複製執行檔到別台機器時,烙印的 cabal 路徑不存在,
--    這一層是唯一能跑起來的方式。放在 @data-files@ __之前__:同一台機器上有舊的
--    cabal 安裝時,zip 解開的那份要用自己帶的註冊表
-- 3. cabal 的 @data-files@(見 @aapms-types.cabal@)
--
-- __找到的目錄必須真的存在__,否則往下一層找;三層都沒有就回
-- 'RegistryNotFound',列出查過的路徑。
--
-- __例外是第一層__:環境變數指向不存在的目錄時__不往下退__——那會讓一個打錯的
-- 環境變數靜默地載入另一份註冊表;錯誤訊息只列出那一個查過的路徑。
locateRegistry :: IO (Either RegistryError (FilePath, RegistrySource))
locateRegistry = locateRegistryWith getExecutablePath

-- | 「執行檔旁」那一層__會去查__的路徑,不管它存不存在。
--
-- 找不到註冊表時的錯誤訊息要說得出「我查過這裡」;`service` 不依賴 `filepath`
-- 與 `directory`,這個路徑由本模組算好給它。
registryBesideExecutable :: IO FilePath
registryBesideExecutable = (</> "registry") . takeDirectory <$> getExecutablePath

-- | 'locateRegistry' 的可注入版本:執行檔路徑由呼叫端給。
--
-- 測試要驗「執行檔旁」這一層,而測試執行檔旁邊不會真的有 @registry\/@;
-- 把 'getExecutablePath' 換成指向臨時目錄的動作就測得到。
locateRegistryWith :: IO FilePath -> IO (Either RegistryError (FilePath, RegistrySource))
locateRegistryWith exePath =
  lookupEnv registryEnvVar >>= \case
    Just p | not (null p) -> do
      found <- existing p
      pure $ case found of
        Just d -> Right (d, FromEnv)
        Nothing -> Left (RegistryNotFound [p])
    _ -> do
      besideDir <- (</> "registry") . takeDirectory <$> exePath
      besideFound <- existing besideDir
      case besideFound of
        Just d -> pure (Right (d, BesideExecutable))
        Nothing -> do
          baseE <- try getDataDir :: IO (Either IOException FilePath)
          case baseE of
            Left e ->
              pure (Left (RegistryNotFound [besideDir, "(cabal data-files 目錄無法定位:" <> show e <> ")"]))
            Right base -> do
              let dataDir = base </> "registry"
              dataFound <- existing dataDir
              pure $ case dataFound of
                Just d -> Right (d, FromDataDir)
                Nothing -> Left (RegistryNotFound [besideDir, dataDir])
  where
    existing p = do
      ok <- doesDirectoryExist p
      pure (if ok then Just p else Nothing)

-- | 'locateRegistry' 的投影:只要目錄,不問來源、不問失敗原因。
defaultRegistryDir :: IO (Maybe FilePath)
defaultRegistryDir = either (const Nothing) (Just . fst) <$> locateRegistry

-- 載入 ------------------------------------------------------------------------

-- | 命名文法詞彙表的檔名。載入時特別排除,不當成型別宣告解析。
namingFileName :: FilePath
namingFileName = "naming.toml"

-- | 掃描目錄下所有 @*.toml@(排除 'namingFileName')並建成註冊表 +
-- 詞彙表。空目錄(扣掉 @naming.toml@ 之後沒有任何型別宣告)仍是合法的空
-- 註冊表,不是錯誤;缺 @naming.toml@ 才是錯誤('NamingFileMissing')。
loadRegistry :: FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))
loadRegistry dir = do
  ok <- doesDirectoryExist dir
  if not ok
    then pure (Left (RegistryDirMissing dir))
    else do
      names <- listDirectory dir
      let files = sort [dir </> n | n <- names, takeExtension n == ".toml", n /= namingFileName]
      loadRegistryFrom files (dir </> namingFileName)

-- | 由明確的型別宣告檔清單 + 明確的 @naming.toml@ 路徑載入。供測試指定臨時
-- 目錄,與未來「內建 + Vault 覆蓋」兩層註冊表使用。
loadRegistryFrom :: [FilePath] -> FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))
loadRegistryFrom typeFiles namingPath = do
  declResults <- mapM readSpec typeFiles
  namingExists <- doesFileExist namingPath
  vocabResult <-
    if namingExists
      then readNamingToml namingPath
      else pure (Left [NamingFileMissing namingPath])
  let (declErrss, decls) = partitionEithers declResults
      declErrs = concat declErrss
      (vocabErrs, mVocab) = case vocabResult of
        Left es -> (es, Nothing)
        Right v -> ([], Just v)
      parseErrs = declErrs ++ vocabErrs
  pure $
    if not (null parseErrs)
      then Left (aggregate parseErrs)
      else case (buildRegistry decls, mVocab) of
        (Left es, _) -> Left (aggregate es)
        (Right reg, Just vocab) -> Right (reg, vocab)
        (Right _, Nothing) -> Left (aggregate [NamingFileMissing namingPath])

aggregate :: [RegistryError] -> RegistryError
aggregate [e] = e
aggregate es = RegistryErrors es

-- | 讀一個檔並解析成一份型別宣告。回傳該檔的__全部__問題。
readSpec :: FilePath -> IO (Either [RegistryError] TypeDecl)
readSpec fp = do
  raw <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
  pure $ case raw of
    Left e -> Left [TomlParseError fp (T.pack (show e))]
    Right bytes -> case TE.decodeUtf8' bytes of
      Left e -> Left [TomlParseError fp ("檔案不是合法的 UTF-8:" <> T.pack (show e))]
      Right txt -> case TOML.decode txt of
        Left e -> Left [TomlParseError fp (TOML.renderTOMLError e)]
        Right (TOML.Table tbl) -> parseSpec fp tbl
        Right _ -> Left [TomlParseError fp "檔案的最上層不是 TOML 表"]

parseSpec :: FilePath -> TOML.Table -> Either [RegistryError] TypeDecl
parseSpec fp tbl =
  case (errs, mspec) of
    ([], Just s) -> Right s
    _ -> Left errs
  where
    ekey = TypeKey <$> reqString fp tbl "key"
    ename = reqString fp tbl "name"
    efamily = reqString fp tbl "family" >>= parseFamilyField
    efields = optArray fp tbl "fields" >>= traverse (fieldSpec fp)
    elinksRaw = optStrings fp tbl "allowed_links"
    estages = optStrings fp tbl "stages"
    edir = fmap T.unpack <$> optMaybeString fp tbl "dir"
    eowner = fmap TypeKey <$> optMaybeString fp tbl "owner_type"
    enameKinds = optStrings fp tbl "name_kinds" >>= traverse (toSegment fp "name_kinds")

    -- asset 族即使留空,載入器也會補上 depicts(契約卡)。
    elinks = do
      fam <- efamily
      raw <- elinksRaw
      let ks = map parseLinkKind raw
      pure $ case fam of
        FAsset | Depicts `notElem` ks -> ks ++ [Depicts]
        _ -> ks

    unknownErrs =
      [UnknownKey fp k | k <- M.keys tbl, k `notElem` topLevelKeys]

    parseFamilyField t = case parseFamily t of
      Just f -> Right f
      Nothing -> Left [UnknownFamily fp t]

    errs =
      concat
        [ lefts1 ekey
        , lefts1 ename
        , lefts1 efamily
        , lefts1 efields
        , lefts1 elinksRaw
        , lefts1 estages
        , lefts1 edir
        , lefts1 eowner
        , lefts1 enameKinds
        , unknownErrs
        ]

    mspec =
      TypeDecl
        <$> toMaybe ekey
        <*> toMaybe ename
        <*> toMaybe efamily
        <*> toMaybe edir
        <*> toMaybe eowner
        <*> toMaybe elinks
        <*> toMaybe estages
        <*> toMaybe efields
        <*> toMaybe enameKinds

-- | 型別宣告的最上層允許的鍵。
--
-- @family@ \/ @name_kinds@ 是 graph-core\/F002 新增的兩個鍵(前者必填,後者
-- 只有 asset 族需要)。@dir@ \/ @owner_type@ 沿用既有的選配慣例。
topLevelKeys :: [Text]
topLevelKeys =
  ["key", "name", "family", "fields", "allowed_links", "stages", "dir", "owner_type", "name_kinds"]

-- | 每個 @[[fields]]@ 表允許的鍵。
fieldKeys :: [Text]
fieldKeys = ["name", "required", "hint"]

fieldSpec :: FilePath -> TOML.Value -> Either [RegistryError] FieldDecl
fieldSpec fp v = case v of
  TOML.Table t ->
    let unknown = [UnknownKey fp ("fields[]." <> k) | k <- M.keys t, k `notElem` fieldKeys]
     in case (reqString fp t "fields[].name", optBool fp t "required", optString fp t "hint") of
          (Right n, Right r, Right h)
            | null unknown -> Right (FieldDecl n r h)
          (a, b, c) -> Left (concat [lefts1 a, lefts1 b, lefts1 c, unknown])
  _ -> Left [BadFieldType fp "fields[]" "表(每個 [[fields]] 都是一個表)"]

-- naming.toml -----------------------------------------------------------------

-- | 讀 @naming.toml@:@kinds@(強制詞彙,命名文法第一段的合法值)、@domains@
-- (不強制,只為與 @kinds@ 對稱)、@states@(強制、封閉,'parseLogicalName'
-- 拆解時唯一查的表,2026-08-23 階段一閘門新增)三個字串陣列。
readNamingToml :: FilePath -> IO (Either [RegistryError] NamingVocab)
readNamingToml fp = do
  raw <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
  pure $ case raw of
    Left e -> Left [TomlParseError fp (T.pack (show e))]
    Right bytes -> case TE.decodeUtf8' bytes of
      Left e -> Left [TomlParseError fp ("檔案不是合法的 UTF-8:" <> T.pack (show e))]
      Right txt -> case TOML.decode txt of
        Left e -> Left [TomlParseError fp (TOML.renderTOMLError e)]
        Right (TOML.Table tbl) -> parseNaming fp tbl
        Right _ -> Left [TomlParseError fp "檔案的最上層不是 TOML 表"]

parseNaming :: FilePath -> TOML.Table -> Either [RegistryError] NamingVocab
parseNaming fp tbl =
  case (errs, mvocab) of
    ([], Just v) -> Right v
    _ -> Left errs
  where
    eKinds = optStrings fp tbl "kinds" >>= traverse (toSegment fp "kinds")
    eDomains = optStrings fp tbl "domains" >>= traverse (toSegment fp "domains")
    eStates = optStrings fp tbl "states" >>= traverse (toSegment fp "states")
    unknownErrs = [UnknownKey fp k | k <- M.keys tbl, k `notElem` ["kinds", "domains", "states"]]
    errs = concat [lefts1 eKinds, lefts1 eDomains, lefts1 eStates, unknownErrs]
    mvocab = NamingVocab <$> toMaybe eKinds <*> toMaybe eDomains <*> toMaybe eStates

-- | 字串轉命名文法分段,失敗時帶欄位名的 'BadFieldType'。
toSegment :: FilePath -> Text -> Text -> Either [RegistryError] Segment
toSegment fp field t = case mkSegment t of
  Right s -> Right s
  Left _ -> Left [BadFieldType fp field "命名文法分段(^[a-z0-9]+(-[a-z0-9]+)*$)"]

-- 取值輔助 -------------------------------------------------------------------

reqString :: FilePath -> TOML.Table -> Text -> Either [RegistryError] Text
reqString fp t k = case M.lookup (baseKey k) t of
  Nothing -> Left [MissingField fp k]
  Just (TOML.String s) -> Right s
  Just _ -> Left [BadFieldType fp k "字串"]

optString :: FilePath -> TOML.Table -> Text -> Either [RegistryError] Text
optString fp t k = case M.lookup k t of
  Nothing -> Right ""
  Just (TOML.String s) -> Right s
  Just _ -> Left [BadFieldType fp k "字串"]

-- | 沒寫與寫了空字串是__不同的兩件事__(前者「這個型別沒宣告目錄」,
-- 後者「宣告放在 Vault 根」),所以不能沿用 'optString' 的空字串預設值。
optMaybeString :: FilePath -> TOML.Table -> Text -> Either [RegistryError] (Maybe Text)
optMaybeString fp t k = case M.lookup k t of
  Nothing -> Right Nothing
  Just (TOML.String s) -> Right (Just s)
  Just _ -> Left [BadFieldType fp k "字串"]

optBool :: FilePath -> TOML.Table -> Text -> Either [RegistryError] Bool
optBool fp t k = case M.lookup k t of
  Nothing -> Right False
  Just (TOML.Boolean b) -> Right b
  Just _ -> Left [BadFieldType fp k "布林值"]

optArray :: FilePath -> TOML.Table -> Text -> Either [RegistryError] [TOML.Value]
optArray fp t k = case M.lookup k t of
  Nothing -> Right []
  Just (TOML.Array xs) -> Right xs
  Just _ -> Left [BadFieldType fp k "陣列"]

optStrings :: FilePath -> TOML.Table -> Text -> Either [RegistryError] [Text]
optStrings fp t k = optArray fp t k >>= traverse str
  where
    str (TOML.String s) = Right s
    str _ = Left [BadFieldType fp k "字串陣列"]

-- | @fields[].name@ 這種顯示用的鍵名,查表時只用最後一段。
baseKey :: Text -> Text
baseKey k = case T.splitOn "." k of
  [] -> k
  parts -> last parts

lefts1 :: Either [RegistryError] a -> [RegistryError]
lefts1 = either id (const [])

toMaybe :: Either [RegistryError] a -> Maybe a
toMaybe = either (const Nothing) Just
