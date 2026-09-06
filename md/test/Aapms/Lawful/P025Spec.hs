-- | lawful 測試:P-025-md-document(qa 填入)。
--
-- 每條 law 一個 @describe "P-025#LAW-n"@ 的 property,每個 example 一個
-- @describe "P-025#EX-n"@。產生器只用 types 層的 smart constructor
-- ('Aapms.Core.Id.parseId'、'Aapms.Core.Meta.Meta' 的欄位)與 Stages 表上的
-- 簽名組合合法值;有 @given@ 行的 law 直接建構滿足前提的值,不做過濾。
module Aapms.Lawful.P025Spec (spec) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Data.Either (isLeft, isRight)
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian)
import Numeric (showHex)
import System.Timeout (timeout)

import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog

import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id
  ( Id
  , IdPrefix (..)
  , Ref (..)
  , VaultId (..)
  , parseId
  , renderId
  , renderIdPrefix
  )
import Aapms.Core.Level (Level (..), Node (..), NodeKind (..), allNodeKinds)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), LinkKind (..), coreLinkKinds)
import Aapms.Core.Meta
  ( Meta (..)
  , Revision (..)
  , Source (..)
  , SourceName
  , Status (..)
  , Timeline (..)
  , TypeKey (..)
  , metaFieldNames
  , mkSourceName
  , sourceNameText
  )
import Aapms.Md.Document
import Aapms.Md.Error (MdError (..), MdErrorKind (..))
import Aapms.Md.Inherit (applyOverride, inheritMeta, overrideOf)
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Md.Render
  ( newDocument
  , newDocumentWith
  , renderDocument
  , renderFrontmatter
  , renderMetaBlock
  , renderSection
  )
import Aapms.Md.Section
  ( FrontExtras (..)
  , MetaExtras (..)
  , MetaOverride (..)
  , emptyOverride
  )
import Aapms.Md.Yaml (decodeFrontmatter)

--------------------------------------------------------------------------------
-- 產生器

-- | 只用 'parseId' 這個 smart constructor 造 'Id';造不出來是測試自己的 bug。
unsafeId :: Text -> Id
unsafeId t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("P-025 測試產生器造出非法 id " <> T.unpack t <> ":" <> show e)

-- | 由索引造出同一份文件裡保證不重複的節 id。
ixId :: IdPrefix -> Int -> Id
ixId p n = unsafeId (renderIdPrefix p <> "-" <> T.justifyRight 8 '0' hx)
  where
    hx = T.pack (showHex (abs n) "")

genId :: IdPrefix -> Gen Id
genId p = do
  hx <- Gen.text (Range.singleton 8) (Gen.element (['0' .. '9'] ++ ['a' .. 'f']))
  pure (unsafeId (renderIdPrefix p <> "-" <> hx))

genVaultId :: Gen VaultId
genVaultId = VaultId . renderId <$> genId PVlt

cjkPool :: String
cjkPool = "世界觀埃提亞琳達測試場景素材授權主角片段"

-- | YAML 的兩個經典危險字元與兩個無害標點。
richPunct :: String
richPunct = ":#,。"

-- | 語法上會咬人的字元:界線、標題、fence、id 屬性、行尾。
chaosPunct :: String
chaosPunct = "-#`{}[]:\n\r \12288\"'"

rawPunct :: String
rawPunct = "-#\n\r`"

-- | 保守字集:英數、常用中文、空白。用在標籤、別名、關聯備註、節標題與正文。
genSafeChar :: Gen Char
genSafeChar =
  Gen.frequency
    [ (6, Gen.alphaNum)
    , (3, Gen.element cjkPool)
    , (2, pure ' ')
    ]

-- | 保守字集再加上 YAML 的兩個經典危險字元 @:@ 與 @#@。
-- 用在 'metaTitle' 與 'metaSummary'——序列化方向自己寫(P-025 的「決定」),
-- 這兩個字元正是 @needsQuote@ 該擋下的東西。
genRichChar :: Gen Char
genRichChar =
  Gen.frequency
    [ (6, Gen.alphaNum)
    , (3, Gen.element cjkPool)
    , (2, pure ' ')
    , (2, Gen.element richPunct)
    ]

genSafeText :: Range.Range Int -> Gen Text
genSafeText r = T.strip <$> Gen.text r genSafeChar

genRichText :: Range.Range Int -> Gen Text
genRichText r = T.strip <$> Gen.text r genRichChar

nonEmpty :: Text -> Gen Text -> Gen Text
nonEmpty fallback g = do
  t <- g
  pure (if T.null t then fallback else t)

genTitle :: Gen Text
genTitle = nonEmpty "節標題" (genSafeText (Range.linear 1 8))

genTagText :: Gen Text
genTagText = nonEmpty "tag" (genSafeText (Range.linear 1 6))

genTypeKey :: Gen TypeKey
genTypeKey =
  Gen.element
    [ TypeKey "character"
    , TypeKey "character-fragment"
    , TypeKey "asset-image"
    , TypeKey "worldbuilding"
    , TypeKey "level"
    , TypeKey "asset-pack"
    , TypeKey "asset-license"
    ]

genStatus :: Gen Status
genStatus = Gen.element [Draft, Canon, Deprecated, Missing]

-- | 'SourceName' 的建構子不匯出(P-025 的 REV-1:非空由型別擋),產生器只能
-- 走 'mkSourceName' 這個 smart constructor。
genSourceName :: Gen Text -> Gen SourceName
genSourceName = Gen.mapMaybe mkSourceName

genSource :: Gen Source
genSource =
  Gen.choice
    [ pure Human
    , pure Scan
    , Agent <$> plain
    , Workshop <$> plain
    , Ai <$> plain
    ]
  where
    plain = genSourceName (Gen.text (Range.linear 1 8) Gen.alphaNum)

genDay :: Gen Day
genDay =
  fromGregorian
    <$> Gen.integral (Range.linear 2000 2035)
    <*> Gen.int (Range.linear 1 12)
    <*> Gen.int (Range.linear 1 28)

