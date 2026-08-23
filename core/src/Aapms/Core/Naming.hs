-- | 命名文法(ADR-019)的**文法層**:分段、正規化、組合、解析、驗證。
--
-- @
-- \<kind\>_\<domain\>_\<subject\>[_\<variant\>][_\<state\>][_\<NNN\>]
-- @
--
-- 例:@ui_gui_travel-book-frame_01a@、@spr_char_hero_attack-01_up@、
-- @tex_ground_tileset-grass@。
--
-- == 2026-08-23 階段一閘門定案(取代舊的位置式演算法)
--
-- 契約 B 的 'parseLogicalName' __帶__ 'NamingVocab' 參數(design.md 的字面
-- 契約;先前把它誤判成「拿掉參數」是設計時筆誤,已由開發者訂正)。'NameParts'
-- 沿用 legacy 的形狀,語意區分 'npVariant'(開放,不查詞彙表)與
-- 'npState'(封閉,必須是 'nvStates' 成員)——不是位置式的 'npModifiers' 清單。
-- @kind@ 從封閉列舉 'AssetDB.Types.KindPrefix' 改成一般 'Segment',合法值改由
-- 外部注入的 'NamingVocab' 的 'nvKinds' 檢查。拆解只查一張表('nvStates'),
-- variant 天生開放,見 'parseLogicalName' 的文件。
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
-- * 'nvKinds' ——__強制__。'mkLogicalName' \/ 'validateLogicalName' 檢查
--   'npKind' 是否為成員,不是就回 'UnknownKindPrefix'(ADR-019:「kind 是封閉
--   列舉」)。
-- * 'nvDomains' ——__不強制__(ADR-019:「domain 根本不比對詞彙表」),只是
--   型別上與 'nvKinds' 對稱,供未來使用。
-- * 'nvStates' ——__強制、封閉__。'parseLogicalName' 拆解時唯一查的表:候選
--   段落在表內才歸類成 'npState',不在表內就落回 'npVariant'(開放全收)。
--   'mkLogicalName' 額外驗證手工建構的 'npState'(若為 @Just@)必須是成員,
--   不是就回 'UnknownState'。
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

--------------------------------------------------------------------------------
-- 建構

-- | 組出邏輯名稱。檢查 'npKind' 在 'nvKinds' 內、'npState'(若為 @Just@)在
-- 'nvStates' 內、渲染後長度不超過上限。
--
-- 允許呼叫端手工建構 'NameParts'(不必每次都經過 'parseLogicalName'),因此
-- 'npState' 可能是任意值——「封裝不變量」不能只靠 'parseLogicalName' 那一條
-- 路徑保證(F002 待確認假設 A5)。
mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName
mkLogicalName vocab parts
  | npKind parts `notElem` nvKinds vocab =
      Left (UnknownKindPrefix (segmentText (npKind parts)))
  | Just st <- npState parts, st `notElem` nvStates vocab =
      Left (UnknownState (segmentText st))
  | otherwise = do
      txt <- renderParts parts
      let n = T.length txt
      if n > maxLogicalNameLength
        then Left (TooLong n txt)
        else Right (LogicalName txt)

-- | 方向沿用 legacy 順序:@kind_domain_subject@ 之後依序接 'npVariant'、
-- 'npState'(各自只在 @Just@ 時附加)、最後 'npIndex'(補零到三位)。
--
-- 契約只保證 @parse → render@ 方向的 round trip(F002 待確認假設 A5):
-- render 之後重新 parse,拿回的字串會與原字串相同,但如果 'NameParts' 是
-- 手工建構、把一個剛好在 'nvStates' 內的詞放進 'npVariant',重新 parse 後
-- 那段文字會依規則被歸類成 'npState'——值不變,語意標籤變了,這不是本
-- 函式的契約義務。
renderParts :: NameParts -> Either NameError Text
renderParts NameParts {..} = do
  ixSeg <- traverse indexSegment npIndex
  let segs =
        [segmentText npKind, segmentText npDomain, segmentText npSubject]
          <> maybe [] (pure . segmentText) npVariant
          <> maybe [] (pure . segmentText) npState
          <> maybe [] (pure . segmentText) ixSeg
  Right (T.intercalate "_" segs)

