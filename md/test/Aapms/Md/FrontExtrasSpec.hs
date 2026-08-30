-- | graph-core/F004(2026-08-25 第三輪,spec-gaps GAP-17):檔案層 frontmatter 的
-- 兩半機制——`FrontExtras` / `frontExtrasOf` / `mergeFrontExtras` /
-- `renderFrontmatterWith` / `newDocumentWith` / `updateFrontmatterExtras` /
-- `packFrontExtras` / `NewPackFront`。
--
-- 本檔只翻新增的那一組:Laws LAW-40–LAW-49(「檔案層的兩半」)與 Examples EX-23–EX-29。
-- 其餘 39 條 law 與 22 條 example 的測試早就存在且全綠,不重寫、不碰。
--
-- __A12 裁決帶來的特殊情況__:`updateFrontmatter` 的缺陷本體__留在原地沒有清成
-- `undefined`__(清了會炸掉十幾條與本輪無關的既有測試)。所以 LAW-45 / LAW-46 /
-- EX-24 / EX-26 這四條__不像其他未實作標記那樣「一定會紅」__——它們是否紅,完全
-- 取決於 qa 有沒有寫出真正戳到現行缺陷本體的斷言。本檔對這四條刻意__避開呼叫
-- `frontExtrasOf` / `mergeFrontExtras` / `renderFrontmatterWith` /
-- `newDocumentWith` / `updateFrontmatterExtras` / `packFrontExtras` 這六個
-- 本輪新的 `undefined` 函式__,只用既已存在、本輪未改動的介面
-- (`updateFrontmatter`、`renderDocument`、`docFrontRaw`、`docPreamble`、
-- `docSections`、`renderSection`、`parseDocument`、`toPack`、
-- `decodeFrontmatter`)當斷言的觀察點,外加逐字文字比對——這樣紅燈才**只能**
-- 歸因於 `updateFrontmatter` 現行本體的缺陷,不會被別的 `undefined` 搶著爆炸。
-- LAW-45 另外附一條「特別地」子句的完整翻譯(呼叫 `newDocumentWith` /
-- `packFrontExtras`),那一條**不在**四條特別關注清單內,紅可能是複合原因。
--
-- __spec 對照__:
--
-- @
-- LAW-40 frontExtrasOf 的判準(對稱 LAW-7)                        -> "LAW-40" it
-- LAW-41 renderFrontmatterWith 的行序列(對稱 LAW-9)               -> "LAW-41" it
-- LAW-42 renderFrontmatter 是 renderFrontmatterWith 的特化(回歸)-> "LAW-42" it
-- LAW-43 newDocument 是 newDocumentWith 的特化                  -> "LAW-43" it
-- LAW-44 檔案層往返(GAP-17 直接否證;七欄皆非預設值)               -> "LAW-44" it
-- LAW-45 updateFrontmatter 不吃掉專屬條目 【特別關注】          -> "LAW-45(1/2)" / "LAW-45(2/2)" 兩個 it
-- LAW-46 updateFrontmatter 冪等(且冪等點仍保有 extras) 【特別關注】 -> "LAW-46" it
-- LAW-47 updateFrontmatterExtras 的對稱保留                     -> "LAW-47" it
-- LAW-48 packFrontExtras 的鍵集合與順序(對稱 LAW-11)               -> "LAW-48" it
-- LAW-49 mergeFrontExtras 就是 mergeExtras(ASM-11 的機械驗證形式)  -> "LAW-49" it
--
-- EX-23 npf 七欄逐欄等於給進去的值(含 author 巢狀子欄位)      -> "EX-23" it
-- EX-24 檔案層版的 EX-1(GAP-2 在檔案層的對稱處置) 【特別關注】       -> "EX-24" it
-- EX-25 npf 全 Nothing/AiUnknown 時退化成既有路徑              -> "EX-25" it
-- EX-26 未知欄位保留 + 冪等(檔案層版的 EX-6) 【特別關注】         -> "EX-26" it
-- EX-27 updateFrontmatterExtras 的編輯路徑(對稱 EX-7)            -> "EX-27" it
-- EX-28 frontmatter YAML 壞掉時的例外路徑(對稱 updateSection)  -> "EX-28" it
-- EX-29 mergeFrontExtras 沒有第二份實作(ASM-11 的機械驗證)        -> "EX-29" it
-- @
module Aapms.Md.FrontExtrasSpec (spec) where

