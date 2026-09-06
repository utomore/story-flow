-- | 型別註冊表與命名詞彙表的 TOML 解析,__純函式__。
--
-- "Aapms.Types.Loader" 的責任因此收成兩件事:找到檔案、把位元組讀進來。
-- 「這串文字是不是一份合規的型別宣告」完全在這裡回答 —— 它不開檔、不查目錄、
-- 不讀環境變數,同一串文字永遠得到同一個結果,測試不需要臨時目錄。
--
-- 所有錯誤訊息一律帶檔名(第一個參數):ADR-005 明說型別宣告寫錯只能在載入時
-- 檢查並報錯,而沒有檔名的錯誤訊息在多個型別檔時等於沒有。文字的來源路徑因此
-- 是解析的參數,不是解析的副作用。
--
-- 單檔解析失敗回傳該檔的__全部__問題(@Either [RegistryError]@),不是第一個就
-- 停:作者一次改好幾份型別宣告時,修一個跑一次太慢。
--
-- __套件歸屬__(design.md 契約 C):純型別('Family' \/ 'TypeDecl' \/
-- 'TypeRegistry' \/ 'NamingVocab' 與純驗證錯誤)定義在 "Aapms.Core.Registry" \/
-- "Aapms.Core.Registry.Build" \/ "Aapms.Core.Naming",本模組只把 TOML 文字翻成
-- 它們。
module Aapms.Types.Parse
  ( -- * 文字 → 宣告
    parseSpecText
  , parseNamingText

    -- * 一整個註冊表目錄的文字 → 宣告清單與命名詞彙(P-004-vault-scope)
  , parseRegistryFiles

    -- * 已解出的 TOML 表 → 宣告
  , parseSpec
  , parseNaming

    -- * 允許的鍵
  , topLevelKeys
  , fieldKeys

    -- * 錯誤彙整
  , aggregate
  ) where

import Aapms.Core.Link (LinkKind (Depicts), parseLinkKind)
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Naming
import Aapms.Core.Registry
import Aapms.Core.Registry.Build
import Data.Either (partitionEithers)
import Data.List (partition)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (takeDirectory, takeFileName, (</>))
import qualified TOML

-- 文字 → 宣告 -------------------------------------------------------------------

-- | 一份型別宣告檔的文字 → 'TypeDecl'。第一個參數是這份文字的來源路徑,
-- 只用來組錯誤訊息。
parseSpecText :: FilePath -> Text -> Either [RegistryError] TypeDecl
parseSpecText fp txt = case TOML.decode txt of
  Left e -> Left [TomlParseError fp (TOML.renderTOMLError e)]
  Right (TOML.Table tbl) -> parseSpec fp tbl
  Right _ -> Left [TomlParseError fp "檔案的最上層不是 TOML 表"]

-- | 一整個註冊表目錄讀進來的 @(路徑, 全文)@ → 型別宣告清單與命名詞彙
-- (P-004-vault-scope 的第 6 步)。
--
-- @naming.toml@ 那一份走 'parseNamingText',其餘走 'parseSpecText';任一份不合規
-- 即失敗,錯誤經 'aggregate' 收成一則(呼叫端只有一個
-- 'Aapms.Service.Types.RegistryLoadFailed' 欄位裝得下)。
parseRegistryFiles :: [(FilePath, Text)] -> Either RegistryError ([TypeDecl], NamingVocab)
parseRegistryFiles files = case (errs, mVocab) of
  ([], Just vocab) -> Right (decls, vocab)
  _ -> Left (aggregate errs)
  where
    (namingFiles, specFiles) = partition (isNamingFile . fst) files

    (declErrss, decls) = partitionEithers [parseSpecText fp txt | (fp, txt) <- specFiles]

    -- 缺 @naming.toml@ 是__錯誤__,不是空詞彙表:註冊表目錄不合規就該硬失敗
    -- (P-004-vault-scope 的決定「三者都是硬錯,不退回預設值」)。
    vocabResult = case namingFiles of
      [] -> Left [NamingFileMissing missingNamingPath]
      ((fp, txt) : _) -> parseNamingText fp txt

    (vocabErrs, mVocab) = case vocabResult of
      Left es -> (es, Nothing)
      Right v -> ([], Just v)

    errs = concat declErrss ++ vocabErrs

    -- 沒有那份檔就沒有它的路徑;拿同一個目錄下任何一份檔的目錄來組,錯誤訊息
    -- 才說得出「我查過這裡」(ADR-005:錯誤訊息一律帶檔名)。
    missingNamingPath = case files of
      [] -> namingFileName
      ((fp, _) : _) -> takeDirectory fp </> namingFileName

-- | 命名文法詞彙表的檔名。解析時特別分出來,不當成型別宣告。
namingFileName :: FilePath
namingFileName = "naming.toml"

-- | 是不是那份 @naming.toml@(只看檔名,不管它在哪個目錄)。
isNamingFile :: FilePath -> Bool
isNamingFile fp = takeFileName fp == namingFileName

-- | @naming.toml@ 的文字 → 'NamingVocab'。第一個參數同 'parseSpecText'。
parseNamingText :: FilePath -> Text -> Either [RegistryError] NamingVocab
parseNamingText fp txt = case TOML.decode txt of
  Left e -> Left [TomlParseError fp (TOML.renderTOMLError e)]
  Right (TOML.Table tbl) -> parseNaming fp tbl
  Right _ -> Left [TomlParseError fp "檔案的最上層不是 TOML 表"]

-- 型別宣告 ---------------------------------------------------------------------

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

-- | @naming.toml@:@kinds@(強制詞彙,命名文法第一段的合法值)、@domains@
-- (不強制,只為與 @kinds@ 對稱)、@states@(強制、封閉,'parseLogicalName'
-- 拆解時唯一查的表,2026-08-23 階段一閘門新增)三個字串陣列。
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

-- 錯誤彙整 ---------------------------------------------------------------------

-- | 一則就是一則,多則收進 'RegistryErrors'。
aggregate :: [RegistryError] -> RegistryError
aggregate [e] = e
aggregate es = RegistryErrors es

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
