-- | lawful 測試:P-026-md-edit(qa 填入)。
--
-- 32 條 law 各一條 property test、31 個 example 各一條 example test,
-- 歸屬字串分別是 @P-026#LAW-n@ 與 @P-026#EX-n@。
module Aapms.Lawful.P026Spec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Either (isLeft)
import qualified Data.List as L
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

import Aapms.Core.Asset (LogicalName (..), Sha256 (..))
import Aapms.Core.Id
  ( Id
  , IdPrefix (..)
  , Ref (..)
  , VaultId (..)
  , localRef
  , parseId
  , renderId
  , renderIdPrefix
  )
import Aapms.Core.Level (NodeKind (..), allNodeKinds)
import Aapms.Core.Link (Link (..), LinkKind (..), coreLinkKinds)
import Aapms.Core.Meta
  ( Meta (..)
  , Revision (..)
  , Source (..)
  , Status (..)
  , Timeline (..)
  , TypeKey (..)
  )
import Aapms.Core.Pack (AiDisclosure (..), Author (..), Pack (..))
import Aapms.Md.Document
import Aapms.Md.Error (MdError (..), MdErrorKind (..))
import Aapms.Md.Parse (parseDocument, toPack)
import Aapms.Md.Render
import Aapms.Md.Section (MetaOverride (..), emptyOverride)
import Aapms.Md.Yaml (decodeFrontmatter)

--------------------------------------------------------------------------------
-- 尺寸與時間上限

-- | 產生的文件最多幾節。
maxSecs :: Int
maxSecs = 5

-- | 每個測試項目的上限;逾時視同紅燈。
itemTimeoutMicros :: Int
itemTimeoutMicros = 60 * 1000 * 1000

withItemTimeout :: IO () -> IO ()
withItemTimeout act = do
  r <- timeout itemTimeoutMicros act
  case r of
    Just () -> pure ()
    Nothing -> expectationFailure "P-026 測試項目逾時(60 秒)"

--------------------------------------------------------------------------------
-- 小工具

hex8i :: Int -> Text
hex8i n = T.justifyRight 8 '0' (T.pack (showHex n ""))

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("P-026 測試:無法建構 Id " <> show t <> ":" <> show e)

mkId :: IdPrefix -> Int -> Id
mkId p n = idOf (renderIdPrefix p <> "-" <> hex8i n)

right :: (Show e) => Either e a -> a
right = either (\e -> error ("P-026 測試前置失敗:" <> show e)) id

keyOf :: Text -> Text
keyOf = T.takeWhile (/= ':')

linesWithKey :: Text -> [Text] -> [Text]
linesWithKey k = filter ((k <> ":") `T.isPrefixOf`)

-- | 一行的頂層鍵是否落在某份欄位清單裡。
hasFieldKey :: [Text] -> Text -> Bool
hasFieldKey ks l = any (\k -> (k <> ":") `T.isPrefixOf` l) ks

emptyFront :: FrontExtras
emptyFront = FrontExtras (MetaExtras [])

--------------------------------------------------------------------------------
-- 產生器:零件

genSafeChar :: Gen Char
genSafeChar = Gen.frequency [(4, Gen.alphaNum), (1, Gen.element ("琳達之章書框" :: String))]

-- | 非空、不含空白與 markdown/YAML 特殊字元的短字串。
genWord :: Gen Text
genWord = Gen.text (Range.linear 1 6) genSafeChar

-- | 可以是空字串的短字串。
genPhrase :: Gen Text
genPhrase = Gen.text (Range.linear 0 8) genSafeChar

genTitle :: Gen Text
genTitle = genWord

genBodyLine :: Gen Text
genBodyLine =
  Gen.text
    (Range.linear 0 12)
    (Gen.frequency [(4, Gen.alphaNum), (1, Gen.element (" 琳達之章" :: String))])

-- | 正文。@blankTail = True@ 時保證以「空行」(兩個行尾)結尾,
-- 供 P-026#LAW-16 的前提直接建構。
genBody :: LineEnding -> Bool -> Gen Text
genBody le blankTail = do
  ls0 <- Gen.list (Range.linear (if blankTail then 1 else 0) 3) genBodyLine
  extra <- if blankTail then pure True else Gen.bool
  let nl = renderLineEnding le
      ls = if blankTail && null ls0 then ["內文"] else ls0
  pure (T.concat [l <> nl | l <- ls] <> (if extra then nl else ""))

genDay :: Gen Day
genDay =
  fromGregorian
    <$> Gen.integral (Range.linear 2020 2030)
    <*> Gen.integral (Range.linear 1 12)
    <*> Gen.integral (Range.linear 1 28)

genStatus :: Gen Status
genStatus = Gen.element [Draft, Canon, Deprecated, Missing]

genSource :: Gen Source
genSource =
  Gen.choice [pure Human, pure Scan, Agent <$> genWord, Workshop <$> genWord, Ai <$> genWord]

genTimeline :: Gen Timeline
genTimeline =
  Gen.choice
    [ Timeline <$> (Just <$> genWord) <*> (Just <$> Gen.integral (Range.linear 0 50))
    , Timeline <$> (Just <$> genWord) <*> pure Nothing
    ]

genVaultId :: Gen VaultId
genVaultId = VaultId . renderId . mkId PVlt <$> Gen.integral (Range.linear 1 20)

genRef :: Gen Ref
genRef = do
  i <- mkId PEnt <$> Gen.integral (Range.linear 1 50)
  Gen.choice [pure (localRef i), (\v -> Ref (Just v) i) <$> genVaultId]

genLink :: Gen Link
genLink =
  Link
    <$> Gen.choice [Gen.element coreLinkKinds, Custom <$> genWord]
    <*> genRef
    <*> Gen.maybe genWord

genTypeKey :: Gen TypeKey
genTypeKey = TypeKey <$> Gen.element ["character-fragment", "note", "asset-image"]

genHex :: Gen Text
genHex = T.pack <$> Gen.list (Range.linear 8 12) (Gen.element ("0123456789abcdef" :: String))

genUrl :: Gen Text
genUrl = (\w -> "https://example.com/" <> w) <$> genWord

genMeta :: IdPrefix -> Text -> Gen Meta
genMeta p ty = do
  n <- Gen.integral (Range.linear 1 500)
  title <- genWord
  summary <- genPhrase
  tags <- Gen.list (Range.linear 0 2) genWord
  st <- genStatus
  tl <- Gen.maybe genTimeline
  als <- Gen.list (Range.linear 0 2) genWord
  lks <- Gen.list (Range.linear 0 2) genLink
  src <- genSource
  rev <- Revision <$> Gen.integral (Range.linear 1 9)
  c <- genDay
  u <- genDay
  v <- genVaultId
  pure
    Meta
      { metaId = mkId p n
      , metaVault = v
      , metaType = TypeKey ty
      , metaTitle = title
      , metaSummary = summary
      , metaTags = tags
      , metaStatus = st
      , metaTimeline = tl
      , metaAliases = als
      , metaLinks = lks
      , metaSource = src
      , metaRevision = rev
      , metaCreated = c
      , metaUpdated = u
      }

genOverride :: Gen MetaOverride
genOverride =
  MetaOverride
    <$> Gen.maybe (Gen.element allNodeKinds)
    <*> Gen.maybe genTypeKey
    <*> Gen.maybe genVaultId
    <*> Gen.maybe genPhrase
    <*> Gen.maybe (Gen.list (Range.linear 0 2) genWord)
    <*> Gen.maybe genStatus
    <*> Gen.maybe genTimeline
    <*> Gen.maybe (Gen.list (Range.linear 0 2) genWord)
    <*> Gen.maybe (Gen.list (Range.linear 0 2) genLink)
    <*> Gen.maybe genSource
    <*> Gen.maybe (Revision <$> Gen.integral (Range.linear 1 9))
    <*> Gen.maybe genDay
    <*> Gen.maybe genDay

