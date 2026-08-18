-- | 型別註冊表的載入層。__本套件唯一的 IO 就是讀檔__。
--
-- 掃描目錄下所有 @*.toml@,逐檔解析,彙整後交給 "StoryFlow.Core.Registry" 的純
-- 驗證函式。單檔解析失敗__不中斷__,繼續讀其餘檔案,最後一次回報全部問題——
-- 作者一次改好幾份型別宣告時,修一個跑一次太慢。
--
-- 所有錯誤訊息一律帶檔名。ADR-0005 明說型別宣告寫錯只能在載入時檢查並報錯,
-- 而沒有檔名的錯誤訊息在 5 個以上型別檔時等於沒有。
module StoryFlow.Types.Loader
  ( -- * 執行期定位
    defaultRegistryDir
  , registryEnvVar

    -- * 載入
  , loadRegistry
  , loadRegistryFrom
  , LoadError (..)
  , renderLoadError
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.Either (partitionEithers)
import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Core.Link (parseLinkKind)
import StoryFlow.Core.Registry
  ( EntityTypeSpec (..)
  , FieldSpec (..)
  , RegistryError
  , TypeRegistry
  , validateRegistry
  )
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeExtension, (</>))
import qualified TOML

import Paths_storyflow_types (getDataDir)

-- 執行期定位 -----------------------------------------------------------------

-- | 覆寫註冊表位置的環境變數名。
--
-- 常數放在這裡而不是各呼叫端各寫一份字串:錯字不會被編譯器擋下來,而
-- 「設了環境變數卻沒生效」是最難查的那種設定問題。
registryEnvVar :: String
registryEnvVar = "STORYFLOW_REGISTRY"

-- | 型別註冊表在執行期的目錄。
--
-- @cabal install@ 之後的執行檔沒有原始碼樹的相對路徑,因此正式的來源是 cabal
-- 的 @data-files@(見 @storyflow-types.cabal@);'registryEnvVar' 有值時優先
-- ——開發時指向工作目錄的 @types\/registry\/@,作者要自訂型別時也不必重編譯。
--
-- __找到的目錄必須真的存在__,否則回 'Nothing':回一個不存在的路徑只會讓
-- 錯誤延後到 'loadRegistry' 才爆,而且訊息會變成「目錄不存在」而不是
-- 「你的環境變數指錯地方」。環境變數指向不存在的目錄時__不退回 @data-files@__
-- ——那會讓一個打錯的環境變數靜默地載入另一份註冊表。
defaultRegistryDir :: IO (Maybe FilePath)
defaultRegistryDir =
  lookupEnv registryEnvVar >>= \case
    Just p | not (null p) -> existing p
    _ -> do
      base <- try getDataDir :: IO (Either IOException FilePath)
      either (const (pure Nothing)) (existing . (</> "registry")) base
  where
    existing p = do
      ok <- doesDirectoryExist p
      pure (if ok then Just p else Nothing)

data LoadError
  = -- | 檔名 + 解析器訊息
    TomlParseError FilePath Text
  | -- | 檔名 + 缺少的必填鍵
    MissingField FilePath Text
  | -- | 檔名 + 欄位名 + 期望的型別
    BadFieldType FilePath Text Text
  | -- | 檔名 + 認不得的鍵。__不容忍未知鍵__:TOML 的表頭語意讓
    -- @allowed_links@ 寫在 @[[fields]]@ 之後就會靜默變成 field 的子鍵,
    -- 而 ADR-0005 的立場是宣告寫錯要當場報錯,不是默默少一半設定
    UnknownKey FilePath Text
  | -- | 註冊表目錄不存在(空目錄是合法的,不存在不是)
    RegistryDirMissing FilePath
  | RegistryInvalid RegistryError
  deriving stock (Show, Eq)

renderLoadError :: LoadError -> Text
renderLoadError = \case
  TomlParseError fp msg -> pack fp <> ": TOML 解析失敗 —— " <> msg
  MissingField fp k -> pack fp <> ": 缺少必填鍵 `" <> k <> "`"
  BadFieldType fp k want ->
    pack fp <> ": 鍵 `" <> k <> "` 的型別不對,應為" <> want
  UnknownKey fp k ->
    pack fp
      <> ": 認不得的鍵 `"
      <> k
      <> "`。注意 TOML 的表頭語意——寫在 [[fields]] 之後的鍵會變成該 field 的子鍵,"
      <> "allowed_links 與 stages 必須放在所有 [[fields]] __之前__"
  RegistryDirMissing fp -> pack fp <> ": 型別註冊表目錄不存在"
  RegistryInvalid e -> "型別宣告不合法 —— " <> pack (show e)
  where
    pack = T.pack

-- | 掃描目錄下所有 @*.toml@ 並建成註冊表。空目錄回傳空註冊表,不是錯誤。
loadRegistry :: FilePath -> IO (Either [LoadError] TypeRegistry)
loadRegistry dir = do
  ok <- doesDirectoryExist dir
  if not ok
    then pure (Left [RegistryDirMissing dir])
    else do
      names <- listDirectory dir
      let files = sort [dir </> n | n <- names, takeExtension n == ".toml"]
      loadRegistryFrom files

