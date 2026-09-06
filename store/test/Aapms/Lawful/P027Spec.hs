-- | lawful 測試:P-027-fts-tokenize(qa 填入)。
--
-- 每條 @LAW-n@ 一個 @describe "P-027#LAW-n"@ 的 property test,每個 @EX-n@
-- 一個 @describe "P-027#EX-n"@ 的 example test。斷言逐字照 pipeline 檔的
-- @|-@ 行翻譯(@length@ \/ @words@ \/ @filter@ \/ @isInfixOf@ 等識別字對應到
-- @Data.Text@ 的同名函數)。
--
-- __案例數__:@hspec-hedgehog@ 的 @Example (PropertyT IO ())@ instance 會把
-- hedgehog 的 @TestLimit@ 直接覆寫成 hspec 的 @maxSuccess@,因此
-- @withTests 100@ 寫在 property 上不會生效;等價寫法是
-- @modifyMaxSuccess (const 100)@ 包住整個模組(見 'spec')。
--
-- __尺寸__:所有文字產生器的 'Range' 上限都是常數(最長 16 個字元),節點的
-- 清單欄位上限 3 筆,不產生無界結構。
--
-- __timeout__:整個模組經 'around_' 對每個 example 套 60 秒上限。
module Aapms.Lawful.P027Spec (spec) where

import Data.Aeson (Value (Null))
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, UTCTime (..), fromGregorian)
import System.Timeout (timeout)

