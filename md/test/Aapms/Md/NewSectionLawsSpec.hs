-- | graph-core/F004(重跑)Laws:LAW-13–LAW-16(GAP-1:payload 寫得出完整的新節)、
-- LAW-17–LAW-18(appendSection 的保留與撞號)、LAW-21(mkSection 的兩半組裝)。
--
-- __委派備註__:同 "Aapms.Md.EditLawsSpec",本檔依賴 @hedgehog@ \/
-- @hspec-hedgehog@,@md\/aapms-md.cabal@ 尚未接線,__未列進__ @other-modules@,
-- 本次委派無法用 @cabal build@ 實際編譯\/執行(回報裡列了需要補的相依)。
--
-- __spec 對照__:
--
-- @
-- LAW-13 appendSection(NSAsset)寫得出 toPack 讀回一致的新 Asset   -> prop_LAW13
-- LAW-14 appendSection(NSLicense)寫得出 toLicenses 讀回一致的新 License -> prop_LAW14
-- LAW-15 appendSection(NSNode)寫得出 toLevel 讀回 nodKind == 給定 kind -> prop_LAW15
-- LAW-16 payloadOverride 的 moKind 規則、其餘十二欄不變               -> prop_LAW16
-- LAW-17 appendSection 保留既有節位元組、新節排最後                   -> prop_LAW17
-- LAW-18 appendSection 撞號回 DuplicateSectionId                      -> prop_LAW18
-- LAW-21 mkSection 的 secMetaRaw 由 payloadOverride/payloadExtras 兩半組成 -> prop_LAW21
-- @
module Aapms.Md.NewSectionLawsSpec (spec) where

import Control.Monad (forM_, when)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Id (Id, IdPrefix (..))
import Aapms.Core.Level (Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..))
import Aapms.Md
import Aapms.Md.Fixtures
import Aapms.Md.Gens

fixtureDocs :: [Document]
fixtureDocs = [docOf lindaMd, docOf packMd, docOf licensesMd, docOf classroomMd]

-- | 給定前綴、產生一個__不會__撞到 @d@ 既有節 id 的新 id。
genFreshId :: IdPrefix -> Document -> Gen Id
genFreshId p d = Gen.filter (`notElem` sectionIds d) (genId p)