import Data.Aeson (encode)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Asset (Sha256 (..))
import Aapms.Core.Id (IdPrefix (..), Ref (..), renderId)
import Aapms.Core.Json ()
import Aapms.Core.Meta
import Aapms.Core.Pack (AiDisclosure (..), Author (..), Pack (..))
import Aapms.Md
import Aapms.Md.Fixtures
import Aapms.Md.Gens

--------------------------------------------------------------------------------
-- 共用 fixture / 產生器

fixtureDocs :: [Document]
fixtureDocs = [docOf lindaMd, docOf packMd, docOf licensesMd, docOf classroomMd]

emptyFront :: FrontExtras
emptyFront = FrontExtras (MetaExtras [])

-- | pack.md 檔案層專屬(非 Meta)的鍵清單,與 'frontmatterFieldOrder' 不相交。
extraFrontKeyPool :: [Text]
extraFrontKeyPool = ["vendor", "archive", "sha256", "license", "author", "source_url", "ai_disclosure"]

-- | 'extraFrontKeyPool' 的隨機子集,每個鍵恰好一行(與 "Aapms.Md.Gens" 的
-- 'genMetaExtrasSubset' 同一個限縮:多行分組規則不是 property test 該猜的細節)。
genFrontExtrasSubset :: Gen FrontExtras
genFrontExtrasSubset = do
  flags <- mapM (const Gen.bool) extraFrontKeyPool
  let chosen = [k | (k, True) <- zip extraFrontKeyPool flags]
  shuffled <- Gen.shuffle chosen
  pure (FrontExtras (MetaExtras [k <> ": v_" <> k | k <- shuffled]))

-- | LAW-44 / LAW-45(2/2) 的 @m@ 前提:'metaType' 是 @asset-pack@、'metaId' 前綴為 'PPck'。
genPackMeta :: Gen Meta
genPackMeta = do
  m <- genMeta
  i <- genId PPck
  pure m {metaId = i, metaType = TypeKey "asset-pack"}

genAuthor :: Gen Author
genAuthor = Author <$> genNonEmptySafeText <*> Gen.maybe genNonEmptySafeText <*> Gen.maybe genNonEmptySafeText

genAiDisclosure :: Gen AiDisclosure
genAiDisclosure = Gen.enumBounded

-- | LAW-44 用:排除 'AiUnknown'(它是「不寫這一欄」的預設值,拿它測往返會讓
-- 那一欄的斷言恆真)。
genAiDisclosureNonDefault :: Gen AiDisclosure
genAiDisclosureNonDefault = Gen.element [AiNone, AiAssisted, AiGenerated]

genNewPackFront :: Gen NewPackFront
genNewPackFront =
  NewPackFront
    <$> Gen.maybe genNonEmptySafeText
    <*> Gen.maybe (T.unpack <$> genEntryText)
    <*> Gen.maybe (Sha256 <$> genHex8)
    <*> Gen.maybe (genRef PLic)
    <*> Gen.maybe genAuthor
    <*> Gen.maybe genNonEmptySafeText
    <*> genAiDisclosure

-- | LAW-44 用:七欄__全部__給非預設值(六個 'Maybe' 欄位皆 'Just',
-- 'npfAiDisclosure' 排除 'AiUnknown')——spec 明白警告全 'Nothing' 的輸入
-- 不足以驗證往返(那樣兩邊都是預設值,斷言會恆真),往返 law 必須用會真正
-- 寫出東西的輸入才驗證得到什麼。
genNewPackFrontAllSet :: Gen NewPackFront
genNewPackFrontAllSet =
  NewPackFront
    <$> (Just <$> genNonEmptySafeText)
    <*> (Just . T.unpack <$> genEntryText)
    <*> (Just . Sha256 <$> genHex8)
    <*> (Just <$> genRef PLic)
    <*> (Just <$> genAuthor)
    <*> (Just <$> genNonEmptySafeText)
    <*> genAiDisclosureNonDefault

