-- | graph-core\/F008:'Aapms.Store.Node' 的五個純函式(受測範圍指定的內部模組),
-- 外加 'Aapms.Store.Create.sanitizeFileName'(檔名淨化,同樣是純函式,獨立於
-- "Aapms.Store.CreateSpec" 之外收在這裡)。__命名避開既有的 F006 "Aapms.Store.NodeSpec"__。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F008-store-write-operations.md@)
--
-- @
-- L20  sanitizeFileName 的值域                          -> prop_L20 / test_E11
-- L21  headingDepthFor                                   -> prop_L21
-- L22  subtreeIds 與 subtreeAfter 一致                   -> prop_L22
-- L23  validateLevelDoc 等價於兩段驗證                    -> prop_L23
-- L24  isRootNode 的三種結果(2026-08-25 G9 裁決補入)     -> prop_L24 / test_E18
-- E11  sanitizeFileName "第一章: 序幕 " "ent-7f3b2a91"    -> test_E11
-- E12  UnderParent 正常路徑(headingDepthFor 部分)        -> 見 Aapms.Store.CreateSpec E12
-- E13  UnderParent 父節點不存在(headingDepthFor 部分)    -> 見 Aapms.Store.CreateSpec E13(此檔另以 headingDepthFor 直接驗證)
-- E14  UnderParent 父節點已達六級(headingDepthFor 部分)  -> 見 Aapms.Store.CreateSpec E14(此檔另以 headingDepthFor 直接驗證)
-- E18  isRootNode 三分支各一(根/非根/不存在)             -> test_E18
-- @
--
-- 'Aapms.Store.Node.isRootNode' 曾經__沒有獨立的 Law 或 Example__(spec-gaps G9),
-- 2026-08-25 開發者裁決補上 L24 與 E18:id 不在文件裡時回 @Left (SectionMissing path id)@,
-- 與 'headingDepthFor'(L21)對稱——「查無此節」與「這個節不是根」是兩件不同的事。
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

