-- | graph-core/F004(重跑)Laws:LAW-2、LAW-3(ADR-010 位元組保留)、LAW-4–LAW-8(GAP-2 的
-- 直接否證形式)、LAW-9–LAW-12(meta 區塊兩半的序列化 / 合併)。
--
-- __委派備註__:本檔依賴 @hedgehog@ \/ @hspec-hedgehog@,而
-- @md\/aapms-md.cabal@ 的 @test-suite@ 目前沒有這項相依,qa 依委派規則不得
-- 自行修改 cabal——本檔__未列進__ @other-modules@,本次委派因此__無法__用
-- @cabal build@ 實際編譯\/執行(回報裡列了需要補的相依與 other-modules)。
--
-- 生成器與慣例見 "Aapms.Md.Gens" 的檔頭說明(尤其 MetaExtras 只生成單行
-- 條目的定義域限縮)。
--
-- __spec 對照__:
--
-- @
-- LAW-2  updateSection 保留未觸及節\/該節標題與正文的位元組  -> prop_LAW2
-- LAW-3  updateSectionExtras 同 LAW-2 的保留條件                -> prop_LAW3
-- LAW-4  updateSection 之後 extrasAt 不變(GAP-2 否證核心)      -> prop_LAW4
-- LAW-5  updateSection 之後 toPack 讀回的 asset 專屬欄位不變 -> prop_LAW5
-- LAW-6  updateSection 之後 toLicenses 讀回的八維度不變      -> prop_LAW6
-- LAW-7  extrasOf 的定義(鍵不在 metaFieldOrder 的頂層條目)  -> prop_LAW7 / prop_LAW7_noMetaBlock
-- LAW-8  updateSection 冪等                                  -> prop_LAW8
-- LAW-9  renderMetaBlock 的行序列結構(M ++ extras ++ fence) -> prop_LAW9
-- LAW-10 MetaExtras [] 時不引入額外行(回歸)                 -> prop_LAW10
-- LAW-11 payloadExtras 的鍵與 metaFieldOrder 不相交          -> prop_LAW11
-- LAW-12 mergeExtras 的鍵聯集/優先權/順序                    -> prop_LAW12
-- @
module Aapms.Md.EditLawsSpec (spec) where

import Control.Monad (forM_, when)
import Data.List (nub, sort)
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.License (License (..))
import Aapms.Md
import Aapms.Md.Fixtures
import Aapms.Md.Gens

-- | 代表性的四份既有文件(LAW-2/LAW-3/LAW-4/LAW-8 的 @d@ 定義域)。
fixtureDocs :: [Document]
fixtureDocs = [docOf lindaMd, docOf packMd, docOf licensesMd, docOf classroomMd]

