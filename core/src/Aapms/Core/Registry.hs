-- | 型別註冊表的純模型與純驗證(ADR-005),含 asset 族(ADR-012)與命名文法
-- (ADR-019)的整合。
--
-- 讀 @types/registry/*.toml@ 是 IO,不在這裡——本模組只認識「已經解析成資料的
-- 型別宣告」,因此註冊表的所有規則都能在零 IO 的情況下被單元測試。載入層見
-- "Aapms.Types.Loader"。
--
-- 這是 graph-core\/F002 對 F001 刪除的舊 @Aapms.Core.Registry@ 的重建:五種
-- entity 族之外加入 'FAsset' 族與 'tdNameKinds','checkEntity' 改成吃
-- 'Aapms.Core.AnyNode.AnyNode' 的 'checkMeta'。
module Aapms.Core.Registry
  ( -- * 家族
    Family (..)
  , renderFamily
  , parseFamily

    -- * 宣告
  , FieldDecl (..)
  , TypeDecl (..)

    -- * 註冊表
  , TypeRegistry
  , reservedTypeKeys
  , buildRegistry
  , lookupType
  , listTypes
  , lookupDir

    -- * 檢查
  , checkMeta

    -- * 錯誤
  , RegistryError (..)
  , renderRegistryError
  ) where

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName (..))
import Aapms.Core.Id (VaultId (..))
import Aapms.Core.Link (Link (..), LinkKind, renderLinkKind)
import Aapms.Core.Meta
  ( Meta (..)
  , MetaWarning (..)
  , Timeline (..)
  , TypeKey (..)
  , metaFieldNames
  )
import Aapms.Core.Naming (NameParts (..), Segment, parseLogicalName, segmentText)
import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

--------------------------------------------------------------------------------
-- 家族

-- | 型別宣告的家族:故事節點(entity)或素材(asset)。
data Family = FEntity | FAsset
  deriving stock (Show, Eq)

-- | 穩定小寫,進 DB 與 JSON 用同一份(ADR-008 風格)。
renderFamily :: Family -> Text
renderFamily = \case
  FEntity -> "entity"
  FAsset -> "asset"

parseFamily :: Text -> Maybe Family
parseFamily = \case
  "entity" -> Just FEntity
  "asset" -> Just FAsset
  _ -> Nothing

--------------------------------------------------------------------------------
-- 宣告

-- | 某個型別建議填寫的一個 'Meta' 欄位。
data FieldDecl = FieldDecl
  { fdName :: Text
  -- ^ 對應 'Meta' 的欄位名,必須出現在 'metaFieldNames' 內
  , fdRequired :: Bool
  , fdHint :: Text
  -- ^ 給作者與 AI Agent 的提示(ADR-005)
  }
  deriving stock (Show, Eq)

-- | 一份型別宣告,entity 族與 asset 族共用同一個形狀。
data TypeDecl = TypeDecl
  { tdKey :: TypeKey
  , tdName :: Text
  , tdFamily :: Family
  , tdDir :: Maybe FilePath
  -- ^ entity 族專用:該型別的檔案放哪個子目錄。asset 族不宣告(依契約卡)。
  , tdOwnerType :: Maybe TypeKey
  -- ^ entity 族專用:這個片段型別所屬的主體型別鍵。
  , tdAllowedLinks :: [LinkKind]
  , tdStages :: [Text]
  -- ^ P5 工作坊用;P1 只存不用
  , tdFields :: [FieldDecl]
  , tdNameKinds :: [Segment]
  -- ^ asset 族專用:命名文法第一段(@kind@)的合法值。entity 族一律 @[]@,
  -- 'checkMeta' 只對 asset 族的分支使用它。
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 註冊表

-- | 不透明,內部是 @Map TypeKey TypeDecl@。
newtype TypeRegistry = TypeRegistry (M.Map TypeKey TypeDecl)

-- | 保留的型別鍵,不可出現在 @types\/registry\/@。
--
-- @level@:檔案層 frontmatter 的 @type: level@ 是 Entity 檔與 Level 檔的判別
-- 依據。@asset-pack@\/@asset-license@:分別是 pack.md 與 licenses.md 的檔案層
-- @type@,不是「某個型別的 asset」。
reservedTypeKeys :: [TypeKey]
reservedTypeKeys = [TypeKey "level", TypeKey "asset-pack", TypeKey "asset-license"]

-- | 驗證一組型別宣告並建成註冊表。回傳__全部__錯誤而非第一個。
buildRegistry :: [TypeDecl] -> Either [RegistryError] TypeRegistry
buildRegistry decls
  | null errs = Right (TypeRegistry (M.fromList [(tdKey d, d) | d <- decls]))
  | otherwise = Left errs
  where
    keys = map tdKey decls

    emptyErrs = [EmptyTypeKey | d <- decls, isBlank (tdKey d)]

    reservedErrs =
      nub [ReservedTypeKey k | k <- keys, k `elem` reservedTypeKeys]

    dupErrs =
      nub [DuplicateTypeKey k | k <- keys, length (filter (== k) keys) > 1]

    fieldErrs =
      [ UnknownMetaField (tdKey d) (fdName f)
      | d <- decls
      , f <- tdFields d
      , fdName f `notElem` metaFieldNames
      ]

    -- 缺 dir 不是錯誤,兩份宣告給同一個 owner_type 兩個不同的 dir 才是
    ownerDirErrs =
      nub
        [ ConflictingOwnerDir o
        | o <- nub [x | d <- decls, Just x <- [tdOwnerType d]]
        , length (nub [dir | d <- decls, tdOwnerType d == Just o, Just dir <- [tdDir d]]) > 1
        ]

    errs = emptyErrs ++ reservedErrs ++ dupErrs ++ fieldErrs ++ ownerDirErrs

    isBlank (TypeKey k) = T.null (T.strip k)

lookupType :: TypeRegistry -> TypeKey -> Maybe TypeDecl
lookupType (TypeRegistry m) k = M.lookup k m

-- | 依 key 排序,讓 CLI 與 API 的輸出穩定。
listTypes :: TypeRegistry -> [TypeDecl]
listTypes (TypeRegistry m) = sortOn tdKey (M.elems m)

-- | 型別鍵 → 新建檔案該落在哪個子目錄。
--
-- 先以 @key@ 精確查;查不到(或該筆沒宣告 @dir@)就掃描全部宣告找
-- @owner_type@ 等於它的第一筆。'listTypes' 已依 'tdKey' 排序,所以「第一筆」
-- 是穩定的。兩者都沒有時回 'Nothing'。
lookupDir :: TypeRegistry -> TypeKey -> Maybe FilePath
lookupDir reg k = case lookupType reg k >>= tdDir of
  Just d -> Just d
  Nothing -> case [d | d <- listTypes reg, tdOwnerType d == Just k] of
    (d : _) -> tdDir d
    [] -> Nothing

--------------------------------------------------------------------------------
-- 檢查

-- | 檢查一個節點是否符合其型別宣告:必填欄位有值、關聯在 @allowed_links@ 內、
-- (僅 asset)命名第一段在 @name_kinds@ 內。__只回警告__,不決定要不要擋
-- (那是 service 的事)。
checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]
checkMeta reg node =
  case lookupType reg (metaType m) of
    Nothing -> [UnknownNodeType (metaType m)]
    Just decl -> missingFields decl ++ badLinks decl ++ badNameKind decl
  where
    m = anyMeta node

    missingFields decl =
      [ MissingRequiredField (tdKey decl) (fdName f)
      | f <- tdFields decl
      , fdRequired f
      , not (fieldPresent (fdName f) m)
      ]

    -- allowed_links 為空視為「未宣告限制」,不產生任何關聯警告。
    badLinks decl
      | null (tdAllowedLinks decl) = []
      | otherwise =
          [ LinkNotAllowed (tdKey decl) (renderLinkKind (linkKind l))
          | l <- metaLinks m
          , linkKind l `notElem` tdAllowedLinks decl
          ]

    -- 只對「有命名」的 asset 檢查;tdNameKinds 空清單比照 allowed_links 的
    -- 慣例視為「未宣告限制」(F002 待確認假設 A3)。
    badNameKind decl = case node of
      NAsset Asset {astName = Just (LogicalName nm)}
        | not (null (tdNameKinds decl))
        , Right parts <- parseLogicalName nm
        , npKind parts `notElem` tdNameKinds decl ->
            [NameKindNotAllowed (tdKey decl) (segmentText (npKind parts))]
      _ -> []

-- | 某個 'Meta' 欄位是否「有填」。
--
-- 對永遠有值的欄位(id / status / revision / 日期)一律為 'True'——把它們
-- 宣告成 required 沒有意義,但也不該因此產生假警告。
fieldPresent :: Text -> Meta -> Bool
fieldPresent name Meta {..} = case name of
  "id" -> True
  "vault" -> notBlank vaultText
  "type" -> notBlank typeText
  "title" -> notBlank metaTitle
  "summary" -> notBlank metaSummary
  "tags" -> not (null metaTags)
  "status" -> True
  "timeline" -> maybe False (\tl -> isJust (tlLabel tl) || isJust (tlOrder tl)) metaTimeline
  "aliases" -> not (null metaAliases)
  "links" -> not (null metaLinks)
  "source" -> True
  "revision" -> True
  "created" -> True
  "updated" -> True
  _ -> False
  where
    notBlank = not . T.null . T.strip
    vaultText = case metaVault of VaultId v -> v
    typeText = case metaType of TypeKey v -> v

--------------------------------------------------------------------------------
-- 錯誤

-- | 涵蓋純驗證('buildRegistry' \/ 'checkMeta')與 TOML 載入
-- ("Aapms.Types.Loader")兩類問題,是契約 G 唯一的 @RegistryError@。
data RegistryError
  = DuplicateTypeKey TypeKey
  | -- | 型別鍵、欄位名。TOML 寫了 'Meta' 上不存在的欄位名,一定是打錯
    UnknownMetaField TypeKey Text
  | EmptyTypeKey
  | -- | 型別鍵佔用了引擎保留的鍵
    ReservedTypeKey TypeKey
  | -- | @owner_type@。同一個主體型別被兩份宣告以不同的 @dir@ 認領
    ConflictingOwnerDir TypeKey
  | -- | 檔名、認不得的 @family@ 值(只接受 @"entity"@\/@"asset"@)
    UnknownFamily FilePath Text
  | -- | 檔名、解析器訊息
    TomlParseError FilePath Text
  | -- | 檔名、缺少的必填鍵
    MissingField FilePath Text
  | -- | 檔名、欄位名、期望的型別
    BadFieldType FilePath Text Text
  | -- | 檔名、認不得的鍵
    UnknownKey FilePath Text
  | -- | 註冊表目錄不存在(空目錄是合法的,不存在不是)
    RegistryDirMissing FilePath
  | -- | 目錄下沒有 @naming.toml@
    NamingFileMissing FilePath
  | -- | 三層定位都找不到,列出查過的路徑
    RegistryNotFound [FilePath]
  | -- | 彙整多個問題,渲染時逐行攤平。單一個元素時載入層不會多包這一層
    RegistryErrors [RegistryError]
  deriving stock (Show, Eq)

renderRegistryError :: RegistryError -> Text
renderRegistryError = \case
  DuplicateTypeKey (TypeKey k) -> "型別鍵重複:" <> k
  UnknownMetaField (TypeKey k) f ->
    "型別 " <> k <> " 宣告了不存在的 Meta 欄位 `" <> f <> "`"
  EmptyTypeKey -> "型別鍵不可為空"
  ReservedTypeKey (TypeKey k) ->
    "型別鍵 `" <> k <> "` 是引擎保留鍵,不可用於註冊表"
  ConflictingOwnerDir (TypeKey o) ->
    "owner_type `" <> o <> "` 被不同的 dir 宣告,註冊表自我矛盾"
  UnknownFamily fp v ->
    pack fp <> ": 認不得的 family `" <> v <> "`,只接受 entity 或 asset"
  TomlParseError fp msg -> pack fp <> ": TOML 解析失敗 —— " <> msg
  MissingField fp k -> pack fp <> ": 缺少必填鍵 `" <> k <> "`"
  BadFieldType fp k want ->
    pack fp <> ": 鍵 `" <> k <> "` 的型別不對,應為" <> want
  UnknownKey fp k -> pack fp <> ": 認不得的鍵 `" <> k <> "`"
  RegistryDirMissing fp -> pack fp <> ": 型別註冊表目錄不存在"
  NamingFileMissing fp -> pack fp <> ": 缺少 naming.toml"
  RegistryNotFound paths ->
    "找不到型別註冊表,查過:" <> T.intercalate "、" (map pack paths)
  RegistryErrors errs -> T.intercalate "\n" (map renderRegistryError errs)
  where
    pack = T.pack
