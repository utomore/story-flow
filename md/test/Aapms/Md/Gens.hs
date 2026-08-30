-- | graph-core\/F004(重跑)測試共用的 Hedgehog 產生器。
--
-- __委派備註__:本檔與所有 import 它的 @*LawsSpec@ 模組一樣,依賴
-- @hedgehog@ 套件,而 @md\/aapms-md.cabal@ 的 @test-suite@ 目前__還沒有__這項
-- 相依(qa 依委派規則不得自行修改 cabal)。這些檔案因此__未被列進__
-- @other-modules@,本次委派也就無法用 @cabal build@ 實際編譯\/執行它們——
-- 詳細清單見回報。
--
-- 產生器的設計原則(呼應 spec 的「數據」段):
--
-- * 'genMetaOverride' \/ 'genMeta' 涵蓋 'Aapms.Core.Meta.Meta' 全部欄位,文字
--   欄位混 ASCII \/ CJK \/ 空白(store\/test 既有慣例)
-- * 'genValue' 深度上限 1,對應 fixture(@meta: {width: 256, height: 192}@)的
--   巢狀程度,足以驗證 'Aapms.Md.Render.NewAsset' 的 @naKindMeta@ 往返不失真
-- * __型別專屬條目(extras)只生成單行條目__:一個「頂層條目」在 spec 的定義裡
--   可以是多行(縮排延續),但多行分組規則不是本 feature 的產生器該猜的細節
--   ——多行案例由 spec 的 Example 8(逐字釘死)覆蓋,property test 只覆蓋
--   「每個條目恰好一行」這個子定義域,在檔案內的註解會重申這個範圍限縮
module Aapms.Md.Gens
  ( -- * 基礎文字
    genSafeText
  , genNonEmptySafeText
  , genEntryText
  , genHex8
  , genDay

    -- * core 型別
  , genId
  , genRef
  , genVaultId
  , genTypeKey
  , genReservedTypeKey
  , genStatus
  , genSource
  , genTimeline
  , genRevision
  , genLinkKind
  , genLink
  , genTagsList
  , genLinksList
  , genMeta
  , genNodeKind

    -- * md 型別
  , genMetaOverride
  , genOverrideFn
  , patchOverride
  , genValue
  , genNewAsset
  , genNewLicense
  , genNewNode
  , genNewSectionPayload
  , genLineEnding
  , genSectionIdOf

    -- * MetaExtras(單行條目子定義域)
  , extraKeyPool
  , genMetaExtrasSubset
  , genExtrasFn
  ) where

import Data.Aeson (Value (..), toJSON)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian)
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Aapms.Core.Asset (LogicalName (..), Sha256 (..))
import Aapms.Core.Id (Id, IdPrefix (..), Ref (..), VaultId (..), parseId, renderIdPrefix)
import Aapms.Core.Level (NodeKind, allNodeKinds)
import Aapms.Core.Link (Link (..), LinkKind (..), coreLinkKinds)
import Aapms.Core.Meta
import Aapms.Md

-- 基礎文字 ---------------------------------------------------------------

genCjkChar :: Gen Char
genCjkChar = Gen.enum '\x4E00' '\x9FFF'

genSafeChar :: Gen Char
genSafeChar = Gen.choice [Gen.alpha, Gen.digit, pure ' ', genCjkChar]

-- | 一般文字(標題\/摘要\/別名……):ASCII 字母數字、空白、CJK 混合。
genSafeText :: Gen Text
genSafeText = Gen.text (Range.linear 0 12) genSafeChar

genNonEmptySafeText :: Gen Text
genNonEmptySafeText = Gen.text (Range.linear 1 12) genSafeChar

-- | 'Aapms.Md.Render.NewAsset' 的 @entry@:路徑形狀的文字。
genEntryText :: Gen Text
genEntryText =
  Gen.text (Range.linear 1 16) (Gen.choice [Gen.alphaNum, Gen.element ("/_-." :: String)])

genHex8 :: Gen Text
genHex8 = T.pack <$> Gen.list (Range.singleton 8) (Gen.element (['0' .. '9'] ++ ['a' .. 'f']))

genDay :: Gen Day
genDay =
  fromGregorian
    <$> Gen.integral (Range.linear 2000 2030)
    <*> Gen.int (Range.linear 1 12)
    <*> Gen.int (Range.linear 1 28)

-- core 型別 ----------------------------------------------------------------

genId :: IdPrefix -> Gen Id
genId p = do
  h <- genHex8
  case parseId (renderIdPrefix p <> "-" <> h) of
    Right (_, i) -> pure i
    Left e -> error ("Aapms.Md.Gens.genId: parseId 不該失敗:" <> show e)

genRef :: IdPrefix -> Gen Ref
genRef p = Ref Nothing <$> genId p

genVaultId :: Gen VaultId
genVaultId = VaultId <$> genNonEmptySafeText