import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (assert, forAll, hedgehog, modifyMaxSuccess, (===))

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (..), VaultId (..), newId)
import Aapms.Core.Level (Level (..), Node (..), NodeKind (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta
  ( Meta (..)
  , Revision (..)
  , Source (..)
  , Status (..)
  , Timeline (..)
  , TypeKey (..)
  )
import Aapms.Core.Pack (AiDisclosure (..), Author (..), Pack (..))
import Aapms.Store.Tokenize
  ( FtsRow (..)
  , FtsText (..)
  , SearchRoute (..)
  , cjkMatchExpr
  , cjkRuns
  , cjkSegment
  , ftsPhrase
  , ftsQuoted
  , ftsRowOf
  , hasCjk
  , isCjk
  , matchesQuery
  , rawFtsText
  , routeOf
  , segmentFtsText
  , triMatchExpr
  , usesCjk
  , usesTrigram
  )
import Aapms.Store.Tokenize.Internal (runHits, stripText, upperAscii, wordHits)

--------------------------------------------------------------------------------
-- 產生器

-- | 中日韓字元。刻意混「小字彙池」與「整段碼位範圍」:小池讓查詢與節點內容
-- 有機會真的互相命中(LAW-14 \/ LAW-15 \/ LAW-16 到 LAW-20 才不會恆為
-- @False == False@);碼位範圍蓋住 'isCjk' 宣稱要收的表意文字、假名與諺文。
genCjkChar :: Gen Char
genCjkChar =
  Gen.frequency
    [ (6, Gen.element ("金門建築藥水琳達台灣日本魔法瓶角色主" :: String))
    , (2, Gen.enum '\x4E00' '\x9FFF') -- CJK 統一表意文字
    , (1, Gen.enum '\x3040' '\x30FF') -- 平假名 + 片假名
    , (1, Gen.enum '\xAC00' '\xD7A3') -- 諺文音節
    ]

-- | 非空白的 ASCII 字元。含雙引號,讓 LAW-12 的「內部雙引號加倍」進得了定義域。
genAsciiChar :: Gen Char
genAsciiChar = Gen.element ("abcABCpotionui-_123\"" :: String)

genWsChar :: Gen Char
genWsChar = Gen.element (" \t\n" :: String)

-- | 非空白字元(ASCII 或中日韓)。
genNonSpaceChar :: Gen Char
genNonSpaceChar = Gen.frequency [(1, genCjkChar), (1, genAsciiChar)]

-- | 混合文字:ASCII、中日韓、空白都有。
genText :: Gen Text
genText =
  Gen.text
    (Range.linear 0 16)
    (Gen.frequency [(4, genCjkChar), (4, genAsciiChar), (2, genWsChar)])

-- | 不含任何中日韓字元的文字(池子裡全是 ASCII,@hasCjk@ 因此恆為 @False@)。
genAsciiText :: Gen Text
genAsciiText =
  Gen.text (Range.linear 0 16) (Gen.frequency [(4, genAsciiChar), (1, genWsChar)])

-- | 非空白的短詞,給 LAW-14 的 @w@ 用;長度刻意跨過三個字元的門檻。
genWord :: Gen Text
genWord = Gen.text (Range.linear 0 6) genNonSpaceChar

-- | 一整段中日韓,給 LAW-15 的 @r@ 用(偶爾摻一般文字,因為 law 的定義域是
-- 整個 @Text@)。
genRunText :: Gen Text
genRunText =
  Gen.frequency
    [ (3, Gen.text (Range.linear 1 5) genCjkChar)
    , (1, genText)
    ]

genWs :: Gen Text
genWs = Gen.text (Range.linear 0 3) genWsChar

-- | 前後補上任意空白。去頭尾空白後的內容不變,因此路由與 @given@ 的判定不變。
pad :: Text -> Gen Text
pad core = do
  a <- genWs
  b <- genWs
  pure (a <> core <> b)

-- | @routeOf@ 為 'CjkOnly' 的查詢:去頭尾空白後含中日韓、長度不到三個字元。
-- 直接建構滿足前提的值,不用過濾。
genCjkOnlyQuery :: Gen Text
genCjkOnlyQuery = do
  core <-
    Gen.choice
      [ T.singleton <$> genCjkChar
      , do
          a <- genCjkChar
          b <- genNonSpaceChar
          swap <- Gen.bool
          pure (T.pack (if swap then [a, b] else [b, a]))
      ]
  pad core

-- | @routeOf@ 為 'BothIndexes' 的查詢:去頭尾空白後含中日韓、長度至少三個
-- 字元。做法是把「一定含中日韓的一段」與一到兩段別的內容用單一空白接起來,
-- 兩端都是非空白字元,所以去頭尾空白後長度至少 1 + 1 + 1 = 3。
genBothQuery :: Gen Text
genBothQuery = do
  n <- Gen.int (Range.linear 1 3)
  idx <- Gen.int (Range.linear 0 (n - 1))
  cs <- Gen.list (Range.singleton n) genNonSpaceChar
  c <- genCjkChar
  let cjkChunk = T.pack (setAt idx c cs)
  extra <- Gen.list (Range.linear 1 2) (Gen.text (Range.linear 1 5) genNonSpaceChar)
  front <- Gen.bool
  let parts = if front then cjkChunk : extra else extra <> [cjkChunk]
  pad (T.intercalate " " parts)

-- | 去頭尾空白後為空的查詢(LAW-13 的前提)。
genBlankQuery :: Gen Text
genBlankQuery = Gen.text (Range.linear 0 4) genWsChar

-- | 純 ASCII、去頭尾空白後非空且不到三個字元的查詢(LAW-20 的前提)。
genShortAsciiQuery :: Gen Text
genShortAsciiQuery = do
  core <- Gen.text (Range.linear 1 2) genAsciiChar
  pad core

setAt :: Int -> a -> [a] -> [a]
setAt i x xs = take i xs <> [x] <> drop (i + 1) xs

--------------------------------------------------------------------------------
-- 節點產生器

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

fixedDay :: Day
fixedDay = fromGregorian 2026 1 1

-- | 'Id' 的建構子沒有匯出,一律走 'newId'(smart constructor)。
mkId :: IdPrefix -> Text -> Id
mkId p seed = newId p seed fixedTime 0

genId :: IdPrefix -> Gen Id
genId p = mkId p <$> Gen.text (Range.linear 1 6) Gen.alphaNum

genMeta :: IdPrefix -> Gen Meta
genMeta p = do
  i <- genId p
  title <- genText
  summary <- genText
  tags <- Gen.list (Range.linear 0 3) genText
  aliases <- Gen.list (Range.linear 0 3) genText
  st <- Gen.element [Draft, Canon, Deprecated, Missing]
  src <- Gen.element [Human, Scan, Agent "claude-code", Workshop "character", Ai "gpt"]
  rev <- Revision <$> Gen.int (Range.linear 1 20)
  tl <-
    Gen.maybe
      (Timeline <$> Gen.maybe genText <*> Gen.maybe (Gen.int (Range.linear 0 100)))
  pure
    Meta
      { metaId = i
      , metaVault = VaultId "vlt-00000001"
      , metaType = TypeKey "character-fragment"
      , metaTitle = title
      , metaSummary = summary
      , metaTags = tags
      , metaStatus = st
      , metaTimeline = tl
      , metaAliases = aliases
      , metaLinks = []
      , metaSource = src
      , metaRevision = rev
      , metaCreated = fixedDay
      , metaUpdated = fixedDay
      }

genAnyNode :: Gen AnyNode
genAnyNode =
  Gen.choice
    [ do
        m <- genMeta PEnt
        b <- genText
        pure (NEntity Entity {entMeta = m, entBody = b})
    , do
        m <- genMeta PAst
        nm <- Gen.maybe (LogicalName <$> Gen.text (Range.linear 1 12) genNonSpaceChar)
        b <- genText
        e <- Gen.text (Range.linear 1 8) genAsciiChar
        pure
          ( NAsset
              Asset
                { astMeta = m
                , astName = nm
                , astSha256 = Sha256 "0000000000000000"
                , astEntry = e
                , astExt = Just "png"
                , astKindMeta = Null
                , astLicense = Nothing
                , astAuthor = Nothing
                , astBody = b
                }
          )
    , do
        m <- genMeta PPck
        b <- genText
        v <- Gen.maybe genText
        pure
          ( NPack
              Pack
                { pckMeta = m
                , pckVendor = v
                , pckArchive = Nothing
                , pckSha256 = Nothing
                , pckLicense = Nothing
                , pckAuthor = Just (Author "kenney" Nothing Nothing)
                , pckSourceUrl = Nothing
                , pckAiDisclosure = AiUnknown
                , pckBody = b
                }
          )
    , do
        m <- genMeta PLic
        pure
          ( NLicense
              License
                { licMeta = m
                , licCommercial = True
                , licAttributionRequired = False
                , licCreditText = Nothing
                , licModificationAllowed = Nothing
                , licRedistributionAllowed = Nothing
                , licResaleAllowed = Nothing
                , licNftAllowed = Nothing
                , licSourceUrl = Nothing
                , licFullText = Nothing
                }
          )
    , do
        m <- genMeta PLvl
        pure (NLevel Level {lvlMeta = m, lvlRoot = mkId PNod "root"})
    , do
        m <- genMeta PNod
        k <- Gen.element [KScene, KCast, KCamera, KInteraction, KDialogue, KBranch]
        o <- Gen.int (Range.linear 0 9)
        pure
          ( NNode
              Node
                { nodMeta = m
                , nodLevel = mkId PLvl "lvl"
                , nodParent = Nothing
                , nodOrder = o
                , nodKind = k
                , nodEntities = []
                }
          )
    ]

genFtsText :: Gen FtsText
genFtsText =
  FtsText
    <$> genText
    <*> genText
    <*> genText
    <*> genText
    <*> genText
    <*> genText

--------------------------------------------------------------------------------
-- Example 用的具體節點

baseMeta :: IdPrefix -> Text -> Meta
baseMeta p seed =
  Meta
    { metaId = mkId p seed
    , metaVault = VaultId "vlt-00000001"
    , metaType = TypeKey "character-fragment"
    , metaTitle = ""
    , metaSummary = ""
    , metaTags = []
    , metaStatus = Draft
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = Revision 1
    , metaCreated = fixedDay
    , metaUpdated = fixedDay
    }

exEntity :: Text -> Text -> Text -> [Text] -> [Text] -> Text -> AnyNode
exEntity seed title summary aliases tags body =
  NEntity
    Entity
      { entMeta =
          (baseMeta PEnt seed)
            { metaTitle = title
            , metaSummary = summary
            , metaAliases = aliases
            , metaTags = tags
            }
      , entBody = body
      }

exAsset :: Text -> Maybe Text -> Text -> Text -> AnyNode
exAsset seed name title body =
  NAsset
    Asset
      { astMeta = (baseMeta PAst seed) {metaTitle = title}
      , astName = LogicalName <$> name
      , astSha256 = Sha256 "0000000000000000"
      , astEntry = "a.png"
      , astExt = Just "png"
      , astKindMeta = Null
      , astLicense = Nothing
      , astAuthor = Nothing
      , astBody = body
      }

-- | 含「魔法藥水瓶」的 asset(EX-11、EX-18)。
nPotion :: AnyNode
nPotion = exAsset "potion" Nothing "魔法藥水瓶" ""

-- | @title@ 為「琳達」的角色主體(EX-12、EX-13)。
nLinda :: AnyNode
nLinda = exEntity "linda" "琳達" "" [] [] ""

-- | EX-9 的角色:別名與標籤各兩筆。
nLindaFull :: AnyNode
nLindaFull = exEntity "linda-full" "琳達" "" ["Linda", "琳"] ["角色", "主角"] ""

-- | @name@ 為 @ui_gui_travel-book-frame_001@ 的 asset(EX-10、EX-14、EX-15)。
nTravelFrame :: AnyNode
nTravelFrame = exAsset "travel-frame" (Just "ui_gui_travel-book-frame_001") "" ""

-- | 只有 @travel-book@、沒有 @frame@ 的 asset(EX-16)。
nTravelOnly :: AnyNode
nTravelOnly = exAsset "travel-only" (Just "ui_gui_travel-book_001") "" ""

-- | @title@ 同時含「藥水」與 @potion@(EX-17)。
nMixed :: AnyNode
nMixed = exEntity "mixed" "藥水 potion" "" [] [] ""

-- | 含「金門」與不相鄰的「建築」(EX-19)。
nSplitJinmen :: AnyNode
nSplitJinmen = exEntity "jinmen" "金門" "建築" [] [] ""

-- | 含「台灣」與不相鄰的「建築」(EX-20)。
nSplitTaiwan :: AnyNode
nSplitTaiwan = exEntity "taiwan" "台灣" "建築" [] [] ""

nLevelEx :: AnyNode
nLevelEx =
  NLevel
    Level
      { lvlMeta = (baseMeta PLvl "lvl-ex") {metaTitle = "第一幕", metaSummary = "開場"}
      , lvlRoot = mkId PNod "root"
      }

nNodeEx :: AnyNode
nNodeEx =
  NNode
    Node
      { nodMeta = (baseMeta PNod "nod-ex") {metaTitle = "琳達登場", metaSummary = "對白"}
      , nodLevel = mkId PLvl "lvl-ex"
      , nodParent = Nothing
      , nodOrder = 0
      , nodKind = KDialogue
      , nodEntities = []
      }

-- | 六欄原文,LAW-14 \/ LAW-15 與 EX-10 共用。
fieldsOf :: FtsText -> [Text]
fieldsOf ft =
  [ ftTitle ft
  , ftSummary ft
  , ftBody ft
  , ftAliases ft
  , ftTags ft
  , ftName ft
  ]

--------------------------------------------------------------------------------
-- spec

-- | 每個 example 60 秒上限;逾時視同失敗。
perItemTimeout :: IO () -> IO ()
perItemTimeout act = do
  r <- timeout (60 * 1000000) act
  maybe (expectationFailure "P-027 測試逾時(60 秒)") pure r

spec :: Spec
spec = around_ perItemTimeout . modifyMaxSuccess (const 100) $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-027#LAW-1" $
    it "切出來的每個 token 只由中日韓字元組成,長度是 1 或 2" $
      hedgehog $ do
        t <- forAll genText
        mapM_
          (\tok -> assert (T.all isCjk tok && T.length tok `elem` [1, 2]))
          (T.words (cjkSegment t))

  describe "P-027#LAW-2" $
    it "每個中日韓字元都以一個長度 1 的 token 依原文順序出現" $
      hedgehog $ do
        t <- forAll genText
        mconcat (filter ((== 1) . T.length) (T.words (cjkSegment t)))
          === T.filter isCjk t

  describe "P-027#LAW-3" $
    it "長度 2 的 token 一定落在某一個中日韓連續段裡,不跨段" $
      hedgehog $ do
        t <- forAll genText
        mapM_
          (\tok -> assert (any (T.isInfixOf tok) (cjkRuns t)))
          (filter ((== 2) . T.length) (T.words (cjkSegment t)))

  describe "P-027#LAW-4" $
    it "bigram 的個數是每一段長度減一的總和" $
      hedgehog $ do
        t <- forAll genText
        length (filter ((== 2) . T.length) (T.words (cjkSegment t)))
          === sum (map (pred . T.length) (cjkRuns t))

  describe "P-027#LAW-5" $
    it "不含中日韓字元的文字切出來是空的,分段也是空的" $
      hedgehog $ do
        -- given not (hasCjk t):產生器只用 ASCII 字元池,直接建構滿足前提的值。
        t <- forAll genAsciiText
        assert (not (hasCjk t))
        cjkSegment t === ""
        cjkRuns t === []

  describe "P-027#LAW-6" $
    it "hasCjk 就是「有中日韓字元」,也等價於分段非空" $
      hedgehog $ do
        t <- forAll genText
        hasCjk t === T.any isCjk t
        hasCjk t === not (null (cjkRuns t))

  describe "P-027#LAW-7" $
    it "六欄是純投影:標題與總結逐字,別名與標籤以單一空白接起來" $
      hedgehog $ do
        n <- forAll genAnyNode
        let ft = rawFtsText n
            m = anyMeta n
        ftTitle ft === metaTitle m
        ftSummary ft === metaSummary m
        ftAliases ft === T.unwords (metaAliases m)
        ftTags ft === T.unwords (metaTags m)

  describe "P-027#LAW-8" $
    it "一列的兩份內容:trigram 側是原文,cjk 側是逐欄預切,列的身分是節點 id" $
      hedgehog $ do
        n <- forAll genAnyNode
        frNode (ftsRowOf n) === metaId (anyMeta n)
        frTri (ftsRowOf n) === rawFtsText n
        frCjk (ftsRowOf n) === segmentFtsText (rawFtsText n)

  describe "P-027#LAW-9" $
    it "預切是逐欄套用同一個 cjkSegment" $
      hedgehog $ do
        ft <- forAll genFtsText
        ftTitle (segmentFtsText ft) === cjkSegment (ftTitle ft)
        ftSummary (segmentFtsText ft) === cjkSegment (ftSummary ft)
        ftBody (segmentFtsText ft) === cjkSegment (ftBody ft)
        ftAliases (segmentFtsText ft) === cjkSegment (ftAliases ft)
        ftTags (segmentFtsText ft) === cjkSegment (ftTags ft)
        ftName (segmentFtsText ft) === cjkSegment (ftName ft)

  describe "P-027#LAW-10" $
    it "路由只看去頭尾空白後的字串" $
      hedgehog $ do
        t <- forAll genText
        usesTrigram (routeOf t)
          === (not (hasCjk (stripText t)) || T.length (stripText t) >= 3)
        usesCjk (routeOf t) === hasCjk (stripText t)

  describe "P-027#LAW-11" $
    it "兩個 MATCH 運算式的有無與路由一致" $
      hedgehog $ do
        t <- forAll genText
        isJust (cjkMatchExpr t) === usesCjk (routeOf t)
        isJust (triMatchExpr t) === not (T.null (stripText t))

  describe "P-027#LAW-12" $
    it "字面字串首尾加雙引號;片語是空白正規化後的字面字串" $
      hedgehog $ do
        t <- forAll genText
        assert (T.isPrefixOf "\"" (ftsQuoted t))
        assert (T.isSuffixOf "\"" (ftsQuoted t))
        ftsPhrase t === ftsQuoted (T.unwords (T.words t))

  describe "P-027#LAW-13" $
    it "去頭尾空白後為空的查詢誰都不命中" $
      hedgehog $ do
        -- given null (stripText t):產生器只產空白字元,直接建構滿足前提的值
        -- (前提本身引用 stripText,而它是 stub,無法在測試裡先驗證)。
        t <- forAll genBlankQuery
        n <- forAll genAnyNode
        assert (not (matchesQuery t n))

  describe "P-027#LAW-14" $
    it "一個詞命中 = 它不分大小寫是六欄原文之一的子字串,且長度至少三個字元" $
      hedgehog $ do
        w <- forAll genWord
        n <- forAll genAnyNode
        wordHits w n
          === ( T.length w >= 3
                  && any
                    (T.isInfixOf (upperAscii w))
                    (map upperAscii (fieldsOf (rawFtsText n)))
              )

  describe "P-027#LAW-15" $
    it "一段中日韓命中 = 它以連續子字串出現在六欄原文之一" $
      hedgehog $ do
        r <- forAll genRunText
        n <- forAll genAnyNode
        runHits r n === any (T.isInfixOf r) (fieldsOf (rawFtsText n))

  describe "P-027#LAW-16" $
    it "只查 trigram 時,命中就是「查詢的每一個詞都命中」" $
      hedgehog $ do
        -- given usesTrigram (routeOf t) and not (usesCjk (routeOf t))
        t <- forAll genAsciiText
        n <- forAll genAnyNode
        assert (usesTrigram (routeOf t))
        assert (not (usesCjk (routeOf t)))
        matchesQuery t n
          === ( not (T.null (stripText t))
                  && all (`wordHits` n) (T.words (stripText t))
              )

  describe "P-027#LAW-17" $
    it "只查 cjk 時,命中就是「查詢的每一個中日韓連續段都命中」" $
      hedgehog $ do
        -- given usesCjk (routeOf t) and not (usesTrigram (routeOf t))
        t <- forAll genCjkOnlyQuery
        n <- forAll genAnyNode
        assert (usesCjk (routeOf t))
        assert (not (usesTrigram (routeOf t)))
        matchesQuery t n === all (`runHits` n) (cjkRuns (stripText t))

  describe "P-027#LAW-18" $
    it "兩張都查時,任一邊命中就算命中" $
      hedgehog $ do
        -- given usesCjk (routeOf t) and usesTrigram (routeOf t)
        t <- forAll genBothQuery
        n <- forAll genAnyNode
        assert (usesCjk (routeOf t))
        assert (usesTrigram (routeOf t))
        matchesQuery t n
          === ( all (`wordHits` n) (T.words (stripText t))
                  || all (`runHits` n) (cjkRuns (stripText t))
              )

  describe "P-027#LAW-19" $
    it "純 ASCII 的查詢不分大小寫" $
      hedgehog $ do
        -- given not (hasCjk t)
        t <- forAll genAsciiText
        n <- forAll genAnyNode
        assert (not (hasCjk t))
        matchesQuery t n === matchesQuery (upperAscii t) n

  describe "P-027#LAW-20" $
    it "純 ASCII 的一、二字元查詢在雙索引下必定不命中" $
      hedgehog $ do
        -- given not (hasCjk t) and not (null (stripText t)) and
        -- length (stripText t) < 3:產生器建構「一到兩個非空白 ASCII 字元、
        -- 前後補空白」,去頭尾空白後恰好 1 或 2 個字元。
        t <- forAll genShortAsciiQuery
        n <- forAll genAnyNode
        assert (not (hasCjk t))
        assert (not (matchesQuery t n))

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-027#EX-1" $
    it "空字串、純 ASCII、單一中文" $ do
      cjkSegment "" `shouldBe` ""
      cjkSegment "hello" `shouldBe` ""
      cjkSegment "金" `shouldBe` "金"
      cjkRuns "" `shouldBe` []
      cjkRuns "hello" `shouldBe` []
      hasCjk "" `shouldBe` False
      hasCjk "hello" `shouldBe` False

  describe "P-027#EX-2" $
    it "unigram 在前、bigram 在後" $
      cjkSegment "金門建築" `shouldBe` "金 門 建 築 金門 門建 建築"

  describe "P-027#EX-3" $
    it "不產生跨段的「灣日」" $
      cjkSegment "台灣 日本" `shouldBe` "台 灣 日 本 台灣 日本"

  describe "P-027#EX-4" $
    it "二字詞;長度 1 的 token 串起來是原文" $ do
      cjkSegment "藥水" `shouldBe` "藥 水 藥水"
      mconcat (filter ((== 1) . T.length) (T.words (cjkSegment "藥水")))
        `shouldBe` "藥水"

  describe "P-027#EX-5" $
    it "四種查詢文字的路由" $ do
      routeOf "藥水" `shouldBe` CjkOnly
      routeOf "travel-book" `shouldBe` TrigramOnly
      routeOf "藥水 potion" `shouldBe` BothIndexes
      routeOf "   " `shouldBe` TrigramOnly
      map (\t -> (usesTrigram (routeOf t), usesCjk (routeOf t)))
        ["藥水", "travel-book", "藥水 potion", "   "]
        `shouldBe` [(False, True), (True, False), (True, True), (True, False)]

  describe "P-027#EX-6" $
    it "運算式的有無與三條路由一致" $ do
      triMatchExpr "   " `shouldBe` Nothing
      cjkMatchExpr "travel-book" `shouldBe` Nothing
      isJust (triMatchExpr "藥水") `shouldBe` True

  describe "P-027#EX-7" $
    it "字面字串與片語" $ do
      ftsQuoted "blue-potion" `shouldBe` "\"blue-potion\""
      ftsQuoted "他說\"好\"" `shouldBe` "\"他說\"\"好\"\"\""
      ftsPhrase "  金門   門建  " `shouldBe` "\"金門 門建\""

  describe "P-027#EX-8" $
    it "Level 與 Node 沒有正文,非 asset 沒有邏輯名稱" $ do
      ftBody (rawFtsText nLevelEx) `shouldBe` ""
      ftBody (rawFtsText nNodeEx) `shouldBe` ""
      ftName (rawFtsText nLevelEx) `shouldBe` ""
      ftName (rawFtsText nNodeEx) `shouldBe` ""

  describe "P-027#EX-9" $
    it "別名與標籤以單一空白接起來" $ do
      let ft = rawFtsText nLindaFull
      ftTitle ft `shouldBe` "琳達"
      ftAliases ft `shouldBe` "Linda 琳"
      ftTags ft `shouldBe` "角色 主角"

  describe "P-027#EX-10" $
    it "一列的兩份內容" $ do
      let row = ftsRowOf nTravelFrame
          raw = rawFtsText nTravelFrame
      frNode row `shouldBe` metaId (anyMeta nTravelFrame)
      frTri row `shouldBe` raw
      map ($ frCjk row) [ftTitle, ftSummary, ftBody, ftAliases, ftTags, ftName]
        `shouldBe` map cjkSegment (fieldsOf raw)
      ftName (frCjk row) `shouldBe` ""

  describe "P-027#EX-11" $
    it "二字中文命中(契約卡驗收標準)" $ do
      routeOf "藥水" `shouldBe` CjkOnly
      matchesQuery "藥水" nPotion `shouldBe` True

  describe "P-027#EX-12" $
    it "判斷對象是去頭尾空白後的字串" $ do
      matchesQuery "琳達" nLinda `shouldBe` True
      matchesQuery "  琳達  " nLinda `shouldBe` True
      matchesQuery "  琳達  " nLinda `shouldBe` matchesQuery "琳達" nLinda

  describe "P-027#EX-13" $
    it "空查詢一律不命中" $
      map (\(t, n) -> matchesQuery t n)
        [("", nLinda), ("   ", nLinda), ("", nPotion), ("   ", nPotion)]
        `shouldBe` [False, False, False, False]

  describe "P-027#EX-14" $
    it "英文子字串走 trigram,不分大小寫,- 不被當成運算子" $ do
      matchesQuery "travel-book" nTravelFrame `shouldBe` True
      matchesQuery "TRAVEL-BOOK" nTravelFrame `shouldBe` True
      matchesQuery "TRAVEL-BOOK" nTravelFrame
        `shouldBe` matchesQuery "travel-book" nTravelFrame

  describe "P-027#EX-15" $
    it "純 ASCII 二字查詢必定不命中" $
      matchesQuery "ui" nTravelFrame `shouldBe` False

  describe "P-027#EX-16" $
    it "每個詞都要出現" $
      matchesQuery "travel-book frame" nTravelOnly `shouldBe` False

  describe "P-027#EX-17" $
    it "兩張都查時任一邊命中就算命中" $ do
      routeOf "藥水 potion" `shouldBe` BothIndexes
      matchesQuery "藥水 potion" nMixed `shouldBe` True

  describe "P-027#EX-18" $
    it "四字查詢走兩張表,cjk 那一側命中" $ do
      routeOf "魔法藥水" `shouldBe` BothIndexes
      matchesQuery "魔法藥水" nPotion `shouldBe` True

  describe "P-027#EX-19" $
    it "每一段中日韓要以連續子字串出現" $
      matchesQuery "金門建築" nSplitJinmen `shouldBe` False

  describe "P-027#EX-20" $
    it "段與段之間是 AND,段內才要求連續" $
      matchesQuery "台灣 建築" nSplitTaiwan `shouldBe` True
