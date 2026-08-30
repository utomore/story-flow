-- | graph-core\/F007 測試共用的 Hedgehog 產生器:ASCII\/CJK 字元與文字、任意
-- 'FtsText'。"Aapms.Store.TokenizeSpec"\/"Aapms.Store.SearchSpec"\/
-- "Aapms.Store.FacetSpec" 共用,避免三份 spec 各自重複定義同一組邊界(空字串、
-- 單字元、CJK 連續段、空白分段點、雙引號)。
module Aapms.Store.Gens
  ( genAsciiChar
  , genCjkChar
  , genMixedText
  , genNonCjkText
  , genCjkRunText
  , genCjkRunsText
  , genQuotableText
  , genPaddedText
  , genFtsText
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Aapms.Store.Tokenize (FtsText (..))

-- | 一般 ASCII 字元:字母、數字,加上常見的英文素材命名符號(@-@\/@_@ 等)與
-- 標點,用來覆蓋「符號不被當運算子」這類情境(EX-5\/EX-8)。
genAsciiChar :: Gen Char
genAsciiChar = Gen.choice [Gen.alpha, Gen.digit, Gen.element (" -_.,!?()[]{}'" :: String)]

-- | 中日韓字元:CJK 統一表意文字、平假名、片假名、諺文音節。
genCjkChar :: Gen Char
genCjkChar =
  Gen.choice
    [ Gen.enum '\x4E00' '\x9FFF'
    , Gen.enum '\x3040' '\x309F'
    , Gen.enum '\x30A0' '\x30FF'
    , Gen.enum '\xAC00' '\xD7A3'
    ]

-- | ASCII 與 CJK 混合、含空白分段點的一般文字。'Range.linear' 下限 0,空字串與
-- 長度 1 都在定義域內。
genMixedText :: Gen Text
genMixedText = Gen.text (Range.linear 0 30) (Gen.choice [genAsciiChar, genCjkChar, pure ' '])

-- | 保證不含任何中日韓字元(LAW-5\/LAW-24 用)。
genNonCjkText :: Gen Text
genNonCjkText = Gen.text (Range.linear 0 30) genAsciiChar

-- | 保證全部由中日韓字元組成、不含空白,長度至少 1(單一極大連續段)。
genCjkRunText :: Gen Text
genCjkRunText = Gen.text (Range.linear 1 8) genCjkChar

-- | 多段中日韓,段間以一個空白隔開(LAW-3 的分段不跨界)。
genCjkRunsText :: Gen Text
genCjkRunsText = do
  runs <- Gen.list (Range.linear 1 4) genCjkRunText
  pure (T.intercalate " " runs)

-- | 含雙引號的一般文字('Aapms.Store.Tokenize.ftsQuoted'\/'Aapms.Store.Tokenize.ftsPhrase'
-- 的跳脫邊界)。
genQuotableText :: Gen Text
genQuotableText =
  Gen.text (Range.linear 0 30) (Gen.choice [genAsciiChar, genCjkChar, pure ' ', pure '"'])

-- | 前後可能帶空白的一般文字('Aapms.Store.Tokenize.routeOf' 等的
-- 'Data.Text.strip' 邊界)。
genPaddedText :: Gen Text
genPaddedText = do
  pre <- Gen.text (Range.linear 0 3) (pure ' ')
  body <- genMixedText
  post <- Gen.text (Range.linear 0 3) (pure ' ')
  pure (pre <> body <> post)

-- | 任意的 'FtsText'(六欄各自獨立產生,供 LAW-8 的純函式部分用)。
genFtsText :: Gen FtsText
genFtsText =
  FtsText
    <$> genMixedText
    <*> genMixedText
    <*> genMixedText
    <*> genMixedText
    <*> genMixedText
    <*> genMixedText