-- | 一般型別鍵。__不會__產生三個保留字(@level@ \/ @asset-pack@ \/
-- @asset-license@)——那三個字面值由 'genReservedTypeKey' 專門覆蓋
-- ('Aapms.Md.DocKindLawSpec' 的 LAW-22 用)。
genTypeKey :: Gen TypeKey
genTypeKey = Gen.filter (`notElem` reserved) (TypeKey <$> genNonEmptySafeText)
  where
    -- TypeKey 沒有 IsString 實例(newtype,建構子才是唯一入口),字面值一律
    -- 用 TypeKey 建構,不能靠 OverloadedStrings 直接寫成 [Text] 字面值清單。
    reserved = [TypeKey "level", TypeKey "asset-pack", TypeKey "asset-license"]

genReservedTypeKey :: Gen TypeKey
genReservedTypeKey = TypeKey <$> Gen.element ["level", "asset-pack", "asset-license"]

genStatus :: Gen Status
genStatus = Gen.enumBounded

genSource :: Gen Source
genSource =
  Gen.choice
    [ pure Human
    , Agent <$> genNonEmptySafeText
    , Workshop <$> genNonEmptySafeText
    , pure Scan
    , Ai <$> genNonEmptySafeText
    ]

genTimeline :: Gen Timeline
genTimeline = Timeline <$> Gen.maybe genNonEmptySafeText <*> Gen.maybe (Gen.int (Range.linear 0 100))

genRevision :: Gen Revision
genRevision = Revision <$> Gen.int (Range.linear 1 20)

genLinkKind :: Gen LinkKind
genLinkKind = Gen.choice (map pure coreLinkKinds ++ [Custom <$> genNonEmptySafeText])

genLink :: Gen Link
genLink = Link <$> genLinkKind <*> genRef PEnt <*> Gen.maybe genNonEmptySafeText

genTagsList :: Gen [Text]
genTagsList = Gen.list (Range.linear 0 3) genNonEmptySafeText

genLinksList :: Gen [Link]
genLinksList = Gen.list (Range.linear 0 3) genLink

genNodeKind :: Gen NodeKind
genNodeKind = Gen.element allNodeKinds

-- | 完整 'Meta'。id 用 'PEnt' 前綴——呼叫端要另一種前綴時自行覆蓋 'metaId'。
genMeta :: Gen Meta
genMeta =
  Meta
    <$> genId PEnt
    <*> genVaultId
    <*> genTypeKey
    <*> genNonEmptySafeText
    <*> genSafeText
    <*> genTagsList
    <*> genStatus
    <*> Gen.maybe genTimeline
    <*> genTagsList
    <*> genLinksList
    <*> genSource
    <*> genRevision
    <*> genDay
    <*> genDay

-- md 型別 -------------------------------------------------------------------

genMetaOverride :: Gen MetaOverride
genMetaOverride =
  MetaOverride
    <$> Gen.maybe genNodeKind
    <*> Gen.maybe genTypeKey
    <*> Gen.maybe genVaultId
    <*> Gen.maybe genSafeText
    <*> Gen.maybe genTagsList
    <*> Gen.maybe genStatus
    <*> Gen.maybe genTimeline
    <*> Gen.maybe genTagsList
    <*> Gen.maybe genLinksList
    <*> Gen.maybe genSource
    <*> Gen.maybe genRevision
    <*> Gen.maybe genDay
    <*> Gen.maybe genDay

-- | 只覆蓋 patch 裡是 'Just' 的欄位,其餘保留原值——這是 'MetaOverride' 語意
-- 上唯一自然的合併規則(與 'Aapms.Md.Inherit.applyOverride' 的「@Nothing@ 保留
-- 原值」同一個精神)。
patchOverride :: MetaOverride -> MetaOverride -> MetaOverride
patchOverride patch ov =
  MetaOverride
    { moKind = orElse (moKind patch) (moKind ov)
    , moType = orElse (moType patch) (moType ov)
    , moVault = orElse (moVault patch) (moVault ov)
    , moSummary = orElse (moSummary patch) (moSummary ov)
    , moTags = orElse (moTags patch) (moTags ov)
    , moStatus = orElse (moStatus patch) (moStatus ov)
    , moTimeline = orElse (moTimeline patch) (moTimeline ov)
    , moAliases = orElse (moAliases patch) (moAliases ov)
    , moLinks = orElse (moLinks patch) (moLinks ov)
    , moSource = orElse (moSource patch) (moSource ov)
    , moRevision = orElse (moRevision patch) (moRevision ov)
    , moCreated = orElse (moCreated patch) (moCreated ov)
    , moUpdated = orElse (moUpdated patch) (moUpdated ov)
    }
  where
    orElse (Just x) _ = Just x
    orElse Nothing y = y

