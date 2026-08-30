-- | graph-core\/F008:'Aapms.Store.Node' 的五個純函式(受測範圍指定的內部模組),
-- 外加 'Aapms.Store.Create.sanitizeFileName'(檔名淨化,同樣是純函式,獨立於
-- "Aapms.Store.CreateSpec" 之外收在這裡)。__命名避開既有的 F006 "Aapms.Store.NodeSpec"__。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F008-store-write-operations.md@,
-- 2026-08-25 第二輪裁決後的版本:GAP-13 改寫 LAW-20、fixture 依編排者歸因修正)
--
-- @
-- LAW-20  sanitizeFileName 的值域(GAP-13 裁決後改寫)          -> prop_LAW20 / test_EX11 / test_EX19 / test_EX20 / test_EX21
-- LAW-21  headingDepthFor                                   -> prop_LAW21
-- LAW-22  subtreeIds 與 subtreeAfter 一致                   -> prop_LAW22
-- LAW-23  validateLevelDoc 等價於兩段驗證                    -> prop_LAW23
-- LAW-24  isRootNode 的三種結果(2026-08-25 GAP-9 裁決補入)     -> prop_LAW24 / test_EX18
-- EX-11  sanitizeFileName "第一章: 序幕 " "ent-7f3b2a91"    -> test_EX11
-- EX-12  UnderParent 正常路徑(headingDepthFor 部分)        -> 見 Aapms.Store.CreateSpec EX-12
-- EX-13  UnderParent 父節點不存在(headingDepthFor 部分)    -> 見 Aapms.Store.CreateSpec EX-13(此檔另以 headingDepthFor 直接驗證)
-- EX-14  UnderParent 父節點已達六級(headingDepthFor 部分)  -> 見 Aapms.Store.CreateSpec EX-14(此檔另以 headingDepthFor 直接驗證)
-- EX-18  isRootNode 三分支各一(根/非根/不存在)             -> test_EX18
-- EX-19  sanitizeFileName 全空白\/全句點 → fb              -> test_EX19
-- EX-20  sanitizeFileName 全非法字元 → 對應數量的 "-"       -> test_EX20
-- EX-21  sanitizeFileName 合法字元原樣回傳(含詞中空白)      -> test_EX21
-- @
--
-- __編排者歸因(第二輪)__:'goodLevelMd' 原本從三級標題直接跳到六級(@HeadingSkip 3 6@),
-- 不是合法的 Level 檔——ADR-009「標題階層即樹」下標題階層必須逐級遞增,不能跳級。已改成
-- 序幕(2)→開場(3)→深一(4)→深二(5)→最深(6)、收束(3,與開場同層的兄弟,在整條深鏈之後)
-- 逐級鋪下去。
--
-- 'Aapms.Store.Node.isRootNode' 曾經__沒有獨立的 Law 或 Example__(spec-gaps GAP-9),
-- 2026-08-25 開發者裁決補上 LAW-24 與 EX-18:id 不在文件裡時回 @Left (SectionMissing path id)@,
-- 與 'headingDepthFor'(LAW-21)對稱——「查無此節」與「這個節不是根」是兩件不同的事。
module Aapms.Store.NodeSpec2 (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Md.Document (Document (..), Section (..))
import Aapms.Md.Parse (parseDocument)
import Aapms.Store.Create (sanitizeFileName)
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Fixtures (idOf)
import Aapms.Store.Node (headingDepthFor, isRootNode, subtreeAfter, subtreeIds, validateLevelDoc)

--------------------------------------------------------------------------------
-- 固定的 Level 檔文字素材(純文字,parseDocument 得到 Document,無需開 vault)。

levelFilePath :: FilePath
levelFilePath = "levels/node-spec2-fixture.md"

-- | 合法的 Level 檔,標題階層__逐級遞增__(ADR-009,不可跳級):
--
-- @
-- 序幕(2,根)
--   └ 開場(3)
--       └ 深一(4)
--           └ 深二(5)
--               └ 最深(6,覆蓋 LAW-21 的深度上限邊界)
-- 收束(3,與開場同層的兄弟,整條深鏈之後)
-- @
goodLevelMd :: Text
goodLevelMd =
  T.unlines
    [ "---"
    , "id: lvl-90000001"
    , "vault: liftgame"
    , "type: level"
    , "title: NodeSpec2 場景"
    , "summary: headingDepthFor / subtreeAfter / subtreeIds / validateLevelDoc 用"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "場景整體說明。"
    , ""
    , "## 序幕 {#nod-90000001}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "### 開場 {#nod-90000002}"
    , ""
    , "```meta"
    , "kind: cast"
    , "```"
    , ""
    , "#### 深一 {#nod-90000005}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "##### 深二 {#nod-90000006}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "###### 最深 {#nod-90000004}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "### 收束 {#nod-90000003}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    ]

-- | 結構壞掉的 Level 檔:兩個 2 級標題,依 ADR-009(標題階層即樹)兩者皆無 parent,
-- 'Aapms.Core.Tree.buildTree' 應回 'Aapms.Core.Tree.MultipleRoots'。
multiRootLevelMd :: Text
multiRootLevelMd =
  T.unlines
    [ "---"
    , "id: lvl-91000001"
    , "vault: liftgame"
    , "type: level"
    , "title: NodeSpec2 雙根場景"
    , "summary: validateLevelDoc 的 TreeInvalidOnWrite 分支用"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "場景整體說明。"
    , ""
    , "## 序幕 {#nod-91000001}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "## 尾聲 {#nod-91000002}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    ]

goodDoc :: Document
goodDoc = case parseDocument goodLevelMd of
  Right d -> d
  Left e -> error ("NodeSpec2 fixture 解析失敗:" <> show e)

multiRootDoc :: Document
multiRootDoc = case parseDocument multiRootLevelMd of
  Right d -> d
  Left e -> error ("NodeSpec2 multi-root fixture 解析失敗:" <> show e)

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "graph-core/F008 Aapms.Store.Node (內部模組) + sanitizeFileName" $ do
  describe "LAW-21: headingDepthFor" $ do
    it "對 goodLevelMd 裡每一個實際存在的節點,結果等於 secLevel + 1(或超過六級時回 NodeDepthExceeded)" $
      forM_ (docSections goodDoc) $ \sec -> do
        let expectedLevel = secLevel sec + 1
            got = headingDepthFor levelFilePath goodDoc (secId sec)
        if expectedLevel > 6
          then got `shouldBe` Left (NodeDepthExceeded (secId sec) expectedLevel)
          else got `shouldBe` Right expectedLevel

    it "父節點不在文件裡時回 Left (SectionMissing _ p)" $ do
      let missing = idOf "nod-99999999"
      headingDepthFor levelFilePath goodDoc missing `shouldBe` Left (SectionMissing levelFilePath missing)

    it "EX-14 對應:六級標題(最深)底下再插入,回 NodeDepthExceeded _ 7" $
      headingDepthFor levelFilePath goodDoc (idOf "nod-90000004")
        `shouldBe` Left (NodeDepthExceeded (idOf "nod-90000004") 7)

  describe "LAW-22: subtreeIds 與 subtreeAfter 一致" $ do
    it "對文件裡每一個實際節點與一個不存在的 id 都滿足 subtreeIds == i : map secId (subtreeAfter …),且子樹每節 secLevel 都嚴格大於 i 的 secLevel" $ do
      let ids = map secId (docSections goodDoc) ++ [idOf "nod-99999999"]
      forM_ ids $ \i -> do
        let after = subtreeAfter goodDoc i
        subtreeIds goodDoc i `shouldBe` i : map secId after
        case [s | s <- docSections goodDoc, secId s == i] of
          (self : _) -> forM_ after $ \s -> secLevel s `shouldSatisfy` (> secLevel self)
          [] -> after `shouldBe` [] -- haddock:「節不存在時是空清單」

    it "序幕(根,2級)的子樹依序是開場、深一、深二、最深、收束(五節皆在其後且 secLevel > 2)" $
      map secId (subtreeAfter goodDoc (idOf "nod-90000001"))
        `shouldBe` [idOf "nod-90000002", idOf "nod-90000005", idOf "nod-90000006", idOf "nod-90000004", idOf "nod-90000003"]

    it "開場(3級)的子樹是深一、深二、最深(收束是它的兄弟,3級不 >3,不算子節點)" $
      map secId (subtreeAfter goodDoc (idOf "nod-90000002"))
        `shouldBe` [idOf "nod-90000005", idOf "nod-90000006", idOf "nod-90000004"]

    it "收束(3級,檔尾)的子樹為空" $
      subtreeAfter goodDoc (idOf "nod-90000003") `shouldBe` []

  describe "LAW-23: validateLevelDoc 等價於「toLevel 成功且 buildTree 回 Right」" $ do
    it "合法的 Level 檔:validateLevelDoc 回 Right ()" $
      validateLevelDoc levelFilePath goodDoc `shouldBe` Right ()

    it "雙根的 Level 檔:validateLevelDoc 回 Left (TreeInvalidOnWrite _ _)" $
      case validateLevelDoc "levels/node-spec2-multiroot.md" multiRootDoc of
        Left (TreeInvalidOnWrite fp _) -> fp `shouldBe` "levels/node-spec2-multiroot.md"
        other -> expectationFailure ("預期 Left (TreeInvalidOnWrite _ _),得到 " <> show other)

  describe "LAW-24 / EX-18: isRootNode 的三種結果(2026-08-25 GAP-9 裁決)" $ do
    it "EX-18 之一:id 是根(序幕,文件裡第一個節)→ Right True" $
      isRootNode levelFilePath goodDoc (idOf "nod-90000001") `shouldBe` Right True

    it "EX-18 之二:id 存在但不是根(開場)→ Right False" $
      isRootNode levelFilePath goodDoc (idOf "nod-90000002") `shouldBe` Right False

    it "EX-18 之三:id 不在文件裡 → Left (SectionMissing path id),不是 Right False(與 headingDepthFor 對稱)" $ do
      let missing = idOf "nod-99999999"
      isRootNode levelFilePath goodDoc missing `shouldBe` Left (SectionMissing levelFilePath missing)

    it "LAW-24:對文件裡每一個實際節點,isRootNode 恰為 Right (secId == 該檔第一個節的 id)" $
      forM_ (docSections goodDoc) $ \sec -> do
        let firstId = secId (head (docSections goodDoc))
            expected = secId sec == firstId
        isRootNode levelFilePath goodDoc (secId sec) `shouldBe` Right expected

  describe "LAW-20 / EX-11 / EX-19 / EX-20 / EX-21: sanitizeFileName(2026-08-25 GAP-13 裁決:替換策略,清空定義收窄)" $ do
    it "EX-11: sanitizeFileName \"第一章: 序幕 \" \"ent-7f3b2a91\" == \"第一章- 序幕\"" $
      sanitizeFileName "第一章: 序幕 " "ent-7f3b2a91" `shouldBe` "第一章- 序幕"

    it "EX-19: 全空白 / 全句點的 t 才算被清空 → 回 fb" $ do
      sanitizeFileName "   " "ent-7f3b2a91" `shouldBe` "ent-7f3b2a91"
      sanitizeFileName "..." "ent-7f3b2a91" `shouldBe` "ent-7f3b2a91"

    it "EX-20: 全非法字元 → 對應數量的 \"-\"(不是 fb;GAP-13 裁決的分岔點)" $ do
      sanitizeFileName "<" "ent-7f3b2a91" `shouldBe` "-"
      sanitizeFileName "<>?" "ent-7f3b2a91" `shouldBe` "---"

    it "EX-21: 只含合法字元、無頭尾空白/句點時逐字回傳(含詞中空白)" $
      sanitizeFileName "琳達 的筆記" "ent-7f3b2a91" `shouldBe` "琳達 的筆記"

    it "LAW-20 第 2 條:t 的每個字元都是空白或句點時(機械定義的「被清空」),結果等於 fb" $
      hedgehog $ do
        fb <- forAll genFallback
        blanked <- forAll (Gen.text (Range.linear 0 10) genBlankOrDot)
        sanitizeFileName blanked fb === fb

    it "LAW-20 第 4 條:t 只含合法字元且無頭尾空白/句點時結果等於 t" $
      hedgehog $ do
        fb <- forAll genFallback
        t <- forAll genCleanName
        sanitizeFileName t fb === t

    it "LAW-20 第 1 條:對任意 t 與合法 fb,結果不含非法字元/控制字元,且不以空白或句點開頭/結尾" $
      hedgehog $ do
        fb <- forAll genFallback
        t <- forAll genMixedName
        let r = sanitizeFileName t fb
        assert (T.all (`notElem` illegalChars) r)
        assert (T.all (\c -> c >= ' ') r || T.null r)
        if not (T.null r)
          then do
            assert (T.head r /= ' ' && T.head r /= '.')
            assert (T.last r /= ' ' && T.last r /= '.')
          else success

    it "LAW-20 第 3 條:t 只由非法字元組成時,r 是對應數量的 \"-\"(不算被清空,不回 fb)" $
      hedgehog $ do
        fb <- forAll genFallback
        n <- forAll (Gen.int (Range.linear 1 8))
        t <- forAll (Gen.text (Range.singleton n) (Gen.element illegalChars))
        sanitizeFileName t fb === T.replicate n "-"

--------------------------------------------------------------------------------
-- sanitizeFileName 用的產生器

illegalChars :: [Char]
illegalChars = "<>:\"/\\|?*"

genFallback :: Gen Text
genFallback = Gen.text (Range.linear 1 12) (Gen.element (['a' .. 'z'] ++ ['0' .. '9']))

-- | LAW-20 第 2 條「被清空」的機械定義:__只__由空白或句點組成(GAP-13 裁決收窄,不再含非法字元)。
genBlankOrDot :: Gen Char
genBlankOrDot = Gen.element (" ." :: String)

-- | 合法、不含頭尾空白\/句點的檔名字元(中文與 ASCII 字母數字)。
genCleanChar :: Gen Char
genCleanChar = Gen.choice [Gen.alphaNum, Gen.enum '\x4E00' '\x9FFF']

-- | 'genCleanChar' 本身就不含空白\/句點\/非法字元,直接串接即滿足「無頭尾空白」。
genCleanName :: Gen Text
genCleanName = Gen.text (Range.linear 1 10) genCleanChar

genMixedName :: Gen Text
genMixedName =
  Gen.text (Range.linear 0 20) (Gen.choice [genCleanChar, Gen.element illegalChars, Gen.element (" ." :: String)])