genNewAsset :: Gen NewAsset
genNewAsset =
  NewAsset
    <$> Gen.maybe (LogicalName <$> genWord)
    <*> (Sha256 <$> genHex)
    <*> ((\w -> "PNG/" <> w <> ".png") <$> genWord)
    <*> Gen.maybe (pure "png")
    <*> Gen.frequency
      [ (3, pure Null)
      , (1, pure (object ["width" .= (4 :: Int), "height" .= (8 :: Int)]))
      ]
    <*> Gen.maybe (localRef . mkId PLic <$> Gen.integral (Range.linear 1 20))
    <*> Gen.maybe genWord

genNewLicense :: Gen NewLicense
genNewLicense =
  NewLicense
    <$> Gen.bool
    <*> Gen.bool
    <*> Gen.maybe genWord
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe genUrl

genPayload :: Gen NewSectionPayload
genPayload =
  Gen.choice
    [ NSFragment <$> genOverride
    , NSAsset <$> genOverride <*> genNewAsset
    , NSLicense <$> genOverride <*> genNewLicense
    , NSNode <$> genOverride <*> (NewNode <$> Gen.element allNodeKinds)
    ]

genPackFront :: Gen NewPackFront
genPackFront =
  NewPackFront
    <$> Gen.maybe genWord
    <*> Gen.maybe ((\w -> T.unpack w <> ".zip") <$> genWord)
    <*> Gen.maybe (Sha256 <$> genHex)
    <*> Gen.maybe (localRef . mkId PLic <$> Gen.integral (Range.linear 1 20))
    <*> Gen.maybe (Author <$> genWord <*> Gen.maybe genUrl <*> Gen.maybe genWord)
    <*> Gen.maybe genUrl
    <*> Gen.element [AiUnknown, AiNone, AiAssisted, AiGenerated]

--------------------------------------------------------------------------------
-- 產生器:型別專屬條目
--
-- 'MetaExtras' / 'FrontExtras' 沒有 smart constructor,合法值的判準寫在
-- P-026#LAW-8 / P-026#LAW-20 / P-026#LAW-24 上:頂層鍵不得落在
-- 'metaFieldOrder' / 'frontmatterFieldOrder' 裡。產生器因此只用
-- 'payloadExtras' / 'packFrontExtras' 的產物,或以那兩份清單自行過濾過的樣本行。

sectionExtraSamples :: [[Text]]
sectionExtraSamples =
  [ ["sha256: deadbeef1234"]
  , ["entry: PNG/a.png"]
  , ["battle_power: 9000"]
  , ["license: lic-00000001"]
  , ["ext: png"]
  , ["meta:", "  width: 4", "  height: 8"]
  ]

legalSectionSamples :: [[Text]]
legalSectionSamples =
  case filter (all (not . hasFieldKey metaFieldOrder)) sectionExtraSamples of
    [] -> [["battle_power: 9000"]]
    xs -> xs

genExtras :: Gen MetaExtras
genExtras =
  Gen.choice
    [ payloadExtras <$> genPayload
    , MetaExtras . concat <$> Gen.subsequence legalSectionSamples
    ]

frontExtraSamples :: [[Text]]
frontExtraSamples =
  [ ["vendor: kenney"]
  , ["archive: ui-pack.zip"]
  , ["sha256: deadbeef1234"]
  , ["battle_power: 9000"]
  , ["ai_disclosure: none"]
  ]

legalFrontSamples :: [[Text]]
legalFrontSamples =
  case filter (all (not . hasFieldKey frontmatterFieldOrder)) frontExtraSamples of
    [] -> [["battle_power: 9000"]]
    xs -> xs

genFrontExtras :: Gen FrontExtras
genFrontExtras =
  Gen.choice
    [ packFrontExtras <$> genPackFront
    , FrontExtras . MetaExtras . concat <$> Gen.subsequence legalFrontSamples
    ]

--------------------------------------------------------------------------------
-- 產生器:函數型變數
--
-- law 的 forall 出現函數時,產生一個有限族的可顯示描述,再解成函數;
-- 反例才讀得懂,也才縮得小。

data OvFn
  = OvId
  | OvConst MetaOverride
  | OvSummary Text
  | OvTags [Text]
  | OvStatus Status
  | OvClearSummary
  deriving stock (Show)

runOvFn :: OvFn -> MetaOverride -> MetaOverride
runOvFn = \case
  OvId -> id
  OvConst v -> const v
  OvSummary s -> \o -> o {moSummary = Just s}
  OvTags ts -> \o -> o {moTags = Just ts}
  OvStatus st -> \o -> o {moStatus = Just st}
  OvClearSummary -> \o -> o {moSummary = Nothing}

genOvFn :: Gen OvFn
genOvFn =
  Gen.choice
    [ pure OvId
    , OvConst <$> genOverride
    , OvSummary <$> genPhrase
    , OvTags <$> Gen.list (Range.linear 0 2) genWord
    , OvStatus <$> genStatus
    , pure OvClearSummary
    ]

data ExFn = ExId | ExConst MetaExtras | ExMerge MetaExtras | ExClear
  deriving stock (Show)

runExFn :: ExFn -> MetaExtras -> MetaExtras
runExFn = \case
  ExId -> id
  ExConst v -> const v
  ExMerge v -> mergeExtras v
  ExClear -> const (MetaExtras [])

genExFn :: Gen ExFn
genExFn =
  Gen.choice [pure ExId, ExConst <$> genExtras, ExMerge <$> genExtras, pure ExClear]

data MetaFn = MfId | MfConst Meta | MfSummary Text | MfStatus Status | MfTags [Text]
  deriving stock (Show)

runMetaFn :: MetaFn -> Meta -> Meta
runMetaFn = \case
  MfId -> id
  MfConst v -> const v
  MfSummary s -> \m -> m {metaSummary = s}
  MfStatus st -> \m -> m {metaStatus = st}
  MfTags ts -> \m -> m {metaTags = ts}

genMetaFn :: Gen MetaFn
genMetaFn =
  Gen.choice
    [ pure MfId
    , MfConst <$> genMeta PEnt "character-fragment"
    , MfSummary <$> genPhrase
    , MfStatus <$> genStatus
    , MfTags <$> Gen.list (Range.linear 0 2) genWord
    ]

data FrontFn = FfId | FfConst FrontExtras | FfMerge FrontExtras | FfClear
  deriving stock (Show)

runFrontFn :: FrontFn -> FrontExtras -> FrontExtras
runFrontFn = \case
  FfId -> id
  FfConst v -> const v
  FfMerge v -> mergeFrontExtras v
  FfClear -> const emptyFront

genFrontFn :: Gen FrontFn
genFrontFn =
  Gen.choice
    [pure FfId, FfConst <$> genFrontExtras, FfMerge <$> genFrontExtras, pure FfClear]

--------------------------------------------------------------------------------
-- 產生器:Document
--
-- 走「生零件 → newDocumentWith → appendSection 加幾節 →
-- parseDocument . renderDocument 正規化」,不直接堆 Document 的欄位。