spec :: Spec
spec = describe "graph-core/F004 重跑:單節編輯與 meta 區塊序列化 Laws" $ do
  it "LAW-2: updateSection 保留其他節、以及該節標題/正文的位元組" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      patch <- forAll genMetaOverride
      let f = patchOverride patch
      case updateSection i f d of
        Left _ -> success
        Right d' -> do
          forM_ (docSections d') $ \s ->
            when (secId s /= i) $
              case sectionById (secId s) d of
                Just orig -> renderSection s === renderSection orig
                Nothing -> footnote "新節不該出現在 updateSection 的結果裡" >> failure
          case (sectionById i d, sectionById i d') of
            (Just orig, Just new) -> do
              secHeadingRaw new === secHeadingRaw orig
              secBodyRaw new === secBodyRaw orig
            _ -> footnote "i 是 genSectionIdOf d 取的,兩邊都該找得到" >> failure

  it "LAW-3: updateSectionExtras 與 LAW-2 相同的保留條件" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      patch <- forAll genMetaExtrasSubset
      let g = mergeExtras patch
      case updateSectionExtras i g d of
        Left _ -> success
        Right d' -> do
          forM_ (docSections d') $ \s ->
            when (secId s /= i) $
              case sectionById (secId s) d of
                Just orig -> renderSection s === renderSection orig
                Nothing -> footnote "新節不該出現在 updateSectionExtras 的結果裡" >> failure
          case (sectionById i d, sectionById i d') of
            (Just orig, Just new) -> do
              secHeadingRaw new === secHeadingRaw orig
              secBodyRaw new === secBodyRaw orig
            _ -> footnote "i 是 genSectionIdOf d 取的,兩邊都該找得到" >> failure

  it "LAW-4(GAP-2 核心否證): updateSection 之後 extrasAt 不變" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      patch <- forAll genMetaOverride
      let f = patchOverride patch
      case updateSection i f d of
        Left _ -> success
        Right d' -> extrasAt i d' === extrasAt i d

  it "LAW-5(GAP-2 核心否證): updateSection 之後 toPack 讀回的 asset 專屬欄位不變" $
    hedgehog $ do
      let d = docOf packMd
      i <- forAll (genSectionIdOf d)
      patch <- forAll genMetaOverride
      let f = patchOverride patch
      case updateSection i f d of
        Left _ -> success
        Right d' ->
          case (toPack d, parseDocument (renderDocument d') >>= toPack) of
            (Right (_, as), Right (_, as')) -> do
              length as === length as'
              forM_ (zip as as') $ \(a, a') -> do
                astSha256 a === astSha256 a'
                astEntry a === astEntry a'
                astExt a === astExt a'
                astName a === astName a'
                astKindMeta a === astKindMeta a'
                astLicense a === astLicense a'
                astAuthor a === astAuthor a'
            other -> footnoteShow other >> failure

  it "LAW-6(GAP-2 核心否證): updateSection 之後 toLicenses 讀回的八維度不變" $
    hedgehog $ do
      let d = docOf licensesMd
      i <- forAll (genSectionIdOf d)
      patch <- forAll genMetaOverride
      let f = patchOverride patch
      case updateSection i f d of
        Left _ -> success
        Right d' ->
          case (toLicenses d, parseDocument (renderDocument d') >>= toLicenses) of
            (Right lics, Right lics') -> do
              length lics === length lics'
              forM_ (zip lics lics') $ \(l, l') -> do
                licCommercial l === licCommercial l'
                licAttributionRequired l === licAttributionRequired l'
                licCreditText l === licCreditText l'
                licModificationAllowed l === licModificationAllowed l'
                licRedistributionAllowed l === licRedistributionAllowed l'
                licResaleAllowed l === licResaleAllowed l'
                licNftAllowed l === licNftAllowed l'
                licSourceUrl l === licSourceUrl l'
            other -> footnoteShow other >> failure

  describe "LAW-7: extrasOf 的定義" $ do
    it "鍵不在 metaFieldOrder 的頂層條目,逐字、順序不變地被取出(單行條目定義域)" $
      hedgehog $ do
        tls <- forAll genTaggedLines
        let s = buildSection tls
            expected = MetaExtras [t | ExtraLine t <- tls]
        extrasOf s === expected
        assert (all (`notElem` metaFieldOrder) [T.takeWhile (/= ':') l | l <- extraLines (extrasOf s)])

    it "沒有 meta 區塊時回 MetaExtras []" $
      hedgehog $ do
        let s = (buildSection []) {secMetaRaw = Nothing}
        extrasOf s === MetaExtras []

  it "LAW-8: updateSection i id 冪等" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      case (updateSection i id d, updateSection i id d >>= updateSection i id) of
        (Right d1, Right d2) -> renderDocument d1 === renderDocument d2
        other -> footnoteShow other >> failure

  it "LAW-9: renderMetaBlock 的行序列 = fence + M(依 metaFieldOrder)+ extras 尾段 + fence" $
    hedgehog $ do
      ov <- forAll genMetaOverride
      ex <- forAll genMetaExtrasSubset
      le <- forAll genLineEnding
      let out = renderMetaBlock ov ex le
          ls = splitOnLE le out
      case (ls, reverse ls) of
        (firstLine : _, lastLine : revInit) -> do
          firstLine === "```meta"
          lastLine === "```"
          let body = drop 1 (reverse revInit) -- 去掉開頭 fence,revInit 已不含結尾 fence
              (mLines, tailLines) = splitAt (length body - length (extraLines ex)) body
          tailLines === extraLines ex
          -- M 的總行數:每個有值欄位依 fieldLineCount 貢獻的行數總和(links 是
          -- 唯一可能 > 1 的欄位:LAW-9 原文「moLinks = Just (_:_) 產生 links: 加
          -- 每個關聯一行」)
          length mLines === sum [fieldLineCount ov k | k <- metaFieldOrder]
          -- M 的欄位鍵序:只看每一組的「起始行」(links 的續行以 spec 附的
          -- lindaMd fixture 逐字取自 system.md 的格式,以 "  - " 開頭,不是
          -- 起始行),依 metaFieldOrder 過濾出有值的欄位
          mapMaybe startKeyOf mLines === [k | k <- metaFieldOrder, fieldLineCount ov k > 0]
        _ -> footnote "renderMetaBlock 應該至少有 ```meta 與 ``` 兩行" >> failure

  it "LAW-10(回歸): MetaExtras [] 時,fence 之間只有 M 這一段" $
    hedgehog $ do
      ov <- forAll genMetaOverride
      le <- forAll genLineEnding
      let out = renderMetaBlock ov (MetaExtras []) le
          ls = splitOnLE le out
      length ls === sum [fieldLineCount ov k | k <- metaFieldOrder] + 2

  it "LAW-11: payloadExtras 的鍵與 metaFieldOrder 不相交" $
    hedgehog $ do
      p <- forAll genNewSectionPayload
      let MetaExtras ls = payloadExtras p
      assert (all (`notElem` metaFieldOrder) (map (T.takeWhile (/= ':')) ls))

  it "LAW-12: mergeExtras 的鍵聯集、同鍵 a 贏、順序 a 在前 b 剩下在後" $
    hedgehog $ do
      MetaExtras a <- forAll genMetaExtrasSubset
      MetaExtras b <- forAll genMetaExtrasSubset
      let keyOf = T.takeWhile (/= ':')
          aKeys = map keyOf a
          MetaExtras merged = mergeExtras (MetaExtras a) (MetaExtras b)
          bRest = filter (\l -> keyOf l `notElem` aKeys) b
      sort (nub (map keyOf merged)) === sort (nub (aKeys ++ map keyOf b))
      merged === a ++ bRest

--------------------------------------------------------------------------------
-- 輔助

-- | 依 'LineEnding' 的字面字串切行,丟掉切割產生的尾端空字串。輸出的每一行
-- __不含__行尾——與 'metaFieldOrder' 的鍵比對時不需要另外去尾。
splitOnLE :: LineEnding -> Text -> [Text]
splitOnLE le = filter (not . T.null) . T.splitOn (renderLineEnding le)

-- | LAW-9/LAW-10 用:'MetaOverride' 的某個 'metaFieldOrder' 鍵貢獻幾行。逐欄對應
-- spec「介面」段 'renderMetaBlock' 的 haddock,只算「幾行」,不重算逐行的
-- 確切文字——格式的位元組級規格由既有 pinned example("Aapms.Md.EditSpec" 的
-- @renderMetaBlock@ describe)守住,避免這裡重新發明一份可能出錯的格式規則。
--
-- 除了 @links@,其餘欄位有值(@Just@)時固定 1 行、未寫時 0 行。@links@ 是
-- LAW-9 原文明講的例外:「@moLinks = Just (_:_)@ 產生 @links:@ 加每個關聯一
-- 行」——@Just ls@ 貢獻 @1 + length ls@ 行(這條公式在 @ls = []@ 時退化成
-- 剛好 1 行,與其他欄位「有值就 1 行」一致,不是額外假設)。
fieldLineCount :: MetaOverride -> Text -> Int
fieldLineCount MetaOverride {..} k = case k of
  "kind" -> boolCount (isJust moKind)
  "type" -> boolCount (isJust moType)
  "vault" -> boolCount (isJust moVault)
  "summary" -> boolCount (isJust moSummary)
  "tags" -> boolCount (isJust moTags)
  "status" -> boolCount (isJust moStatus)
  "timeline" -> boolCount (isJust moTimeline)
  "aliases" -> boolCount (isJust moAliases)
  "source" -> boolCount (isJust moSource)
  "revision" -> boolCount (isJust moRevision)
  "created" -> boolCount (isJust moCreated)
  "updated" -> boolCount (isJust moUpdated)
  "links" -> maybe 0 ((+ 1) . length) moLinks
  _ -> 0
  where
    boolCount b = if b then 1 else 0

-- | LAW-9 用:一行是不是某個欄位的「起始行」(而不是 @links@ 的續行)。續行的
-- 格式(以 @"  - "@ 開頭)逐字取自 'Aapms.Md.Fixtures.lindaMd'(該 fixture
-- 本身「逐字取自 system.md 的『Markdown 分節格式』節」,是 spec 層級的事實,
-- 不是讀實作猜的)。
startKeyOf :: Text -> Maybe Text
startKeyOf l
  | "  - " `T.isPrefixOf` l = Nothing
  | otherwise = Just (T.takeWhile (/= ':') l)

-- | LAW-7 用:標記一行是「屬於 Meta 的欄位」還是「型別專屬條目」,產生器只生成
-- __單行__條目(見 "Aapms.Md.Gens" 檔頭說明的定義域限縮)。
data TaggedLine = MetaLine Text | ExtraLine Text
  deriving stock (Show)

genTaggedLines :: Gen [TaggedLine]
genTaggedLines = Gen.list (Range.linear 0 6) (Gen.choice [genMetaLine, genExtraLine])
  where
    genMetaLine = do
      k <- Gen.element metaFieldOrder
      v <- genNonEmptySafeText
      pure (MetaLine (k <> ": " <> v))
    genExtraLine = do
      k <- Gen.element extraKeyPool
      v <- genNonEmptySafeText
      pure (ExtraLine (k <> ": " <> v))

-- | 由標記行組一個 'Section':標題行\/正文是固定的無關內容,只有 'secMetaRaw'
-- 隨產生器變化。'extrasOf' 是純函式,不需要真的走過 'parseDocument'。
buildSection :: [TaggedLine] -> Section
buildSection tls =
  Section
    { secLevel = 2
    , secHeadingRaw = "## t {#ent-00000001}\n"
    , secTitle = "t"
    , secId = idOf "ent-00000001"
    , secMetaRaw = Just ("\n```meta\n" <> T.concat [tlText tl <> "\n" | tl <- tls] <> "```\n")
    , secBodyRaw = "\n body\n"
    , secLine = 1
    }
  where
    tlText (MetaLine t) = t
    tlText (ExtraLine t) = t
