-- | 檔名叢集推論。
--
-- == 這個模組解決什麼
--
-- 6,393 筆資源要命名。逐筆決定不可能;但**同一個素材包內的檔名一定內部一致**,
-- 所以把檔名抽象成「形狀」再分群,一包 1,693 個檔案通常塌縮成三五個叢集。
-- 人對每個叢集確認一次規則,整群套用。
--
-- 決策量因此從 6,393 降到約 100。而且資料庫存的是**規則**而不是結果,
-- 廠商出更新版時自動重套。
--
-- == 形狀的抽象層級
--
-- 太細會碎裂成幾百個叢集,太粗會把語意不同的東西混在一起。實測下來
-- 「字母/數字/大小寫的模式,分隔符一律正規化」是恰好的粒度:
--
-- @
-- UI_TravelBook_Frame01a  ->  U_W_WNa
-- UI_HoloBook_Alert02b    ->  U_W_WNa     (同一叢集)
-- ores-minerals13         ->  w_wN
-- Blue Potion 2           ->  W_W_N
-- 00                      ->  N
-- idle_down               ->  w_w
-- @
module AssetDB.Ingest.Cluster
  ( -- * 形狀
    Token (..)
  , tokenize
  , fileShape

    -- * 目錄角色
  , DirRole (..)
  , dirRole
  , dirRoleText

    -- * 叢集
  , ClusterKey (..)
  , clusterKeyText
  , clusterKeyOf
  , Cluster (..)
  , clusterBy

    -- * 命名規則
  , NumericRole (..)
  , NameRule (..)
  , applyRule
  ) where

import AssetDB.Naming
import AssetDB.Types (KindPrefix)
import Data.Aeson
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

--------------------------------------------------------------------------------
-- 形狀

-- | 檔名裡的一個權杖:一段連續的英數字。
--
-- 拆成三部分是因為廠商幾乎都把序號直接黏在名字後面
-- (@Frame01a@、@potion10@、@attack1@),而那個序號是 variant 或 index,
-- 不屬於主體。
data Token = Token
  { tkLetters :: Text
  -- ^ 前段字母。可能為空(純數字的權杖,如 @00@)。
  , tkDigits :: Text
  -- ^ 中段數字。可能為空。
  , tkSuffix :: Text
  -- ^ 數字之後的單一字母(@Frame01a@ 的 @a@)。可能為空。
  }
  deriving stock (Eq, Show)

-- | 把檔名主幹拆成權杖。**任何非英數字元都是分隔符。**
--
-- 分隔符不保留在形狀裡:@idle_down@ 與 @idle-down@ 語意相同,
-- 讓它們落在不同叢集只會製造無意義的確認工作。
tokenize :: Text -> [Token]
tokenize = mapMaybe toToken . T.split (not . isAlnum)
  where
    isAlnum c = isAsciiLower c || isAsciiUpper c || isDigit c

    toToken run
      | T.null run = Nothing
      | otherwise =
          let (letters, rest) = T.span (not . isDigit) run
              (digits, tailPart) = T.span isDigit rest
              suffix = T.takeWhile (not . isDigit) tailPart
           in Just (Token letters digits suffix)

-- | 權杖序列的形狀字串。
--
-- @
-- w   全小寫字母        W   首字大寫        U   全大寫(兩字以上)
-- N   數字              a   數字後的字母尾綴
-- ?   其他(混合大小寫等無法歸類的)
-- @
fileShape :: Text -> Text
fileShape = T.intercalate "_" . map shapeOf . tokenize
  where
    shapeOf Token {..} =
      T.concat
        [ letterShape tkLetters
        , if T.null tkDigits then "" else "N"
        , if T.null tkSuffix then "" else "a"
        ]

    letterShape t
      | T.null t = ""
      | T.all isAsciiLower t = "w"
      | T.all isAsciiUpper t = if T.length t >= 2 then "U" else "W"
      | isAsciiUpper (T.head t) && T.all isAsciiLower (T.drop 1 t) = "W"
      | isAsciiUpper (T.head t) = "W" -- CamelCase 內部大寫仍算 W
      | otherwise = "?"

