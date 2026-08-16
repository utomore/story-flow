-- | 有方向性的關聯,一律存在來源端。
--
-- ADR-0005:引擎認得八個核心關聯並據以推論,其餘一律是 'Custom'——引擎當純標註
-- 儲存,可查詢、可顯示、可被 AI 讀到,但不驅動任何邏輯。
module StoryFlow.Core.Link
  ( LinkKind (..)
  , Link (..)
  , coreLinkKinds
  , renderLinkKind
  , parseLinkKind
  , isCoreKind
  , suggestCoreKind
  ) where

import Data.Char (isAlpha, toLower)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Ref)

-- | 八個核心建構子 + 一個 'Custom'。封閉的部分讓核心關聯的處理可以窮盡比對,
-- 未來新增核心關聯時編譯器會列出所有待處理的地方。
data LinkKind
  = -- | A 與 B 矛盾。衝突偵測第 1 層的確定性命中
    Contradicts
  | -- | A 取代 B。B 自動視為過時,不再當比對基準
    Supersedes
  | -- | A 衍生自 B。改動 B 時提示 A 需複查
    DerivedFrom
  | -- | A 是 B 的一部分。片段 → 角色 / 世界觀
    PartOf
  | -- | A 牽涉到 B。場景/劇情 → 角色、道具
    Involves
  | -- | A 發生在 B。事件 → 地點 / 時期
    OccursIn
  | -- | A 提到 B。弱關聯,擴充檢索範圍
    References
  | -- | Node A 合流到 Node B。標註而非結構(ADR-0004)
    ConvergesTo
  | -- | 自訂關聯。可儲存、可查詢,但不驅動邏輯
    Custom Text
  deriving stock (Show, Eq, Ord)

data Link = Link
  { linkKind :: LinkKind
  , linkTarget :: Ref
  , linkNote :: Maybe Text
  }
  deriving stock (Show, Eq, Ord)

-- | 八個核心關聯,依 architecture.md 的詞彙表順序。
coreLinkKinds :: [LinkKind]
coreLinkKinds =
  [ Contradicts
  , Supersedes
  , DerivedFrom
  , PartOf
  , Involves
  , OccursIn
  , References
  , ConvergesTo
  ]

renderLinkKind :: LinkKind -> Text
renderLinkKind = \case
  Contradicts -> "contradicts"
  Supersedes -> "supersedes"
  DerivedFrom -> "derivedFrom"
  PartOf -> "partOf"
  Involves -> "involves"
  OccursIn -> "occursIn"
  References -> "references"
  ConvergesTo -> "convergesTo"
  Custom t -> t

-- | 不回傳 'Either':任何字串都是合法關聯,認不得就是 'Custom'。
-- 這正是 ADR-0005 的決策——引擎不阻止作者表達,只是不對自訂關聯做推論。
parseLinkKind :: Text -> LinkKind
parseLinkKind t =
  case lookup t [(renderLinkKind k, k) | k <- coreLinkKinds] of
    Just k -> k
    Nothing -> Custom t

isCoreKind :: LinkKind -> Bool
isCoreKind = \case
  Custom _ -> False
  _ -> True

-- | 自訂關聯的名稱與某個核心關聯高度相似時,回傳建議。
--
-- ADR-0005 的負面影響那條指出「使用者可能誤以為寫了『矛盾於』引擎就會偵測」;
-- 這個函式是該問題的緩解措施,供 CLI 與 API 在收到自訂關聯時提示用。
-- 已經是核心關聯的字串回傳 'Nothing'——沒有什麼好建議的。
suggestCoreKind :: Text -> Maybe LinkKind
suggestCoreKind raw
  | isCoreKind (parseLinkKind raw) = Nothing
  | otherwise = lookup (normalize raw) synonyms

-- | 比對前先正規化:去掉大小寫、空白、底線與連字號的差異。
normalize :: Text -> Text
normalize = T.map (toLower) . T.filter keep
  where
    keep c = isAlpha c || c > '\x7f'

synonyms :: [(Text, LinkKind)]
synonyms =
  [ ("矛盾", Contradicts)
  , ("矛盾於", Contradicts)
  , ("衝突", Contradicts)
  , ("衝突於", Contradicts)
  , ("conflictswith", Contradicts)
  , ("contradict", Contradicts)
  , ("取代", Supersedes)
  , ("取代了", Supersedes)
  , ("替代", Supersedes)
  , ("supersede", Supersedes)
  , ("replaces", Supersedes)
  , ("衍生自", DerivedFrom)
  , ("源自", DerivedFrom)
  , ("derivedfrom", DerivedFrom)
  , ("derivesfrom", DerivedFrom)
  , ("屬於", PartOf)
  , ("part", PartOf)
  , ("partof", PartOf)
  , ("belongsto", PartOf)
  , ("牽涉", Involves)
  , ("涉及", Involves)
  , ("involve", Involves)
  , ("involving", Involves)
  , ("發生於", OccursIn)
  , ("發生在", OccursIn)
  , ("occursin", OccursIn)
  , ("happensin", OccursIn)
  , ("提到", References)
  , ("參照", References)
  , ("引用", References)
  , ("reference", References)
  , ("refersto", References)
  , ("合流", ConvergesTo)
  , ("合流到", ConvergesTo)
  , ("匯合", ConvergesTo)
  , ("convergeto", ConvergesTo)
  , ("convergesto", ConvergesTo)
  ]
