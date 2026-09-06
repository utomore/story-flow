-- | graph-core\/F008:寫入路徑共用紀律的那幾個函式。
--
-- 2026-09-06 退場波:@Aapms.Store.Edit@ 整個模組退場(它是與
-- 'Aapms.Store.Editing.applyWrite' 並存的第二份實作)。@checkRevision@ 與
-- @sectionBodyRaw@ 是純函式,本來就住 "Aapms.Store.Editing"
-- (P-003-node-write 第 4 列與它的私有切片),改從那裡 import;@commit@ 那一條
-- 測的是「落地」,改走唯一進入點 'Aapms.Store.Write.applyWriteIO' 的
-- @WriteBody@ ——新核心會同時把 revision \/ updated 兩行蓋上,所以檔案位元組的
-- 比對改用 'Aapms.Store.Types.stripStamps'(P-003 LAW-6 對「除 revision 與
-- updated 之外逐位元組相同」用的同一個觀察點)。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F008-store-write-operations.md@)
--
-- @
-- LAW-1(部分)  checkRevision i r a 在 r == a 時且僅在此時回 Right ()  -> prop_checkRevision
-- LAW-19       sectionBodyRaw 的形狀                                  -> prop_sectionBodyRaw
-- LAW-2\/LAW-16\/LAW-18(經由 commit 直接呼叫)commit 的落地行為              -> test_commit_*
-- @
--
-- __其餘 8 個函式沒有獨立測試,理由是 spec 本身的 L-__:
--
-- * @(>>?)@ \/ @(?>>)@ ——「無獨立 law:它們是 'Either' 的短路組合子……『失敗就不繼續』
--   這件事已由 LAW-1 與 LAW-16 的『檔案不變』觀察到」,已由 "Aapms.Store.WriteSpec" \/
--   "Aapms.Store.CreateSpec" 對公開介面的樂觀鎖\/位元組保留斷言間接涵蓋
-- * @orMd@ \/ @vaultAbsPath@ \/ @ensureDir@ \/ @readDocument@ \/ @locate@ \/ @dropFile@ ——
--   同一條 L-:「純粹的包裝與定位,沒有任何從公開介面觀察得到、而不被 LAW-10 \/ LAW-13 \/ LAW-16
--   覆蓋的行為」。@locate@ 由 "Aapms.Store.WriteSpec" 的 'Aapms.Store.Error.NodeNotFound'
--   案例間接涵蓋;@dropFile@ 由 "Aapms.Store.CreateSpec" 的 @deleteNode@ 案例間接涵蓋
module Aapms.Store.EditSpec (spec) where

import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (query_)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Id (Id)
import Aapms.Core.Meta (Revision (..))
import Aapms.Md.Document (Document (..), LineEnding (..), renderLineEnding)
import Aapms.Md.Parse (parseDocument)
import Aapms.Md.Render (renderDocument, updateSectionBody)
import Aapms.Store.Atomic (readTextFile)
import Aapms.Store.Editing (checkRevision, sectionBodyRaw)
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Fixtures
import Aapms.Store.Marker (VaultHandle, vhConn, vhRoot)
import Aapms.Store.Types (WriteOp (..), outcomeId, outcomePath, outcomeRevision, stripStamps)
import Aapms.Store.Write (applyWriteIO)
import System.FilePath ((</>))

