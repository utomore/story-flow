-- | 型別註冊表的純模型與純驗證(ADR-005)。
--
-- 讀 @types/registry/*.toml@ 是 IO,不在這裡——本模組只認識「已經解析成資料的
-- 型別宣告」,因此註冊表的所有規則都能在零 IO 的情況下被單元測試。
-- 載入層見 @Aapms.Types.Loader@。
module Aapms.Core.Registry
  ( -- * 宣告
    FieldSpec (..)
  , EntityTypeSpec (..)

    -- * 註冊表
  , TypeRegistry
  , emptyRegistry
  , validateRegistry
  , lookupType
  , listTypes
  , lookupDir

    -- * 檢查
  , checkEntity
  , RegistryError (..)
  , EntityWarning (..)
  , reservedTypeKeys
  ) where

import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Maybe (isJust)
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Link (Link (..), LinkKind, renderLinkKind)
import Aapms.Core.Meta
  ( Meta (..)
  , Timeline (..)
  , metaFieldNames
  )

-- | 某個型別建議填寫的一個 'Meta' 欄位。
data FieldSpec = FieldSpec
  { -- | 對應 'Meta' 的欄位名,必須出現在 'metaFieldNames' 內
    fsName :: Text
  , fsRequired :: Bool
  , -- | 給作者與 AI Agent 的提示(ADR-005)
    fsHint :: Text
  }
  deriving stock (Show, Eq)

data EntityTypeSpec = EntityTypeSpec
  { etsKey :: Text
  , etsName :: Text
  , etsFields :: [FieldSpec]
  , etsAllowedLinks :: [LinkKind]
  , -- | P5 工作坊用;P1 只存不用
    etsStages :: [Text]
  , -- | 該型別的檔案放哪個子目錄,如 @characters@。
    --
    -- 'Maybe' 而不是 'Text':既有的宣告在補上這一欄之前必須仍能載入,
    -- 'validateRegistry' 不因缺欄位報錯(ADR-005 的立場是引導而非阻擋)
    etsDir :: Maybe Text
  , -- | 這個片段型別所屬的主體型別鍵,如 @character@。
    --
    -- 補的是一個__已經在資料裡、註冊表卻沒表達__的事實:檔案層主體寫
    -- @type: character@、節層片段寫 @type: character-fragment@,而
    -- @character@ 這個鍵不在註冊表裡。宣告 @owner_type@ 之後,兩個鍵都
    -- 命中同一筆宣告
    etsOwnerType :: Maybe Text
  }
  deriving stock (Show, Eq)

newtype TypeRegistry = TypeRegistry (M.Map Text EntityTypeSpec)
  deriving stock (Show, Eq)

emptyRegistry :: TypeRegistry
emptyRegistry = TypeRegistry M.empty

-- | 保留的型別鍵,不可出現在 @types/registry/@。
--
-- system.md:檔案層 frontmatter 的 @type: level@ 是 Entity 檔與 Level 檔的
-- 判別依據,因此 @level@ 被引擎佔用。
reservedTypeKeys :: [Text]
reservedTypeKeys = ["level"]

data RegistryError
  = DuplicateTypeKey Text
  | -- | 型別 key, 欄位名。TOML 寫了 'Meta' 上不存在的欄位名,一定是打錯
    UnknownMetaField Text Text
  | EmptyTypeKey
  | -- | 型別 key,佔用了引擎保留的鍵
    ReservedTypeKey Text
  | -- | 型別 key, 關聯名。__保留但不由 'validateRegistry' 產生__:
    -- @allowed_links@ 裡出現自訂關聯是合法的(ADR-005),
    -- 這個建構子留給未來需要「警告等級」輸出的呼叫端使用
    UnknownLinkInAllowed Text Text
  | -- | @owner_type@。同一個主體型別被兩份宣告以__不同的 @dir@__ 認領,
    -- 註冊表在自我矛盾;靜默取第一筆會讓同一種檔案散在兩個目錄
    ConflictingOwnerDir Text
  deriving stock (Show, Eq)

-- | 一個 Entity 不符合其型別宣告時的警告。
--
-- 是警告而不是錯誤——ADR-005 的立場是引導而非阻擋,實際是否拒絕由
-- service(P2)決定。
data EntityWarning
  = -- | 型別 key, 缺少的必填欄位名
    MissingRequiredField Text Text
  | -- | 型別 key, 不在 allowed_links 內的關聯名
    LinkNotAllowed Text Text
  | -- | Entity 的 type 不在註冊表內
    UnknownEntityType Text
  deriving stock (Show, Eq)

-- | 驗證一組型別宣告並建成註冊表。回傳__全部__錯誤而非第一個。
validateRegistry :: [EntityTypeSpec] -> Either [RegistryError] TypeRegistry
validateRegistry specs
  | null errs = Right (TypeRegistry (M.fromList [(etsKey s, s) | s <- specs]))
  | otherwise = Left errs
  where
    keys = map etsKey specs

    emptyErrs = [EmptyTypeKey | s <- specs, T.null (T.strip (etsKey s))]

    reservedErrs =
      nub [ReservedTypeKey k | k <- keys, k `elem` reservedTypeKeys]

    dupErrs =
      nub [DuplicateTypeKey k | k <- keys, length (filter (== k) keys) > 1]

    fieldErrs =
      [ UnknownMetaField (etsKey s) (fsName f)
      | s <- specs
      , f <- etsFields s
      , fsName f `notElem` metaFieldNames
      ]

    -- 缺 dir 不是錯誤,兩份宣告給同一個 owner_type 兩個不同的 dir 才是
    ownerDirErrs =
      nub
        [ ConflictingOwnerDir o
        | o <- nub [x | s <- specs, Just x <- [etsOwnerType s]]
        , length (nub [d | s <- specs, etsOwnerType s == Just o, Just d <- [etsDir s]]) > 1
        ]

    errs = emptyErrs ++ reservedErrs ++ dupErrs ++ fieldErrs ++ ownerDirErrs

lookupType :: Text -> TypeRegistry -> Maybe EntityTypeSpec
lookupType k (TypeRegistry m) = M.lookup k m

-- | 依 key 排序,讓 CLI 與 API 的輸出穩定。
listTypes :: TypeRegistry -> [EntityTypeSpec]
listTypes (TypeRegistry m) = sortOn etsKey (M.elems m)

-- | 型別鍵 → 新建檔案該落在哪個子目錄。
--
-- 先以 @key@ 精確查;查不到(或該筆沒宣告 @dir@)就掃描全部宣告找
-- @owner_type@ 等於它的第一筆。'listTypes' 已依 'etsKey' 排序,所以
-- 「第一筆」是穩定的。兩者都沒有時回 'Nothing',由呼叫端決定丟哪裡。
--
-- 這讓「查 @character@ 的目錄」與「查 @character-fragment@ 的目錄」命中
-- 同一筆宣告——垂直切片 1(新增型別不改程式)因此涵蓋到「檔案放哪裡」。
lookupDir :: Text -> TypeRegistry -> Maybe Text
lookupDir k reg = case lookupType k reg >>= etsDir of
  Just d -> Just d
  Nothing -> case [s | s <- listTypes reg, etsOwnerType s == Just k] of
    (s : _) -> etsDir s
    [] -> Nothing

-- | 檢查一個 Entity 是否符合其型別宣告:必填欄位有值、關聯在 @allowed_links@ 內。
--
-- @allowed_links@ 為空視為「未宣告限制」,不產生任何關聯警告。
checkEntity :: TypeRegistry -> Entity -> [EntityWarning]
checkEntity reg (Entity m _) =
  case lookupType (metaType m) reg of
    Nothing -> [UnknownEntityType (metaType m)]
    Just s -> missing s ++ badLinks s
  where
    missing s =
      [ MissingRequiredField (etsKey s) (fsName f)
      | f <- etsFields s
      , fsRequired f
      , not (fieldPresent (fsName f) m)
      ]

    badLinks s
      | null (etsAllowedLinks s) = []
      | otherwise =
          [ LinkNotAllowed (etsKey s) (renderLinkKind (linkKind l))
          | l <- metaLinks m
          , linkKind l `notElem` etsAllowedLinks s
          ]

-- | 某個 'Meta' 欄位是否「有填」。
--
-- 對永遠有值的欄位(id / status / revision / 日期)一律為 'True'——把它們宣告成
-- required 沒有意義,但也不該因此產生假警告。
fieldPresent :: Text -> Meta -> Bool
fieldPresent name Meta {..} = case name of
  "id" -> True
  "vault" -> notBlank metaVault
  "type" -> notBlank metaType
  "title" -> notBlank metaTitle
  "summary" -> notBlank metaSummary
  "tags" -> not (null metaTags)
  "status" -> True
  "timeline" -> isJust (tlLabel metaTimeline) || isJust (tlOrder metaTimeline)
  "aliases" -> not (null metaAliases)
  "links" -> not (null metaLinks)
  "source" -> True
  "revision" -> True
  "created" -> True
  "updated" -> True
  _ -> False
  where
    notBlank = not . T.null . T.strip
