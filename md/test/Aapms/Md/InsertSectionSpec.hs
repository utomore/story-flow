-- | graph-core/F004(2026-08-25 追加,F008 假設 A5 的裁決):'insertSection' ——
-- 在指定父節點的__子樹之後__插入新節(= 成為它的最後一個子節點),以及
-- 'Aapms.Md.Error.renderMdErrorKind' 新增的 'HeadingTooDeep' 分支。
--
-- 本檔只翻新增的那一組:Laws L32–L39(「在父節點底下插入」)與 Examples
-- E11–E22。其餘 31 條 law 的測試已存在(見 "Aapms.Md.EditLawsSpec" /
-- "Aapms.Md.NewSectionLawsSpec" / "Aapms.Md.RegressionLawsSpec" /
-- "Aapms.Md.DocKindLawSpec"),本檔不重寫、不碰。
--
-- __預期紅綠__:'insertSection' 本體是 @undefined@,'HeadingTooDeep' 的
-- @renderMdErrorKind@ 分支本體也是 @undefined@——所有呼叫到這兩者的測試都
-- 應該紅。E16\/E17\/E19\/E20 只斷言 'insertSection' 回傳的 'MdError' __值__
-- (建構子相等),不呼叫 'renderMdError',所以它們的紅綠只繫於 'insertSection'
-- 是否正確 pattern match 到對應分支;E21 才是唯一同時撞到
-- 'renderMdErrorKind' 那個 @undefined@ 分支的測試。
--
-- __spec 對照__:
--
-- @
-- L32 插入位置(k = j+1+length(subtree p d))              -> "L32" it
-- L33 ADR-010 位元組保留(唯一例外:插入點前一節的尾端)     -> "L33" it
-- L34 新節內容(與 mkSection 一致;正文的 blankTail 條款)   -> "L34" it
-- L35 可解析(parseDocument\/to* 往返,依文件身分分四個 it) -> "L35" describe(四個 it)
-- L36 樹合法性與父子關係(nodParent\/nodOrder\/buildTree)   -> "L36" it
-- L37 父節點是最後一節時退化為 appendSection               -> "L37" it
-- L38 四條錯誤檢查依序取第一個成立的分支                    -> "L38" it
-- L39 HeadingTooDeep 的訊息(前綴\/兩個 # 字串\/下一步指引)  -> "L39" it
--
-- E11 「子樹之後」而非「父節點正後方」                      -> "E11" it
-- E12 格式正常的檔案上插入點位元組不變(+ 單一空行變體)     -> "E12" 兩個 it
-- E13 1,693 節,對中間有子樹的節插入                        -> "E13" it
-- E14 父節點是最後一節,退化為 appendSection                -> "E14" it
-- E15 新節本身的行尾補齊(不會與下一節標題黏住)              -> "E15" it
-- E16 父節點不存在                                          -> "E16" it
-- E17 nsLevel 不等於 secLevel(父)+1                        -> "E17" it
-- E18 算出來的層級 > 6                                      -> "E18" it
-- E19 撞號優先於層級檢查                                    -> "E19" it
-- E20 第 3 條檢查先於第 4 條(HeadingSkip 不是 HeadingTooDeep) -> "E20" it
-- E21 HeadingTooDeep 訊息逐字(契約 G:下一步指引)            -> "E21" it
-- E22 既有建構子的訊息回歸(見檔內註解:spec-gaps G3)         -> "E22" it
-- @
module Aapms.Md.InsertSectionSpec (spec) where

import Control.Monad (forM_, when)
import Numeric (showHex)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (..))
import Aapms.Core.Level (Node (..), NodeKind (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Tree (buildTree)
import Aapms.Md
import Aapms.Md.Fixtures
import Aapms.Md.Gens

--------------------------------------------------------------------------------
-- 共用 fixture / 產生器 / spec 定義的 oracle

-- | 代表性的四份既有文件(與 "Aapms.Md.EditLawsSpec" / "Aapms.Md.NewSectionLawsSpec"
-- 同一份清單)。
fixtureDocs :: [Document]
fixtureDocs = [docOf lindaMd, docOf packMd, docOf licensesMd, docOf classroomMd]

-- | 給定前綴、產生一個不會撞到 @d@ 既有節 id 的新 id(與既有 *LawsSpec 同款)。
genFreshId :: IdPrefix -> Document -> Gen Id
genFreshId p d = Gen.filter (`notElem` sectionIds d) (genId p)

-- | 可以合法當父節點插入的既有節:secLevel < 6(nsLevel = secLevel+1 才可能 <= 6)。
-- 四份 fixture 至少各有一個 secLevel 2 的節,恆非空。
genInsertableParent :: Document -> Gen Section
genInsertableParent d = case filter ((< 6) . secLevel) (docSections d) of
  [] -> error "genInsertableParent: fixture 應該至少有一個 secLevel < 6 的節"
  secs -> Gen.element secs

-- | spec「在父節點底下插入」記號段的 @j@:@p@ 在 'docSections' 中的索引(0 起算)。
sectionIndexOf :: Id -> Document -> Int
sectionIndexOf pid d = length (takeWhile ((/= pid) . secId) (docSections d))

-- | spec 記號段的 @subtree p d@:@p@ 之後、'secLevel' 一路都大於 @secLevel p@
-- 的最長前綴。
subtreeOf :: Id -> Document -> [Section]
subtreeOf pid d =
  let secs = docSections d
      j = sectionIndexOf pid d
      pLevel = secLevel (secs !! j)
   in takeWhile ((> pLevel) . secLevel) (drop (j + 1) secs)

-- | spec 記號段的插入索引 @k = j + 1 + length (subtree p d)@。
insertIndexOf :: Id -> Document -> Int
insertIndexOf pid d = sectionIndexOf pid d + 1 + length (subtreeOf pid d)

insertAt :: Int -> a -> [a] -> [a]
insertAt k x xs = let (pre, post) = splitAt k xs in pre ++ [x] ++ post

-- | L33\/A10 原文轉錄的 'blankTail' 公式(私有函式,test-suite 拿不到,只能
-- 依 spec 給的算法自己重建一份 oracle):原文已以兩個行尾結尾時原樣回傳、
-- 以一個行尾結尾時補一個、空字串補一個、其餘補兩個。
blankTailOracle :: LineEnding -> Text -> Text
blankTailOracle le t
  | T.null t = nl
  | (nl <> nl) `T.isSuffixOf` t = t
  | nl `T.isSuffixOf` t = t <> nl
  | otherwise = t <> nl <> nl
  where
    nl = renderLineEnding le

spec :: Spec
spec = do
  describe "graph-core/F004(2026-08-25):insertSection Laws(L32-L39)" $ do
    it "L32: 插入索引 k 符合 subtree 定義;有子節點時新節前一節是子樹最後一節" $
      hedgehog $ do
        d <- forAll (Gen.element fixtureDocs)
        p <- forAll (genInsertableParent d)
        let pid = secId p
        i <- forAll (genFreshId PEnt d)
        payload <- forAll genNewSectionPayload
        title <- forAll genNonEmptySafeText
        body <- forAll genSafeText
        let ns = NewSection i (secLevel p + 1) title body payload
        case insertSection pid ns d of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right d' -> do
            let k = insertIndexOf pid d
                expectedIds = insertAt k i (sectionIds d)
            sectionIds d' === expectedIds
            case subtreeOf pid d of
              [] -> success
              sub -> do
                let predId = secId (docSections d' !! (k - 1))
                predId === secId (last sub)
                assert (predId /= pid)

    it "L33(ADR-010): 除插入點前一節的正文尾端外,其餘節逐位元組不變;frontRaw/preamble 不變" $
      hedgehog $ do
        d <- forAll (Gen.element fixtureDocs)
        p <- forAll (genInsertableParent d)
        let pid = secId p
        i <- forAll (genFreshId PEnt d)
        payload <- forAll genNewSectionPayload
        title <- forAll genNonEmptySafeText
        body <- forAll genSafeText
        let ns = NewSection i (secLevel p + 1) title body payload
            k = insertIndexOf pid d
        case insertSection pid ns d of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right d' -> do
            docFrontRaw d' === docFrontRaw d
            docPreamble d' === docPreamble d
            forM_ (zip [0 :: Int ..] (docSections d')) $ \(idx, s) ->
              when (secId s /= i) $
                case sectionById (secId s) d of
                  Nothing -> footnote "新節不該在這裡出現" >> failure
                  Just orig -> do
                    secHeadingRaw s === secHeadingRaw orig
                    secMetaRaw s === secMetaRaw orig
                    if idx == k - 1
                      then secBodyRaw s === blankTailOracle (docEnding d) (secBodyRaw orig)
                      else secBodyRaw s === secBodyRaw orig

    it "L34: 新節的標題\\/meta\\/層級\\/標題文字\\/id 與 mkSection 一致;正文依是否為最後一節套用 blankTail" $
      hedgehog $ do
        d <- forAll (Gen.element fixtureDocs)
        p <- forAll (genInsertableParent d)
        let pid = secId p
        i <- forAll (genFreshId PEnt d)
        payload <- forAll genNewSectionPayload
        title <- forAll genNonEmptySafeText
        body <- forAll genSafeText
        let lvl = secLevel p + 1
            ns = NewSection i lvl title body payload
            expected = mkSection (docEnding d) lvl i title (Just payload) body
        case insertSection pid ns d of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right d' -> case sectionById i d' of
            Nothing -> footnote "新節應該存在" >> failure
            Just new -> do
              secHeadingRaw new === secHeadingRaw expected
              secMetaRaw new === secMetaRaw expected
              secLevel new === secLevel expected
              secTitle new === secTitle expected
              secId new === secId expected
              if secId (last (docSections d')) == i
                then secBodyRaw new === body
                else secBodyRaw new === blankTailOracle (docEnding d) body

    describe "L35(可解析:parseDocument/to* 在插入後仍成功,新節點 metaId 正確)" $ do
      it "TopicDoc(lindaMd, NSFragment)" $
        hedgehog $ do
          let d = docOf lindaMd
          p <- forAll (genInsertableParent d)
          i <- forAll (genFreshId PEnt d)
          ov <- forAll genMetaOverride
          title <- forAll genNonEmptySafeText
          body <- forAll genSafeText
          let ns = NewSection i (secLevel p + 1) title body (NSFragment ov)
          case insertSection (secId p) ns d of
            Left e -> footnote (T.unpack (renderMdError e)) >> failure
            Right d' -> case parseDocument (renderDocument d') of
              Left e -> footnote (T.unpack (renderMdError e)) >> failure
              Right d'' -> do
                sectionIds d'' === sectionIds d'
                case toTopic d'' of
                  Left e -> footnote (T.unpack (renderMdError e)) >> failure
                  Right (_, frags) -> case filter ((== i) . metaId . entMeta) frags of
                    [_] -> success
                    other -> footnoteShow (length other) >> failure

      it "PackDoc(packMd, NSAsset)" $
        hedgehog $ do
          let d = docOf packMd
          p <- forAll (genInsertableParent d)
          i <- forAll (genFreshId PAst d)
          na <- forAll genNewAsset
          t <- forAll genTypeKey
          title <- forAll genNonEmptySafeText
          body <- forAll genSafeText
          let ov = emptyOverride {moType = Just t}
              ns = NewSection i (secLevel p + 1) title body (NSAsset ov na)
          case insertSection (secId p) ns d of
            Left e -> footnote (T.unpack (renderMdError e)) >> failure
            Right d' -> case parseDocument (renderDocument d') of
              Left e -> footnote (T.unpack (renderMdError e)) >> failure
              Right d'' -> do
                sectionIds d'' === sectionIds d'
                case toPack d'' of
                  Left e -> footnote (T.unpack (renderMdError e)) >> failure
                  Right (_, as) -> case filter ((== i) . metaId . astMeta) as of
                    [_] -> success
                    other -> footnoteShow (length other) >> failure

      it "LicenseDoc(licensesMd, NSLicense)" $
        hedgehog $ do
          let d = docOf licensesMd
          p <- forAll (genInsertableParent d)
          i <- forAll (genFreshId PLic d)
          nl <- forAll genNewLicense
          t <- forAll genTypeKey
          title <- forAll genNonEmptySafeText
          body <- forAll genSafeText
          let ov = emptyOverride {moType = Just t}
              ns = NewSection i (secLevel p + 1) title body (NSLicense ov nl)
          case insertSection (secId p) ns d of
            Left e -> footnote (T.unpack (renderMdError e)) >> failure
            Right d' -> case parseDocument (renderDocument d') of
              Left e -> footnote (T.unpack (renderMdError e)) >> failure
              Right d'' -> do
                sectionIds d'' === sectionIds d'
                case toLicenses d'' of
                  Left e -> footnote (T.unpack (renderMdError e)) >> failure
                  Right lics -> case filter ((== i) . metaId . licMeta) lics of
                    [_] -> success
                    other -> footnoteShow (length other) >> failure

      it "LevelDoc(classroomMd, NSNode)" $
        hedgehog $ do
          let d = docOf classroomMd
          p <- forAll (genInsertableParent d)
          i <- forAll (genFreshId PNod d)
          nn <- forAll genNewNode
          ov <- forAll genMetaOverride
          title <- forAll genNonEmptySafeText
          body <- forAll genSafeText
          let ns = NewSection i (secLevel p + 1) title body (NSNode ov nn)
          case insertSection (secId p) ns d of
            Left e -> footnote (T.unpack (renderMdError e)) >> failure
            Right d' -> case parseDocument (renderDocument d') of
              Left e -> footnote (T.unpack (renderMdError e)) >> failure
              Right d'' -> do
                sectionIds d'' === sectionIds d'
                case toLevel d'' of
                  Left e -> footnote (T.unpack (renderMdError e)) >> failure
                  Right (_, nodes) -> case filter ((== i) . metaId . nodMeta) nodes of
                    [n] -> nodKind n === nnKind nn
                    other -> footnoteShow (length other) >> failure

    it "L36: 樹合法性 — nodParent/nodKind/nodOrder 正確,既有節點不重編,buildTree 成功" $
      hedgehog $ do
        let d = docOf classroomMd
        p <- forAll (genInsertableParent d)
        let pid = secId p
        i <- forAll (genFreshId PNod d)
        k' <- forAll genNodeKind
        ov <- forAll genMetaOverride
        title <- forAll genNonEmptySafeText
        body <- forAll genSafeText
        let ns = NewSection i (secLevel p + 1) title body (NSNode ov (NewNode k'))
        case toLevel d of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right (lvl, ns0) -> case insertSection pid ns d of
            Left e -> footnote (T.unpack (renderMdError e)) >> failure
            Right d' -> case parseDocument (renderDocument d') >>= toLevel of
              Left e -> footnote (T.unpack (renderMdError e)) >> failure
              Right (lvl', ns1) -> do
                lvl' === lvl
                case filter ((== i) . metaId . nodMeta) ns1 of
                  [newNode] -> do
                    nodParent newNode === Just pid
                    nodKind newNode === k'
                    let siblingCount = length (filter ((== Just pid) . nodParent) ns0)
                    nodOrder newNode === siblingCount + 1
                  other -> footnoteShow (length other) >> failure
                forM_ ns0 $ \n0 ->
                  case filter ((== metaId (nodMeta n0)) . metaId . nodMeta) ns1 of
                    [n1] -> do
                      nodMeta n1 === nodMeta n0
                      nodParent n1 === nodParent n0
                      nodOrder n1 === nodOrder n0
                      nodKind n1 === nodKind n0
                      nodEntities n1 === nodEntities n0
                    other -> footnoteShow (length other) >> failure
                case buildTree lvl' ns1 of
                  Left errs -> footnoteShow errs >> failure
                  Right _ -> success

    it "L37: 父節點是最後一節時,insertSection 與 appendSection 產生相同的 renderDocument" $
      hedgehog $ do
        d <- forAll (Gen.element fixtureDocs)
        let lastSec = last (docSections d)
        i <- forAll (genFreshId PEnt d)
        payload <- forAll genNewSectionPayload
        title <- forAll genNonEmptySafeText
        body <- forAll genSafeText
        if secLevel lastSec < 6
          then do
            let ns = NewSection i (secLevel lastSec + 1) title body payload
            (renderDocument <$> insertSection (secId lastSec) ns d)
              === (renderDocument <$> appendSection ns d)
          else success

    it "L38: 四個檢查依序取第一個成立的分支(含 E19:撞號優先於層級)" $
      hedgehog $ do
        d <- forAll (Gen.element fixtureDocs)
        existingId <- forAll (genSectionIdOf d)
        freshPid <- forAll (genFreshId PEnt d)
        pid <- forAll (Gen.element [existingId, freshPid])
        freshNsId <- forAll (genFreshId PLvl d)
        nsIdVal <- forAll (Gen.element [existingId, freshNsId])
        useCorrectLevel <- forAll Gen.bool
        randomLvl <- forAll (Gen.int (Range.linear 1 12))
        payload <- forAll genNewSectionPayload
        title <- forAll genNonEmptySafeText
        body <- forAll genSafeText
        let lvl = case (sectionById pid d, useCorrectLevel) of
              (Just p, True) -> secLevel p + 1
              _ -> randomLvl
            ns = NewSection nsIdVal lvl title body payload
            result = insertSection pid ns d
        case sectionById pid d of
          Nothing -> result === Left (mdError 1 (UnknownSectionId pid))
          Just p ->
            if nsIdVal `elem` sectionIds d
              then result === Left (mdError 1 (DuplicateSectionId nsIdVal))
              else
                if lvl /= secLevel p + 1
                  then result === Left (mdError 1 (HeadingSkip (secLevel p) lvl))
                  else
                    if lvl > 6
                      then result === Left (mdError 1 (HeadingTooDeep (secLevel p) lvl))
                      else case result of
                        Right _ -> success
                        Left e -> footnoteShow e >> failure

    it "L39: HeadingTooDeep 的訊息以「第 <l> 行:」開頭,含兩個 # 字串與下一步指引" $
      hedgehog $ do
        l <- forAll (Gen.int (Range.linear 1 9999))
        parent <- forAll (Gen.int (Range.linear 1 6))
        cur <- forAll (Gen.int (Range.linear 7 12))
        let msg = renderMdError (mdError l (HeadingTooDeep parent cur))
        assert (("第 " <> T.pack (show l) <> " 行:") `T.isPrefixOf` msg)
        assert (T.replicate cur "#" `T.isInfixOf` msg)
        assert (T.replicate parent "#" `T.isInfixOf` msg)
        assert ("請改插到較淺的父節點底下,或先把這條分支中間的層級壓平" `T.isInfixOf` msg)

  describe "graph-core/F004(2026-08-25):insertSection Examples(E11-E22)" $ do
    it "E11: 插在子樹之後(而非父節點正後方)" $ do
      let d = docOf e11LevelMd
          ns = NewSection (idOf "nod-0030") 3 "新場景" "" (NSNode emptyOverride (NewNode KScene))
      case insertSection (idOf "nod-0003") ns d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          sectionIds d'
            `shouldBe` map idOf ["nod-0003", "nod-0010", "nod-0011", "nod-0020", "nod-0030", "nod-0004"]
          case parseDocument (renderDocument d') >>= toLevel of
            Left e -> expectationFailure (T.unpack (renderMdError e))
            Right (_, nodes) -> do
              let lookupNode i = filter ((== idOf i) . metaId . nodMeta) nodes
              case lookupNode "nod-0030" of
                [n] -> do
                  nodParent n `shouldBe` Just (idOf "nod-0003")
                  nodOrder n `shouldBe` 3
                  nodKind n `shouldBe` KScene
                other -> expectationFailure ("nod-0030 應該恰一筆,得到 " <> show (length other))
              forM_
                [ ("nod-0010" :: Text, Just (idOf "nod-0003"), 1 :: Int)
                , ("nod-0011", Just (idOf "nod-0003"), 2)
                , ("nod-0020", Just (idOf "nod-0011"), 1)
                , ("nod-0004", Nothing, 2)
                ]
                $ \(i, par, ord) -> case lookupNode i of
                  [n] -> do
                    nodParent n `shouldBe` par
                    nodOrder n `shouldBe` ord
                  other -> expectationFailure (T.unpack i <> " 應該恰一筆,得到 " <> show (length other))

    it "E12: 格式正常(雙空行)的檔案上,插入點也一個位元組都不動" $ do
      let d = docOf e11LevelMd
          ns = NewSection (idOf "nod-0030") 3 "新場景" "" (NSNode emptyOverride (NewNode KScene))
      case insertSection (idOf "nod-0003") ns d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          docFrontRaw d' `shouldBe` docFrontRaw d
          docPreamble d' `shouldBe` docPreamble d
          forM_ (docSections d) $ \orig ->
            case sectionById (secId orig) d' of
              Nothing -> expectationFailure "既有節不該消失"
              Just s -> renderSection s `shouldBe` renderSection orig

    it "E12 變體:nod-0020 只有單一空行時,只有它的 secBodyRaw 尾端補齊,其餘不變" $ do
      let d = docOf e12SingleBlankVariant
          ns = NewSection (idOf "nod-0030") 3 "新場景" "" (NSNode emptyOverride (NewNode KScene))
      case insertSection (idOf "nod-0003") ns d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          docFrontRaw d' `shouldBe` docFrontRaw d
          docPreamble d' `shouldBe` docPreamble d
          forM_ (docSections d) $ \orig ->
            when (secId orig /= idOf "nod-0020") $
              case sectionById (secId orig) d' of
                Nothing -> expectationFailure "既有節不該消失"
                Just s -> renderSection s `shouldBe` renderSection orig
          case (sectionById (idOf "nod-0020") d, sectionById (idOf "nod-0020") d') of
            (Just orig, Just s) -> do
              secHeadingRaw s `shouldBe` secHeadingRaw orig
              secMetaRaw s `shouldBe` secMetaRaw orig
              secBodyRaw s `shouldBe` blankTailOracle LF (secBodyRaw orig)
            _ -> expectationFailure "nod-0020 應該在兩邊都找得到"

    it "E13: 1,693 節的合成 Level 檔,對中間有子樹的節插入,除插入點前一節外其餘 1,692 節逐位元組不變" $ do
      let midI = 846
          src = synthLevelMd 1693 midI
          d = docOf src
          parentId = idOf (synthChapterId midI)
          childId = idOf synthChildId
          newId = idOf "nod-ffffffff"
          ns = NewSection newId 4 "新子節" "" (NSNode emptyOverride (NewNode KCast))
      length (docSections d) `shouldBe` 1693
      case insertSection parentId ns d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          length (docSections d') `shouldBe` 1694
          forM_ (docSections d) $ \orig ->
            when (secId orig /= childId) $
              case sectionById (secId orig) d' of
                Nothing -> expectationFailure "既有節不該消失"
                Just s -> renderSection s `shouldBe` renderSection orig
          case parseDocument (renderDocument d') >>= toLevel of
            Left e -> expectationFailure (T.unpack (renderMdError e))
            Right (lvl', nodes) -> case buildTree lvl' nodes of
              Left errs -> expectationFailure ("buildTree 應該成功:" <> show errs)
              Right _ -> pure ()

    it "E14: 父節點是文件的最後一節時,insertSection 與 appendSection 產生相同的 renderDocument" $ do
      let d = docOf classroomMd
          lastSec = last (docSections d)
          ns = NewSection (idOf "nod-0099") (secLevel lastSec + 1) "附註" "" (NSNode emptyOverride (NewNode KCamera))
      (renderDocument <$> insertSection (secId lastSec) ns d)
        `shouldBe` (renderDocument <$> appendSection ns d)

    it "E15: 新節插在中間、nsBody 不以行尾結尾,不會與下一節標題黏在一起" $ do
      let d = docOf e11LevelMd
          ns = NewSection (idOf "nod-0031") 3 "新場景" "內文" (NSNode emptyOverride (NewNode KScene))
      case insertSection (idOf "nod-0003") ns d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> case parseDocument (renderDocument d') of
          Left e -> expectationFailure (T.unpack (renderMdError e))
          Right d'' -> do
            length (docSections d'') `shouldBe` length (docSections d) + 1
            case sectionById (idOf "nod-0031") d'' of
              Nothing -> expectationFailure "新節應該存在"
              Just s -> secTitle s `shouldBe` "新場景"

    it "E16: 父節點不存在回 UnknownSectionId" $ do
      let d = docOf classroomMd
          ns = NewSection (idOf "nod-0099") 3 "x" "" (NSFragment emptyOverride)
      insertSection (idOf "nod-9999") ns d `shouldBe` Left (mdError 1 (UnknownSectionId (idOf "nod-9999")))

    it "E17: nsLevel 不等於 secLevel(父)+1 時回 HeadingSkip" $ do
      let d = docOf classroomMd -- nod-0001 是 level 2
          ns = NewSection (idOf "nod-0099") 4 "x" "" (NSFragment emptyOverride)
      insertSection (idOf "nod-0001") ns d `shouldBe` Left (mdError 1 (HeadingSkip 2 4))

    it "E18: 父節點在第 6 級,nsLevel = 7 時回 HeadingTooDeep(第 3 條檢查會過)" $ do
      let d = docOf classroomMd -- nod-0007 是 level 6
          ns = NewSection (idOf "nod-0099") 7 "x" "" (NSFragment emptyOverride)
      insertSection (idOf "nod-0007") ns d `shouldBe` Left (mdError 1 (HeadingTooDeep 6 7))

    it "E19: nsId 撞號時優先於層級檢查,回 DuplicateSectionId" $ do
      let d = docOf classroomMd -- nod-0001 是 level 2,nod-0002 已存在
          ns = NewSection (idOf "nod-0002") 5 "x" "" (NSFragment emptyOverride)
      insertSection (idOf "nod-0001") ns d `shouldBe` Left (mdError 1 (DuplicateSectionId (idOf "nod-0002")))

    it "E20: 父節點在第 6 級但 nsLevel = 9(第 3 條先擋下),回 HeadingSkip 不是 HeadingTooDeep" $ do
      let d = docOf classroomMd -- nod-0007 是 level 6
          ns = NewSection (idOf "nod-0099") 9 "x" "" (NSFragment emptyOverride)
      insertSection (idOf "nod-0007") ns d `shouldBe` Left (mdError 1 (HeadingSkip 6 9))

    it "E21: HeadingTooDeep 的訊息逐字相符(契約 G:下一步指引;L39 原文轉錄)" $
      renderMdError (mdError 12 (HeadingTooDeep 6 7))
        `shouldBe` "第 12 行:標題層級 #######(第 7 級)超過 Markdown 的六級上限,父節點 ###### 已經在第 6 級,底下加不了子節點了:請改插到較淺的父節點底下,或先把這條分支中間的層級壓平"

    -- E22:既有建構子的訊息逐字回歸(不受 HeadingTooDeep 影響)。
    --
    -- __委派備註__:spec 原文說「既有 14 個建構子」,但 'MdErrorKind' 扣掉
    -- 'HeadingTooDeep' 實際數出來是 15 個(與 "Aapms.Md.ErrorSpec"「每一種
    -- 錯誤都有非空訊息」測試枚舉的清單一致)——這條數字對不上已記進
    -- spec-gaps(G3)。以下訊息逐字轉錄自現行(本次委派明令不得更動)的
    -- 'renderMdErrorKind',是回歸 law 的釘子,不是對受測介面(insertSection /
    -- HeadingTooDeep)行為的推論。
    it "E22: 既有(15 個)建構子的訊息與本輪之前逐字相同" $ do
      renderMdError (mdError 1 NoFrontmatter) `shouldBe` "第 1 行:檔案開頭缺少 --- frontmatter 界線"
      renderMdError (mdError 1 UnterminatedFrontmatter)
        `shouldBe` "第 1 行:frontmatter 只有開頭的 ---,找不到結尾的 ---"
      renderMdError (mdError 1 (FrontmatterYaml "壞了")) `shouldBe` "第 1 行:frontmatter 的 YAML 無法解析:壞了"
      renderMdError (mdError 1 (SectionYaml (idOf "ent-0001") "壞了"))
        `shouldBe` "第 1 行:節 ent-0001 的 meta 區塊 YAML 無法解析:壞了"
      renderMdError (mdError 1 (HeadingWithoutId "標題")) `shouldBe` "第 1 行:標題「標題」缺少合法的 {#id} 屬性"
      renderMdError (mdError 1 (DuplicateSectionId (idOf "ent-0001")))
        `shouldBe` "第 1 行:節 id ent-0001 在同一份檔案中重複"
      renderMdError (mdError 1 (IdPrefixMismatch (idOf "nod-0001") "ent"))
        `shouldBe` "第 1 行:節 id nod-0001 的前綴不是 ent-"
      renderMdError (mdError 1 (HeadingSkip 2 4)) `shouldBe` "第 1 行:標題層級跳級:## 之後不能直接接 ####"
      renderMdError (mdError 1 (HeadingAboveRoot 2 1)) `shouldBe` "第 1 行:標題層級 # 比根層級 ## 還淺"
      renderMdError (mdError 1 UnterminatedMetaBlock) `shouldBe` "第 1 行:```meta 區塊沒有結尾的 ```"
      renderMdError (mdError 1 (MissingNodeKind (idOf "nod-0001")))
        `shouldBe` "第 1 行:節 nod-0001 的 meta 區塊缺少必填的 kind"
      renderMdError (mdError 1 (RootMismatch (idOf "nod-0009") (idOf "nod-0001")))
        `shouldBe` "第 1 行:frontmatter 宣告的 root nod-0009 與第一個節 nod-0001 不符"
      renderMdError (mdError 1 (RequiredFieldMissing "title")) `shouldBe` "第 1 行:frontmatter 缺少必填欄位 title"
      renderMdError (mdError 1 (SectionFieldMissing (idOf "lic-0000000a") "commercial"))
        `shouldBe` "第 1 行:節 lic-0000000a 缺少必填欄位 commercial"
      renderMdError (mdError 1 (UnknownSectionId (idOf "ent-0001"))) `shouldBe` "第 1 行:找不到節 ent-0001"

--------------------------------------------------------------------------------
-- E11–E13 專用 fixture(本檔自建,不改 "Aapms.Md.Fixtures":委派指示只准新建
-- 本檔)。結構依 F004 spec 的 E11 描述逐字構造:@## 第三章 {#nod-0003}@ 底下
-- 依序有 @### 第一節 {#nod-0010}@、@### 第二節 {#nod-0011}@,
-- @nod-0011@ 底下還有 @#### 場景 A {#nod-0020}@;檔尾另有
-- @## 第四章 {#nod-0004}@。每節之後隔兩個空行(理由同
-- 'Aapms.Md.Fixtures.synthPackMd' 的檔頭註解:secBodyRaw 已經是 @"\n\n"@,
-- blankTail 補齊分隔空行時剛好是 no-op——E12「格式正常的檔案上插入點位元組
-- 不變」才斷言得到逐位元組相等,不必靠但書)。

e11LevelMd :: Text
e11LevelMd =
  T.unlines
    [ "---"
    , "id: lvl-0000e011"
    , "vault: liftgame"
    , "type: level"
    , "title: E11 Level"
    , "summary: 測試用 Level 檔"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "整章概述。"
    , ""
    , "## 第三章 {#nod-0003}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , ""
    , "### 第一節 {#nod-0010}"
    , ""
    , "```meta"
    , "kind: cast"
    , "```"
    , ""
    , ""
    , "### 第二節 {#nod-0011}"
    , ""
    , "```meta"
    , "kind: cast"
    , "```"
    , ""
    , ""
    , "#### 場景 A {#nod-0020}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , ""
    , "## 第四章 {#nod-0004}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , ""
    ]

-- | 與 'e11LevelMd' 只有一處不同:@nod-0020@ 到 @nod-0004@ 之間只有__單一__
-- 空行(而不是雙空行),用來覆蓋 L33 的但書(插入點前一節__還沒有__以空行
-- 結尾時才補齊)。
e12SingleBlankVariant :: Text
e12SingleBlankVariant =
  T.unlines
    [ "---"
    , "id: lvl-0000e011"
    , "vault: liftgame"
    , "type: level"
    , "title: E11 Level"
    , "summary: 測試用 Level 檔"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "整章概述。"
    , ""
    , "## 第三章 {#nod-0003}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , ""
    , "### 第一節 {#nod-0010}"
    , ""
    , "```meta"
    , "kind: cast"
    , "```"
    , ""
    , ""
    , "### 第二節 {#nod-0011}"
    , ""
    , "```meta"
    , "kind: cast"
    , "```"
    , ""
    , ""
    , "#### 場景 A {#nod-0020}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "## 第四章 {#nod-0004}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , ""
    ]

-- E13 專用:合成 1,693 節的 Level 檔(D4:測試內生成器合成,不需要真實大檔,
-- 與 'Aapms.Md.Fixtures.synthPackMd' 同一個理由)。
--
-- __W6 仲裁修正(F004 第 1 輪)__:上一版把 1,692 個章節全部放在 level 2,
-- 節層階層決定父子關係(ADR-009),所以那 1,692 個節的 nodParent 全是
-- Nothing——也就是 1,692 個 root。這__不是__一份合法的 Level 檔(design.md
-- 契約 A 的 `Level { lvlRoot :: Id }` 是單數;`buildTree` 只接受恰好一個
-- root),`toLevel` 之後餵給 `buildTree` 必然回 `MultipleRoots`,與
-- `insertSection` 本身對不對無關。改法:只留__一個__ level-2 根節點,其餘
-- 1,691 個「章」節全部降一級(level 3),當根節點的子節點(兄弟關係,單根
-- 嚴格樹);@mid@ 這個章節底下再帶一個 level-4 子節點(製造「有子樹」的插入
-- 點),插入目標\/nsLevel 因此也跟著降一級(父節點是 level 3 的章,新節
-- nsLevel = 4)。每節之後隔兩個空行(理由同上,讓未受影響的節位元組不變)。

synthRootId :: Text
synthRootId = "nod-" <> hex8 (0 :: Int)

synthChapterId :: Int -> Text
synthChapterId i = "nod-" <> hex8 i

synthChildId :: Text
synthChildId = "nod-" <> hex8 (9001 :: Int)

hex8 :: Int -> Text
hex8 i = T.justifyRight 8 '0' (T.pack (showHex i ""))

-- | @n@ 節、單根嚴格樹:一個 level-2 根,其下 @n - 2@ 個 level-3 章節
-- (兄弟),其中 @mid@ 那一章額外帶一個 level-4 子節(所以總節數是
-- @1(根) + (n - 3)(一般章) + 2(mid 章 + 它的子節) = n@)。
synthLevelMd :: Int -> Int -> Text
synthLevelMd n mid =
  T.unlines $
    [ "---"
    , "id: lvl-00000002"
    , "vault: liftgame"
    , "type: level"
    , "title: 合成 Level"
    , "summary: E13 用"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-10"
    , "updated: 2026-08-10"
    , "---"
    , ""
    , "合成測試用。"
    , ""
    , "## 根 {#" <> synthRootId <> "}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , ""
    ]
      ++ concatMap chapter [1 .. n - 2]
  where
    chapter :: Int -> [Text]
    chapter i
      | i == mid =
          [ "### 章 " <> T.pack (show i) <> " {#" <> synthChapterId i <> "}"
          , ""
          , "```meta"
          , "kind: scene"
          , "```"
          , ""
          , ""
          , "#### 子節 {#" <> synthChildId <> "}"
          , ""
          , "```meta"
          , "kind: cast"
          , "```"
          , ""
          , ""
          ]
      | otherwise =
          [ "### 章 " <> T.pack (show i) <> " {#" <> synthChapterId i <> "}"
          , ""
          , "```meta"
          , "kind: scene"
          , "```"
          , ""
          , ""
          ]