--------------------------------------------------------------------------------
-- 目錄角色

-- | 壓縮檔內目錄的用途。
--
-- 廠商的目錄名千奇百怪,但用途只有幾種。這個分類讓「宣傳圖」與「實際素材」
-- 即使檔名形狀相同也會落在不同叢集 —— 它們需要完全不同的規則
-- (前者根本不該進索引)。
data DirRole
  = RoleSprites
  | RoleAnimated
  | RoleSheet
  | RoleSource
  | RolePreview
  | RoleFont
  | RoleDoc
  | RoleOther
  deriving stock (Eq, Ord, Show)

dirRoleText :: DirRole -> Text
dirRoleText = \case
  RoleSprites -> "sprites"
  RoleAnimated -> "animated"
  RoleSheet -> "spritesheet"
  RoleSource -> "source"
  RolePreview -> "preview"
  RoleFont -> "font"
  RoleDoc -> "doc"
  RoleOther -> "other"

-- | 由路徑中的任一段推導角色。**preview 優先** ——
-- 誤把宣傳圖當素材的代價,比誤把素材當宣傳圖高。
dirRole :: Text -> DirRole
dirRole path =
  case sortOn priority (mapMaybe classify segs) of
    (r : _) -> r
    [] -> RoleOther
  where
    -- 依**優先序**而非路徑順序挑選。@Sprites\/Preview\/@ 這種巢狀在
    -- 廠商包裡真的存在,取路徑先出現的會判成 sprites。
    priority :: DirRole -> Int
    priority = \case
      RolePreview -> 0
      RoleSource -> 1
      RoleSheet -> 2
      RoleAnimated -> 3
      RoleSprites -> 4
      RoleFont -> 5
      RoleDoc -> 6
      RoleOther -> 7

    segs = map (T.toLower) (init' (T.splitOn "/" path))
    init' xs = if null xs then [] else init xs

    classify s
      | any (`T.isInfixOf` s) ["preview", "promo", "screenshot", "banner", "showcase"] = Just RolePreview
      | any (`T.isInfixOf` s) ["animated", "animation"] = Just RoleAnimated
      | any (`T.isInfixOf` s) ["spritesheet", "sheet", "atlas"] = Just RoleSheet
      | any (`T.isInfixOf` s) ["aseprite", "psd", "tiff", "source", "src"] = Just RoleSource
      | any (`T.isInfixOf` s) ["sprite", "individual", "single"] = Just RoleSprites
      | any (`T.isInfixOf` s) ["font"] = Just RoleFont
      | any (`T.isInfixOf` s) ["doc", "license", "readme"] = Just RoleDoc
      | otherwise = Nothing

--------------------------------------------------------------------------------
-- 叢集

data ClusterKey = ClusterKey
  { ckRole :: DirRole
  , ckShape :: Text
  , ckExt :: Text
  }
  deriving stock (Eq, Ord, Show)

clusterKeyText :: ClusterKey -> Text
clusterKeyText ClusterKey {..} = dirRoleText ckRole <> "|" <> ckShape <> "|" <> ckExt

data Cluster = Cluster
  { clKey :: ClusterKey
  , clCount :: Int
  , clSamples :: [Text]
  -- ^ 代表性樣本。取字典序的頭尾與中段,不是前 N 筆 ——
  -- 前 N 筆常常長得一模一樣,看不出叢集的實際跨度。
  }
  deriving stock (Eq, Show)

-- | 單一路徑所屬的叢集。套用規則時要用它反查 —— 分群與反查必須是
-- **同一段程式碼**,否則規則會套到錯的檔案上。
clusterKeyOf :: Text -> ClusterKey
clusterKeyOf p =
  ClusterKey
    { ckRole = dirRole p
    , ckShape = fileShape (stemOf p)
    , ckExt = extOf p
    }

-- | 把一包的項目路徑分群。
clusterBy :: [Text] -> [Cluster]
clusterBy paths =
  sortOn (negate . clCount) [toCluster k ps | (k, ps) <- Map.toList grouped]
  where
    grouped = foldr (flip add) Map.empty paths
    add m p = Map.insertWith (<>) (clusterKeyOf p) [p] m

    toCluster k ps =
      let sorted = sortOn id ps
       in Cluster k (length ps) (spread sorted)

    -- 頭、中、尾各取幾筆
    spread xs =
      let n = length xs
       in if n <= 5
            then xs
            else [xs !! 0, xs !! 1, xs !! (n `div` 2), xs !! (n - 2), xs !! (n - 1)]

stemOf :: Text -> Text
stemOf p =
  let leaf = last ("" : T.splitOn "/" p)
   in case T.breakOnEnd "." leaf of
        (pre, _) | not (T.null pre) -> T.dropEnd 1 pre
        _ -> leaf

extOf :: Text -> Text
extOf p =
  let leaf = last ("" : T.splitOn "/" p)
   in case T.breakOnEnd "." leaf of
        (pre, suf) | not (T.null pre) -> T.toLower ("." <> suf)
        _ -> ""

--------------------------------------------------------------------------------
-- 命名規則

-- | 尾端數字要當成 variant 還是動畫格號。
--
-- 自動判斷不可靠:@potion10@ 的 10 是變體編號,@00.png@ 的 00 是動畫格。
-- 兩者形狀相同,差別只有人知道。
data NumericRole = NumAuto | NumVariant | NumIndex
  deriving stock (Eq, Show)

instance ToJSON NumericRole where
  toJSON = \case NumAuto -> "auto"; NumVariant -> "variant"; NumIndex -> "index"

instance FromJSON NumericRole where
  parseJSON = withText "NumericRole" $ \case
    "auto" -> pure NumAuto
    "variant" -> pure NumVariant
    "index" -> pure NumIndex
    other -> fail ("未知的 numeric 角色:" <> T.unpack other)

data NameRule = NameRule
  { nrKind :: KindPrefix
  , nrDomain :: Text
  , nrSubject :: Maybe Text
  -- ^ 固定的主體前綴。
  --
  -- 必要的原因:@idle_down.png@ 這種檔名裡**根本沒有主體** ——
  -- 它是誰的 idle?那個資訊只存在於人的腦袋裡。
  , nrDropTokens :: [Int]
  -- ^ 要丟棄的權杖索引(0 起算)。@UI_TravelBook_Frame01a@ 的第 0 個
  -- 權杖 @UI@ 與 kind 前綴重複,丟掉。
  , nrIncludeDirs :: Int
  -- ^ 把最後 N 層目錄名納入主體。
  --
  -- 必要的原因:BDragon 的特效包是 @32x32\/A\/00.png@ 到 @32x32\/K\/11.png@ ——
  -- 不含目錄的話所有叢集成員都叫同一個名字,而 @logical_name@ 是唯一的。
  , nrNumeric :: NumericRole
  -- ^ 尾端數字的角色。見 'NumericRole' —— 這是人必須告訴系統的事。
  , nrTags :: [Text]
  }
  deriving stock (Eq, Show)

-- 手寫而非 Generic:這個 JSON 存進資料庫的 @name_clusters.rule_json@,
-- 是**跨越工具版本的持久化格式**。欄位名不該由 Haskell 的欄位名間接決定 ——
-- 那種寫法在有人重新命名欄位時會讓既有的規則全部讀不回來。
instance ToJSON NameRule where
  toJSON NameRule {..} =
    object
      [ "kind" .= nrKind
      , "domain" .= nrDomain
      , "subject" .= nrSubject
      , "dropTokens" .= nrDropTokens
      , "includeDirs" .= nrIncludeDirs
      , "numeric" .= nrNumeric
      , "tags" .= nrTags
      ]

instance FromJSON NameRule where
  parseJSON = withObject "NameRule" $ \o ->
    NameRule
      <$> o .: "kind"
      <*> o .: "domain"
      <*> o .:? "subject"
      <*> o .:? "dropTokens" .!= []
      <*> o .:? "includeDirs" .!= 0
      <*> o .:? "numeric" .!= NumAuto
      <*> o .:? "tags" .!= []

-- | 對單一項目路徑套用規則,產生邏輯名稱。
applyRule :: NamingVocab -> NameRule -> Text -> Either NameError LogicalName
applyRule vocab NameRule {..} path = do
  let toks = tokenize (stemOf path)
      kept = [t | (i, t) <- zip [0 ..] toks, i `notElem` nrDropTokens]
      dirs = takeLast nrIncludeDirs (dropLast1 (T.splitOn "/" path))

  -- 由右往左剝:先看最後一個權杖的數字,再看倒數的狀態詞。
  let (afterNum, mNumeric) = peelNumeric kept
      (afterState, mState) = peelState vocab afterNum

      -- **非末尾權杖的數字必須保留。**
      --
      -- UI_TravelBook_Alert01a_3 的 01a 是變體編號,不是雜訊:
      -- 丟掉它的話 Alert01a_1 與 Alert02a_1 會產生同一個邏輯名稱,
      -- 而 logical_name 是唯一的 —— 508 筆動畫格會直接撞名。
      -- 只有被 peelNumeric 剝掉的那個末尾數字才是 variant/index。
      letterParts =
        map T.toLower dirs
          <> catMaybes [nrSubject]
          <> map tokenText (filter (not . emptyToken) afterState)

      tokenText t
        | T.null (tkDigits t) = tkLetters t
        | T.null (tkLetters t) = tkDigits t <> tkSuffix t
        | otherwise = tkLetters t <> "-" <> tkDigits t <> tkSuffix t

      emptyToken t = T.null (tkLetters t) && T.null (tkDigits t)

  subject <- normalizeSegment (T.intercalate "-" (filter (not . T.null) letterParts))
  domain <- normalizeSegment nrDomain
  state <- traverse (mkSegment . T.toLower) mState

  (variant, index) <- resolveNumeric mNumeric

  mkLogicalName
    vocab
    NameParts
      { npKind = nrKind
      , npDomain = domain
      , npSubject = subject
      , npVariant = variant
      , npState = state
      , npIndex = index
      }
  where
    resolveNumeric Nothing = Right (Nothing, Nothing)
    resolveNumeric (Just (digits, suffix)) =
      case nrNumeric of
        NumIndex -> asIndex
        NumVariant -> asVariant
        -- 自動判斷只在形狀明確時才敢下結論:三位數以上或超過 99
        -- 不可能是兩位數的 variant,只能是序號。
        NumAuto -> if T.length digits >= 3 || n > 99 then asIndex else asVariant
      where
        n = readDigits digits
        asIndex =
          if n > 999
            then Left (IndexOutOfRange n)
            else Right (Nothing, Just n)
        asVariant = case variantFromNumber n of
          Just v -> Right (Just (withSuffix v suffix), Nothing)
          Nothing -> asIndex

    -- Frame01a 的 a:接在兩位數變體後面,如 "01a"。
    withSuffix v suffix
      | T.null suffix = v
      | otherwise = either (const v) id (mkSegment (segmentText v <> T.toLower suffix))

-- | 剝掉最後一個帶數字的權杖。
peelNumeric :: [Token] -> ([Token], Maybe (Text, Text))
peelNumeric toks =
  case reverse toks of
    (t : rest)
      | not (T.null (tkDigits t)) ->
          let stripped = t {tkDigits = "", tkSuffix = ""}
              keep = reverse (if T.null (tkLetters t) then rest else stripped : rest)
           in (keep, Just (tkDigits t, tkSuffix t))
    _ -> (toks, Nothing)

-- | 剝掉最後一個屬於狀態詞彙的權杖。
peelState :: NamingVocab -> [Token] -> ([Token], Maybe Text)
peelState vocab toks =
  case reverse toks of
    (t : rest)
      | T.null (tkDigits t)
      , let w = T.toLower (tkLetters t)
      , Set.member w (nvStates vocab)
      , not (null rest) ->
          (reverse rest, Just w)
    _ -> (toks, Nothing)

readDigits :: Text -> Int
readDigits = T.foldl' (\a c -> a * 10 + (fromEnum c - 48)) 0

takeLast :: Int -> [a] -> [a]
takeLast n xs = drop (length xs - n) xs

dropLast1 :: [a] -> [a]
dropLast1 xs = if null xs then [] else init xs