-- | LAW-41 用:'Meta' 的某個 'frontmatterFieldOrder' 鍵貢獻幾行。'Meta' 沒有
-- 'Maybe' 包裝(除了個別欄位型別本身是 'Maybe'),每個欄位__一律輸出一行__
-- (LAW-30 已證實、且仍是回歸 law),只有 @links@ 依 spec 原文是
-- @1 + length metaLinks@。
frontFieldLineCount :: Meta -> Text -> Int
frontFieldLineCount Meta {..} k = case k of
  "links" -> 1 + length metaLinks
  _ -> 1

-- | 依 'LineEnding' 切行,丟掉切割產生的尾端空字串(與
-- "Aapms.Md.EditLawsSpec" 的私有 @splitOnLE@ 同款,無法重用只能各自一份)。
splitOnLE :: LineEnding -> Text -> [Text]
splitOnLE le = filter (not . T.null) . T.splitOn (renderLineEnding le)

-- | LAW-40 用:標記一行是「屬於 'Meta' 的欄位」還是「檔案層專屬條目」,只生成
-- __單行__條目(與 "Aapms.Md.Gens" 檔頭說明的節層限縮同一個理由)。
data TaggedLine = MetaLine Text | ExtraLine Text
  deriving stock (Show)

genFrontTaggedLines :: Gen [TaggedLine]
genFrontTaggedLines = Gen.list (Range.linear 0 6) (Gen.choice [genMetaLine, genExtraLine])
  where
    genMetaLine = do
      k <- Gen.element frontmatterFieldOrder
      v <- genNonEmptySafeText
      pure (MetaLine (k <> ": " <> v))
    genExtraLine = do
      k <- Gen.element extraFrontKeyPool
      v <- genNonEmptySafeText
      pure (ExtraLine (k <> ": " <> v))

-- | LAW-40 用:由標記行直接組一個 'Document'(不經過 'parseDocument'——'frontExtrasOf'
-- 是純函式,'docFrontRaw' 是它唯一需要的欄位)。'docFrontRaw' 的定義是「不含
-- @---@ 界線本身、含其行尾字元」,所以第一個字元是開頭界線的行尾。
buildFrontDoc :: [TaggedLine] -> Document
buildFrontDoc tls =
  Document
    { docFrontRaw = "\n" <> T.concat [tlText tl <> "\n" | tl <- tls]
    , docPreamble = "\n"
    , docSections = []
    , docEnding = LF
    , docFinalNL = True
    , docKind = TopicDoc
    }
  where
    tlText (MetaLine t) = t
    tlText (ExtraLine t) = t

-- EX-23 / EX-24 / EX-25 / EX-27 共用的一份最小合法 pack.md 'Meta'(asset-pack 型別、
-- PPck 前綴,對稱 LAW-44 的前提)。
e23Meta :: Meta
e23Meta =
  Meta
    { metaId = idOf "pck-0000e023"
    , metaVault = vaultOf "liftgame-assets"
    , metaType = typeOf "asset-pack"
    , metaTitle = "EX-23 pack"
    , metaSummary = "測試用"
    , metaTags = []
    , metaStatus = Canon
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = Revision 1
    , metaCreated = day0
    , metaUpdated = day0
    }

e23Npf :: NewPackFront
e23Npf =
  NewPackFront
    (Just "Kenney")
    (Just "ui-pack.zip")
    (Just (Sha256 "deadbeef1234"))
    (Just (Ref Nothing (idOf "lic-0000000a")))
    (Just (Author "Kenney" (Just "https://kenney.nl") Nothing))
    (Just "https://kenney.nl/assets/ui-pack")
    AiNone

-- | EX-26 用:主題檔 frontmatter 含未知(型別註冊表宣告的自訂)頂層欄位
-- @battle_power: 9000@,與節層 EX-6 同一個理由(檔案層版)。
e26TopicMd :: Text
e26TopicMd =
  T.unlines
    [ "---"
    , "id: ent-0000e026"
    , "vault: liftgame"
    , "type: character"
    , "title: EX-26 測試"
    , "summary: 測試用"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "battle_power: 9000"
    , "---"
    , ""
    , "本體。"
    ]

