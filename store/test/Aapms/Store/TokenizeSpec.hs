-- | graph-core\/F007:"Aapms.Store.Tokenize" 的純函式(字元判定、六欄投影、
-- CJK 預切\/還原、查詢路由與運算式、FTS5 字面字串)。
--
-- __spec 對照__(每條 law\/example 對回
-- @.design\/subsystems\/graph-core\/features\/F007-store-fts-dual-index.md@):
--
-- @
-- LAW-1  cjkSegment 的 token 只由 CJK 字元組成、長度 1 或 2  -> prop_LAW1
-- LAW-2  unigram token 依序覆蓋原文全部 CJK 字元             -> prop_LAW2
-- LAW-3  bigram 多重集合 = 各 cjkRuns 段的相鄰字元對          -> prop_LAW3
-- LAW-5  不含 CJK 字元的文字 cjkSegment 為空、hasCjk 為否     -> prop_LAW5
-- LAW-6  hasCjk 三種等價定義                                  -> prop_LAW6
-- LAW-7  rawFtsText 六欄逐一符合 Meta 投影規則                -> prop_LAW7
-- LAW-8  ftsRowOf 的 frTri\/frCjk;segmentFtsText 逐欄套用     -> prop_LAW8a / prop_LAW8b
-- LAW-9  routeOf 由 hasCjk 與長度決定 usesTrigram\/usesCjk    -> prop_LAW9
-- LAW-10 cjkMatchExpr\/triMatchExpr 的 Just 條件               -> prop_LAW10
-- LAW-11 ftsQuoted 的跳脫規則;ftsPhrase 定義                  -> prop_LAW11
-- EX-1  cjkSegment "金門建築"                                -> test_EX1
-- EX-2  cjkSegment "台灣 日本"(bigram 不跨界)                -> test_EX2
-- EX-3  cjkSegment "hello" / "" / "金"                        -> test_EX3
-- EX-4  routeOf 三條路由各一                                  -> test_EX4
-- EX-5  ftsQuoted 的 "-" 與雙引號跳脫                          -> test_EX5
-- @
module Aapms.Store.TokenizeSpec (spec) where

import Control.Monad (forM_)
import Data.List (nubBy, sort)
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Meta (Meta (..), Status (Missing))
import Aapms.Store.Fixtures (withIndexedAssetVault, withIndexedStoryVault)
import Aapms.Store.Gens
import Aapms.Store.Marker (VaultHandle)
import Aapms.Store.Query (NodeFilter (..), emptyNodeFilter, listNodes, lookupNode)
import Aapms.Store.Tokenize

