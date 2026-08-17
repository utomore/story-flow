-- | 統一命名規範的**文法**:建構、渲染、解析、驗證。
--
-- @
-- \<kind\>_\<domain\>_\<subject\>[_\<variant\>][_\<state\>][_\<NNN\>]
-- @
--
-- 例:@ui_gui_travel-book-frame_01a@、@spr_char_hero_attack-01_up@、@tex_ground_tileset-grass@
--
-- == 為什麼是這個形狀
--
-- 參考 Unreal 的 @Prefix_BaseName_Variant_Suffix@ 慣例。前綴在最前面,是為了讓
-- **字典序自動分堆**:檔案總管排序後所有 @ui_@ 會擠在一起。索引數字補零到三位,
-- 是為了讓 @_002@ 排在 @_010@ 前面 —— 現有素材庫的 @potion10.png@ 排在
-- @potion1.png@ 與 @potion14.png@ 中間,正是沒補零的後果。
--
-- 全小寫純 ASCII 不是美學選擇:macOS 檔名大小寫不敏感、Linux 敏感、Windows 有保留
-- 字元,全小寫 ASCII 是三者唯一的安全交集。現有路徑裡的空格、@&@、@'@、@#@、@[]@、
-- 括號在跨平台建置與 shell 呼叫時都會出事。
--
-- == 這裡刻意**不做**的事
--
-- 「一個廠商檔名該對應到哪個 kind/domain」是啟發式推導,牽涉路徑規則與人工覆寫,
-- 屬於 @assetdb-ingest@。本模組只負責:給定各部位,產生合法名稱;給定名稱,拆回各部位。
-- 純函數,沒有 IO,可以用 QuickCheck 打。
{-# LANGUAGE RecordWildCards #-}

module AssetDB.Naming
  ( -- * 型別
    Segment
  , segmentText
  , mkSegment
  , LogicalName
  , logicalNameText
  , NameParts (..)
  , NameError (..)
  , renderNameError

    -- * 詞彙表
  , NamingVocab (..)
  , defaultVocab

    -- * 建構與解析
  , mkLogicalName
  , parseLogicalName
  , validateLogicalName
  , renderParts

    -- * 數字部位
  , variantFromNumber
  , indexSegment
  , isVariantShaped
  , isIndexShaped

    -- * 文字正規化基本操作(給 ingest 用)
  , normalizeSegment
  , splitCamel
  , splitTrailingNumber

    -- * 常數
  , maxLogicalNameLength
  ) where

import AssetDB.Types (KindPrefix, TextEnum (..), parseTextEnum)
import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

--------------------------------------------------------------------------------
-- Segment

-- | 一個名稱分段,已保證符合 @^[a-z0-9]+(-[a-z0-9]+)*$@。
--
-- 建構子不外露 —— 拿到 'Segment' 就代表已經驗證過,
-- 下游不需要再檢查一次,也沒辦法繞過。
newtype Segment = Segment Text
  deriving newtype (Eq, Ord)

instance Show Segment where
  show (Segment t) = show t

segmentText :: Segment -> Text
segmentText (Segment t) = t

-- | 嚴格驗證。要把任意廠商文字轉成分段請用 'normalizeSegment'。
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
-- LogicalName

-- | 完整的邏輯名稱。同時是遊戲載入器 @HashMap Text Texture@ 的 key。
newtype LogicalName = LogicalName Text
  deriving newtype (Eq, Ord)

instance Show LogicalName where
  show (LogicalName t) = show t

logicalNameText :: LogicalName -> Text
logicalNameText (LogicalName t) = t

instance ToJSON LogicalName where
  toJSON = toJSON . logicalNameText

instance FromJSON LogicalName where
  parseJSON =
    withText "LogicalName" $
      either (fail . T.unpack . renderNameError) pure . validateLogicalName

-- | 上限 64 是為了留給專案端的路徑深度。現有素材庫的路徑已經逼近
-- Windows 的 260 字元上限,檔名本身不該再吃掉太多預算。
maxLogicalNameLength :: Int
maxLogicalNameLength = 64

-- | 拆解後的各部位。
data NameParts = NameParts
  { npKind :: KindPrefix
  -- ^ 位置固定在第一段,取自封閉列舉。
  , npDomain :: Segment
  -- ^ 用途領域(@gui@ / @ground@ / @char@ / @rune@ …)。
  --
  -- 刻意**不是**封閉列舉:每加一種素材領域就要改一次程式碼,會違反
  -- 「加音效不需重構」的設計目標。這裡不比對任何詞彙表 —— 只要是合法
  -- 'Segment' 就收,加一種領域因此連資料都不必動(bug-0006)。
  , npSubject :: Segment
  -- ^ 主體,單一分段(內部可用 @-@ 連接多字,如 @travel-book-frame@)。
  , npVariant :: Maybe Segment
  -- ^ 樣式變體:@01a@、@red@、@large@。
  , npState :: Maybe Segment
  -- ^ 狀態或方向:@idle@、@hover@、@up@。必須出現在解析時所用 'NamingVocab'
  -- 的 @nvStates@ 中(全庫一律是 'defaultVocab')。
  , npIndex :: Maybe Int
  -- ^ 數字序號,渲染時補零到三位。動畫格號或字符索引都走這裡。
  }
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- 錯誤

data NameError
  = EmptySegment
  | BadSegment Text
  | NoAsciiContent Text
    -- ^ 正規化後什麼都不剩。中文檔名會走到這裡 —— 這是刻意的,
    -- 系統要求人工指定名稱,而不是自作主張音譯或丟掉。
  | TooLong Int Text
  | UnknownKindPrefix Text
  | TooFewSegments Int Text
  | AmbiguousTrailing [Text] Text
    -- ^ 拆掉 index/state/variant 之後,主體位置剩下不只一段。
  | SubjectLooksLikeModifier Text
    -- ^ 主體長得像 variant/state/index,會讓解析無法還原。
  | IndexOutOfRange Int
  deriving stock (Eq, Show)

renderNameError :: NameError -> Text
renderNameError = \case
  EmptySegment -> "名稱分段不可為空"
  BadSegment t ->
    "分段 " <> tshow t <> " 不合法,只允許 ^[a-z0-9]+(-[a-z0-9]+)*$"
  NoAsciiContent t ->
    "「" <> t <> "」正規化後不含任何 ASCII 內容,請手動指定名稱"
  TooLong n t ->
    "名稱長度 " <> tshow n <> " 超過上限 " <> tshow maxLogicalNameLength <> ":" <> t
  UnknownKindPrefix t -> "未知的 kind 前綴 " <> tshow t
  TooFewSegments n t ->
    "名稱至少需要 3 段(kind_domain_subject),只有 " <> tshow n <> " 段:" <> t
  AmbiguousTrailing rest t ->
    "主體位置剩下多段 " <> tshow rest <> ",無法判斷哪段是 variant/state:" <> t
  SubjectLooksLikeModifier t ->
    "主體 " <> tshow t <> " 長得像 variant/state/index,會導致解析歧義"
  IndexOutOfRange n -> "序號 " <> tshow n <> " 超出範圍 0..999"
  where
    tshow :: Show a => a -> Text
    tshow = T.pack . show

--------------------------------------------------------------------------------
-- 詞彙表

-- | 解析需要知道哪些字算 state、哪些算具名 variant,否則
-- @spr_item_potion_blue@ 無法判斷 @blue@ 是變體還是主體的一部分。
--
-- 做成參數而非寫死,是為了讓測試能餵自己的詞彙表(見 @NamingSpec@ 的
-- QuickCheck 產生器),不是為了讓它從資料庫載入。
--
-- == 為什麼這份詞彙表**不**做成可用資料擴充(bug-0006)
--
-- 曾經有一張 @naming_vocab@ 表打算扮演這個角色,但它從未被任何程式碼查詢,
-- 已於 store migration 004 移除。這不只是「沒做完」——把它做完是錯的:
-- 這裡的字決定了 @blue@ 是變體還是主體的一部分,也就是決定了
-- @parse ∘ render == id@ 的結果。事後 INSERT 一個新 state,會改變**已經寫進**
-- @assets.logical_name@ 的舊名字的解析語意。這是文法,該跟著程式碼版本走。
--
-- 開放性的訴求(ADR-0004:「加一種素材領域不用改程式碼」)由 'npDomain'
-- 承擔 —— 它根本不比對詞彙表,連這裡都不必動。
data NamingVocab = NamingVocab
  { nvStates :: Set Text
  , nvVariants :: Set Text
  }
  deriving stock (Eq, Show)

defaultVocab :: NamingVocab
defaultVocab =
  NamingVocab
    { nvStates =
        Set.fromList
          [ -- 互動狀態
            "idle", "hover", "pressed", "disabled", "active", "selected", "focus"
          , -- 開合
            "open", "closed", "empty", "full", "on", "off"
          , -- 動作
            "walk", "run", "attack", "dash", "death", "hurt", "cast"
          , -- 方向
            "up", "down", "left", "right", "front", "back"
          , "north", "south", "east", "west"
          , -- 時段與播放段落
            "day", "night", "dawn", "dusk", "intro", "loop", "outro"
          ]
    , nvVariants =
        Set.fromList
          [ -- 顏色
            "red", "green", "blue", "yellow", "purple", "orange", "pink"
          , "brown", "black", "white", "grey", "gold", "silver", "cyan"
          , -- 尺寸
            "tiny", "small", "medium", "large", "huge", "wide", "tall"
          , -- 材質階級
            "wood", "stone", "iron", "bronze", "steel", "mithril"
          ]
    }

--------------------------------------------------------------------------------
-- 數字部位

-- | 兩位數字 + 可選單一小寫字母,如 @01@、@02a@。
isVariantShaped :: Text -> Bool
isVariantShaped t =
  case T.span isDigit t of
    (ds, rest)
      | T.length ds == 2 ->
          T.null rest || (T.length rest == 1 && T.all isAsciiLower rest)
    _ -> False

-- | 剛好三位數字,如 @000@、@100@。與 'isVariantShaped' 互斥(位數不同)。
isIndexShaped :: Text -> Bool
isIndexShaped t = T.length t == 3 && T.all isDigit t

-- | 把小數字轉成兩位補零的 variant。三位以上不是 variant,回傳 'Nothing'
-- —— 那種情況應該用 'indexSegment'。
variantFromNumber :: Int -> Maybe Segment
variantFromNumber n
  | n < 0 || n > 99 = Nothing
  | otherwise = Just (Segment (T.justifyRight 2 '0' (T.pack (show n))))

indexSegment :: Int -> Either NameError Segment
indexSegment n
  | n < 0 || n > 999 = Left (IndexOutOfRange n)
  | otherwise = Right (Segment (T.justifyRight 3 '0' (T.pack (show n))))

--------------------------------------------------------------------------------
-- 建構

-- | 組出邏輯名稱,並檢查它**解析得回來**。
--
-- 拒絕主體長得像修飾詞,是為了讓 @parse . render == id@ 這條性質真的成立。
-- 沒有這個檢查,@spr_char_idle@ 會被解析成「有 state 沒 subject」。
mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName
mkLogicalName vocab parts = do
  let subj = segmentText (npSubject parts)
  if isModifierLike vocab subj
    then Left (SubjectLooksLikeModifier subj)
    else pure ()
  txt <- renderParts parts
  let n = T.length txt
  if n > maxLogicalNameLength
    then Left (TooLong n txt)
    else Right (LogicalName txt)

-- | 主體不可佔用修飾詞的形狀,否則右至左的解析會把它誤認。
isModifierLike :: NamingVocab -> Text -> Bool
isModifierLike vocab t =
  isVariantShaped t
    || isIndexShaped t
    || Set.member t (nvStates vocab)
    || Set.member t (nvVariants vocab)

renderParts :: NameParts -> Either NameError Text
renderParts NameParts {..} = do
  ix <- traverse indexSegment npIndex
  let segs =
        [toTextEnum npKind, segmentText npDomain, segmentText npSubject]
          <> map segmentText (concatMap toList [npVariant, npState, ix])
  Right (T.intercalate "_" segs)
  where
    toList = maybe [] pure

--------------------------------------------------------------------------------
-- 解析

-- | 只檢查形狀合不合法,不拆解。給資料庫欄位驗證與 JSON 解碼用。
validateLogicalName :: Text -> Either NameError LogicalName
validateLogicalName t = do
  _ <- parseLogicalName defaultVocab t
  Right (LogicalName t)

-- | 由右往左剝:先 index、再 state、再 variant,剩下的就是主體。
--
-- 這個順序來自各部位形狀互斥:index 是三位純數字、state 來自封閉詞彙表、
-- variant 是兩位數字或具名詞彙。任何一段不符合當前層級的形狀就停止剝除,
-- 所以「有 state 沒 variant」這種缺項組合能正確處理。
parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts
parseLogicalName vocab full = do
  let n = T.length full
  if n > maxLogicalNameLength then Left (TooLong n full) else Right ()

  let rawSegs = T.splitOn "_" full
  case rawSegs of
    (kindTxt : domainTxt : rest@(_ : _)) -> do
      kind <- either (const (Left (UnknownKindPrefix kindTxt))) Right (parseTextEnum kindTxt)
      domain <- mkSegment domainTxt
      restSegs <- traverse mkSegment rest

      let (afterIndex, mIndex) = peel isIndexShaped restSegs
          (afterState, mState) = peel (`Set.member` nvStates vocab) afterIndex
          (afterVariant, mVariant) =
            peel (\s -> isVariantShaped s || Set.member s (nvVariants vocab)) afterState

      subject <- case afterVariant of
        [s] -> Right s
        [] -> Left (TooFewSegments (length rawSegs) full)
        many' -> Left (AmbiguousTrailing (map segmentText many') full)

      idx <- traverse readIndex mIndex

      Right
        NameParts
          { npKind = kind
          , npDomain = domain
          , npSubject = subject
          , npVariant = mVariant
          , npState = mState
          , npIndex = idx
          }
    _ -> Left (TooFewSegments (length rawSegs) full)
  where
    -- 只有在剝掉之後主體位置還留得下東西時才剝,否則 @spr_gui_01a@
    -- 會變成「有 variant 沒 subject」。
    peel :: (Text -> Bool) -> [Segment] -> ([Segment], Maybe Segment)
    peel p segs = case reverse segs of
      (lastSeg : others)
        | not (null others) && p (segmentText lastSeg) -> (reverse others, Just lastSeg)
      _ -> (segs, Nothing)

    readIndex :: Segment -> Either NameError Int
    readIndex s = case decimal' (segmentText s) of
      Just v -> Right v
      Nothing -> Left (BadSegment (segmentText s))