genTimeline :: Gen Timeline
genTimeline =
  Timeline
    <$> Gen.maybe (nonEmpty "崩塌前後" (genSafeText (Range.linear 1 8)))
    <*> Gen.maybe (Gen.int (Range.linear (-50) 50))

genRef :: Gen Ref
genRef = Ref <$> Gen.maybe genVaultId <*> genId PEnt

genLinkKind :: Gen LinkKind
genLinkKind =
  Gen.choice
    [ Gen.element coreLinkKinds
    , Custom <$> (("x-" <>) <$> Gen.text (Range.linear 1 6) Gen.alphaNum)
    ]

genLink :: Gen Link
genLink =
  Link
    <$> genLinkKind
    <*> genRef
    <*> Gen.maybe (nonEmpty "備註" (genSafeText (Range.linear 1 8)))

genMetaFor :: IdPrefix -> TypeKey -> Gen Meta
genMetaFor p tk =
  Meta
    <$> genId p
    <*> genVaultId
    <*> pure tk
    <*> nonEmpty "標題" (genRichText (Range.linear 1 10))
    <*> genRichText (Range.linear 0 16)
    <*> Gen.list (Range.linear 0 3) genTagText
    <*> genStatus
    <*> Gen.maybe genTimeline
    <*> Gen.list (Range.linear 0 2) genTagText
    <*> Gen.list (Range.linear 0 2) genLink
    <*> genSource
    <*> (Revision <$> Gen.int (Range.linear 1 99))
    <*> genDay
    <*> genDay

genMeta :: Gen Meta
genMeta = do
  p <- Gen.element [PEnt, PAst, PLvl, PNod, PPck, PLic]
  tk <- genTypeKey
  genMetaFor p tk

--------------------------------------------------------------------------------
-- LAW-9 的定義域:@forall m in Meta@ 就是任意文字,不是「乾淨的」文字。
--
-- P-025 的「決定」寫死了「渲染器對任意 'Text' 負責:控制字元由 @quote@ 跳脫,
-- 不把限制推給 'Meta' 的欄位」,REV-1 又把 @quote@ 的責任範圍列了出來。下面這組
-- 產生器就是照那份清單造的:C0(含 @\\x00@)、DEL、C1、U+2028 / U+2029、
-- U+FEFF / U+FFFE / U+FFFF,外加一般 unicode('Gen.unicodeAll',含非 BMP)。
-- 只有 LAW-9 用它;別的 law 的定義域另有形狀限制(節標題、id 屬性、fence),
-- 沿用原本的保守字集。

-- | REV-1 逐條點名的危險碼位。
wildSpecials :: [Char]
wildSpecials =
  ['\x00' .. '\x1f'] -- C0(含 NUL / TAB / LF / CR)
    ++ ['\x7f'] -- DEL
    ++ ['\x80' .. '\x9f'] -- C1
    ++ ['\x2028', '\x2029'] -- 行分隔 / 段分隔
    ++ ['\xfeff', '\xfffe', '\xffff'] -- BOM 與兩個非字元

-- | 上面那組碼位的判定式(標覆蓋率用)。
isWildChar :: Char -> Bool
isWildChar c =
  c < '\x20'
    || (c >= '\x7f' && c <= '\x9f')
    || c == '\x2028'
    || c == '\x2029'
    || c == '\xfeff'
    || c == '\xfffe'
    || c == '\xffff'

-- | 一般字元排前面:縮小時往 alphaNum 收,反例才讀得出「是哪一個碼位出事」。
genWildChar :: Gen Char
genWildChar =
  Gen.frequency
    [ (2, Gen.alphaNum)
    , (1, Gen.element cjkPool)
    , (2, pure '\x00')
    , (3, Gen.element wildSpecials)
    , (2, Gen.unicodeAll)
    ]

-- | 不做 'T.strip':前後空白也在 LAW-9 的定義域裡。
genWildText :: Range.Range Int -> Gen Text
genWildText r = Gen.text r genWildChar

genWildSource :: Gen Source
genWildSource =
  Gen.choice
    [ pure Human
    , pure Scan
    , Agent <$> wild
    , Workshop <$> wild
    , Ai <$> wild
    ]
  where
    wild = genSourceName (genWildText (Range.linear 1 8))

-- | 與 'genMetaFor' 同形狀,只有 REV-1 點名的文字欄位(title / summary / tags /
-- aliases 與 'SourceName' 的 payload)換成 'genWildText'。
genWildMeta :: Gen Meta
genWildMeta = do
  p <- Gen.element [PEnt, PAst, PLvl, PNod, PPck, PLic]
  tk <- genTypeKey
  Meta
    <$> genId p
    <*> genVaultId
    <*> pure tk
    <*> genWildText (Range.linear 1 10)
    <*> genWildText (Range.linear 0 16)
    <*> Gen.list (Range.linear 0 3) (genWildText (Range.linear 1 6))
    <*> genStatus
    <*> Gen.maybe genTimeline
    <*> Gen.list (Range.linear 0 2) (genWildText (Range.linear 1 6))
    <*> Gen.list (Range.linear 0 2) genLink
    <*> genWildSource
    <*> (Revision <$> Gen.int (Range.linear 1 99))
    <*> genDay
    <*> genDay

-- | 'Source' 的 payload;'Human' 與 'Scan' 沒有 payload。
sourceNameOf :: Source -> Text
sourceNameOf = \case
  Agent n -> sourceNameText n
  Workshop n -> sourceNameText n
  Ai n -> sourceNameText n
  Human -> ""
  Scan -> ""

-- | 這份 'Meta' 的文字欄位裡有沒有 REV-1 點名的碼位。
metaTextFields :: Meta -> [Text]
metaTextFields m =
  metaTitle m : metaSummary m : sourceNameOf (metaSource m) : metaTags m ++ metaAliases m