spec :: Spec
spec = do
  describe "graph-core/F004(2026-08-25 第三輪,GAP-17):檔案層 extras Laws(LAW-40-LAW-49)" $ do
    it "LAW-40: frontExtrasOf 恰好取出鍵不在 frontmatterFieldOrder 的頂層條目,逐字、順序不變" $
      hedgehog $ do
        tls <- forAll genFrontTaggedLines
        let d = buildFrontDoc tls
            expected = FrontExtras (MetaExtras [t | ExtraLine t <- tls])
        frontExtrasOf d === expected
        assert
          ( all
              (`notElem` frontmatterFieldOrder)
              [T.takeWhile (/= ':') l | l <- extraLines (unFrontExtras (frontExtrasOf d))]
          )

    it "LAW-41: renderFrontmatterWith 的行序列 = F(依 frontmatterFieldOrder)+ lines fx 尾段" $
      hedgehog $ do
        m <- forAll genMeta
        fx <- forAll genFrontExtrasSubset
        le <- forAll genLineEnding
        let out = renderFrontmatterWith m fx le
            ls = splitOnLE le out
            extraLs = extraLines (unFrontExtras fx)
            (fLines, tailLines) = splitAt (length ls - length extraLs) ls
        tailLines === extraLs
        length fLines === sum [frontFieldLineCount m k | k <- frontmatterFieldOrder]

    it "LAW-42(回歸): renderFrontmatterWith m emptyFront le 與 renderFrontmatter m le 逐位元組相同" $
      hedgehog $ do
        m <- forAll genMeta
        le <- forAll genLineEnding
        renderFrontmatterWith m emptyFront le === renderFrontmatter m le

    it "LAW-43: newDocumentWith k m emptyFront b == newDocument k m b" $
      hedgehog $ do
        k <- forAll (Gen.element [TopicDoc, LevelDoc, PackDoc, LicenseDoc])
        m <- forAll genMeta
        b <- forAll genSafeText
        newDocumentWith k m emptyFront b === newDocument k m b

    it "LAW-44(GAP-17 直接否證): newDocumentWith 帶 packFrontExtras npf,寫出去再讀回來七欄逐欄相等(npf 七欄皆非預設值)" $
      hedgehog $ do
        m <- forAll genPackMeta
        npf <- forAll genNewPackFrontAllSet
        b <- forAll genSafeText
        let d0 = newDocumentWith PackDoc m (packFrontExtras npf) b
        case parseDocument (renderDocument d0) >>= toPack of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right (pck, _) -> do
            pckVendor pck === npfVendor npf
            pckArchive pck === npfArchive npf
            pckSha256 pck === npfSha256 npf
            pckLicense pck === npfLicense npf
            pckAuthor pck === npfAuthor npf
            pckSourceUrl pck === npfSourceUrl npf
            pckAiDisclosure pck === npfAiDisclosure npf

    -- 【特別關注】LAW-45(1/2):只用 updateFrontmatter + 純文字/toPack 觀察,
    -- 不呼叫本輪任何一個新 undefined 函式——紅只能歸因於 updateFrontmatter
    -- 現行本體。packMd 本來就有 vendor/archive/sha256/license 四個檔案層
    -- extras(既有 fixture,已被 "Aapms.Md.ParsePackSpec" 證實可正確讀回),
    -- 是這條律最直接的證人。
    it "LAW-45(1/2,對著現行缺陷本體): updateFrontmatter 不吃掉檔案層專屬條目(以 packMd 既有的 4 個 extras 為證人)" $
      hedgehog $ do
        m' <- forAll genMeta
        let d = docOf packMd
        case updateFrontmatter (const m') d of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right d' -> do
            let out = docFrontRaw d'
            assert ("vendor: kenney" `T.isInfixOf` out)
            assert ("archive: library/packs/kenney/ui-pack/kenney_ui-pack.zip" `T.isInfixOf` out)
            assert ("sha256: 3c1f9a2b" `T.isInfixOf` out)
            assert ("license: lic-00000001" `T.isInfixOf` out)
            case toPack d' of
              Left e -> footnote (T.unpack (renderMdError e)) >> failure
              Right (pck, _) -> do
                pckVendor pck === Just "kenney"
                pckArchive pck === Just "library/packs/kenney/ui-pack/kenney_ui-pack.zip"
                pckSha256 pck === Just (Sha256 "3c1f9a2b")
                pckLicense pck === Just (Ref Nothing (idOf "lic-00000001"))

    -- LAW-45(2/2):spec「特別地」子句的完整翻譯——呼叫 newDocumentWith /
    -- packFrontExtras,不在四條特別關注清單內,紅可能是複合原因(那兩個
    -- 本輪也是 undefined)。
    it "LAW-45(2/2,特別地子句): 對 LAW-44 的 d0 做 updateFrontmatter 後再 toPack,七欄仍等於 npf" $
      hedgehog $ do
        m <- forAll genPackMeta
        npf <- forAll genNewPackFrontAllSet
        b <- forAll genSafeText
        m' <- forAll genMeta
        let d0 = newDocumentWith PackDoc m (packFrontExtras npf) b
        case parseDocument (renderDocument d0) of
          Left e -> footnote (T.unpack (renderMdError e)) >> failure
          Right d -> case updateFrontmatter (const m') d of
            Left e -> footnote (T.unpack (renderMdError e)) >> failure
            Right d' -> case toPack d' of
              Left e -> footnote (T.unpack (renderMdError e)) >> failure
              Right (pck, _) -> do
                pckVendor pck === npfVendor npf
                pckArchive pck === npfArchive npf
                pckSha256 pck === npfSha256 npf
                pckLicense pck === npfLicense npf
                pckAuthor pck === npfAuthor npf
                pckSourceUrl pck === npfSourceUrl npf
                pckAiDisclosure pck === npfAiDisclosure npf

    -- 【特別關注】LAW-46:同樣只用 updateFrontmatter + 純文字觀察。冪等單獨測
    -- (兩次呼叫的 renderDocument 相同)__不足以__戳到這個缺陷——現行本體對
    -- 「第一次已經吃掉 extras 的文件」再呼叫一次一樣是 no-op,兩次呼叫結果會
    -- 剛好相等,冪等律本身反而會在缺陷本體上「意外通過」。所以本測試__額外__
    -- 斷言冪等點上 extras 仍在,這才是 LAW-46 括號原文
    -- (「既有檔案的 frontmatter 行序只重排一次」)真正要保證的事——重排的前提
    -- 是那些行還在。
    it "LAW-46(對著現行缺陷本體): updateFrontmatter id 冪等,且冪等點仍保有檔案層專屬條目" $
      hedgehog $ do
        let d = docOf packMd
        case (updateFrontmatter id d, updateFrontmatter id d >>= updateFrontmatter id) of
          (Right d1, Right d2) -> do
            renderDocument d1 === renderDocument d2
            let out = docFrontRaw d1
            assert ("vendor: kenney" `T.isInfixOf` out)
            assert ("archive: library/packs/kenney/ui-pack/kenney_ui-pack.zip" `T.isInfixOf` out)
            assert ("sha256: 3c1f9a2b" `T.isInfixOf` out)
            assert ("license: lic-00000001" `T.isInfixOf` out)
          (Left e, _) -> footnote (T.unpack (renderMdError e)) >> failure
          (_, Left e) -> footnote (T.unpack (renderMdError e)) >> failure

    it "LAW-47: updateFrontmatterExtras 保留 Meta/docPreamble/各節,良型輸出時 frontExtrasOf 符合 g" $
      hedgehog $ do
        d <- forAll (Gen.element fixtureDocs)
        patch <- forAll genFrontExtrasSubset
        let g = mergeFrontExtras patch
        case updateFrontmatterExtras g d of
          Left _ -> success
          Right d' -> do
            docPreamble d' === docPreamble d
            map renderSection (docSections d') === map renderSection (docSections d)
            decodeFrontmatter (docFrontRaw d') === decodeFrontmatter (docFrontRaw d)
            frontExtrasOf d' === g (frontExtrasOf d)

    it "LAW-48: packFrontExtras 的鍵依序取自七個欄位、與 frontmatterFieldOrder 不相交,Nothing/AiUnknown 不產生行" $
      hedgehog $ do
        npf <- forAll genNewPackFront
        let FrontExtras (MetaExtras ls) = packFrontExtras npf
            keys = map (T.takeWhile (/= ':')) ls
            expectedKeys =
              concat
                [ ["vendor" | isJust (npfVendor npf)]
                , ["archive" | isJust (npfArchive npf)]
                , ["sha256" | isJust (npfSha256 npf)]
                , ["license" | isJust (npfLicense npf)]
                , ["author" | isJust (npfAuthor npf)]
                , ["source_url" | isJust (npfSourceUrl npf)]
                , ["ai_disclosure" | npfAiDisclosure npf /= AiUnknown]
                ]
        keys === expectedKeys
        assert (all (`notElem` frontmatterFieldOrder) keys)

    it "LAW-49: mergeFrontExtras a b == FrontExtras (mergeExtras (unFrontExtras a) (unFrontExtras b))" $
      hedgehog $ do
        a <- forAll genFrontExtrasSubset
        b <- forAll genFrontExtrasSubset
        mergeFrontExtras a b === FrontExtras (mergeExtras (unFrontExtras a) (unFrontExtras b))

  describe "graph-core/F004(2026-08-25 第三輪,GAP-17):檔案層 extras Examples(EX-23-EX-29)" $ do
    it "EX-23: newDocumentWith 帶 packFrontExtras npf,七欄逐欄等於給進去的值(含 author 巢狀子欄位)" $ do
      let d = newDocumentWith PackDoc e23Meta (packFrontExtras e23Npf) "素材包說明"
      case parseDocument (renderDocument d) >>= toPack of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right (pck, _) -> do
          pckVendor pck `shouldBe` Just "Kenney"
          pckArchive pck `shouldBe` Just "ui-pack.zip"
          pckSha256 pck `shouldBe` Just (Sha256 "deadbeef1234")
          pckLicense pck `shouldBe` Just (Ref Nothing (idOf "lic-0000000a"))
          pckAuthor pck `shouldBe` Just (Author "Kenney" (Just "https://kenney.nl") Nothing)
          pckSourceUrl pck `shouldBe` Just "https://kenney.nl/assets/ui-pack"
          pckAiDisclosure pck `shouldBe` AiNone

    -- 【特別關注】EX-24:手寫一份已經含全部七個 pack 專屬欄位的 pack.md(不經過
    -- newDocumentWith / packFrontExtras),author 那一行借真正的
    -- ToJSON Author 實例產生(spec「使用到的既有介面」表明講的做法:借 aeson
    -- 編碼器,不在測試裡另猜一套格式),只呼叫 updateFrontmatter + toPack /
    -- 純文字比對——紅只能歸因於 updateFrontmatter 現行本體。
    it "EX-24(對著現行缺陷本體): 檔案層版的 EX-1 — updateFrontmatter 之後七個 pack 專屬欄位逐字保留" $ do
      let licId = idOf "lic-0000e024"
          authorLine = "author: " <> TL.toStrict (TLE.decodeUtf8 (encode (Author "Kenney" (Just "https://kenney.nl") Nothing)))
          src =
            T.unlines
              [ "---"
              , "id: pck-0000e024"
              , "vault: liftgame-assets"
              , "type: asset-pack"
              , "title: EX-24 pack"
              , "vendor: Kenney"
              , "archive: ui-pack.zip"
              , "sha256: deadbeef1234"
              , "license: " <> renderId licId
              , authorLine
              , "source_url: https://kenney.nl/assets/ui-pack"
              , "ai_disclosure: none"
              , "status: canon"
              , "source: human"
              , "revision: 1"
              , "created: 2026-08-10"
              , "updated: 2026-08-10"
              , "---"
              , ""
              , "素材包說明"
              ]
          d = docOf src
      case updateFrontmatter (\mm -> mm {metaSummary = "after"}) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` T.isInfixOf "vendor: Kenney"
          out `shouldSatisfy` T.isInfixOf "archive: ui-pack.zip"
          out `shouldSatisfy` T.isInfixOf "sha256: deadbeef1234"
          out `shouldSatisfy` T.isInfixOf ("license: " <> renderId licId)
          out `shouldSatisfy` T.isInfixOf "source_url: https://kenney.nl/assets/ui-pack"
          out `shouldSatisfy` T.isInfixOf "ai_disclosure: none"
          out `shouldSatisfy` T.isInfixOf authorLine
          case parseDocument out >>= toPack of
            Left e -> expectationFailure (T.unpack (renderMdError e))
            Right (pck, _) -> do
              pckVendor pck `shouldBe` Just "Kenney"
              pckArchive pck `shouldBe` Just "ui-pack.zip"
              pckSha256 pck `shouldBe` Just (Sha256 "deadbeef1234")
              pckLicense pck `shouldBe` Just (Ref Nothing licId)
              pckSourceUrl pck `shouldBe` Just "https://kenney.nl/assets/ui-pack"
              pckAiDisclosure pck `shouldBe` AiNone
              metaSummary (pckMeta pck) `shouldBe` "after"

    it "EX-25: npf 七欄全 Nothing/AiUnknown 時,packFrontExtras 是空 extras,newDocumentWith 與 newDocument 逐位元組相同" $ do
      let npf = NewPackFront Nothing Nothing Nothing Nothing Nothing Nothing AiUnknown
      packFrontExtras npf `shouldBe` FrontExtras (MetaExtras [])
      newDocumentWith PackDoc e23Meta (packFrontExtras npf) "body"
        `shouldBe` newDocument PackDoc e23Meta "body"

    -- 【特別關注】EX-26:手寫主題檔 fixture(含未知欄位 battle_power,定義見檔尾
    -- 'e26TopicMd'),只呼叫 updateFrontmatter + 純文字比對,兩次呼叫確認冪等。
    it "EX-26(對著現行缺陷本體): 檔案層版的 EX-6 — 未知欄位逐字保留,再呼叫一次冪等" $ do
      let d = docOf e26TopicMd
      case updateFrontmatter (\mm -> mm {metaStatus = Canon}) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d1 -> do
          let out1 = renderDocument d1
          out1 `shouldSatisfy` T.isInfixOf "battle_power: 9000"
          case updateFrontmatter id d1 of
            Left e -> expectationFailure (T.unpack (renderMdError e))
            Right d2 -> renderDocument d2 `shouldBe` out1

    it "EX-27: updateFrontmatterExtras (mergeFrontExtras (packFrontExtras npf')) 只換 license,其餘不變" $ do
      let newLic = idOf "lic-0000000b"
          npf' = e23Npf {npfLicense = Just (Ref Nothing newLic)}
          d0 = newDocumentWith PackDoc e23Meta (packFrontExtras e23Npf) "素材包說明"
      case parseDocument (renderDocument d0) of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d -> case updateFrontmatterExtras (mergeFrontExtras (packFrontExtras npf')) d of
          Left e -> expectationFailure (T.unpack (renderMdError e))
          Right d' -> do
            let out = renderDocument d'
            out `shouldSatisfy` T.isInfixOf ("license: " <> renderId newLic)
            out `shouldNotSatisfy` T.isInfixOf ("license: " <> renderId (idOf "lic-0000000a"))
            out `shouldSatisfy` T.isInfixOf "vendor: Kenney"
            out `shouldSatisfy` T.isInfixOf "archive: ui-pack.zip"
            out `shouldSatisfy` T.isInfixOf "sha256: deadbeef1234"
            decodeFrontmatter (docFrontRaw d') `shouldBe` decodeFrontmatter (docFrontRaw d)
            docPreamble d' `shouldBe` docPreamble d
            map renderSection (docSections d') `shouldBe` map renderSection (docSections d)

    it "EX-28: frontmatter 的 YAML 壞掉時 updateFrontmatterExtras 回 Left(FrontmatterYaml),docFrontRaw 不覆蓋" $ do
      let d =
            Document
              { docFrontRaw = "\nid: ent-0001\ntitle: [unclosed\n"
              , docPreamble = "\n"
              , docSections = []
              , docEnding = LF
              , docFinalNL = True
              , docKind = TopicDoc
              }
      case updateFrontmatterExtras id d of
        Right _ -> expectationFailure "應該回 Left"
        Left e -> case errKind e of
          FrontmatterYaml _ -> pure ()
          other -> expectationFailure ("預期 FrontmatterYaml,得到 " <> show other)

    it "EX-29: mergeFrontExtras 與 mergeExtras 的結果相等(wrapper 沒有第二份實作)" $ do
      let a = FrontExtras (MetaExtras ["battle_power: 9000", "custom_a: x"])
          b = FrontExtras (MetaExtras ["custom_a: y", "custom_b: z"])
      mergeFrontExtras a b `shouldBe` FrontExtras (mergeExtras (unFrontExtras a) (unFrontExtras b))