-- | 標題層級序列:第一節固定 2,之後只在 2..4 之間上下一級,不跳級。
genLevels :: Int -> Gen [Int]
genLevels n
  | n <= 0 = pure []
  | otherwise = (2 :) <$> go (n - 1) 2
  where
    go 0 _ = pure []
    go k prev = do
      lv <- Gen.element (filter (\x -> x >= 2 && x <= 4) [prev - 1, prev, prev + 1])
      (lv :) <$> go (k - 1 :: Int) lv

genNewSectionAt :: Id -> Int -> Bool -> Gen NewSection
genNewSectionAt i lv blankTail =
  NewSection i lv <$> genTitle <*> genBody LF blankTail <*> genPayload

genDocWith :: Int -> Int -> Bool -> Gen Document
genDocWith lo hi blankTail = do
  m <- genMeta PEnt "character-fragment"
  fx <- genFrontExtras
  pre <- genBody LF False
  n <- Gen.integral (Range.linear lo hi)
  lvls <- genLevels n
  parts <- mapM (\(k, lv) -> genNewSectionAt (mkId PEnt (1000 + k)) lv blankTail) (zip [1 ..] lvls)
  crlf <- Gen.bool
  let d0 = newDocumentWith TopicDoc m fx pre
      d1 = foldl (\acc ns -> either (const acc) id (appendSection ns acc)) d0 parts
      txt0 = renderDocument d1
      txt = if crlf then T.replace "\n" "\r\n" (T.replace "\r\n" "\n" txt0) else txt0
  pure (either (const d1) id (parseDocument txt))

genDoc :: Int -> Int -> Gen Document
genDoc lo hi = genDocWith lo hi False

-- | 不在文件裡的節 id(文件的節一律用 1000 起算的索引)。
genAbsentId :: Gen Id
genAbsentId = mkId PEnt <$> Gen.integral (Range.linear 900000 900100)

genSection :: Gen Section
genSection =
  Gen.choice
    [ do
        le <- Gen.element [LF, CRLF]
        lv <- Gen.integral (Range.linear 1 6)
        n <- Gen.integral (Range.linear 1 100)
        t <- genTitle
        mp <- Gen.maybe genPayload
        b <- genBody le False
        pure (mkSection le lv (mkId PEnt n) t mp b)
    , do
        d <- genDoc 1 maxSecs
        case docSections d of
          [] -> pure (mkSection LF 2 (mkId PEnt 1) "節" Nothing "")
          ss -> Gen.element ss
    ]

--------------------------------------------------------------------------------
-- Example 的固定素材

baseMeta :: Id -> Text -> Meta
baseMeta i ty =
  Meta
    { metaId = i
    , metaVault = VaultId "vlt-00000001"
    , metaType = TypeKey ty
    , metaTitle = "測試"
    , metaSummary = "before"
    , metaTags = ["a"]
    , metaStatus = Draft
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = [Link References (localRef (mkId PEnt 2)) Nothing]
    , metaSource = Human
    , metaRevision = Revision 1
    , metaCreated = fromGregorian 2026 1 1
    , metaUpdated = fromGregorian 2026 1 1
    }

topicMeta :: Meta
topicMeta = baseMeta (mkId PEnt 1) "character-fragment"

packMeta :: Meta
packMeta = baseMeta (mkId PPck 1) "asset-pack"

levelMeta :: Meta
levelMeta = baseMeta (mkId PLvl 1) "level"

-- | 一節的原文。@Nothing@ = 沒有 meta 區塊;@Just []@ = 有區塊但一欄都沒寫。
secText :: Int -> Text -> Text -> Maybe [Text] -> Text -> Text
secText lvl title ident mlines body =
  T.replicate lvl "#" <> " " <> title <> " {#" <> ident <> "}\n" <> metaPart <> body
  where
    metaPart = case mlines of
      Nothing -> ""
      Just ls -> "\n```meta\n" <> T.concat [l <> "\n" | l <- ls] <> "```\n"

ensureNL :: Text -> Text
ensureNL t = if "\n" `T.isSuffixOf` t then t else t <> "\n"

-- | 用 newDocumentWith 產生合法的 frontmatter,再接上手寫的節,整份解析回來。
buildDoc :: DocKind -> Meta -> FrontExtras -> Text -> [Text] -> Document
buildDoc k m fx pre secs =
  right (parseDocument (ensureNL (renderDocument (newDocumentWith k m fx pre)) <> T.concat secs))

exNpf :: NewPackFront
exNpf =
  NewPackFront
    (Just "Kenney")
    (Just "ui-pack.zip")
    (Just (Sha256 "deadbeef1234"))
    (Just (localRef (idOf "lic-0001")))
    (Just (Author "Kenney" (Just "https://kenney.nl") Nothing))
    (Just "https://kenney.nl/assets/ui-pack")
    AiNone

exAssetOv :: MetaOverride
exAssetOv = emptyOverride {moType = Just (TypeKey "asset-image")}

exAsset :: NewAsset
exAsset =
  NewAsset
    { naName = Nothing
    , naSha256 = Sha256 "deadbeef1234"
    , naEntry = "PNG/a.png"
    , naExt = Nothing
    , naKindMeta = Null
    , naLicense = Nothing
    , naAuthor = Nothing
    }

--------------------------------------------------------------------------------