-- | 「任一 @f :: MetaOverride -> MetaOverride@」的代表性取樣:隨機產生一份
-- patch,'f' 是「用 patch 裡有值的欄位覆蓋、其餘不動」。涵蓋 no-op(全
-- 'Nothing')到整份替換(全 'Just')的連續光譜。
--
-- __呼叫端注意__:'Hedgehog.forAll' 要求產生的值有 'Show'(失敗時才印得出
-- 反例),函式沒有 'Show' 實例,所以__不能__直接 @forAll genOverrideFn@。
-- 呼叫端請改成 @patch \<- forAll genMetaOverride; let f = patchOverride patch@
-- ——'patchOverride' 因此也匯出。本函式保留是給不透過 hedgehog、已經有
-- 'MetaOverride -> MetaOverride' 值的呼叫情境用。
genOverrideFn :: Gen (MetaOverride -> MetaOverride)
genOverrideFn = patchOverride <$> genMetaOverride

-- | 深度上限 1 的 'Value':涵蓋純量、單層陣列、單層物件——對齊
-- fixture 裡 @meta: {width: 256, height: 192}@ 的巢狀程度。
genValue :: Int -> Gen Value
genValue depth
  | depth <= 0 = leaf
  | otherwise = Gen.choice [leaf, container]
  where
    leaf =
      Gen.choice
        [ pure Null
        , toJSON <$> Gen.bool
        , toJSON <$> Gen.int (Range.linear (-1000) 1000)
        , toJSON <$> genSafeText
        ]
    container =
      Gen.choice
        [ toJSON <$> Gen.list (Range.linear 0 3) (genValue (depth - 1))
        , toJSON . M.fromList <$> Gen.list (Range.linear 0 3) ((,) <$> genFieldKey <*> genValue (depth - 1))
        ]
    genFieldKey :: Gen Text
    genFieldKey = Gen.text (Range.linear 1 6) Gen.alpha

genNewAsset :: Gen NewAsset
genNewAsset =
  NewAsset
    <$> Gen.maybe (LogicalName <$> genNonEmptySafeText)
    <*> (Sha256 <$> genHex8)
    <*> genEntryText
    <*> Gen.maybe genNonEmptySafeText
    <*> genValue 1
    <*> Gen.maybe (genRef PLic)
    <*> Gen.maybe genNonEmptySafeText

genNewLicense :: Gen NewLicense
genNewLicense =
  NewLicense
    <$> Gen.bool
    <*> Gen.bool
    <*> Gen.maybe genSafeText
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe Gen.bool
    <*> Gen.maybe genSafeText

genNewNode :: Gen NewNode
genNewNode = NewNode <$> Gen.element allNodeKinds

genNewSectionPayload :: Gen NewSectionPayload
genNewSectionPayload =
  Gen.choice
    [ NSFragment <$> genMetaOverride
    , NSAsset <$> genMetaOverride <*> genNewAsset
    , NSLicense <$> genMetaOverride <*> genNewLicense
    , NSNode <$> genMetaOverride <*> genNewNode
    ]

genLineEnding :: Gen LineEnding
genLineEnding = Gen.element [LF, CRLF]

-- | 從既有 'Document' 裡挑一個既有的節 id(呼叫端保證 @docSections@ 非空)。
genSectionIdOf :: Document -> Gen Id
genSectionIdOf = Gen.element . sectionIds

-- MetaExtras(單行條目子定義域,見檔頭說明)-------------------------------

-- | 五個不在 'metaFieldOrder' 裡的合成鍵。
extraKeyPool :: [Text]
extraKeyPool = ["battle_power", "custom_a", "custom_b", "custom_c", "custom_d"]

-- | 'extraKeyPool' 的隨機子集,每個鍵恰好一行、值與鍵本身綁定(方便斷言
-- 「這一行來自哪個鍵」),子集內部順序隨機重排以涵蓋不同的原始序。
genMetaExtrasSubset :: Gen MetaExtras
genMetaExtrasSubset = do
  flags <- mapM (const Gen.bool) extraKeyPool
  let chosen = [k | (k, True) <- zip extraKeyPool flags]
  shuffled <- Gen.shuffle chosen
  pure (MetaExtras [k <> ": v_" <> k | k <- shuffled])

-- | 「任一 @g :: MetaExtras -> MetaExtras@」的代表性取樣,取實際呼叫端
-- (spec Example 7)的真實用法:'mergeExtras' 部分套用。
--
-- __呼叫端注意__:同 'genOverrideFn',函式沒有 'Show',不能直接
-- @forAll genExtrasFn@。改成
-- @patch \<- forAll genMetaExtrasSubset; let g = mergeExtras patch@
-- ('mergeExtras' 是 "Aapms.Md.Render" 的公開介面,由 "Aapms.Md" 匯出)。
genExtrasFn :: Gen (MetaExtras -> MetaExtras)
genExtrasFn = mergeExtras <$> genMetaExtrasSubset