-- | 合法的 Level 檔:序幕(2級,根)→ 開場(3級)、收束(3級,與開場同層的兄弟)→
-- 最深(6級,緊接收束之後,用來覆蓋 L21 的深度上限邊界)。
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
    , "### 收束 {#nod-90000003}"
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
  describe "L21: headingDepthFor" $ do
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

    it "E14 對應:六級標題(最深)底下再插入,回 NodeDepthExceeded _ 7" $
      headingDepthFor levelFilePath goodDoc (idOf "nod-90000004")
        `shouldBe` Left (NodeDepthExceeded (idOf "nod-90000004") 7)

  describe "L22: subtreeIds 與 subtreeAfter 一致" $ do
    it "對文件裡每一個實際節點與一個不存在的 id 都滿足 subtreeIds == i : map secId (subtreeAfter …),且子樹每節 secLevel 都嚴格大於 i 的 secLevel" $ do
      let ids = map secId (docSections goodDoc) ++ [idOf "nod-99999999"]
      forM_ ids $ \i -> do
        let after = subtreeAfter goodDoc i
        subtreeIds goodDoc i `shouldBe` i : map secId after
        case [s | s <- docSections goodDoc, secId s == i] of
          (self : _) -> forM_ after $ \s -> secLevel s `shouldSatisfy` (> secLevel self)
          [] -> after `shouldBe` [] -- haddock:「節不存在時是空清單」

    it "序幕(根,2級)的子樹依序是開場、收束、最深(三節皆在其後且 secLevel > 2)" $
      map secId (subtreeAfter goodDoc (idOf "nod-90000001"))
        `shouldBe` [idOf "nod-90000002", idOf "nod-90000003", idOf "nod-90000004"]

    it "開場(3級)的子樹為空(收束緊接其後但同為 3 級,不是子節點)" $
      subtreeAfter goodDoc (idOf "nod-90000002") `shouldBe` []

  describe "L23: validateLevelDoc 等價於「toLevel 成功且 buildTree 回 Right」" $ do
    it "合法的 Level 檔:validateLevelDoc 回 Right ()" $
      validateLevelDoc levelFilePath goodDoc `shouldBe` Right ()

    it "雙根的 Level 檔:validateLevelDoc 回 Left (TreeInvalidOnWrite _ _)" $
      case validateLevelDoc "levels/node-spec2-multiroot.md" multiRootDoc of
        Left (TreeInvalidOnWrite fp _) -> fp `shouldBe` "levels/node-spec2-multiroot.md"
        other -> expectationFailure ("預期 Left (TreeInvalidOnWrite _ _),得到 " <> show other)

  describe "L24 / E18: isRootNode 的三種結果(2026-08-25 G9 裁決)" $ do
    it "E18 之一:id 是根(序幕,文件裡第一個節)→ Right True" $
      isRootNode levelFilePath goodDoc (idOf "nod-90000001") `shouldBe` Right True

    it "E18 之二:id 存在但不是根(開場)→ Right False" $
      isRootNode levelFilePath goodDoc (idOf "nod-90000002") `shouldBe` Right False

    it "E18 之三:id 不在文件裡 → Left (SectionMissing path id),不是 Right False(與 headingDepthFor 對稱)" $ do
      let missing = idOf "nod-99999999"
      isRootNode levelFilePath goodDoc missing `shouldBe` Left (SectionMissing levelFilePath missing)

    it "L24:對文件裡每一個實際節點,isRootNode 恰為 Right (secId == 該檔第一個節的 id)" $
      forM_ (docSections goodDoc) $ \sec -> do
        let firstId = secId (head (docSections goodDoc))
            expected = secId sec == firstId
        isRootNode levelFilePath goodDoc (secId sec) `shouldBe` Right expected

  describe "L20 / E11: sanitizeFileName" $ do
    it "E11: sanitizeFileName \"第一章: 序幕 \" \"ent-7f3b2a91\" == \"第一章- 序幕\"" $
      sanitizeFileName "第一章: 序幕 " "ent-7f3b2a91" `shouldBe` "第一章- 序幕"

    it "L20: t 被清空時(只含非法字元/控制字元/空白)結果等於 fb" $
      hedgehog $ do
        fb <- forAll genFallback
        badOnly <- forAll (Gen.text (Range.linear 0 10) genOnlyStrippable)
        sanitizeFileName badOnly fb === fb

    it "L20: t 只含合法字元且無頭尾空白時結果等於 t" $
      hedgehog $ do
        fb <- forAll genFallback
        t <- forAll genCleanName
        sanitizeFileName t fb === t

    it "L20: 對任意 t 與非空 fb,結果不含非法字元/控制字元,且不以空白或句點開頭/結尾" $
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

--------------------------------------------------------------------------------
-- sanitizeFileName 用的產生器

illegalChars :: [Char]
illegalChars = "<>:\"/\\|?*"

genFallback :: Gen Text
genFallback = Gen.text (Range.linear 1 12) (Gen.element (['a' .. 'z'] ++ ['0' .. '9']))

-- | 只由「會被淨化掉」的字元組成:非法字元、控制字元、空白、句點(頭尾會被去掉)。
genOnlyStrippable :: Gen Char
genOnlyStrippable = Gen.choice [Gen.element illegalChars, Gen.element (" ." :: String), pure '\t']

-- | 合法、不含頭尾空白\/句點的檔名字元(中文與 ASCII 字母數字)。
genCleanChar :: Gen Char
genCleanChar = Gen.choice [Gen.alphaNum, Gen.enum '\x4E00' '\x9FFF']

-- | 'genCleanChar' 本身就不含空白\/句點\/非法字元,直接串接即滿足「無頭尾空白」。
genCleanName :: Gen Text
genCleanName = Gen.text (Range.linear 1 10) genCleanChar

genMixedName :: Gen Text
genMixedName =
  Gen.text (Range.linear 0 20) (Gen.choice [genCleanChar, Gen.element illegalChars, Gen.element (" ." :: String)])