-- | 由明確的檔案清單載入。供測試與未來的「內建 + Vault 覆蓋」兩層註冊表使用。
loadRegistryFrom :: [FilePath] -> IO (Either [LoadError] TypeRegistry)
loadRegistryFrom files = do
  results <- mapM readSpec files
  let (errss, specs) = partitionEithers results
      errs = concat errss
  pure $
    if not (null errs)
      then Left errs
      else case validateRegistry specs of
        Left res -> Left (map RegistryInvalid res)
        Right reg -> Right reg

-- | 讀一個檔並解析成一份型別宣告。回傳該檔的__全部__問題。
readSpec :: FilePath -> IO (Either [LoadError] EntityTypeSpec)
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

parseSpec :: FilePath -> TOML.Table -> Either [LoadError] EntityTypeSpec
parseSpec fp tbl =
  case (errs, mspec) of
    ([], Just s) -> Right s
    _ -> Left errs
  where
    ekey = reqString fp tbl "key"
    ename = reqString fp tbl "name"
    efields = optArray fp tbl "fields" >>= traverse (fieldSpec fp)
    elinks = fmap (map parseLinkKind) (optStrings fp tbl "allowed_links")
    estages = optStrings fp tbl "stages"
    edir = optMaybeString fp tbl "dir"
    eowner = optMaybeString fp tbl "owner_type"

    unknownErrs =
      [UnknownKey fp k | k <- M.keys tbl, k `notElem` topLevelKeys]

    errs =
      concat
        [ lefts1 ekey
        , lefts1 ename
        , lefts1 efields
        , lefts1 elinks
        , lefts1 estages
        , lefts1 edir
        , lefts1 eowner
        , unknownErrs
        ]

    mspec =
      EntityTypeSpec
        <$> toMaybe ekey
        <*> toMaybe ename
        <*> toMaybe efields
        <*> toMaybe elinks
        <*> toMaybe estages
        <*> toMaybe edir
        <*> toMaybe eowner

-- | 型別宣告的最上層允許的鍵。
--
-- @dir@ 與 @owner_type@ 是 func-0005 補的,__兩個都是選配__:既有的宣告在
-- 補上它們之前必須仍能載入。
topLevelKeys :: [Text]
topLevelKeys = ["key", "name", "fields", "allowed_links", "stages", "dir", "owner_type"]

-- | 每個 @[[fields]]@ 表允許的鍵。
fieldKeys :: [Text]
fieldKeys = ["name", "required", "hint"]

fieldSpec :: FilePath -> TOML.Value -> Either [LoadError] FieldSpec
fieldSpec fp v = case v of
  TOML.Table t ->
    let unknown = [UnknownKey fp ("fields[]." <> k) | k <- M.keys t, k `notElem` fieldKeys]
     in case (reqString fp t "fields[].name", optBool fp t "required", optString fp t "hint") of
          (Right n, Right r, Right h)
            | null unknown -> Right (FieldSpec n r h)
          (a, b, c) -> Left (concat [lefts1 a, lefts1 b, lefts1 c, unknown])
  _ -> Left [BadFieldType fp "fields[]" "表(每個 [[fields]] 都是一個表)"]

-- 取值輔助 -------------------------------------------------------------------

reqString :: FilePath -> TOML.Table -> Text -> Either [LoadError] Text
reqString fp t k = case M.lookup (baseKey k) t of
  Nothing -> Left [MissingField fp k]
  Just (TOML.String s) -> Right s
  Just _ -> Left [BadFieldType fp k "字串"]

optString :: FilePath -> TOML.Table -> Text -> Either [LoadError] Text
optString fp t k = case M.lookup k t of
  Nothing -> Right ""
  Just (TOML.String s) -> Right s
  Just _ -> Left [BadFieldType fp k "字串"]

-- | 沒寫與寫了空字串是__不同的兩件事__(前者「這個型別沒宣告目錄」,
-- 後者「宣告放在 Vault 根」),所以不能沿用 'optString' 的空字串預設值。
optMaybeString :: FilePath -> TOML.Table -> Text -> Either [LoadError] (Maybe Text)
optMaybeString fp t k = case M.lookup k t of
  Nothing -> Right Nothing
  Just (TOML.String s) -> Right (Just s)
  Just _ -> Left [BadFieldType fp k "字串"]

optBool :: FilePath -> TOML.Table -> Text -> Either [LoadError] Bool
optBool fp t k = case M.lookup k t of
  Nothing -> Right False
  Just (TOML.Boolean b) -> Right b
  Just _ -> Left [BadFieldType fp k "布林值"]

optArray :: FilePath -> TOML.Table -> Text -> Either [LoadError] [TOML.Value]
optArray fp t k = case M.lookup k t of
  Nothing -> Right []
  Just (TOML.Array xs) -> Right xs
  Just _ -> Left [BadFieldType fp k "陣列"]

optStrings :: FilePath -> TOML.Table -> Text -> Either [LoadError] [Text]
optStrings fp t k = optArray fp t k >>= traverse str
  where
    str (TOML.String s) = Right s
    str _ = Left [BadFieldType fp k "字串陣列"]

-- | @fields[].name@ 這種顯示用的鍵名,查表時只用最後一段。
baseKey :: Text -> Text
baseKey k = case T.splitOn "." k of
  [] -> k
  parts -> last parts

lefts1 :: Either [LoadError] a -> [LoadError]
lefts1 = either id (const [])

toMaybe :: Either [LoadError] a -> Maybe a
toMaybe = either (const Nothing) Just
