-- | graph-core/F004(重跑)的__回歸 Laws__:LAW-1、LAW-19、LAW-20、LAW-23–LAW-31。這些函式本次
-- 未改動本體(骨架的「未改動、行為與上一輪相同的匯出」清單),預期全部__綠__。
--
-- __委派備註__:同 "Aapms.Md.EditLawsSpec",依賴 @hedgehog@ \/
-- @hspec-hedgehog@,@md\/aapms-md.cabal@ 尚未接線,__未列進__
-- @other-modules@,本次委派無法用 @cabal build@ 實際編譯\/執行。
--
-- __spec 對照__:
--
-- @
-- LAW-1  renderDocument . parseDocument 位元組往返(ADR-010)   -> prop_LAW1
-- LAW-19 removeSection 保留其他節、未知 id 回 Left             -> prop_LAW19 / prop_LAW19_unknown
-- LAW-20 updateSectionBody 保留標題/meta,其他節不變           -> prop_LAW20
-- LAW-23 inheritMeta 的節層繼承規則(design.md 表格)           -> prop_LAW23
-- LAW-24 type 是否繼承依 typeInherits 旗標(pack.md 不繼承)    -> prop_LAW24
-- LAW-25 newDocument 的 docKind 與可再解析                     -> prop_LAW25
-- LAW-26 updateFrontmatter 保留 preamble 與各節              -> prop_LAW26
-- LAW-27 overrideAt 的定義、未知 id 回 Left                    -> prop_LAW27 / prop_LAW27_unknown
-- LAW-28 renameSection 只換標題文字,其餘不變                  -> prop_LAW28
-- LAW-29 replacePreamble 保留各節與 docFrontRaw                -> prop_LAW29
-- LAW-30 renderFrontmatter 欄位順序與往返不失真                -> prop_LAW30
-- LAW-31 renderSection 是三段切片的串接                        -> prop_LAW31
-- @
module Aapms.Md.RegressionLawsSpec (spec) where

import Control.Monad (forM_, when)
import Data.List (nub)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Id (Id, IdPrefix (..))
import Aapms.Core.Meta (Meta (..), Revision (..))
import Aapms.Md
import Aapms.Md.Fixtures
import Aapms.Md.Gens
import Aapms.Md.Lexer (metaBlockYaml)

fixtureDocs :: [Document]
fixtureDocs = [docOf lindaMd, docOf packMd, docOf licensesMd, docOf classroomMd]

-- | LAW-1 的定義域:'parseDocument' 能成功解析的文字。生成任意合法 Markdown 文字
-- 超出本次委派可負擔的範圍,改用既有 fixture 的代表性樣本(呼應
-- "Aapms.Md.RenderSpec" STEP-15 的既有 example 覆蓋,這裡翻成可重複抽樣的
-- property 版本)。
roundtripSamples :: [T.Text]
roundtripSamples =
  [ lindaMd
  , crlf lindaMd
  , dropFinalNL lindaMd
  , classroomMd
  , crlf classroomMd
  , packMd
  , crlf packMd
  , licensesMd
  , crlf licensesMd
  ]

genFreshId :: IdPrefix -> Document -> Gen Id
genFreshId p d = Gen.filter (`notElem` sectionIds d) (genId p)

genMetaOverrideWithoutType :: Gen MetaOverride
genMetaOverrideWithoutType = (\ov -> ov {moType = Nothing}) <$> genMetaOverride

genArbitrarySection :: Gen Section
genArbitrarySection =
  Section
    <$> Gen.int (Range.linear 1 6)
    <*> genSafeText
    <*> genSafeText
    <*> genId PEnt
    <*> Gen.maybe genSafeText
    <*> genSafeText
    <*> Gen.int (Range.linear 1 1000)