spec :: Spec
spec = around_ withItemTimeout $ modifyMaxSuccess (const 100) $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-026#LAW-1" $
    it "改一節的 Meta 半邊,其他每一節逐位元組不變" $
      hedgehog $ do
        d <- forAll (genDoc 2 maxSecs)
        let ids = sectionIds d
        i <- forAll (Gen.element ids)
        j <- forAll (Gen.element (filter (/= i) ids))
        f <- forAll genOvFn
        case updateSection i (runOvFn f) d of
          Left _ -> discard
          Right d2 ->
            fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)

  describe "P-026#LAW-2" $
    it "被改的那一節只有 meta 區塊被重寫,標題行與正文逐位元組不變" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        i <- forAll (Gen.element (sectionIds d))
        f <- forAll genOvFn
        case updateSection i (runOvFn f) d of
          Left _ -> discard
          Right d2 -> do
            fmap secHeadingRaw (sectionById i d2) === fmap secHeadingRaw (sectionById i d)
            fmap secBodyRaw (sectionById i d2) === fmap secBodyRaw (sectionById i d)
            docFrontRaw d2 === docFrontRaw d
            docPreamble d2 === docPreamble d

  describe "P-026#LAW-3" $
    it "改 Meta 半邊不吃掉型別專屬條目" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        i <- forAll (Gen.element (sectionIds d))
        f <- forAll genOvFn
        case updateSection i (runOvFn f) d of
          Left _ -> discard
          Right d2 -> extrasAt i d2 === extrasAt i d

  describe "P-026#LAW-4" $
    it "第一次 updateSection 把 meta 行序重排一次,第二次起是恆等" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        i <- forAll (Gen.element (sectionIds d))
        case updateSection i id d of
          Left _ -> discard
          Right d2 ->
            fmap renderDocument (updateSection i id d2) === Right (renderDocument d2)

  describe "P-026#LAW-5" $
    it "節不存在時每個編輯都回 Left,一個位元組都不動" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        i <- forAll genAbsentId
        f <- forAll genOvFn
        g <- forAll genExFn
        b <- forAll (genBody (docEnding d) False)
        isLeft (updateSection i (runOvFn f) d) === True
        isLeft (updateSectionExtras i (runExFn g) d) === True
        isLeft (updateSectionBody i b d) === True
        isLeft (renameSection i b d) === True
        isLeft (removeSection i d) === True
        isLeft (overrideAt i d) === True
        isLeft (extrasAt i d) === True

  describe "P-026#LAW-6" $
    it "改型別專屬半邊,Meta 那一半、標題行、正文與其他節都不動" $
      hedgehog $ do
        d <- forAll (genDoc 2 maxSecs)
        let ids = sectionIds d
        i <- forAll (Gen.element ids)
        j <- forAll (Gen.element (filter (/= i) ids))
        g <- forAll genExFn
        case updateSectionExtras i (runExFn g) d of
          Left _ -> discard
          Right d2 -> do
            overrideAt i d2 === overrideAt i d
            fmap secHeadingRaw (sectionById i d2) === fmap secHeadingRaw (sectionById i d)
            fmap secBodyRaw (sectionById i d2) === fmap secBodyRaw (sectionById i d)
            fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)

  describe "P-026#LAW-7" $
    it "extrasAt 就是該節的 extrasOf;沒有 meta 區塊時是空的一組" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        i <- forAll (Gen.element (sectionIds d))
        extrasAt i d === Right (fromMaybe (MetaExtras []) (fmap extrasOf (sectionById i d)))

  describe "P-026#LAW-8" $
    it "取出來的專屬條目不含任何 metaFieldOrder 裡的鍵" $
      hedgehog $ do
        s <- forAll genSection
        let ls = extraLines (extrasOf s)
        annotateShow ls
        assert (and [not ((k <> ":") `T.isPrefixOf` l) | l <- ls, k <- metaFieldOrder])

  describe "P-026#LAW-9" $
    it "刪節之後 id 清單恰好少掉那一個,其餘每一節逐位元組不變" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        i <- forAll (Gen.element (sectionIds d))
        case removeSection i d of
          Left _ -> discard
          Right d2 -> do
            sectionIds d2 === filter (/= i) (sectionIds d)
            forM_ (sectionIds d2) $ \j ->
              fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)

  describe "P-026#LAW-10" $
    it "追加的節排在最後,既有 id 的順序不變" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        ns <- forAll (genNewSectionAt (mkId PEnt 900001) 2 False)
        case appendSection ns d of
          Left _ -> discard
          Right d2 -> sectionIds d2 === concat [sectionIds d, [nsId ns]]

  describe "P-026#LAW-11" $
    it "追加不動既有節的標題行與 meta 區塊" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        ns <- forAll (genNewSectionAt (mkId PEnt 900001) 2 False)
        case appendSection ns d of
          Left _ -> discard
          Right d2 -> do
            forM_ (sectionIds d) $ \j -> do
              fmap secHeadingRaw (sectionById j d2) === fmap secHeadingRaw (sectionById j d)
              fmap secMetaRaw (sectionById j d2) === fmap secMetaRaw (sectionById j d)
            docFrontRaw d2 === docFrontRaw d

  describe "P-026#LAW-12" $
    it "nsId 與既有節撞號時追加與插入都回 Left" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        dup <- forAll (Gen.element (sectionIds d))
        pid <- forAll (Gen.choice [Gen.element (sectionIds d), genAbsentId])
        ns <- forAll (genNewSectionAt dup 2 False)
        isLeft (appendSection ns d) === True
        isLeft (insertSection pid ns d) === True

  describe "P-026#LAW-13" $
    it "插入保序:把新節拿掉之後的 id 清單與原本逐一相同" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        pid <- forAll (Gen.element (sectionIds d))
        let plv = maybe 2 secLevel (sectionById pid d)
        ns <- forAll (genNewSectionAt (mkId PEnt 900001) (plv + 1) False)
        case insertSection pid ns d of
          Left _ -> discard
          Right d2 -> filter (/= nsId ns) (sectionIds d2) === sectionIds d

  describe "P-026#LAW-14" $
    it "插入不動其他節的標題行與 meta 區塊" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        pid <- forAll (Gen.element (sectionIds d))
        let plv = maybe 2 secLevel (sectionById pid d)
        ns <- forAll (genNewSectionAt (mkId PEnt 900001) (plv + 1) False)
        case insertSection pid ns d of
          Left _ -> discard
          Right d2 -> do
            forM_ (filter (/= nsId ns) (sectionIds d)) $ \j -> do
              fmap secHeadingRaw (sectionById j d2) === fmap secHeadingRaw (sectionById j d)
              fmap secMetaRaw (sectionById j d2) === fmap secMetaRaw (sectionById j d)
            docFrontRaw d2 === docFrontRaw d
            docPreamble d2 === docPreamble d

  describe "P-026#LAW-15" $
    it "插入唯一可能動到的位元組是插入點之前那一段的尾端,而且只在尾端補" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        pid <- forAll (Gen.element (sectionIds d))
        let plv = maybe 2 secLevel (sectionById pid d)
        ns <- forAll (genNewSectionAt (mkId PEnt 900001) (plv + 1) False)
        case insertSection pid ns d of
          Left _ -> discard
          Right d2 ->
            forM_ (filter (/= nsId ns) (sectionIds d)) $ \j -> do
              let before = fromMaybe "" (fmap secBodyRaw (sectionById j d))
                  after = fromMaybe "" (fmap secBodyRaw (sectionById j d2))
              annotateShow (before, after)
              assert (before `T.isPrefixOf` after)

  describe "P-026#LAW-16" $
    it "blankTail 冪等:原本就以空行結尾的節,插入之後正文一個位元組都不動" $
      hedgehog $ do
        d <- forAll (genDocWith 1 maxSecs True)
        pid <- forAll (Gen.element (sectionIds d))
        let plv = maybe 2 secLevel (sectionById pid d)
        ns <- forAll (genNewSectionAt (mkId PEnt 900001) (plv + 1) False)
        case insertSection pid ns d of
          Left _ -> discard
          Right d2 -> do
            let nl = renderLineEnding (docEnding d)
                endsBlank j =
                  (nl <> nl) `T.isSuffixOf` fromMaybe "" (fmap secBodyRaw (sectionById j d))
                qualifying = filter endsBlank (filter (/= nsId ns) (sectionIds d))
            cover 50 "有以空行結尾的節" (not (null qualifying))
            forM_ qualifying $ \j ->
              fmap secBodyRaw (sectionById j d2) === fmap secBodyRaw (sectionById j d)

  describe "P-026#LAW-17" $
    it "新節的 meta 區塊由兩半組出來;payload 為 Nothing 時完全不產生區塊" $
      hedgehog $ do
        le <- forAll (Gen.element [LF, CRLF])
        n <- forAll (Gen.integral (Range.linear 1 6))
        k <- forAll (Gen.integral (Range.linear 1 100))
        title <- forAll genTitle
        p <- forAll genPayload
        b <- forAll (genBody le False)
        let i = mkId PEnt k
        secMetaRaw (mkSection le n i title (Just p) b)
          === Just
            ( mconcat
                [renderLineEnding le, renderMetaBlock (payloadOverride p) (payloadExtras p) le]
            )
        secMetaRaw (mkSection le n i title Nothing b) === Nothing

  describe "P-026#LAW-18" $
    it "NSNode 的 kind 以 NewNode 為唯一真相來源" $
      hedgehog $ do
        ov <- forAll genOverride
        n <- forAll (NewNode <$> Gen.element allNodeKinds)
        moKind (payloadOverride (NSNode ov n)) === Just (nnKind n)

  describe "P-026#LAW-19" $
    it "其餘三個建構子的 payloadOverride 原樣回傳自己帶的 MetaOverride" $
      hedgehog $ do
        ov <- forAll genOverride
        a <- forAll genNewAsset
        l <- forAll genNewLicense
        payloadOverride (NSFragment ov) === ov
        payloadOverride (NSAsset ov a) === ov
        payloadOverride (NSLicense ov l) === ov

  describe "P-026#LAW-20" $
    it "payload 產生的專屬條目與 metaFieldOrder 的鍵不相交" $
      hedgehog $ do
        p <- forAll genPayload
        let ls = extraLines (payloadExtras p)
        annotateShow ls
        assert (and [not ((k <> ":") `T.isPrefixOf` l) | l <- ls, k <- metaFieldOrder])

  describe "P-026#LAW-21" $
    it "合併是聯集:第一個參數的條目依原序在前,第二個參數中鍵未被覆蓋的依原序在後" $
      hedgehog $ do
        a <- forAll genExtras
        b <- forAll genExtras
        let merged = extraLines (mergeExtras a b)
        annotateShow merged
        assert (extraLines a `L.isPrefixOf` merged)
        assert (all (`elem` concat [extraLines a, extraLines b]) merged)

  describe "P-026#LAW-22" $
    it "與空的一組合併,兩個方向都是恆等" $
      hedgehog $ do
        a <- forAll genExtras
        mergeExtras a (MetaExtras []) === a
        mergeExtras (MetaExtras []) a === a

  describe "P-026#LAW-23" $
    it "檔案層的合併就是節層的合併,不得有第二份實作" $
      hedgehog $ do
        a <- forAll genFrontExtras
        b <- forAll genFrontExtras
        mergeFrontExtras a b === FrontExtras (mergeExtras (unFrontExtras a) (unFrontExtras b))

  describe "P-026#LAW-24" $
    it "pack 的七個檔案層欄位與 frontmatterFieldOrder 的鍵不相交" $
      hedgehog $ do
        npf <- forAll genPackFront
        let ls = extraLines (unFrontExtras (packFrontExtras npf))
        annotateShow ls
        assert (and [not ((k <> ":") `T.isPrefixOf` l) | l <- ls, k <- frontmatterFieldOrder])

  describe "P-026#LAW-25" $
    it "改檔案層的 Meta 半邊不吃掉檔案層的專屬條目" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        f <- forAll genMetaFn
        case updateFrontmatter (runMetaFn f) d of
          Left _ -> discard
          Right d2 -> frontExtrasOf d2 === frontExtrasOf d

  describe "P-026#LAW-26" $
    it "改檔案層不動 preamble 與任何一節" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        f <- forAll genMetaFn
        case updateFrontmatter (runMetaFn f) d of
          Left _ -> discard
          Right d2 -> do
            docPreamble d2 === docPreamble d
            forM_ (sectionIds d) $ \j ->
              fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)

  describe "P-026#LAW-27" $
    it "檔案層的欄位順序只重排一次:第二次 updateFrontmatter id 是恆等" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        case updateFrontmatter id d of
          Left _ -> discard
          Right d2 ->
            fmap renderDocument (updateFrontmatter id d2) === Right (renderDocument d2)

  describe "P-026#LAW-28" $
    it "改檔案層的專屬條目,Meta 那一半一欄都不動,preamble 與每一節逐位元組不變" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        g <- forAll genFrontFn
        case updateFrontmatterExtras (runFrontFn g) d of
          Left _ -> discard
          Right d2 -> do
            decodeFrontmatter (docFrontRaw d2) === decodeFrontmatter (docFrontRaw d)
            docPreamble d2 === docPreamble d
            forM_ (sectionIds d) $ \j ->
              fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)

  describe "P-026#LAW-29" $
    it "只換正文:該節的標題行與 meta 區塊、其他節逐位元組不變" $
      hedgehog $ do
        d <- forAll (genDoc 2 maxSecs)
        let ids = sectionIds d
        i <- forAll (Gen.element ids)
        j <- forAll (Gen.element (filter (/= i) ids))
        b <- forAll (genBody (docEnding d) False)
        case updateSectionBody i b d of
          Left _ -> discard
          Right d2 -> do
            fmap secHeadingRaw (sectionById i d2) === fmap secHeadingRaw (sectionById i d)
            fmap secMetaRaw (sectionById i d2) === fmap secMetaRaw (sectionById i d)
            fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)

  describe "P-026#LAW-30" $
    it "只換標題文字:層級與 id 不變,meta 區塊與正文、其他節逐位元組不變" $
      hedgehog $ do
        d <- forAll (genDoc 2 maxSecs)
        let ids = sectionIds d
        i <- forAll (Gen.element ids)
        j <- forAll (Gen.element (filter (/= i) ids))
        title <- forAll genTitle
        case renameSection i title d of
          Left _ -> discard
          Right d2 -> do
            fmap secTitle (sectionById i d2) === Just title
            fmap secLevel (sectionById i d2) === fmap secLevel (sectionById i d)
            fmap secId (sectionById i d2) === fmap secId (sectionById i d)
            fmap secMetaRaw (sectionById i d2) === fmap secMetaRaw (sectionById i d)
            fmap secBodyRaw (sectionById i d2) === fmap secBodyRaw (sectionById i d)
            fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)

  describe "P-026#LAW-31" $
    it "只換 preamble:frontmatter 與每一節逐位元組不變" $
      hedgehog $ do
        d <- forAll (genDoc 1 maxSecs)
        b <- forAll (genBody (docEnding d) False)
        let d2 = replacePreamble b d
        docFrontRaw d2 === docFrontRaw d
        forM_ (sectionIds d) $ \j ->
          fmap renderSection (sectionById j d2) === fmap renderSection (sectionById j d)
        sectionIds d2 === sectionIds d

  describe "P-026#LAW-32" $
    it "每一種編輯的結果都還解析得回來,解出的 id 清單與編輯後相同" $
      hedgehog $ do
        d <- forAll (genDoc 0 maxSecs)
        ns <- forAll (genNewSectionAt (mkId PEnt 900001) 2 False)
        if not (either (const False) (const True) (parseDocument (renderDocument d)))
          then discard
          else case appendSection ns d of
            Left _ -> discard
            Right d2 ->
              fmap sectionIds (parseDocument (renderDocument d2)) === Right (sectionIds d2)

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-026#EX-1" $
    it "asset 節改 summary,sha256 / entry 逐字留著" $ do
      let aid = idOf "ast-00000001"
          d =
            buildDoc
              PackDoc
              packMeta
              emptyFront
              "\n"
              [ secText
                  2
                  "圖示"
                  "ast-00000001"
                  (Just ["type: asset-image", "summary: before", "sha256: deadbeef1234", "entry: PNG/a.png"])
                  "內文\n\n"
              ]
          d' = right (updateSection aid (\o -> o {moSummary = Just "after"}) d)
          out = renderDocument d'
      out `shouldSatisfy` T.isInfixOf "sha256: deadbeef1234"
      out `shouldSatisfy` T.isInfixOf "entry: PNG/a.png"
      extrasAt aid d' `shouldBe` extrasAt aid d
      fmap moSummary (overrideAt aid d') `shouldBe` Right (Just "after")
      fmap secHeadingRaw (sectionById aid d') `shouldBe` fmap secHeadingRaw (sectionById aid d)
      fmap secBodyRaw (sectionById aid d') `shouldBe` fmap secBodyRaw (sectionById aid d)

  describe "P-026#EX-2" $
    it "第二次 updateSection id 的輸出與第一次逐位元組相同" $ do
      let i = idOf "ent-00000001"
          d =
            buildDoc
              TopicDoc
              topicMeta
              emptyFront
              "\n"
              [secText 2 "片段" "ent-00000001" (Just ["summary: x", "sha256: deadbeef1234"]) "內文\n\n"]
          d1 = right (updateSection i id d)
          d2 = right (updateSection i id d1)
      renderDocument d2 `shouldBe` renderDocument d1

  describe "P-026#EX-3" $
    it "三節的主題檔改中間那一節,另外兩節逐位元組不變" $ do
      let mid = idOf "ent-00000002"
          d = threeSectionDoc
          d' = right (updateSection mid (\o -> o {moSummary = Just "after"}) d)
      forM_ [idOf "ent-00000001", idOf "ent-00000003"] $ \j ->
        fmap renderSection (sectionById j d') `shouldBe` fmap renderSection (sectionById j d)
      docFrontRaw d' `shouldBe` docFrontRaw d
      docPreamble d' `shouldBe` docPreamble d

  describe "P-026#EX-4" $
    it "對不存在的節 id 呼叫七個編輯入口都回 UnknownSectionId" $ do
      let miss = idOf "ent-9999"
          d = threeSectionDoc
          expected :: Either MdError a -> Expectation
          expected r = case r of
            Left e -> e `shouldBe` MdError 1 (UnknownSectionId miss)
            Right _ -> expectationFailure "應該是 Left"
      expected (updateSection miss id d)
      expected (updateSectionExtras miss id d)
      expected (updateSectionBody miss "x" d)
      expected (renameSection miss "x" d)
      expected (removeSection miss d)
      expected (overrideAt miss d)
      expected (extrasAt miss d)

  describe "P-026#EX-5" $
    it "只換 license 那一行,sha256 / entry / meta 逐字不變" $ do
      let aid = idOf "ast-00000001"
          lic1 = idOf "lic-0001"
          lic2 = idOf "lic-0002"
          na =
            NewAsset
              { naName = Nothing
              , naSha256 = Sha256 "deadbeef1234"
              , naEntry = "PNG/a.png"
              , naExt = Nothing
              , naKindMeta = object ["width" .= (4 :: Int)]
              , naLicense = Just (localRef lic1)
              , naAuthor = Nothing
              }
          na' = na {naLicense = Just (localRef lic2)}
          d0 = newDocumentWith PackDoc packMeta emptyFront "\n"
          d = right (appendSection (NewSection aid 2 "圖示" "內文\n\n" (NSAsset exAssetOv na)) d0)
          d' = right (updateSectionExtras aid (mergeExtras (payloadExtras (NSAsset emptyOverride na'))) d)
          before = extraLines (right (extrasAt aid d))
          after = extraLines (right (extrasAt aid d'))
          metaEntry ls = filter (\l -> "meta:" `T.isPrefixOf` l || " " `T.isPrefixOf` l) ls
      linesWithKey "sha256" after `shouldBe` linesWithKey "sha256" before
      linesWithKey "entry" after `shouldBe` linesWithKey "entry" before
      metaEntry after `shouldBe` metaEntry before
      after `shouldSatisfy` any (T.isInfixOf (renderId lic2))
      after `shouldSatisfy` (not . any (T.isInfixOf (renderId lic1)))
      overrideAt aid d' `shouldBe` overrideAt aid d
      fmap secHeadingRaw (sectionById aid d') `shouldBe` fmap secHeadingRaw (sectionById aid d)
      fmap secBodyRaw (sectionById aid d') `shouldBe` fmap secBodyRaw (sectionById aid d)

  describe "P-026#EX-6" $
    it "空的 meta 區塊與根本沒有 meta 區塊,extrasAt 都是空的一組" $ do
      let i1 = idOf "ent-00000001"
          i2 = idOf "ent-00000002"
          d =
            buildDoc
              TopicDoc
              topicMeta
              emptyFront
              "\n"
              [ secText 2 "空區塊" "ent-00000001" (Just []) "內文\n\n"
              , secText 2 "無區塊" "ent-00000002" Nothing "內文\n\n"
              ]
      extrasAt i1 d `shouldBe` Right (MetaExtras [])
      extrasAt i2 d `shouldBe` Right (MetaExtras [])
      overrideAt i2 d `shouldBe` Right emptyOverride

  describe "P-026#EX-7" $
    it "extrasOf 只留鍵不在 metaFieldOrder 裡的條目" $ do
      let i = idOf "ent-00000001"
          d =
            buildDoc
              TopicDoc
              topicMeta
              emptyFront
              "\n"
              [ secText
                  2
                  "節"
                  "ent-00000001"
                  (Just ["summary: x", "sha256: deadbeef1234", "battle_power: 9000"])
                  "內文\n\n"
              ]
          s = right (maybe (Left ("找不到節" :: Text)) Right (sectionById i d))
      extraLines (extrasOf s) `shouldBe` ["sha256: deadbeef1234", "battle_power: 9000"]

  describe "P-026#EX-8" $
    it "區塊風格的巢狀值三行整段逐字保留、順序不變" $ do
      let i = idOf "ent-00000001"
          d =
            buildDoc
              TopicDoc
              topicMeta
              emptyFront
              "\n"
              [ secText
                  2
                  "節"
                  "ent-00000001"
                  (Just ["summary: x", "meta:", "  width: 4", "  height: 8"])
                  "內文\n\n"
              ]
          d' = right (updateSection i id d)
      extraLines (right (extrasAt i d')) `shouldBe` ["meta:", "  width: 4", "  height: 8"]
      renderDocument d' `shouldSatisfy` T.isInfixOf "meta:\n  width: 4\n  height: 8"

  describe "P-026#EX-9" $
    it "removeSection 掉中間那一節,剩下兩節逐位元組不變" $ do
      let d = threeSectionDoc
          mid = idOf "ent-00000002"
          d' = right (removeSection mid d)
      sectionIds d' `shouldBe` [idOf "ent-00000001", idOf "ent-00000003"]
      forM_ (sectionIds d') $ \j ->
        fmap renderSection (sectionById j d') `shouldBe` fmap renderSection (sectionById j d)

  describe "P-026#EX-10" $
    it "沒有任何節的 pack.md 追加一節,toPack 解得出一筆 asset" $ do
      let aid = idOf "ast-0001"
          d0 = newDocumentWith PackDoc packMeta emptyFront "\n"
          d = right (appendSection (NewSection aid 2 "圖示" "" (NSAsset exAssetOv exAsset)) d0)
          d2 = right (parseDocument (renderDocument d))
      sectionIds d `shouldBe` [aid]
      length (snd (right (toPack d2))) `shouldBe` 1

  describe "P-026#EX-11" $
    it "1,693 節的 pack.md 追加第 1,694 節,前 1,693 節逐位元組不變" $ do
      let n = 1693 :: Int
          secs =
            [ secText
                2
                ("圖" <> T.pack (show k))
                ("ast-" <> hex8i k)
                (Just ["type: asset-image", "sha256: deadbeef1234", "entry: PNG/a.png"])
                "內文\n\n"
            | k <- [1 .. n]
            ]
          d = buildDoc PackDoc packMeta emptyFront "\n" secs
          ns = NewSection (idOf ("ast-" <> hex8i (n + 1))) 2 "新圖" "" (NSAsset exAssetOv exAsset)
          d2 = right (appendSection ns d)
      length (docSections d) `shouldBe` n
      map secHeadingRaw (take n (docSections d2)) `shouldBe` map secHeadingRaw (docSections d)
      map secMetaRaw (take n (docSections d2)) `shouldBe` map secMetaRaw (docSections d)
      map secId (drop n (docSections d2)) `shouldBe` [nsId ns]

  describe "P-026#EX-12" $
    it "撞號時追加與插入都回 DuplicateSectionId" $ do
      let d = threeSectionDoc
          dup = idOf "ent-00000002"
          ns = NewSection dup 2 "x" "" (NSFragment emptyOverride)
      appendSection ns d `shouldBe` Left (MdError 1 (DuplicateSectionId dup))
      insertSection dup ns d `shouldBe` Left (MdError 1 (DuplicateSectionId dup))

  describe "P-026#EX-13" $
    it "插入成為父節點子樹的最後一個子節點" $ do
      let d = levelDoc "內文\n\n"
          ns = NewSection (idOf "nod-0030") 3 "新節" "新內文\n" (NSNode emptyOverride (NewNode KScene))
          d2 = right (insertSection (idOf "nod-0003") ns d)
      sectionIds d2
        `shouldBe` map
          idOf
          ["nod-0002", "nod-0003", "nod-0010", "nod-0011", "nod-0020", "nod-0030", "nod-0004"]
      filter (/= idOf "nod-0030") (sectionIds d2) `shouldBe` sectionIds d

  describe "P-026#EX-14" $
    it "插入點之前的正文已經以空行結尾時,每一節逐位元組不變" $ do
      let d = levelDoc "內文\n\n"
          ns = NewSection (idOf "nod-0030") 3 "新節" "新內文\n" (NSNode emptyOverride (NewNode KScene))
          d2 = right (insertSection (idOf "nod-0003") ns d)
      forM_ (sectionIds d) $ \j ->
        fmap renderSection (sectionById j d2) `shouldBe` fmap renderSection (sectionById j d)
      docFrontRaw d2 `shouldBe` docFrontRaw d
      docPreamble d2 `shouldBe` docPreamble d

  describe "P-026#EX-15" $
    it "插入點之前的正文沒有空行時只在尾端補齊,舊正文仍是新正文的前綴" $ do
      let d = levelDoc "內文\n"
          n20 = idOf "nod-0020"
          ns = NewSection (idOf "nod-0030") 3 "新節" "新內文\n" (NSNode emptyOverride (NewNode KScene))
          d2 = right (insertSection (idOf "nod-0003") ns d)
          before = fromMaybe "" (fmap secBodyRaw (sectionById n20 d))
          after = fromMaybe "" (fmap secBodyRaw (sectionById n20 d2))
      after `shouldSatisfy` T.isPrefixOf before
      forM_ (filter (/= n20) (sectionIds d)) $ \j ->
        fmap renderSection (sectionById j d2) `shouldBe` fmap renderSection (sectionById j d)

  describe "P-026#EX-16" $
    it "mkSection 的 secMetaRaw 由兩半組出來;Nothing 時沒有區塊" $ do
      let i = idOf "ast-0001"
          p = NSAsset exAssetOv exAsset
      secMetaRaw (mkSection LF 2 i "圖示" (Just p) "內文")
        `shouldBe` Just
          (renderLineEnding LF <> renderMetaBlock (payloadOverride p) (payloadExtras p) LF)
      secMetaRaw (mkSection LF 2 i "圖示" Nothing "內文") `shouldBe` Nothing

  describe "P-026#EX-17" $
    it "NSNode 的 kind 覆蓋 moKind,其餘十二欄不變" $ do
      let ov = emptyOverride {moKind = Just KDialogue, moSummary = Just "s", moTags = Just ["a"]}
          r = payloadOverride (NSNode ov (NewNode KScene))
      moKind r `shouldBe` Just KScene
      r {moKind = moKind ov} `shouldBe` ov

  describe "P-026#EX-18" $
    it "其餘三個建構子逐欄等於 ov" $ do
      let ov = emptyOverride {moSummary = Just "s", moTags = Just ["a"]}
          nl =
            NewLicense
              { nlcCommercial = True
              , nlcAttributionRequired = False
              , nlcCreditText = Nothing
              , nlcModificationAllowed = Nothing
              , nlcRedistributionAllowed = Nothing
              , nlcResaleAllowed = Nothing
              , nlcNftAllowed = Nothing
              , nlcSourceUrl = Nothing
              }
      payloadOverride (NSFragment ov) `shouldBe` ov
      payloadOverride (NSAsset ov exAsset) `shouldBe` ov
      payloadOverride (NSLicense ov nl) `shouldBe` ov

  describe "P-026#EX-19" $
    it "全空的 NewAsset 只產生 sha256 與 entry 兩行" $ do
      let ls = extraLines (payloadExtras (NSAsset emptyOverride exAsset))
      map keyOf ls `shouldBe` ["sha256", "entry"]
      forM_ ls $ \l -> hasFieldKey metaFieldOrder l `shouldBe` False

  describe "P-026#EX-20" $
    it "同鍵第一個參數贏,其餘依原序在後" $
      mergeExtras
        (MetaExtras ["license: lic-0002"])
        (MetaExtras ["sha256: deadbeef1234", "license: lic-0001"])
        `shouldBe` MetaExtras ["license: lic-0002", "sha256: deadbeef1234"]

  describe "P-026#EX-21" $
    it "與空的一組合併,兩個方向都逐字等於 a" $ do
      let a = MetaExtras ["sha256: deadbeef1234", "license: lic-0001"]
      mergeExtras a (MetaExtras []) `shouldBe` a
      mergeExtras (MetaExtras []) a `shouldBe` a

  describe "P-026#EX-22" $
    it "mergeFrontExtras 等於包一層的 mergeExtras" $ do
      let a = MetaExtras ["license: lic-0002"]
          b = MetaExtras ["sha256: deadbeef1234", "license: lic-0001"]
      mergeFrontExtras (FrontExtras a) (FrontExtras b) `shouldBe` FrontExtras (mergeExtras a b)

  describe "P-026#EX-23" $
    it "packFrontExtras 的七行鍵依序,且一個都不在 frontmatterFieldOrder 裡" $ do
      let ls = extraLines (unFrontExtras (packFrontExtras exNpf))
          tops = filter (not . (" " `T.isPrefixOf`)) ls
      map keyOf tops
        `shouldBe` ["vendor", "archive", "sha256", "license", "author", "source_url", "ai_disclosure"]
      forM_ ls $ \l -> hasFieldKey frontmatterFieldOrder l `shouldBe` False

  describe "P-026#EX-24" $
    it "七欄全空的 NewPackFront 產生空的一組" $
      packFrontExtras (NewPackFront Nothing Nothing Nothing Nothing Nothing Nothing AiUnknown)
        `shouldBe` FrontExtras (MetaExtras [])

  describe "P-026#EX-25" $
    it "改檔案層 summary,pack 的七欄與 preamble、每一節都不動" $ do
      let d = packDocWithFront
          d' = right (updateFrontmatter (\mm -> mm {metaSummary = "after"}) d)
          out = renderDocument d'
          sevenOf p =
            ( pckVendor p
            , pckArchive p
            , pckSha256 p
            , pckLicense p
            , pckAuthor p
            , pckSourceUrl p
            , pckAiDisclosure p
            )
          packOf x = fst (right (toPack (right (parseDocument (renderDocument x)))))
      forM_ (extraLines (unFrontExtras (packFrontExtras exNpf))) $ \l ->
        out `shouldSatisfy` T.isInfixOf l
      sevenOf (packOf d') `shouldBe` sevenOf (packOf d)
      metaSummary (pckMeta (packOf d')) `shouldBe` "after"
      docPreamble d' `shouldBe` docPreamble d
      forM_ (sectionIds d) $ \j ->
        fmap renderSection (sectionById j d') `shouldBe` fmap renderSection (sectionById j d)

  describe "P-026#EX-26" $
    it "註冊表宣告的 battle_power 逐字保留(排在 links: 之後),第二次是恆等" $ do
      let d = newDocumentWith TopicDoc topicMeta (FrontExtras (MetaExtras ["battle_power: 9000"])) "\n"
          d1 = right (updateFrontmatter (\mm -> mm {metaStatus = Canon}) d)
          d2 = right (updateFrontmatter id d1)
          fr = docFrontRaw d1
          idxOf a = T.length (fst (T.breakOn a fr))
      renderDocument d1 `shouldSatisfy` T.isInfixOf "battle_power: 9000"
      fr `shouldSatisfy` T.isInfixOf "links:"
      idxOf "battle_power:" `shouldSatisfy` (> idxOf "links:")
      renderDocument d2 `shouldBe` renderDocument d1

  describe "P-026#EX-27" $
    it "只換檔案層的 license 那一行,Meta 那一半一欄都不動" $ do
      let d = packDocWithFront
          npf' = exNpf {npfLicense = Just (localRef (idOf "lic-0002"))}
          d' = right (updateFrontmatterExtras (mergeFrontExtras (packFrontExtras npf')) d)
          before = extraLines (unFrontExtras (frontExtrasOf d))
          after = extraLines (unFrontExtras (frontExtrasOf d'))
      docFrontRaw d' `shouldSatisfy` T.isInfixOf "lic-0002"
      docFrontRaw d' `shouldSatisfy` (not . T.isInfixOf "lic-0001")
      forM_ ["vendor", "archive", "sha256"] $ \k ->
        linesWithKey k after `shouldBe` linesWithKey k before
      decodeFrontmatter (docFrontRaw d') `shouldBe` decodeFrontmatter (docFrontRaw d)
      docPreamble d' `shouldBe` docPreamble d
      forM_ (sectionIds d) $ \j ->
        fmap renderSection (sectionById j d') `shouldBe` fmap renderSection (sectionById j d)

  describe "P-026#EX-28" $
    it "frontmatter 的 YAML 壞掉時兩個入口都回 FrontmatterYaml,一個位元組都沒動" $ do
      let raw = "\ntitle: [unclosed\n"
          bad =
            Document
              { docFrontRaw = raw
              , docPreamble = "\n"
              , docSections = []
              , docEnding = LF
              , docFinalNL = True
              , docKind = TopicDoc
              }
          yamlErr :: Either MdError Document -> Expectation
          yamlErr r = case r of
            Left (MdError 1 (FrontmatterYaml _)) -> pure ()
            other -> expectationFailure ("應該是 FrontmatterYaml,實際是 " <> show other)
      yamlErr (updateFrontmatter id bad)
      yamlErr (updateFrontmatterExtras id bad)
      docFrontRaw bad `shouldBe` raw

  describe "P-026#EX-29" $
    it "換成不以行尾結尾的正文,下一節的標題不會黏上去" $ do
      let d =
            buildDoc
              TopicDoc
              topicMeta
              emptyFront
              "\n"
              [ secText 2 "第一節" "ent-00000001" (Just ["summary: x"]) "內文\n\n"
              , secText 2 "第二節" "ent-00000002" (Just ["summary: y"]) "內文\n\n"
              ]
          i1 = idOf "ent-00000001"
          i2 = idOf "ent-00000002"
          d' = right (updateSectionBody i1 "新正文" d)
      fmap secHeadingRaw (sectionById i1 d') `shouldBe` fmap secHeadingRaw (sectionById i1 d)
      fmap secMetaRaw (sectionById i1 d') `shouldBe` fmap secMetaRaw (sectionById i1 d)
      fmap renderSection (sectionById i2 d') `shouldBe` fmap renderSection (sectionById i2 d)
      fmap sectionIds (parseDocument (renderDocument d')) `shouldBe` Right (sectionIds d')

  describe "P-026#EX-30" $
    it "CRLF 檔改標題文字,層級 / id / 行尾都不變" $ do
      let txt =
            T.replace "\n" "\r\n" $
              ensureNL (renderDocument (newDocumentWith TopicDoc topicMeta emptyFront "\n"))
                <> secText 2 "琳達" "ent-7f3a" (Just ["summary: x"]) "內文\n\n"
                <> secText 2 "另一節" "ent-7f3b" Nothing "內文\n\n"
          d = right (parseDocument txt)
          i = idOf "ent-7f3a"
          j = idOf "ent-7f3b"
          d' = right (renameSection i "琳達(改)" d)
      fmap secTitle (sectionById i d') `shouldBe` Just "琳達(改)"
      fmap secLevel (sectionById i d') `shouldBe` Just 2
      fmap secId (sectionById i d') `shouldBe` Just i
      fmap (T.isSuffixOf "\r\n" . secHeadingRaw) (sectionById i d') `shouldBe` Just True
      fmap secMetaRaw (sectionById i d') `shouldBe` fmap secMetaRaw (sectionById i d)
      fmap secBodyRaw (sectionById i d') `shouldBe` fmap secBodyRaw (sectionById i d)
      fmap renderSection (sectionById j d') `shouldBe` fmap renderSection (sectionById j d)

  describe "P-026#EX-31" $
    it "只換 preamble,frontmatter 與兩節逐位元組不變" $ do
      let d =
            buildDoc
              TopicDoc
              topicMeta
              emptyFront
              "\n"
              [ secText 2 "第一節" "ent-00000001" (Just ["summary: x"]) "內文\n\n"
              , secText 2 "第二節" "ent-00000002" Nothing "內文\n\n"
              ]
          d' = replacePreamble "新的主體正文" d
      docFrontRaw d' `shouldBe` docFrontRaw d
      forM_ (sectionIds d) $ \j ->
        fmap renderSection (sectionById j d') `shouldBe` fmap renderSection (sectionById j d)
      sectionIds d' `shouldBe` sectionIds d

--------------------------------------------------------------------------------
-- Example 的共用文件

threeSectionDoc :: Document
threeSectionDoc =
  buildDoc
    TopicDoc
    topicMeta
    emptyFront
    "\n"
    [ secText 2 "第一節" "ent-00000001" (Just ["summary: a", "sha256: deadbeef1234"]) "內文\n\n"
    , secText 2 "第二節" "ent-00000002" (Just ["summary: b", "entry: PNG/a.png"]) "內文\n\n"
    , secText 2 "第三節" "ent-00000003" Nothing "內文\n\n"
    ]

-- | EX-13 / EX-14 / EX-15 的 Level 檔;@tailBody@ 決定 nod-0020 的正文尾端。
levelDoc :: Text -> Document
levelDoc tailBody =
  buildDoc
    LevelDoc
    levelMeta
    emptyFront
    "\n"
    [ secText 2 "第一章" "nod-0002" (Just ["kind: scene"]) "內文\n\n"
    , secText 2 "第三章" "nod-0003" (Just ["kind: scene"]) "內文\n\n"
    , secText 3 "第一節" "nod-0010" (Just ["kind: scene"]) "內文\n\n"
    , secText 3 "第二節" "nod-0011" (Just ["kind: scene"]) "內文\n\n"
    , secText 4 "場景 A" "nod-0020" (Just ["kind: scene"]) tailBody
    , secText 2 "第四章" "nod-0004" (Just ["kind: scene"]) "內文\n\n"
    ]

-- | EX-25 / EX-27 的 pack.md:檔案層帶滿七個專屬欄位,並有一節 asset。
packDocWithFront :: Document
packDocWithFront =
  right
    ( appendSection
        (NewSection (idOf "ast-0001") 2 "圖示" "內文\n\n" (NSAsset exAssetOv exAsset))
        (newDocumentWith PackDoc packMeta (packFrontExtras exNpf) "\n")
    )