spec :: Spec
spec = describe "graph-core/F004 重跑:NewSectionPayload / appendSection / mkSection Laws" $ do
  it "LAW-13(GAP-1): appendSection(NSAsset)之後 toPack 讀回的新 Asset 與 na 逐欄相等" $
    hedgehog $ do
      let d = docOf packMd
      i <- forAll (genFreshId PAst d)
      na <- forAll genNewAsset
      t <- forAll genTypeKey
      title <- forAll genNonEmptySafeText
      body <- forAll genSafeText
      let ov = emptyOverride {moType = Just t}
          ns = NewSection i 2 title body (NSAsset ov na)
      case appendSection ns d of
        Left e -> footnote (T.unpack (renderMdError e)) >> failure
        Right d' -> case parseDocument (renderDocument d') >>= toPack of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right (_, as) -> case filter ((== i) . metaId . astMeta) as of
            [a] -> do
              astSha256 a === naSha256 na
              astEntry a === naEntry na
              astExt a === naExt na
              astName a === naName na
              astKindMeta a === naKindMeta na
              astLicense a === naLicense na
              astAuthor a === naAuthor na
            other -> footnoteShow (length other) >> failure

  it "LAW-14(GAP-1): appendSection(NSLicense)之後 toLicenses 讀回的新 License 與 nl 逐欄相等" $
    hedgehog $ do
      let d = docOf licensesMd
      i <- forAll (genFreshId PLic d)
      nl <- forAll genNewLicense
      t <- forAll genTypeKey
      title <- forAll genNonEmptySafeText
      body <- forAll genSafeText
      let ov = emptyOverride {moType = Just t}
          ns = NewSection i 2 title body (NSLicense ov nl)
      case appendSection ns d of
        Left e -> footnote (T.unpack (renderMdError e)) >> failure
        Right d' -> case parseDocument (renderDocument d') >>= toLicenses of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right lics -> case filter ((== i) . metaId . licMeta) lics of
            [l] -> do
              licCommercial l === nlcCommercial nl
              licAttributionRequired l === nlcAttributionRequired nl
              licCreditText l === nlcCreditText nl
              licModificationAllowed l === nlcModificationAllowed nl
              licRedistributionAllowed l === nlcRedistributionAllowed nl
              licResaleAllowed l === nlcResaleAllowed nl
              licNftAllowed l === nlcNftAllowed nl
              licSourceUrl l === nlcSourceUrl nl
            other -> footnoteShow (length other) >> failure

  it "LAW-15(GAP-1): appendSection(NSNode)之後 toLevel 讀回的 nodKind == 給定的 kind,不論 moKind ov" $
    hedgehog $ do
      let d = docOf classroomMd
      i <- forAll (genFreshId PNod d)
      nn <- forAll genNewNode
      ov <- forAll genMetaOverride
      title <- forAll genNonEmptySafeText
      body <- forAll genSafeText
      let ns = NewSection i 2 title body (NSNode ov nn)
      case appendSection ns d of
        Left e -> footnote (T.unpack (renderMdError e)) >> failure
        Right d' -> case parseDocument (renderDocument d') >>= toLevel of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right (_, nodes) -> case filter ((== i) . metaId . nodMeta) nodes of
            [n] -> nodKind n === nnKind nn
            other -> footnoteShow (length other) >> failure

  it "LAW-16: payloadOverride 的 moKind 規則(NSNode 由 NewNode 覆蓋),其餘十二欄不變" $
    hedgehog $ do
      p <- forAll genNewSectionPayload
      let ov = payloadOverride p
      case p of
        NSNode baseOv n -> do
          moKind ov === Just (nnKind n)
          ov {moKind = moKind baseOv} === baseOv
        NSFragment baseOv -> ov === baseOv
        NSAsset baseOv _ -> ov === baseOv
        NSLicense baseOv _ -> ov === baseOv

  it "LAW-17: appendSection 保留既有節的 secHeadingRaw/secMetaRaw(僅最後節可能補尾),新節排最後" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genFreshId PEnt d)
      payload <- forAll genNewSectionPayload
      title <- forAll genNonEmptySafeText
      body <- forAll genSafeText
      let ns = NewSection i 2 title body payload
      case appendSection ns d of
        Left e -> footnote (T.unpack (renderMdError e)) >> failure
        Right d' -> do
          let origSecs = docSections d
              newSecs = docSections d'
              n = length origSecs
          length newSecs === n + 1
          secId (last newSecs) === i
          let leading = take n newSecs
          forM_ (zip origSecs leading) $ \(o, s) -> do
            secHeadingRaw s === secHeadingRaw o
            secMetaRaw s === secMetaRaw o
          forM_ (zip [1 :: Int ..] (zip origSecs leading)) $ \(idx, (o, s)) ->
            when (idx /= n) $ secBodyRaw s === secBodyRaw o

  it "LAW-18: appendSection 撞號回 Left (mdError 1 (DuplicateSectionId (nsId ns)))" $
    hedgehog $ do
      d <- forAll (Gen.element fixtureDocs)
      i <- forAll (genSectionIdOf d)
      payload <- forAll genNewSectionPayload
      title <- forAll genNonEmptySafeText
      body <- forAll genSafeText
      let ns = NewSection i 2 title body payload
      case appendSection ns d of
        Left e -> e === mdError 1 (DuplicateSectionId i)
        Right _ -> footnote "nsId 撞號應該回 Left" >> failure

  it "LAW-21: mkSection 的 secMetaRaw 由 payloadOverride/payloadExtras 兩半組成;Nothing 時無 meta 區塊" $
    hedgehog $ do
      le <- forAll genLineEnding
      level <- forAll (Gen.int (Range.linear 1 6))
      i <- forAll (genId PEnt)
      title <- forAll genNonEmptySafeText
      body <- forAll genSafeText
      p <- forAll genNewSectionPayload
      let sJust = mkSection le level i title (Just p) body
      secMetaRaw sJust === Just (renderLineEnding le <> renderMetaBlock (payloadOverride p) (payloadExtras p) le)
      let sNothing = mkSection le level i title Nothing body
      secMetaRaw sNothing === Nothing
