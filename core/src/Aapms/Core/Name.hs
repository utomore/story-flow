-- | 命名文法(ADR-019)的**資料層**:分段、拆解後的部位、詞彙表與錯誤。
--
-- 本模組只有型別、它們的 smart constructor 與純量投影,__不含文法演算法__
-- (組合 \/ 解析 \/ 驗證住 "Aapms.Core.Naming")。分家的理由是層次:'Segment'
-- 與 'NamingVocab' 這一組是註冊表宣告('Aapms.Core.Registry.TypeDecl' 的
-- @tdNameKinds@)與載入層都要拿的__資料__,而它們一旦與文法演算法住同一個模組,
-- 型別層的模組就得往上依賴一個做推導的模組。
--
-- "Aapms.Core.Naming" 原樣 re-export 本模組的全部名字,既有呼叫端不受影響。
module Aapms.Core.Name
  ( -- * 分段
    Segment
  , segmentText
  , mkSegment

    -- * 部位與詞彙表
  , NameParts (..)
  , NamingVocab (..)

    -- * 錯誤
  , NameError (..)
  , renderNameError

    -- * 數字部位
  , indexSegment
  , isIndexShaped

    -- * 常數
  , maxLogicalNameLength
  ) where

import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import qualified Data.Text as T

--------------------------------------------------------------------------------
-- Segment

-- | 一個名稱分段,已保證符合 @^[a-z0-9]+(-[a-z0-9]+)*$@。
--
-- 建構子不外露——拿到 'Segment' 就代表已經驗證過,下游不需要再檢查一次。
newtype Segment = Segment Text
  deriving newtype (Eq, Ord)

instance Show Segment where
  show (Segment t) = show t

segmentText :: Segment -> Text
segmentText (Segment t) = t

mkSegment :: Text -> Either NameError Segment
mkSegment t
  | T.null t = Left EmptySegment
  | isValidSegment t = Right (Segment t)
  | otherwise = Left (BadSegment t)

isValidSegment :: Text -> Bool
isValidSegment t =
  not (T.null t) && all validPart (T.splitOn "-" t)
  where
    -- 空的 part 代表出現了開頭、結尾或連續的 '-'
    validPart p = not (T.null p) && T.all isSegChar p
    isSegChar c = isAsciiLower c || isDigit c

--------------------------------------------------------------------------------
-- NameParts

-- | 拆解後的各部位(design.md「命名文法的拆解規則」段落,2026-08-23 階段一
-- 閘門定案)。__形狀沿用 legacy__:'npVariant' 與 'npState' 語意分開,不是
-- 位置式的清單。
data NameParts = NameParts
  { npKind :: Segment
  -- ^ 封閉,必須在 'nvKinds' 內。
  , npDomain :: Segment
  -- ^ 用途領域。刻意不比對任何詞彙表(ADR-019):加一種素材領域連資料都
  -- 不必動。
  , npSubject :: Segment
  , npVariant :: Maybe Segment
  -- ^ 開放,不查詞彙表——任何合法 'Segment' 都收(@01a@、@blue@、
  -- @attack-01@、@v2@……)。
  , npState :: Maybe Segment
  -- ^ 封閉,必須在 'nvStates' 內(@up@\/@down@\/@hover@\/@pressed@……)。
  , npIndex :: Maybe Int
  -- ^ 數字序號,渲染時補零到三位。尾端三位純數字,純語法判斷,不查表。
  }
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- 詞彙表(契約 C)

-- | 命名文法的詞彙表,由註冊表載入層(@aapms-types@)從 @naming.toml@ 注入。
-- __程式碼裡不得有 @defaultVocab@__,三組詞彙全部住 @naming.toml@。
--
-- * 'nvKinds' ——__強制__。'Aapms.Core.Naming.mkLogicalName' \/
--   'Aapms.Core.Naming.validateLogicalName' 檢查 'npKind' 是否為成員,不是就回
--   'UnknownKindPrefix'(ADR-019:「kind 是封閉列舉」)。
-- * 'nvDomains' ——__不強制__(ADR-019:「domain 根本不比對詞彙表」),只是
--   型別上與 'nvKinds' 對稱,供未來使用。
-- * 'nvStates' ——__強制、封閉__。'Aapms.Core.Naming.parseLogicalName' 拆解時
--   唯一查的表:候選段落在表內才歸類成 'npState',不在表內就落回 'npVariant'
--   (開放全收)。'Aapms.Core.Naming.mkLogicalName' 額外驗證手工建構的
--   'npState'(若為 @Just@)必須是成員,不是就回 'UnknownState'。
data NamingVocab = NamingVocab
  { nvKinds :: [Segment]
  , nvDomains :: [Segment]
  , nvStates :: [Segment]
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 錯誤

data NameError
  = EmptySegment
  | BadSegment Text
  | NoAsciiContent Text
  | TooLong Int Text
  | UnknownKindPrefix Text
  | UnknownState Text
  | TooFewSegments Int Text
  | AmbiguousTrailing [Text] Text
  | IndexOutOfRange Int
  deriving stock (Eq, Show)

renderNameError :: NameError -> Text
renderNameError = \case
  EmptySegment -> "名稱分段不可為空"
  BadSegment t ->
    "分段 " <> tshow t <> " 不合法,只允許 ^[a-z0-9]+(-[a-z0-9]+)*$"
  NoAsciiContent t ->
    "「" <> t <> "」含非 ASCII 內容,請手動指定名稱"
  TooLong n t ->
    "名稱長度 " <> tshow n <> " 超過上限 " <> tshow maxLogicalNameLength <> ":" <> t
  UnknownKindPrefix t -> "未知的 kind 前綴 " <> tshow t
  UnknownState t -> "未知的 state 詞 " <> tshow t
  TooFewSegments n t ->
    "名稱至少需要 3 段(kind_domain_subject),只有 " <> tshow n <> " 段:" <> t
  AmbiguousTrailing rest t ->
    "主體位置剩下多段 " <> tshow rest <> ",無法判斷哪段是修飾詞:" <> t
  IndexOutOfRange n -> "序號 " <> tshow n <> " 超出範圍 0..999"
  where
    tshow :: Show a => a -> Text
    tshow = T.pack . show

--------------------------------------------------------------------------------
-- 常數與數字部位

-- | 上限 64 是為了留給專案端的路徑深度。
maxLogicalNameLength :: Int
maxLogicalNameLength = 64

-- | 剛好三位數字,如 @000@、@100@。
isIndexShaped :: Text -> Bool
isIndexShaped t = T.length t == 3 && T.all isDigit t

indexSegment :: Int -> Either NameError Segment
indexSegment n
  | n < 0 || n > 999 = Left (IndexOutOfRange n)
  | otherwise = Right (Segment (T.justifyRight 3 '0' (T.pack (show n))))