genOverride :: Gen MetaOverride
genOverride =
  MetaOverride
    <$> Gen.maybe (Gen.element allNodeKinds)
    <*> Gen.maybe genTypeKey
    <*> Gen.maybe genVaultId
    <*> Gen.maybe (genRichText (Range.linear 0 12))
    <*> Gen.maybe (Gen.list (Range.linear 0 3) genTagText)
    <*> Gen.maybe genStatus
    <*> Gen.maybe genTimeline
    <*> Gen.maybe (Gen.list (Range.linear 0 2) genTagText)
    <*> Gen.maybe (Gen.list (Range.linear 0 2) genLink)
    <*> Gen.maybe genSource
    <*> Gen.maybe (Revision <$> Gen.int (Range.linear 1 99))
    <*> Gen.maybe genDay
    <*> Gen.maybe genDay

-- | 型別專屬條目:鍵一律不在 @metaFieldOrder@ 裡(那是 'MetaExtras' 的前提),
-- 每個元素是一行、不含行尾字元。
genExtras :: Gen MetaExtras
genExtras = MetaExtras <$> Gen.list (Range.linear 0 3) genExtraLine
  where
    genExtraLine = do
      k <- Gen.element ["sha256", "entry", "ext", "author", "commercial", "custom_x"]
      v <- nonEmpty "v" (genSafeText (Range.linear 1 8))
      pure (k <> ": " <> v)

genLineEnding :: Gen LineEnding
genLineEnding = Gen.element [LF, CRLF]

genDocKind :: Gen DocKind
genDocKind = Gen.element [TopicDoc, LevelDoc, PackDoc, LicenseDoc]

--------------------------------------------------------------------------------
-- 由零件組出合法的 Markdown 全文

data SecSpec = SecSpec
  { ssEnding :: LineEnding
  , ssLevel :: Int
  , ssId :: Id
  , ssTitle :: Text
  , ssMeta :: Maybe Text
  , ssBody :: Text
  }
  deriving stock (Show)

renderSecText :: SecSpec -> Text
renderSecText SecSpec {..} =
  mconcat
    [ T.replicate ssLevel "#"
    , " "
    , ssTitle
    , " {#"
    , renderId ssId
    , "}"
    , renderLineEnding ssEnding
    , fromMaybe "" ssMeta
    , ssBody
    ]

ensureNL :: Text -> Text
ensureNL t
  | T.null t = t
  | T.isSuffixOf "\n" t = t
  | otherwise = t <> "\n"

stripOneNL :: Text -> Text
stripOneNL t
  | T.isSuffixOf "\r\n" t = T.dropEnd 2 t
  | T.isSuffixOf "\n" t = T.dropEnd 1 t
  | otherwise = t

