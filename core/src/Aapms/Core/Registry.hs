-- | 型別註冊表的純模型(ADR-005),含 asset 族(ADR-012)與命名文法(ADR-019)
-- 整合後的宣告形狀。
--
-- 本模組是__型別層__:型別宣告、它們的 smart constructor 與存取子,以及錯誤語彙
-- 的文字投影,因此只依賴其他型別層模組('Aapms.Core.Meta' \/ 'Aapms.Core.Link' \/
-- 'Aapms.Core.Name')。'buildRegistry' 留在這裡:'TypeRegistry' 的建構子不外露,
-- 它就是__那個型別唯一的 smart constructor__ ——驗證與建構分家等於把不變量的
-- 守門人搬出被守的型別之外。
--
-- __節點檢查不在這裡__:'Aapms.Core.Registry.Build.checkMeta' 要看
-- 'Aapms.Core.AnyNode.AnyNode' 與 'Aapms.Core.Meta.Meta' 的內容做推導,住
-- "Aapms.Core.Registry.Build";本模組__不__ import 它,否則型別層就反過來依賴
-- 推導層了。
--
-- 讀 @types\/registry\/*.toml@ 是 IO,一樣不在這裡——載入層見 "Aapms.Types.Loader"。
--
-- 這是 graph-core\/F002 對 F001 刪除的舊 @Aapms.Core.Registry@ 的重建:五種
-- entity 族之外加入 'FAsset' 族與 'tdNameKinds','checkEntity' 改成吃
-- 'Aapms.Core.AnyNode.AnyNode' 的 @checkMeta@。
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

    -- * 錯誤
  , RegistryError (..)
  , renderRegistryError
  ) where

import Aapms.Core.Link (LinkKind)
import Aapms.Core.Meta (TypeKey (..), metaFieldNames)
import Aapms.Core.Name (Segment)
import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
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

-- | 某個型別建議填寫的一個 'Aapms.Core.Meta.Meta' 欄位。
data FieldDecl = FieldDecl
  { fdName :: Text
  -- ^ 對應 'Aapms.Core.Meta.Meta' 的欄位名,必須出現在
  -- 'Aapms.Core.Meta.metaFieldNames' 內
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
  -- ^ S5 工作坊用;S1 只存不用
  , tdFields :: [FieldDecl]
  , tdNameKinds :: [Segment]
  -- ^ asset 族專用:命名文法第一段(@kind@)的合法值。entity 族一律 @[]@,
  -- 'Aapms.Core.Registry.Build.checkMeta' 只對 asset 族的分支使用它。
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
--
-- 這是 'TypeRegistry' 的 smart constructor:建構子不外露,拿得到一份
-- 'TypeRegistry' 就代表這五條規則都過了(鍵非空、不撞保留鍵、不重複、宣告的
-- 欄位名存在於 'Aapms.Core.Meta.metaFieldNames'、同一個 @owner_type@ 不被兩個
-- @dir@ 認領)。它與型別住同一個模組,不是為了方便——把守門人搬到型別之外就
-- 得開一個繞過驗證的建構入口,那個入口一旦存在,不變量就只剩註解在守。
--
-- 全部檢查都只看宣告本身(五個純清單運算 + 一張 'Aapms.Core.Meta.metaFieldNames'),
-- 沒有一項需要離開型別層。
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
-- 錯誤

-- | 涵蓋純驗證('buildRegistry' \/ 'Aapms.Core.Registry.Build.checkMeta')與
-- TOML 載入("Aapms.Types.Loader")兩類問題,是契約 G 唯一的 @RegistryError@。
data RegistryError
  = DuplicateTypeKey TypeKey
  | -- | 型別鍵、欄位名。TOML 寫了 'Aapms.Core.Meta.Meta' 上不存在的欄位名,一定是打錯
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