--------------------------------------------------------------------------------
-- 解析

-- | 由右往左剝,只查 'nvStates' 一張表(design.md「命名文法的拆解規則」
-- 段落逐字):
--
-- 1. 全域檢查:純 ASCII、長度上限
-- 2. @rawSegs = splitOn "_" full@;至少 @kind_domain_subject@ 三段,否則
--    'TooFewSegments'
-- 3. 逐段以 'mkSegment' 驗證(@kindTxt@ 同樣只過語法,'nvKinds' 成員檢查
--    留給 'mkLogicalName' \/ 'validateLogicalName')
-- 4. 若 @rest@ 的最後一段 'isIndexShaped'(剛好三位純數字,純語法、不查
--    表),剝掉當 'npIndex'
-- 5. __guard__:僅當剝掉 index 後剩下的段落數 @>= 2@(剝掉後還留得下至少
--    一段給 subject)__且__最後一段 @∈ nvStates@ 時,才剝掉當 'npState';
--    否則 'npState' 為 @Nothing@(這個 guard 沿用 legacy @peel@「不剝到
--    清空」的保護,見 F002 待確認假設 A4——沒有它,單獨一段又剛好撞見
--    state 詞的主體〔如 @spr_char_up@〕會被誤剝成「沒有 subject」而報錯)
-- 6. 剩下的段落依長度分派:@[s]@ → 只有 'npSubject';@[s, v]@ → 'npSubject'
--    加 'npVariant'(__開放,不查表__);@[]@ → 'TooFewSegments';更長 →
--    'AmbiguousTrailing'
parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts
parseLogicalName vocab full
  | not (T.all isAscii full) = Left (NoAsciiContent full)
  | T.length full > maxLogicalNameLength = Left (TooLong (T.length full) full)
  | otherwise = case rawSegs of
      (kindTxt : domainTxt : rest@(_ : _)) -> do
        kind <- mkSegment kindTxt
        domain <- mkSegment domainTxt
        restSegs <- traverse mkSegment rest
        let (mIndexSeg, afterIndex) = peelIndex restSegs
            (mStateSeg, afterState) = peelState afterIndex
        case afterState of
          [] -> Left (TooFewSegments (length rawSegs) full)
          [subj] ->
            Right
              NameParts
                { npKind = kind
                , npDomain = domain
                , npSubject = subj
                , npVariant = Nothing
                , npState = mStateSeg
                , npIndex = fmap readIndex mIndexSeg
                }
          [subj, var] ->
            Right
              NameParts
                { npKind = kind
                , npDomain = domain
                , npSubject = subj
                , npVariant = Just var
                , npState = mStateSeg
                , npIndex = fmap readIndex mIndexSeg
                }
          more -> Left (AmbiguousTrailing (map segmentText more) full)
      _ -> Left (TooFewSegments (length rawSegs) full)
  where
    rawSegs = T.splitOn "_" full

    -- 只有在最後一段長得像 index 時才剝;剝了之後剩下什麼交給下一步判斷。
    peelIndex :: [Segment] -> (Maybe Segment, [Segment])
    peelIndex segs = case reverse segs of
      (lastSeg : others) | isIndexShaped (segmentText lastSeg) ->
        (Just lastSeg, reverse others)
      _ -> (Nothing, segs)

    -- guard:剝掉後至少留一段給 subject,且候選段落要在 nvStates 內。
    peelState :: [Segment] -> (Maybe Segment, [Segment])
    peelState segs
      | length segs >= 2
      , (lastSeg : others) <- reverse segs
      , lastSeg `elem` nvStates vocab =
          (Just lastSeg, reverse others)
      | otherwise = (Nothing, segs)

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
  parts <- parseLogicalName vocab t
  if npKind parts `notElem` nvKinds vocab
    then Left (UnknownKindPrefix (segmentText (npKind parts)))
    else Right ()