-- 三位純數字已由 'isIndexShaped' 保證,這裡只是把它讀成 Int。
-- 自己寫一行,省掉 @text-read@ / @readMaybe@ 的字串轉換。
decimal' :: Text -> Maybe Int
decimal' t
  | T.null t || not (T.all isDigit t) = Nothing
  | otherwise = Just (T.foldl' (\acc c -> acc * 10 + fromEnum c - 48) 0 t)

--------------------------------------------------------------------------------
-- 文字正規化(給 ingest 的基本操作)

-- | 把任意廠商文字壓成合法分段。
--
-- @
-- "Blue Potion"            -> "blue-potion"
-- "TravelBook"             -> "travel-book"
-- "TX Tileset Grass"       -> "tx-tileset-grass"
-- "herbs&medicinal-plants" -> "herbs-medicinal-plants"
-- "Shikashi's"             -> "shikashis"
-- "Lifon (work in progress)" -> "lifon-work-in-progress"
-- "福岡廟宇"                -> Left NoAsciiContent
-- @
--
-- 撇號是**刪除**而非轉成分隔符,因為 @Shikashi's@ 該變成 @shikashis@ 而不是
-- @shikashi-s@。其餘標點一律當分隔符。
--
-- 非 ASCII 字元一律當分隔符,所以純中文名稱會正規化成空字串並回報
-- 'NoAsciiContent'。這是刻意的:自動音譯會產生沒人查得到的名稱,
-- 不如當場要求人工命名。
normalizeSegment :: Text -> Either NameError Segment
normalizeSegment raw
  | T.null raw = Left EmptySegment
  | T.null trimmed = Left (NoAsciiContent raw)
  | otherwise = Right (Segment trimmed)
  where
    camelJoined = T.intercalate "-" (splitCamel raw)
    apostropheDropped = T.filter (`notElem` ("'\x2019" :: String)) camelJoined
    lowered = T.toLower apostropheDropped
    sanitized = T.map (\c -> if isAsciiLower c || isDigit c then c else '-') lowered
    collapsed = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" sanitized))
    trimmed = collapsed

-- | 依 camelCase / PascalCase 邊界切開。
--
-- @
-- "TravelBook" -> ["Travel","Book"]
-- "UI"         -> ["UI"]
-- "UIIcon"     -> ["UI","Icon"]
-- "TXPlayer"   -> ["TX","Player"]
-- "potion"     -> ["potion"]
-- @
--
-- 兩條邊界規則:小寫或數字之後接大寫;以及連續大寫之後接小寫
-- (讓 @UIIcon@ 切在正確位置而不是 @U@ + @IIcon@)。
--
-- 刻意**不**在字母與數字之間切 —— 那是 'splitTrailingNumber' 的職責,
-- 因為 @Frame01a@ 的 @01a@ 該進 variant 欄位,不是變成主體的一部分。
splitCamel :: Text -> [Text]
splitCamel txt = go (T.unpack txt) [] []
  where
    go [] cur acc = reverse (emit cur acc)
    go (c : cs) cur acc
      | isBoundary cur c cs = go cs [c] (emit cur acc)
      | otherwise = go cs (c : cur) acc

    -- cur 是反向累積的,所以 head 就是前一個字元
    isBoundary cur c cs = case cur of
      [] -> False
      (prev : _) ->
        isAsciiUpper c
          && ( isAsciiLower prev
                 || isDigit prev
                 || (isAsciiUpper prev && maybe False isAsciiLower (headMay cs))
             )

    emit cur acc = if null cur then acc else T.pack (reverse cur) : acc
    headMay = \case { (x : _) -> Just x; [] -> Nothing }

-- | 剝掉結尾的數字(可帶一個尾隨字母)。
--
-- @
-- "Frame01a" -> ("Frame", Just "01a")
-- "potion10" -> ("potion", Just "10")
-- "rune100"  -> ("rune",  Just "100")
-- "grass"    -> ("grass", Nothing)
-- "00"       -> ("",      Just "00")
-- @
--
-- 現有素材庫幾乎每個廠商都把序號直接黏在名字後面,這是把它們拆進
-- variant / index 欄位的入口。
splitTrailingNumber :: Text -> (Text, Maybe Text)
splitTrailingNumber t
  | T.null digits = (t, Nothing)
  | otherwise = (before, Just (digits <> suffixLetter))
  where
    (body, suffixLetter) = case T.unsnoc t of
      Just (b, c)
        | isLetter' c
        , Just (_, lastB) <- T.unsnoc b
        , isDigit lastB ->
            (b, T.singleton c)
      _ -> (t, T.empty)
    digits = T.takeWhileEnd isDigit body
    before = T.dropWhileEnd isDigit body
    isLetter' c = isAsciiLower c || isAsciiUpper c