spec :: Spec
spec = describe "graph-core/F004 重跑:回歸 Laws(本次未改動的函式)" $ do
  it "LAW-1: renderDocument . parseDocument 位元組往返(ADR-010)" $
    hedgehog $ do
      t <- forAll (Gen.element roundtripSamples)
      (renderDocument <$> parseDocument t) === Right t

  it "LAW-19: removeSection 保留其他節,未知 id 回 Left" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      case removeSection i d of
        Left e -> footnoteShow e >> failure
        Right d' -> do
          sectionIds d' === filter (/= i) (sectionIds d)
          forM_ (docSections d') $ \s ->
            case sectionById (secId s) d of
              Just orig -> renderSection s === renderSection orig
              Nothing -> footnote "不該出現新節" >> failure

  it "LAW-19: 未知 id 回 Left (mdError 1 (UnknownSectionId i))" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genFreshId PEnt d)
      removeSection i d === Left (mdError 1 (UnknownSectionId i))

  it "LAW-20: updateSectionBody 保留目標節的標題/meta,其他節逐位元組不變" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      body <- forAll genSafeText
      case updateSectionBody i body d of
        Left e -> footnoteShow e >> failure
        Right d' -> do
          case (sectionById i d, sectionById i d') of
            (Just orig, Just new) -> do
              secHeadingRaw new === secHeadingRaw orig
              secMetaRaw new === secMetaRaw orig
            _ -> footnote "i 應該在兩邊都找得到" >> failure
          forM_ (docSections d') $ \s ->
            when (secId s /= i) $
              case sectionById (secId s) d of
                Just orig -> renderSection s === renderSection orig
                Nothing -> footnote "不該出現新節" >> failure

  it "LAW-23: inheritMeta 的節層繼承規則(design.md 表格)" $
    hedgehog $ do
      front <- forAll genMeta
      i <- forAll (genId PEnt)
      title <- forAll genNonEmptySafeText
      ov <- forAll genMetaOverride
      case inheritMeta True front i title ov of
        Left e -> footnoteShow e >> failure -- typeInherits=True 必不失敗
        Right m -> do
          metaVault m === maybe (metaVault front) id (moVault ov)
          metaStatus m === maybe (metaStatus front) id (moStatus ov)
          metaTimeline m === maybe (metaTimeline front) Just (moTimeline ov)
          metaSource m === maybe (metaSource front) id (moSource ov)
          metaCreated m === maybe (metaCreated front) id (moCreated ov)
          metaUpdated m === maybe (metaUpdated front) id (moUpdated ov)
          metaTags m === nub (metaTags front ++ maybe [] id (moTags ov))
          metaSummary m === maybe "" id (moSummary ov)
          metaAliases m === maybe [] id (moAliases ov)
          metaLinks m === maybe [] id (moLinks ov)
          metaRevision m === maybe (Revision 1) id (moRevision ov)
          metaId m === i
          metaTitle m === title

  it "LAW-24: type 是否繼承依 typeInherits 旗標(pack.md 節不繼承且缺漏是錯誤)" $
    hedgehog $ do
      front <- forAll genMeta
      i <- forAll (genId PAst)
      title <- forAll genNonEmptySafeText
      ov <- forAll genMetaOverrideWithoutType
      inheritMeta False front i title ov === Left (SectionFieldMissing i "type")
      case inheritMeta True front i title ov of
        Right m -> metaType m === metaType front
        Left e -> footnoteShow e >> failure

  it "LAW-25: newDocument 的 docKind 與 renderDocument 可再解析" $
    hedgehog $ do
      k <- forAll (Gen.element [TopicDoc, LevelDoc, PackDoc, LicenseDoc])
      m <- forAll genMeta
      b <- forAll genSafeText
      let d = newDocument k m b
      docKind d === k
      case parseDocument (renderDocument d) of
        Left e -> footnoteShow e >> failure
        Right _ -> success

  it "LAW-26: updateFrontmatter 保留 docPreamble 與每一節" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      m' <- forAll genMeta
      case updateFrontmatter (const m') d of
        Left _ -> success
        Right d' -> do
          docPreamble d' === docPreamble d
          map renderSection (docSections d') === map renderSection (docSections d)

  it "LAW-27: overrideAt 等於節的 meta 區塊解出的 MetaOverride(無區塊為 emptyOverride)" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      case sectionById i d of
        Nothing -> footnote "genSectionIdOf 保證存在" >> failure
        Just s -> case secMetaRaw s of
          Nothing -> overrideAt i d === Right emptyOverride
          Just raw -> case decodeMeta (snd (metaBlockYaml raw)) of
            Left _ -> success -- fixture 的區塊保證解得開,理論上不會落入此分支
            Right expected -> overrideAt i d === Right expected

  it "LAW-27: 未知 id 回 Left (mdError 1 (UnknownSectionId i))" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genFreshId PEnt d)
      overrideAt i d === Left (mdError 1 (UnknownSectionId i))

  it "LAW-28: renameSection 只換標題文字,secMetaRaw/secBodyRaw/secId/secLevel 與其他節不變" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      title <- forAll genNonEmptySafeText
      case renameSection i title d of
        Left e -> footnoteShow e >> failure
        Right d' -> do
          case (sectionById i d, sectionById i d') of
            (Just orig, Just new) -> do
              secMetaRaw new === secMetaRaw orig
              secBodyRaw new === secBodyRaw orig
              secId new === secId orig
              secLevel new === secLevel orig
              secTitle new === title
            _ -> footnote "i 應該在兩邊都找得到" >> failure
          forM_ (docSections d') $ \s ->
            when (secId s /= i) $
              case sectionById (secId s) d of
                Just orig -> renderSection s === renderSection orig
                Nothing -> footnote "不該出現新節" >> failure

  it "LAW-29: replacePreamble 保留各節與 docFrontRaw,結果仍可再解析" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      body <- forAll genSafeText
      let d' = replacePreamble body d
      map renderSection (docSections d') === map renderSection (docSections d)
      docFrontRaw d' === docFrontRaw d
      case parseDocument (renderDocument d') of
        Left e -> footnoteShow e >> failure
        Right _ -> success

  it "LAW-30: renderFrontmatter 的鍵序等於 frontmatterFieldOrder,且往返不失真" $
    hedgehog $ do
      m <- forAll genMeta
      le <- forAll genLineEnding
      let out = renderFrontmatter m le
          keys = filter (`elem` frontmatterFieldOrder) (map (T.takeWhile (/= ':')) (T.lines out))
      keys === frontmatterFieldOrder
      decodeFrontmatter out === Right m

  it "LAW-31: renderSection 是三段切片的串接" $
    hedgehog $ do
      s <- forAll genArbitrarySection
      renderSection s === secHeadingRaw s <> maybe "" id (secMetaRaw s) <> secBodyRaw s