spec :: Spec
spec = describe "graph-core/F008 寫入路徑的共用紀律" $ do
  describe "LAW-1(部分): checkRevision" $ do
    it "r == a 時回 Right ()" $
      checkRevision (idOf "ent-00000001") (Revision 3) (Revision 3) `shouldBe` Right ()

    it "r /= a 時回 Left (RevisionMismatch i r a)" $
      checkRevision (idOf "ent-00000001") (Revision 2) (Revision 3)
        `shouldBe` Left (RevisionMismatch (idOf "ent-00000001") (Revision 2) (Revision 3))

    it "對任意 i、r、a:checkRevision i r a == Right () 若且唯若 r == a,否則為 Left (RevisionMismatch i r a)" $
      hedgehog $ do
        i <- forAll genTestId
        base <- forAll (Gen.int (Range.linear 0 1000))
        equal <- forAll Gen.bool
        let a = Revision base
        r <-
          if equal
            then pure a
            else do
              delta <- forAll (Gen.int (Range.linear 1 50))
              pure (Revision (base + delta))
        if r == a
          then checkRevision i r a === Right ()
          else checkRevision i r a === Left (RevisionMismatch i r a)

  describe "LAW-19: sectionBodyRaw" $
    it "對任意非空白 t 與行尾風格 le:sectionBodyRaw le t 以 renderLineEnding le 開頭且結尾,且 strip 後等於 T.strip t" $
      hedgehog $ do
        le <- forAll (Gen.element [LF, CRLF])
        t <- forAll genNonBlankText
        let nl = renderLineEnding le
            r = sectionBodyRaw le t
        assert (nl `T.isPrefixOf` r)
        assert (nl `T.isSuffixOf` r)
        T.strip r === T.strip t

  describe "LAW-2 / LAW-16 / LAW-18(經唯一進入點 applyWriteIO 的 WriteBody)" $
    it "落地寫入 renderDocument 的位元組(去掉 revision/updated 兩行後)、回傳的 revision 與傳入值一致,且 files 表裡其他檔案的 (path, mtime, size) 不變" $
      withIndexedStoryVault $ \vh -> do
        let targetPath = "characters/test-character.md"
            targetId = idOf "ent-00000002"
            newRevision = Revision 2
        beforeOthers <- otherFilesSnapshot vh targetPath

        Just srcText <- pure (lookup targetPath storyVaultFiles)
        srcDoc <- either (\e -> fail ("fixture 解析失敗:" <> show e)) pure (parseDocument srcText)
        newDoc <-
          either (\e -> fail ("updateSectionBody 失敗:" <> show e)) pure $
            updateSectionBody targetId (sectionBodyRaw (docEnding srcDoc) "commit 測試用的新內容") srcDoc

        result <- applyWriteIO vh (WriteBody targetId (Revision 1) "commit 測試用的新內容")
        case result of
          Left e -> expectationFailure ("預期寫入成功,得到 " <> show e)
          Right o -> do
            outcomeId o `shouldBe` targetId
            outcomePath o `shouldBe` targetPath
            outcomeRevision o `shouldBe` newRevision

        onDisk <- orDie =<< readTextFile (vhAbsPath vh targetPath)
        stripStamps onDisk `shouldBe` stripStamps (renderDocument newDoc)

        afterOthers <- otherFilesSnapshot vh targetPath
        sort afterOthers `shouldBe` sort beforeOthers

--------------------------------------------------------------------------------

genTestId :: Gen Id
genTestId = Gen.element (map idOf ["ent-00000001", "ent-00000002", "ent-00000003", "nod-00000001", "ast-00000001"])

genNonBlankText :: Gen Text
genNonBlankText = do
  core <- Gen.text (Range.linear 1 20) (Gen.choice [Gen.alphaNum, Gen.enum '\x4E00' '\x9FFF'])
  pad <- Gen.text (Range.linear 0 3) (pure ' ')
  pure (pad <> core <> pad)

-- | @files@ 表裡除了 @excluded@ 之外每一列的 (path, mtime, size),依 path 排序好比對。
otherFilesSnapshot :: VaultHandle -> FilePath -> IO [(Text, Int, Int)]
otherFilesSnapshot vh excluded = do
  rows <- query_ (vhConn vh) "SELECT path, mtime, size FROM files ORDER BY path"
  pure [(p, m, s) | (p, m, s) <- rows, p /= T.pack excluded]

vhAbsPath :: VaultHandle -> FilePath -> FilePath
vhAbsPath vh rel = vhRoot vh </> rel