-- | 檔案層走 'newDocument'(P-025#newDocument),節層自己接字串。這樣
-- frontmatter 一定含齊十四欄,而節與行尾的變化仍由測試控制。
buildDocText :: DocKind -> Meta -> Text -> [SecSpec] -> Text
buildDocText k m preamble secs =
  ensureNL (renderDocument (newDocument k m preamble))
    <> mconcat (map renderSecText secs)

genBodyText :: LineEnding -> Gen Text
genBodyText le = do
  ls <- Gen.list (Range.linear 1 3) (genSafeText (Range.linear 0 12))
  pure (mconcat [l <> renderLineEnding le | l <- ls])

genPreambleText :: Gen Text
genPreambleText = do
  le <- genLineEnding
  Gen.frequency [(1, pure ""), (3, genBodyText le)]

genSecSpec :: IdPrefix -> Int -> Gen SecSpec
genSecSpec p ix = do
  le <- genLineEnding
  title <- genTitle
  ov <- genOverride
  ex <- genExtras
  mb <- Gen.frequency [(1, pure Nothing), (3, pure (Just (renderMetaBlock ov ex le)))]
  body <- genBodyText le
  pure (SecSpec le 2 (ixId p ix) title mb body)

-- | 任一份「解析得開」的全文:frontmatter 由 'newDocument' 產生,節由零件接起來,
-- 行尾逐段隨機(混合行尾正是 ADR-010 要保護的情況),檔尾換行有無各半。
genParseableText :: Gen Text
genParseableText = do
  m <- genMeta
  k <- genDocKind
  pre <- genPreambleText
  n <- Gen.int (Range.linear 0 3)
  secs <- traverse (genSecSpec PEnt) [0 .. n - 1]
  cut <- Gen.bool
  let t = buildDocText k m pre secs
  pure (if cut && not (null secs) then stripOneNL t else t)

-- | 亂七八糟的文字:'total' 那條 law 的定義域是整個 'Text'。
genArbitraryText :: Gen Text
genArbitraryText =
  Gen.choice
    [ Gen.text (Range.linear 0 120) chaos
    , genParseableText
    , T.take <$> Gen.int (Range.linear 0 80) <*> genParseableText
    , Gen.element ["", "---", "---\n", "---\r\n", "---\nid: [broken", "# 標題\n", "```meta\n"]
    ]
  where
    chaos =
      Gen.frequency
        [ (5, Gen.alphaNum)
        , (3, Gen.element cjkPool)
        , (4, Gen.element chaosPunct)
        ]

--------------------------------------------------------------------------------
-- 直接建構的 Document / Section(LAW-2 / LAW-3 的定義域是型別本身)

genRawText :: Gen Text
genRawText = Gen.text (Range.linear 0 24) (Gen.frequency [(6, genSafeChar), (2, Gen.element rawPunct)])

genRawSection :: Gen Section
genRawSection =
  Section
    <$> Gen.int (Range.linear 1 6)
    <*> genRawText
    <*> genSafeText (Range.linear 0 8)
    <*> genId PEnt
    <*> Gen.maybe genRawText
    <*> genRawText
    <*> Gen.int (Range.linear 1 500)

genRawDocument :: Gen Document
genRawDocument =
  Document
    <$> genRawText
    <*> genRawText
    <*> Gen.list (Range.linear 0 4) genRawSection
    <*> genLineEnding
    <*> Gen.bool
    <*> genDocKind

--------------------------------------------------------------------------------
-- 四種文件:直接建構滿足 given 前提的值

genTopicText :: Gen Text
genTopicText = do
  m <- genMetaFor PEnt (TypeKey "character")
  pre <- genPreambleText
  n <- Gen.int (Range.linear 0 3)
  secs <- traverse (genSecSpec PEnt) [1 .. n]
  pure (buildDocText TopicDoc m pre secs)

genLevelText :: Gen Text
genLevelText = do
  m <- genMetaFor PLvl (TypeKey "level")
  pre <- genPreambleText
  n <- Gen.int (Range.linear 1 3)
  secs <- traverse genLevelSec [1 .. n]
  -- 第一節是根,其餘一律是它的子節點:層級不跳級、不比根淺,只有一個根。
  let levelled = zipWith (\ix s -> s {ssLevel = if ix == (1 :: Int) then 2 else 3}) [1 ..] secs
  pure (buildDocText LevelDoc m pre levelled)
  where
    genLevelSec ix = do
      s <- genSecSpec PNod ix
      k <- Gen.element allNodeKinds
      ov <- genOverride
      pure s {ssMeta = Just (renderMetaBlock ov {moKind = Just k} (MetaExtras []) (ssEnding s))}

genPackText :: Gen Text
genPackText = do
  m <- genMetaFor PPck (TypeKey "asset-pack")
  pre <- genPreambleText
  n <- Gen.int (Range.linear 0 3)
  secs <- traverse genPackSec [1 .. n]
  pure (buildDocText PackDoc m pre secs)
  where
    genPackSec ix = do
      s <- genSecSpec PAst ix
      ov <- genOverride
      sha <- Gen.text (Range.singleton 12) (Gen.element (['0' .. '9'] ++ ['a' .. 'f']))
      ent <- nonEmpty "a.png" (genSafeText (Range.linear 1 8))
      let ex = MetaExtras ["sha256: \"" <> sha <> "\"", "entry: \"PNG/" <> ent <> "\""]
      pure s {ssMeta = Just (renderMetaBlock ov {moType = Just (TypeKey "asset-image")} ex (ssEnding s))}

genLicensesText :: Gen Text
genLicensesText = do
  m <- genMetaFor PLic (TypeKey "asset-license")
  pre <- genPreambleText
  n <- Gen.int (Range.linear 0 3)
  secs <- traverse genLicSec [1 .. n]
  pure (buildDocText LicenseDoc m pre secs)
  where
    genLicSec ix = do
      s <- genSecSpec PLic ix
      ov <- genOverride
      c <- Gen.bool
      a <- Gen.bool
      let ex =
            MetaExtras
              [ "commercial: " <> bool' c
              , "attribution_required: " <> bool' a
              ]
      pure s {ssMeta = Just (renderMetaBlock ov {moType = Nothing} ex (ssEnding s))}
    bool' b = if b then "true" else "false"

--------------------------------------------------------------------------------
-- 斷言小工具

-- | @total@ 種類:求值到正規形(逐字走過 'show')不拋例外。
assertTotal :: (Show a) => a -> PropertyT IO ()
assertTotal x = do
  r <- evalIO (try (evaluate (length (show x))) :: IO (Either SomeException Int))
  case r of
    Right _ -> success
    Left e -> footnote ("求值拋出例外:" <> displayException e) >> failure

expectTotal :: (Show a) => a -> Expectation
expectTotal x = do
  r <- try (evaluate (length (show x))) :: IO (Either SomeException Int)
  case r of
    Right _ -> pure ()
    Left e -> expectationFailure ("求值拋出例外:" <> displayException e)

-- | given 行的前提由產生器直接建構滿足;真的沒滿足就當紅燈報出來,不靜默跳過。
requireRight :: (Show e) => String -> Either e a -> PropertyT IO a
requireRight what = \case
  Right a -> pure a
  Left e -> do
    footnote (what <> " 的前提不成立(產生器造出的值被拒絕):" <> show e)
    failure

--------------------------------------------------------------------------------
-- 固定值(examples)

mkMeta :: Text -> TypeKey -> Text -> Meta
mkMeta idText tk title =
  Meta
    { metaId = unsafeId idText
    , metaVault = VaultId "vlt-00000001"
    , metaType = tk
    , metaTitle = title
    , metaSummary = ""
    , metaTags = []
    , metaStatus = Draft
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = Revision 1
    , metaCreated = fromGregorian 2026 1 1
    , metaUpdated = fromGregorian 2026 1 1
    }

-- | 手寫的最小 frontmatter:除了 @type@ 之外的必填欄位都在。
frontWith :: Maybe Text -> Text
frontWith mty =
  mconcat
    [ "---\n"
    , "id: ent-00000001\n"
    , "vault: vlt-00000001\n"
    , maybe "" (\t -> "type: " <> t <> "\n") mty
    , "title: 琳達\n"
    , "created: 2026-01-01\n"
    , "updated: 2026-01-01\n"
    , "---\n"
    ]

--------------------------------------------------------------------------------

spec :: Spec
spec =
  around_ withTimeLimit
    . modifyMaxSuccess (const 100)
    $ do
      laws
      examples

-- | 整個模組的時限。跑爆機器的測試視同紅燈。
withTimeLimit :: IO () -> IO ()
withTimeLimit act =
  timeout (300 * 1000 * 1000) act
    >>= maybe (expectationFailure "P-025 測試逾時(300 秒)") pure

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-025#LAW-1" $
    it "解析得開的文字原樣寫回,逐位元組相同" $
      hedgehog $ do
        t <- forAll genParseableText
        d <- requireRight "isRight (parseDocument t)" (parseDocument t)
        renderDocument d === t

  describe "P-025#LAW-2" $
    it "寫回是四段原始切片依序接起來,只有兩條 --- 界線由 renderDocument 重生" $
      hedgehog $ do
        d <- forAll genRawDocument
        renderDocument d
          === mconcat
            [ "---"
            , docFrontRaw d
            , "---"
            , docPreamble d
            , mconcat (map renderSection (docSections d))
            ]

  describe "P-025#LAW-3" $
    it "一節就是標題行、meta 區塊與正文三段原始切片" $
      hedgehog $ do
        s <- forAll genRawSection
        renderSection s
          === mconcat [secHeadingRaw s, fromMaybe "" (secMetaRaw s), secBodyRaw s]

  describe "P-025#LAW-4" $
    it "解析對任何文字都有值,不拋例外" $
      hedgehog $ do
        t <- forAll genArbitraryText
        assertTotal (parseDocument t)

  describe "P-025#LAW-5" $
    it "行尾風格與檔尾換行由全檔多數決定,解析出來就是原文的事實" $
      hedgehog $ do
        t <- forAll genParseableText
        d <- requireRight "isRight (parseDocument t)" (parseDocument t)
        docEnding d === detectLineEnding t
        docFinalNL d === T.isSuffixOf "\n" t

  describe "P-025#LAW-6" $
    it "從零產生的文件一定解析得回來" $
      hedgehog $ do
        k <- forAll genDocKind
        m <- forAll genMeta
        b <- forAll genPreambleText
        let r = parseDocument (renderDocument (newDocument k m b))
        footnote ("parseDocument 的結果:" <> show r)
        assert (isRight r)

  describe "P-025#LAW-7" $
    it "檔案身分只由檔案層 type 決定:三個保留鍵各對一種,其餘一律 TopicDoc" $
      hedgehog $ do
        k <- forAll genDocKind
        m <- forAll genMeta
        b <- forAll genPreambleText
        d <- requireRight "parseDocument (renderDocument (newDocument k m b))" $
          parseDocument (renderDocument (newDocument k m b))
        docKind d
          === fromMaybe
            TopicDoc
            ( lookup
                (metaType m)
                [ (TypeKey "level", LevelDoc)
                , (TypeKey "asset-pack", PackDoc)
                , (TypeKey "asset-license", LicenseDoc)
                ]
            )

  describe "P-025#LAW-8" $
    it "沒有檔案層專屬欄位時 newDocument 就是 newDocumentWith 的特化" $
      hedgehog $ do
        k <- forAll genDocKind
        m <- forAll genMeta
        b <- forAll genPreambleText
        newDocument k m b === newDocumentWith k m (FrontExtras (MetaExtras [])) b

  describe "P-025#LAW-9" $
    it "frontmatter 序列化再解回來不失真" $
      hedgehog $ do
        m <- forAll genWildMeta
        le <- forAll genLineEnding
        let fields = metaTextFields m
            anyWild = any (T.any isWildChar) fields
            anyNul = any (T.any (== '\x00')) fields
            srcWild = T.any isWildChar (sourceNameOf (metaSource m))
        classify "文字欄位含 REV-1 點名的碼位" anyWild
        classify "文字欄位含 NUL(U+0000)" anyNul
        classify "SourceName 的 payload 含 REV-1 點名的碼位" srcWild
        cover 50 "文字欄位含 REV-1 點名的碼位" anyWild
        cover 20 "文字欄位含 NUL(U+0000)" anyNul
        cover 15 "SourceName 的 payload 含 REV-1 點名的碼位" srcWild
        decodeFrontmatter (renderFrontmatter m le) === Right m

  describe "P-025#LAW-10" $
    it "meta 區塊以行尾收尾,型別專屬條目的每一行逐字都在裡面" $
      hedgehog $ do
        ov <- forAll genOverride
        ex <- forAll genExtras
        le <- forAll genLineEnding
        let block = renderMetaBlock ov ex le
        footnote ("區塊:" <> show block)
        assert (T.isSuffixOf (renderLineEnding le) block)
        assert (all (`T.isInfixOf` block) (extraLines ex))

  describe "P-025#LAW-11" $
    it "節的 tags 是檔案層與節層的聯集去重" $
      hedgehog $ do
        front <- forAll genMeta
        i <- forAll (genId PEnt)
        title <- forAll genTitle
        ov <- forAll genOverride
        fmap metaTags (inheritMeta True front i title ov)
          === Right (nub (concat [metaTags front, fromMaybe [] (moTags ov)]))

  describe "P-025#LAW-12" $
    it "節層未寫時 vault / status / source / created / updated / timeline 一律繼承檔案層" $
      hedgehog $ do
        front <- forAll genMeta
        i <- forAll (genId PEnt)
        title <- forAll genTitle
        let r = inheritMeta True front i title emptyOverride
        fmap metaVault r === Right (metaVault front)
        fmap metaStatus r === Right (metaStatus front)
        fmap metaSource r === Right (metaSource front)
        fmap metaCreated r === Right (metaCreated front)
        fmap metaUpdated r === Right (metaUpdated front)
        fmap metaTimeline r === Right (metaTimeline front)

  describe "P-025#LAW-13" $
    it "summary / aliases / links 不繼承,未寫為空;revision 不繼承,未寫是 1" $
      hedgehog $ do
        front <- forAll genMeta
        i <- forAll (genId PEnt)
        title <- forAll genTitle
        let r = inheritMeta True front i title emptyOverride
        fmap metaSummary r === Right ""
        fmap metaAliases r === Right []
        fmap metaLinks r === Right []
        fmap metaRevision r === Right (Revision 1)

  describe "P-025#LAW-14" $
    it "節的 id 與標題取自節本身,永遠不繼承" $
      hedgehog $ do
        front <- forAll genMeta
        i <- forAll (genId PEnt)
        title <- forAll genTitle
        ov <- forAll genOverride
        fmap metaId (inheritMeta True front i title ov) === Right i
        fmap metaTitle (inheritMeta True front i title ov) === Right title

  describe "P-025#LAW-15" $
    it "type 是否繼承由旗標決定:pack.md 的節不繼承,缺漏是錯誤" $
      hedgehog $ do
        front <- forAll genMeta
        i <- forAll (genId PEnt)
        title <- forAll genTitle
        fmap metaType (inheritMeta True front i title emptyOverride)
          === Right (metaType front)
        let bad = inheritMeta False front i title emptyOverride
        footnote ("typeInherits = False 的結果:" <> show bad)
        assert (isLeft bad)

  describe "P-025#LAW-16" $
    it "展開再套回同一份 Meta 是恆等" $
      hedgehog $ do
        m <- forAll genMeta
        applyOverride (overrideOf m) m === m

  describe "P-025#LAW-17" $
    it "套回是逐欄覆蓋,id 與 title 表達不了因此原樣保留" $
      hedgehog $ do
        a <- forAll genMeta
        b <- forAll genMeta
        metaSummary (applyOverride (overrideOf a) b) === metaSummary a
        metaTags (applyOverride (overrideOf a) b) === metaTags a
        metaId (applyOverride (overrideOf a) b) === metaId b
        metaTitle (applyOverride (overrideOf a) b) === metaTitle b

  describe "P-025#LAW-18" $
    it "主題檔的片段與節一一對應,依文件順序" $
      hedgehog $ do
        t <- forAll genTopicText
        d <- requireRight "parseDocument" (parseDocument t)
        (_, frags) <- requireRight "isRight (toTopic d)" (toTopic d)
        map (metaId . entMeta) frags === sectionIds d

  describe "P-025#LAW-19" $
    it "Level 檔的節點與節一一對應,依文件順序" $
      hedgehog $ do
        t <- forAll genLevelText
        d <- requireRight "parseDocument" (parseDocument t)
        (_, nodes) <- requireRight "isRight (toLevel d)" (toLevel d)
        map (metaId . nodMeta) nodes === sectionIds d

  describe "P-025#LAW-20" $
    it "pack.md 的 asset 與節一一對應,依文件順序" $
      hedgehog $ do
        t <- forAll genPackText
        d <- requireRight "parseDocument" (parseDocument t)
        (_, assets) <- requireRight "isRight (toPack d)" (toPack d)
        map (metaId . astMeta) assets === sectionIds d

  describe "P-025#LAW-21" $
    it "licenses.md 每一節一個授權,容器本身不是節點" $
      hedgehog $ do
        t <- forAll genLicensesText
        d <- requireRight "parseDocument" (parseDocument t)
        lics <- requireRight "isRight (toLicenses d)" (toLicenses d)
        map (metaId . licMeta) lics === sectionIds d

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-025#EX-1" $
    it "空檔案與只有一行 --- 的檔案都是 Left,不拋例外" $ do
      expectTotal (parseDocument "")
      expectTotal (parseDocument "---\n")
      fmap errKind (flipE (parseDocument "")) `shouldBe` Just NoFrontmatter
      fmap errKind (flipE (parseDocument "---\n")) `shouldBe` Just UnterminatedFrontmatter

  describe "P-025#EX-2" $
    it "parseDocument \"---\\nid: [broken\" 是第 1 行的 UnterminatedFrontmatter" $ do
      expectTotal (parseDocument "---\nid: [broken")
      parseErr (parseDocument "---\nid: [broken")
        `shouldBe` Just (MdError 1 UnterminatedFrontmatter)

  describe "P-025#EX-3" $
    it "只有 frontmatter、沒有任何節的 pack.md 逐位元組寫回,sectionIds 為空" $ do
      let m = mkMeta "pck-00000001" (TypeKey "asset-pack") "Kenney UI Pack"
          t = renderDocument (newDocument PackDoc m "這個素材包沒有任何節。\n")
      case parseDocument t of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right d -> do
          renderDocument d `shouldBe` t
          sectionIds d `shouldBe` []

  describe "P-025#EX-4" $
    it "frontmatter 界線用 LF、正文用 CRLF 的混合檔:逐位元組相同,docEnding 是 CRLF" $ do
      let t = mixedEndingDoc
      case parseDocument t of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right d -> do
          renderDocument d `shouldBe` t
          docEnding d `shouldBe` CRLF
          docFinalNL d `shouldBe` True

  describe "P-025#EX-5" $
    it "檔尾沒有換行:docFinalNL 為 False,寫回仍逐位元組相同" $ do
      let t = stripOneNL mixedEndingDoc
      case parseDocument t of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right d -> do
          docFinalNL d `shouldBe` False
          renderDocument d `shouldBe` t

  describe "P-025#EX-6" $
    it "一節等於三段接起來,整份等於 --- + frontRaw + --- + preamble + 各節" $ do
      let s =
            Section
              { secLevel = 2
              , secHeadingRaw = "## 琳達 {#ent-7f3a}\n"
              , secTitle = "琳達"
              , secId = unsafeId "ent-7f3a"
              , secMetaRaw = Just "\n```meta\nsummary: 主角\n```\n"
              , secBodyRaw = "\n她住在埃提亞。\n"
              , secLine = 9
              }
          d =
            Document
              { docFrontRaw = "\nid: ent-00000001\ntype: character\n"
              , docPreamble = "\n前言。\n\n"
              , docSections = [s]
              , docEnding = LF
              , docFinalNL = True
              , docKind = TopicDoc
              }
      renderSection s
        `shouldBe` mconcat [secHeadingRaw s, fromMaybe "" (secMetaRaw s), secBodyRaw s]
      renderDocument d
        `shouldBe` mconcat
          [ "---"
          , docFrontRaw d
          , "---"
          , docPreamble d
          , mconcat (map renderSection (docSections d))
          ]

  describe "P-025#EX-7" $
    it "五份 frontmatter 的 docKind 依序是 LevelDoc / PackDoc / LicenseDoc / TopicDoc / TopicDoc" $ do
      let kinds =
            map
              (fmap docKind . parseDocument . frontWith)
              [Just "level", Just "asset-pack", Just "asset-license", Just "character", Nothing]
      kinds
        `shouldBe` [ Right LevelDoc
                   , Right PackDoc
                   , Right LicenseDoc
                   , Right TopicDoc
                   , Right TopicDoc
                   ]

  describe "P-025#EX-8" $
    it "newDocument PackDoc m 的產物解析得回來,且等於 newDocumentWith 的空專屬欄位版本" $ do
      let m = mkMeta "pck-00000001" (TypeKey "asset-pack") "Kenney UI Pack"
          d1 = newDocument PackDoc m "素材包說明"
          d2 = newDocumentWith PackDoc m (FrontExtras (MetaExtras [])) "素材包說明"
      renderDocument d1 `shouldBe` renderDocument d2
      d1 `shouldBe` d2
      parseDocument (renderDocument d1) `shouldSatisfy` isRight

  describe "P-025#EX-9" $
    it "renderFrontmatter 輸出十四欄(tags: []、timeline: null),decodeFrontmatter 解回等於 m" $ do
      let m = mkMeta "ent-00000001" (TypeKey "character") "琳達"
          out = renderFrontmatter m LF
          ls = T.lines out
      mapM_
        (\n -> (n, any (T.isPrefixOf (n <> ":")) ls) `shouldBe` (n, True))
        metaFieldNames
      out `shouldSatisfy` T.isInfixOf "tags: []"
      out `shouldSatisfy` T.isInfixOf "timeline: null"
      decodeFrontmatter out `shouldBe` Right m

  describe "P-025#EX-10" $
    it "renderMetaBlock 以 ```meta 起、以 ``` 與換行收,中間逐字含那兩行" $ do
      let ex = MetaExtras ["sha256: deadbeef1234", "entry: PNG/a.png"]
          out = renderMetaBlock emptyOverride ex LF
      out `shouldSatisfy` T.isPrefixOf "```meta\n"
      out `shouldSatisfy` T.isSuffixOf "```\n"
      out `shouldSatisfy` T.isInfixOf "sha256: deadbeef1234"
      out `shouldSatisfy` T.isInfixOf "entry: PNG/a.png"

  describe "P-025#EX-11" $
    it "檔案層與節層的 tags 是聯集去重,檔案層在前" $ do
      let front = (mkMeta "ent-00000001" (TypeKey "character") "琳達") {metaTags = ["世界觀", "埃提亞"]}
          ov = emptyOverride {moTags = Just ["埃提亞", "主角"]}
      fmap metaTags (inheritMeta True front (unsafeId "ent-7f3a") "片段" ov)
        `shouldBe` Right ["世界觀", "埃提亞", "主角"]

  describe "P-025#EX-12" $
    it "節的 meta 區塊什麼都沒寫時的繼承結果" $ do
      let front =
            (mkMeta "ent-00000001" (TypeKey "character") "琳達")
              { metaStatus = Canon
              , metaSource = Agent "claude-code"
              , metaTimeline = Just (Timeline (Just "崩塌前") (Just 3))
              , metaCreated = fromGregorian 2026 2 3
              , metaUpdated = fromGregorian 2026 3 4
              , metaSummary = "檔案層的一句話"
              , metaAliases = ["小琳"]
              , metaRevision = Revision 7
              }
          r = inheritMeta True front (unsafeId "ent-7f3a") "片段" emptyOverride
      fmap metaVault r `shouldBe` Right (metaVault front)
      fmap metaStatus r `shouldBe` Right Canon
      fmap metaSource r `shouldBe` Right (Agent "claude-code")
      fmap metaCreated r `shouldBe` Right (fromGregorian 2026 2 3)
      fmap metaUpdated r `shouldBe` Right (fromGregorian 2026 3 4)
      fmap metaTimeline r `shouldBe` Right (Just (Timeline (Just "崩塌前") (Just 3)))
      fmap metaSummary r `shouldBe` Right ""
      fmap metaAliases r `shouldBe` Right []
      fmap metaLinks r `shouldBe` Right []
      fmap metaRevision r `shouldBe` Right (Revision 1)

  describe "P-025#EX-13" $
    it "節的 id 與標題取自節本身,與檔案層無關" $ do
      let front = mkMeta "ent-00000001" (TypeKey "character") "琳達"
          r = inheritMeta True front (unsafeId "ent-7f3a") "琳達" emptyOverride
      fmap metaId r `shouldBe` Right (unsafeId "ent-7f3a")
      fmap metaTitle r `shouldBe` Right "琳達"

  describe "P-025#EX-14" $
    it "typeInherits 為 True 時繼承檔案層,為 False 時是 SectionFieldMissing" $ do
      let front = mkMeta "pck-00000001" (TypeKey "asset-pack") "Kenney UI Pack"
          secId' = unsafeId "ast-0001"
      fmap metaType (inheritMeta True front secId' "一張圖" emptyOverride)
        `shouldBe` Right (TypeKey "asset-pack")
      inheritMeta False front secId' "一張圖" emptyOverride
        `shouldBe` Left (SectionFieldMissing secId' "type")

  describe "P-025#EX-15" $
    it "pack.md 的節沒有寫 type,toPack 回 SectionFieldMissing" $ do
      let sid = unsafeId "ast-0001"
          t = packDocText [(sid, Nothing)]
      case parseDocument t >>= toPack of
        Right _ -> expectationFailure "缺 type 的 pack.md 竟然解析成功"
        Left e -> errKind e `shouldBe` SectionFieldMissing sid "type"

  describe "P-025#EX-16" $
    it "applyOverride (overrideOf m) m 逐欄等於 m" $ do
      let m =
            (mkMeta "ent-00000001" (TypeKey "character") "琳達")
              { metaTags = ["世界觀"]
              , metaSummary = "一句話"
              , metaLinks = [Link Involves (Ref Nothing (unsafeId "ent-7f3a")) (Just "備註")]
              , metaStatus = Canon
              }
      applyOverride (overrideOf m) m `shouldBe` m

  describe "P-025#EX-17" $
    it "套回是逐欄覆蓋,id 與 title 仍是 b 的" $ do
      let a =
            (mkMeta "ent-00000001" (TypeKey "character") "琳達")
              {metaSummary = "A 的一句話", metaTags = ["A標籤"]}
          b =
            (mkMeta "ent-00000002" (TypeKey "worldbuilding") "埃提亞")
              {metaSummary = "B 的一句話", metaTags = ["B標籤"]}
          r = applyOverride (overrideOf a) b
      metaSummary r `shouldBe` metaSummary a
      metaTags r `shouldBe` metaTags a
      metaId r `shouldBe` metaId b
      metaTitle r `shouldBe` metaTitle b

  describe "P-025#EX-18" $
    it "主題檔的兩個片段依序是 ent-0001 / ent-0002,與 sectionIds 相同" $ do
      let m = mkMeta "ent-00000001" (TypeKey "character") "琳達"
          mk i title =
            SecSpec LF 2 (unsafeId i) title Nothing "片段內文。\n\n"
          t =
            buildDocText
              TopicDoc
              m
              "琳達是主角。\n\n"
              [mk "ent-0001" "童年", mk "ent-0002" "旅途"]
      case parseDocument t >>= \d -> (,) d <$> toTopic d of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right (d, (_, frags)) -> do
          map (metaId . entMeta) frags
            `shouldBe` [unsafeId "ent-0001", unsafeId "ent-0002"]
          map (metaId . entMeta) frags `shouldBe` sectionIds d

  describe "P-025#EX-19" $
    it "Level 檔的節點依序是 nod-0003 / nod-0010 / nod-0011,root 以第一個節填入" $ do
      let m = mkMeta "lvl-00000001" (TypeKey "level") "第三章"
          mk lvl i title k =
            SecSpec
              LF
              lvl
              (unsafeId i)
              title
              (Just (renderMetaBlock emptyOverride {moKind = Just k} (MetaExtras []) LF))
              "\n"
          t =
            buildDocText
              LevelDoc
              m
              ""
              [ mk 2 "nod-0003" "第三章" KScene
              , mk 3 "nod-0010" "第一節" KDialogue
              , mk 3 "nod-0011" "第二節" KDialogue
              ]
      case parseDocument t >>= \d -> (,) d <$> toLevel d of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right (d, (lvl, nodes)) -> do
          map (metaId . nodMeta) nodes
            `shouldBe` [unsafeId "nod-0003", unsafeId "nod-0010", unsafeId "nod-0011"]
          map (metaId . nodMeta) nodes `shouldBe` sectionIds d
          lvlRoot lvl `shouldBe` unsafeId "nod-0003"

  describe "P-025#EX-20" $
    it "pack.md 兩個 asset 節解回長度 2,metaId 依序等於 sectionIds" $ do
      let t =
            packDocText
              [ (unsafeId "ast-0001", Just (TypeKey "asset-image"))
              , (unsafeId "ast-0002", Just (TypeKey "asset-image"))
              ]
      case parseDocument t >>= \d -> (,) d <$> toPack d of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right (d, (_, assets)) -> do
          length assets `shouldBe` 2
          map (metaId . astMeta) assets `shouldBe` sectionIds d
          map (metaId . astMeta) assets
            `shouldBe` [unsafeId "ast-0001", unsafeId "ast-0002"]

  describe "P-025#EX-21" $
    it "licenses.md 缺 commercial 是錯誤;三節寫齊時長度 3 且 metaId 依序等於 sectionIds" $ do
      let sid = unsafeId "lic-0001"
          bad = licensesDocText [(sid, False)]
      case parseDocument bad >>= toLicenses of
        Right _ -> expectationFailure "缺 commercial 的 licenses.md 竟然解析成功"
        Left e -> errKind e `shouldBe` SectionFieldMissing sid "commercial"
      let good =
            licensesDocText
              [ (unsafeId "lic-0001", True)
              , (unsafeId "lic-0002", True)
              , (unsafeId "lic-0003", True)
              ]
      case parseDocument good >>= \d -> (,) d <$> toLicenses d of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right (d, lics) -> do
          length lics `shouldBe` 3
          map (metaId . licMeta) lics `shouldBe` sectionIds d

  describe "P-025#EX-22" $
    it "第一個帶 {#id} 的標題之前的無 id 標題留在 preamble,寫回仍逐位元組相同" $ do
      let m = mkMeta "ent-00000001" (TypeKey "character") "琳達"
          t =
            buildDocText TopicDoc m "琳達是主角。\n\n## 前言\n\n這一段沒有 id。\n\n" $
              [SecSpec LF 2 (unsafeId "ent-0001") "童年" Nothing "片段內文。\n"]
      case parseDocument t of
        Left e -> expectationFailure ("解析失敗:" <> show e)
        Right d -> do
          docPreamble d `shouldSatisfy` T.isInfixOf "## 前言"
          sectionIds d `shouldBe` [unsafeId "ent-0001"]
          renderDocument d `shouldBe` t

--------------------------------------------------------------------------------
-- examples 的固定素材

flipE :: Either a b -> Maybe a
flipE = either Just (const Nothing)

parseErr :: Either MdError a -> Maybe MdError
parseErr = flipE

-- | frontmatter 的三條界線與欄位用 LF,正文全部用 CRLF:CRLF 是多數。
mixedEndingDoc :: Text
mixedEndingDoc =
  mconcat
    [ "---\n"
    , "id: ent-00000001\n"
    , "vault: vlt-00000001\n"
    , "type: character\n"
    , "title: 琳達\n"
    , "created: 2026-01-01\n"
    , "updated: 2026-01-01\n"
    , "---\n"
    , "\r\n"
    , "琳達是主角。\r\n"
    , "她住在埃提亞。\r\n"
    , "\r\n"
    , "## 童年 {#ent-0001}\r\n"
    , "\r\n"
    , "她在崩塌前出生。\r\n"
    , "\r\n"
    , "## 旅途 {#ent-0002}\r\n"
    , "\r\n"
    , "她離開了故鄉。\r\n"
    ]

packDocText :: [(Id, Maybe TypeKey)] -> Text
packDocText secs =
  buildDocText
    PackDoc
    (mkMeta "pck-00000001" (TypeKey "asset-pack") "Kenney UI Pack")
    "這個素材包有幾張圖。\n\n"
    [ SecSpec
      LF
      2
      i
      "一張圖"
      ( Just
          ( renderMetaBlock
              emptyOverride {moType = mty}
              (MetaExtras ["sha256: deadbeef1234", "entry: PNG/" <> renderId i <> ".png"])
              LF
          )
      )
      "\n"
    | (i, mty) <- secs
    ]

licensesDocText :: [(Id, Bool)] -> Text
licensesDocText secs =
  buildDocText
    LicenseDoc
    (mkMeta "lic-ffffffff" (TypeKey "asset-license") "授權清單")
    "本 vault 用到的授權。\n\n"
    [ SecSpec
      LF
      2
      i
      "CC0"
      ( Just
          ( renderMetaBlock
              emptyOverride
              ( MetaExtras
                  ( ["commercial: true" | withCommercial]
                      ++ ["attribution_required: false"]
                  )
              )
              LF
          )
      )
      "\n"
    | (i, withCommercial) <- secs
    ]
