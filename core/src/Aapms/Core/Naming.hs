-- | 命名文法(ADR-019)的**文法層**:分段、正規化、組合、解析、驗證。
--
-- @
-- \<kind\>_\<domain\>_\<subject\>[_\<modifier\>][_\<modifier\>][_\<NNN\>]
-- @
--
-- 例:@ui_gui_travel-book-frame_01a@、@spr_char_hero_attack-01_up@、
-- @tex_ground_tileset-grass@。
--
-- == 與 legacy @AssetDB.Naming@ 的差異(graph-core/F002)
--
-- 契約 B 的 'parseLogicalName' 拿掉了 legacy 版的 @NamingVocab@ 參數,演算法因此
-- 從「右往左靠 state\/variant 詞彙表剝」改成__純位置式__:不再區分 variant 與
-- state 兩種角色,合併成 'npModifiers'(順序即原始順序,最多兩個)。@kind@ 也從
-- 封閉列舉 'AssetDB.Types.KindPrefix' 改成一般 'Segment',合法值改由外部注入的
-- 'NamingVocab' 的 'nvKinds' 檢查(見 F002 待確認假設 A1)。
module Aapms.Core.Naming
  ( -- * 型別
    Segment
  , segmentText
  , mkSegment
  , NameParts (..)
  , NamingVocab (..)
  , NameError (..)
  , renderNameError

    -- * 建構與解析
  , mkLogicalName
  , parseLogicalName
  , validateLogicalName
  , renderParts

    -- * 數字部位
  , indexSegment
  , isIndexShaped

    -- * 常數
  , maxLogicalNameLength
  ) where

import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Meta (TypeKey)
import Data.Char (digitToInt, isAscii, isAsciiLower, isDigit)
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

-- | 拆解後的各部位。__形狀改自 legacy__(F002 待確認假設 A1):不再有
-- @npVariant@\/@npState@ 兩個語意分開的欄位,合併成 'npModifiers'(0..2 個,
-- 只留順序不留語意標籤),因為契約 B 的 'parseLogicalName' 拿掉了
-- @NamingVocab@ 參數,結構上不可能再做語意消歧。
data NameParts = NameParts
  { npKind :: Segment
  , npDomain :: Segment
  -- ^ 用途領域。刻意不比對任何詞彙表(ADR-019):加一種素材領域連資料都
  -- 不必動。
  , npSubject :: Segment
  , npModifiers :: [Segment]
  -- ^ 對應原文法的 @[variant][state]@,不再語意區分,只留順序,最多兩個。
  , npIndex :: Maybe Int
  -- ^ 數字序號,渲染時補零到三位。
  }
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- 詞彙表(契約 C)

-- | 命名文法的詞彙表,由註冊表載入層(@aapms-types@)從 @naming.toml@ 注入。
--
-- 'nvKinds' 是__強制__的:'mkLogicalName' \/ 'validateLogicalName' 檢查 'npKind'
-- 是否為成員,不是就回 'UnknownKindPrefix'(ADR-019:「kind 是封閉列舉」)。
-- 'nvDomains' 目前__不強制__(ADR-019:「domain 根本不比對詞彙表」),只是型別
-- 上與 'nvKinds' 對稱,供未來使用。
data NamingVocab = NamingVocab
  { nvKinds :: [Segment]
  , nvDomains :: [Segment]
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

--------------------------------------------------------------------------------
-- 建構

-- | 組出邏輯名稱。檢查 'npKind' 在詞彙表內、渲染後長度不超過上限。
mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName
mkLogicalName vocab parts
  | npKind parts `notElem` nvKinds vocab =
      Left (UnknownKindPrefix (segmentText (npKind parts)))
  | otherwise = do
      txt <- renderParts parts
      let n = T.length txt
      if n > maxLogicalNameLength
        then Left (TooLong n txt)
        else Right (LogicalName txt)

renderParts :: NameParts -> Either NameError Text
renderParts NameParts {..} = do
  ixSeg <- traverse indexSegment npIndex
  let segs =
        [segmentText npKind, segmentText npDomain, segmentText npSubject]
          <> map segmentText npModifiers
          <> maybe [] (pure . segmentText) ixSeg
  Right (T.intercalate "_" segs)

--------------------------------------------------------------------------------
-- 解析

-- | 純位置式解析,__不吃詞彙表__(契約 B 的簽名沒有 'NamingVocab' 參數)。
--
-- 1. 全域檢查:純 ASCII、長度上限
-- 2. @rawSegs = splitOn "_" full@;至少 @kind_domain_subject@ 三段,否則
--    'TooFewSegments'
-- 3. 逐段以 'mkSegment' 驗證
-- 4. 若最後一段 'isIndexShaped',剝掉當 'npIndex'
-- 5. 剩下的第一段是 'npSubject',其餘是 'npModifiers'(超過兩個回
--    'AmbiguousTrailing')
parseLogicalName :: Text -> Either NameError NameParts
parseLogicalName full
  | not (T.all isAscii full) = Left (NoAsciiContent full)
  | T.length full > maxLogicalNameLength = Left (TooLong (T.length full) full)
  | otherwise = case rawSegs of
      (kindTxt : domainTxt : rest@(_ : _)) -> do
        kind <- mkSegment kindTxt
        domain <- mkSegment domainTxt
        restSegs <- traverse mkSegment rest
        let (mIndexSeg, remaining) = peelIndex restSegs
        case remaining of
          [] -> Left (TooFewSegments (length rawSegs) full)
          (subj : mods)
            | length mods > 2 ->
                Left (AmbiguousTrailing (map segmentText mods) full)
            | otherwise ->
                Right
                  NameParts
                    { npKind = kind
                    , npDomain = domain
                    , npSubject = subj
                    , npModifiers = mods
                    , npIndex = fmap readIndex mIndexSeg
                    }
      _ -> Left (TooFewSegments (length rawSegs) full)
  where
    rawSegs = T.splitOn "_" full

    -- 只有在最後一段長得像 index 時才剝;剝了之後剩下什麼由呼叫端判斷。
    peelIndex :: [Segment] -> (Maybe Segment, [Segment])
    peelIndex segs = case reverse segs of
      (lastSeg : others) | isIndexShaped (segmentText lastSeg) ->
        (Just lastSeg, reverse others)
      _ -> (Nothing, segs)

    -- 'isIndexShaped' 已保證剛好三位數字,直接讀成 'Int'。
    readIndex :: Segment -> Int
    readIndex s = T.foldl' (\acc c -> acc * 10 + digitToInt c) 0 (segmentText s)

-- | 只檢查形狀合不合法、'npKind' 是否為詞彙表成員,不拆解給呼叫端。
--
-- 'TypeKey' 參數__不參與判斷邏輯__(F002 待確認假設 A2):型別專屬的
-- @name_kinds@ 檢查交給 'Aapms.Core.Registry.checkMeta'(只回警告),
-- 這裡只做與型別無關的檢查,避免同一件事一邊硬擋一邊只警告。
validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()
validateLogicalName vocab _typeKey (LogicalName t) = do
  parts <- parseLogicalName t
  if npKind parts `notElem` nvKinds vocab
    then Left (UnknownKindPrefix (segmentText (npKind parts)))
    else Right ()