spec :: Spec
spec = describe "graph-core/F007 Tokenize" $ do
  describe "LAW-1-LAW-6: 字元判定與 CJK 預切(純函式)" $ do
    it "LAW-1: cjkSegment 的每個 token 只由 isCjk 為真的字元組成,長度 1 或 2" $
      hedgehog $ do
        t <- forAll genMixedText
        let toks = T.words (cjkSegment t)
        assert (all (\tok -> T.all isCjk tok && (T.length tok == 1 || T.length tok == 2)) toks)

    it "LAW-2: 原文每個 CJK 字元都以一個長度 1 的 token 依序出現在 cjkSegment 裡" $
      hedgehog $ do
        t <- forAll genMixedText
        let toks = T.words (cjkSegment t)
            unigramToks = filter ((== 1) . T.length) toks
            expected = map T.singleton (T.unpack (T.filter isCjk t))
        unigramToks === expected

    it "LAW-3: 長度 2 token 的多重集合 = 對每段 cjkRuns 取相鄰重疊字元對的多重集合" $
      hedgehog $ do
        t <- forAll genCjkRunsText
        let toks = T.words (cjkSegment t)
            bigrams = filter ((== 2) . T.length) toks
            adjacentPairs run = [T.take 2 (T.drop i run) | i <- [0 .. T.length run - 2]]
            expected = concatMap adjacentPairs (cjkRuns t)
        sort bigrams === sort expected

    it "LAW-5: 不含 CJK 字元的文字(含空字串),cjkSegment 為空、hasCjk 為否" $
      hedgehog $ do
        t <- forAll genNonCjkText
        cjkSegment t === ""
        hasCjk t === False

    it "LAW-6: hasCjk t == T.any isCjk t == not (null (cjkRuns t))" $
      hedgehog $ do
        t <- forAll genMixedText
        hasCjk t === T.any isCjk t
        hasCjk t === not (null (cjkRuns t))

  describe
    "LAW-7/LAW-8: 六欄投影(對 fixture vault 裡的每個既有節點逐一驗證。AnyNode/Meta/\
    \Entity/Asset 等 core 型別未給 deriving 子句,不確定有沒有 Show,避免依賴 \
    \hedgehog forAll 的 Show 限制,改用窮舉)"
    $ do
    it "LAW-7: rawFtsText 的 ftTitle/ftSummary/ftAliases/ftTags/ftName/ftBody 符合投影規則" $
      withAllFixtureNodes $ \nodes ->
        forM_ nodes $ \n -> do
          let m = anyMeta n
              ft = rawFtsText n
          ftTitle ft `shouldBe` metaTitle m
          ftSummary ft `shouldBe` metaSummary m
          ftAliases ft `shouldBe` T.unwords (metaAliases m)
          ftTags ft `shouldBe` T.unwords (metaTags m)
          let isNamedAsset = case n of
                NAsset a -> isJust (astName a)
                _ -> False
          not (T.null (ftName ft)) `shouldBe` isNamedAsset
          case n of
            NLevel _ -> ftBody ft `shouldBe` ""
            NNode _ -> ftBody ft `shouldBe` ""
            _ -> pure ()

    it "LAW-8: ftsRowOf 的 frTri 是原文、frCjk 是 segmentFtsText 的結果" $
      withAllFixtureNodes $ \nodes ->
        forM_ nodes $ \n -> do
          let row = ftsRowOf n
          frTri row `shouldBe` rawFtsText n
          frCjk row `shouldBe` segmentFtsText (rawFtsText n)

    it "LAW-8: segmentFtsText 的每一欄等於對應欄套用 cjkSegment 的結果" $
      hedgehog $ do
        ft <- forAll genFtsText
        let seg = segmentFtsText ft
        ftTitle seg === cjkSegment (ftTitle ft)
        ftSummary seg === cjkSegment (ftSummary ft)
        ftBody seg === cjkSegment (ftBody ft)
        ftAliases seg === cjkSegment (ftAliases ft)
        ftTags seg === cjkSegment (ftTags ft)
        ftName seg === cjkSegment (ftName ft)

  describe "LAW-9-LAW-11: 查詢路由與 MATCH/字面字串運算式" $ do
    it "LAW-9: usesTrigram/usesCjk 由 strip 後的字串長度與 hasCjk 決定" $
      hedgehog $ do
        t <- forAll genPaddedText
        let s = T.strip t
        usesTrigram (routeOf t) === (not (hasCjk s) || T.length s >= 3)
        usesCjk (routeOf t) === hasCjk s

    it "LAW-10: cjkMatchExpr/triMatchExpr 的 Just 條件" $
      hedgehog $ do
        t <- forAll genPaddedText
        isJust (cjkMatchExpr t) === usesCjk (routeOf t)
        isJust (triMatchExpr t) === not (T.null (T.strip t))

    it "LAW-11: ftsQuoted 首尾各一個雙引號、內容跳脫;ftsPhrase == ftsQuoted . unwords . words" $
      hedgehog $ do
        t <- forAll genQuotableText
        let q = ftsQuoted t
        T.take 1 q === "\""
        T.takeEnd 1 q === "\""
        T.drop 1 (T.dropEnd 1 q) === T.replace "\"" "\"\"" t
        ftsPhrase t === ftsQuoted (T.unwords (T.words t))

  describe "Examples" $ do
    it "EX-1: cjkSegment \"金門建築\" == \"金 門 建 築 金門 門建 建築\"" $
      cjkSegment "金門建築" `shouldBe` "金 門 建 築 金門 門建 建築"

    it "EX-2: cjkSegment \"台灣 日本\" == \"台 灣 日 本 台灣 日本\"(bigram 不跨越空白)" $
      cjkSegment "台灣 日本" `shouldBe` "台 灣 日 本 台灣 日本"

    it "EX-3: 純 ASCII / 空字串 / 單一 CJK 字元" $ do
      cjkSegment "hello" `shouldBe` ""
      cjkSegment "" `shouldBe` ""
      cjkSegment "金" `shouldBe` "金"

    it "EX-4: routeOf 三條路由各一" $ do
      routeOf "藥水" `shouldBe` CjkOnly
      routeOf "travel-book" `shouldBe` TrigramOnly
      routeOf "藥水 potion" `shouldBe` BothIndexes

    it "EX-5: ftsQuoted 的 \"-\" 不被當 NOT、雙引號加倍跳脫" $ do
      ftsQuoted "blue-potion" `shouldBe` "\"blue-potion\""
      ftsQuoted "他說\"好\"" `shouldBe` "\"他說\"\"好\"\"\""

--------------------------------------------------------------------------------
-- LAW-7/LAW-8 用:蒐集 story vault + asset vault 全部既有節點(涵蓋六種 AnyNode)。

-- | 依 id 去重(只需要 Eq),分別以預設條件與 nfStatus = [Missing] 各查一次,
-- 涵蓋 fixture 裡唯一的 @status: missing@ 節點('ast-00000002'),再逐一
-- 'lookupNode' 取回完整 'AnyNode'。
collectAllNodes :: VaultHandle -> IO [AnyNode]
collectAllNodes vh = do
  base <- listNodes vh emptyNodeFilter {nfIncludeReference = True}
  missing <- listNodes vh emptyNodeFilter {nfIncludeReference = True, nfStatus = [Missing]}
  let ids = nubBy (\a b -> a == b) (map metaId base ++ map metaId missing)
  catMaybes <$> mapM (lookupNode vh) ids

withAllFixtureNodes :: ([AnyNode] -> IO a) -> IO a
withAllFixtureNodes act =
  withIndexedStoryVault $ \vhStory ->
    withIndexedAssetVault $ \vhAsset -> do
      storyNodes <- collectAllNodes vhStory
      assetNodes <- collectAllNodes vhAsset
      act (storyNodes ++ assetNodes)
