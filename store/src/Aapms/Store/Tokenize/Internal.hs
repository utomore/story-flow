-- | P-027-fts-tokenize 的內部觀察點:只為 law 觀察而匯出,沒有 production 消費者
-- (boundary.md「測試與邊界」:住 @*.Internal@,只准 "Aapms.Store.Tokenize" 自己與測試 import)。
module Aapms.Store.Tokenize.Internal
  ( stripText
  , upperAscii
  , wordHits
  , runHits
  ) where

import Data.Char (isAsciiLower, toUpper)
import Data.Text (Text)
import qualified Data.Text as T

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Pack (Pack (..))

-- | 去頭尾空白,路由與運算式的判斷對象。
stripText :: Text -> Text
stripText = T.strip

-- | ASCII 大寫化,寫出「不分大小寫」用;非 ASCII 字元原樣。
--
-- 刻意不是 @Data.Text.toUpper@:那會做完整的 Unicode 大小寫映射,對中日韓
-- 以外的非 ASCII 字元(例如德文 ß → SS)會改變字串長度,讓「不分大小寫」
-- 這條性質牽扯進與 FTS5 無關的 locale 行為。這裡只翻 @a@-@z@。
upperAscii :: Text -> Text
upperAscii = T.map up
  where
    up c
      | isAsciiLower c = toUpper c
      | otherwise = c

-- | 一個詞在 trigram 路由下打不打得中這個節點。
--
-- 兩個條件:trigram tokenizer 的三字元下限(FTS5 對長度不足三個字元的
-- @MATCH@ 必定空結果),以及不分大小寫的子字串比對。
wordHits :: Text -> AnyNode -> Bool
wordHits w n =
  T.length w >= 3
    && any (T.isInfixOf (upperAscii w)) (map upperAscii (rawFields n))

-- | 一段中日韓在 cjk 路由下打不打得中這個節點。
--
-- 段內是片語比對('Aapms.Store.Tokenize.cjkMatchExpr' 用該段的全部 bigram
-- 組成片語),語意上等同「這一段以連續子字串出現在某一欄」。中日韓沒有
-- 大小寫,所以不套 'upperAscii'。
runHits :: Text -> AnyNode -> Bool
runHits r n = any (T.isInfixOf r) (rawFields n)

--------------------------------------------------------------------------------
-- 私有

-- | 六欄原文,順序同 'Aapms.Store.Tokenize.FtsText' 的欄位。
--
-- 內容與 'Aapms.Store.Tokenize.rawFtsText' 相同,但這裡重寫一份:
-- @*.Internal@ 不得 import 自己的父模組(boundary.md「測試與邊界」),
-- 而 P-027-fts-tokenize#LAW-14 \/ #LAW-15 逐字要求兩者等值,兩份一旦分岔
-- 就是那兩條 law 的紅燈。
rawFields :: AnyNode -> [Text]
rawFields n =
  [ metaTitle m
  , metaSummary m
  , bodyOf n
  , T.unwords (metaAliases m)
  , T.unwords (metaTags m)
  , nameOf n
  ]
  where
    m = anyMeta n

    bodyOf (NEntity e) = entBody e
    bodyOf (NAsset a) = astBody a
    bodyOf (NPack p) = pckBody p
    bodyOf (NLicense l) = maybe "" id (licFullText l)
    bodyOf (NLevel _) = ""
    bodyOf (NNode _) = ""

    nameOf (NAsset a) = maybe "" (\(LogicalName t) -> t) (astName a)
    nameOf _ = ""
