-- | graph-core\/E001:cabal 可見度界線(L1\/L2\/L3\/E1)、"Aapms.Store.Index" 匯出清單
-- 界線(L4)、門面完整性(R1\/E2)與 'WriteResult' 型別同一性(R2)。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/enhancements\/E001-store-internal-module-boundary.md@)
--
-- @
-- R1  只 import Aapms.Store 就取得到契約 E 的每一個公開符號,由「能不能編譯」證明 -> test_E2
-- R2  WriteResult 經 Aapms.Store 與經 Aapms.Store.Write 取得的是同一個型別        -> _r2SameType(型別檢查即斷言)
-- L1  aapms-store.cabal 的 exposed-modules 不含 Edit\/Node\/Row\/Walk             -> test_L1
-- L2  上述四個模組都在 other-modules                                             -> test_L2
-- L3  aapms-store-test 的 build-depends 不含 aapms-store,hs-source-dirs 含 src+test -> test_L3
-- L4  Index.hs 的匯出清單不含 vaultMarkdownFiles\/statOf                          -> test_L4
-- E1  exposed-modules 11 項 + other-modules 4 項 = 15,對帳                       -> test_E1
-- E2  只 import Aapms.Store(...)列出契約 E 全部符號各引用一次,編譯通過           -> test_E2 / _contractEFunctions / ContractETypesCheck
-- @
--
-- __禁止讀實作__:L1\/L2\/L3\/L4 全部是對原始檔文字的字串比對,不解讀語意;
-- 契約 E 的完整符號清單抄自 @.design\/subsystems\/graph-core\/design.md@「### E. 落地」,
-- 不是從程式碼推論出來的。
module Aapms.Store.BoundarySpec (spec) where

import qualified Data.ByteString as BS
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

import Aapms.Core.Id (Id)
import Aapms.Core.Meta (Revision)
import Aapms.Store
  ( -- 把手
    VaultKind
  , VaultMarker
  , VaultHandle
  , readMarker
  , initVaultAt
  , openVault
  , closeVault
    -- 索引維護
  , rebuildIndex
  , refreshStale
  , indexFile
  , unindexFile
    -- 單一 vault 查詢
  , lookupNode
  , lookupByName
  , listNodes
  , childrenOf
  , linksFrom
  , linksTo
  , loadLinkGraph
  , search
    -- 跨 vault 讀
  , VaultSet
  , openVaultSet
  , lookupRef
  , listAcross
  , searchAcross
  , checkReferences
  , closeVaultSet
  , vaultSetIds
  , maxAttachedVaults
  , DanglingRef
  , DanglingReason
    -- 寫入
  , SectionPlacement
  , createTopicFile
  , createLevelFile
  , createPackFile
  , addSection
  , writeMeta
  , writeAssetFields
  , writeBody
  , addLink
  , removeLink
  , upsertLicense
  , deleteNode
  , allocateId
    -- 結果 / 查詢 DTO / 錯誤
  , WriteResult (..)
  , CreateResult
  , DeleteResult
  , DeleteMode
  , IndexIssue
  , NodeFilter
  , SearchQuery
  , SearchHit
  , FacetCounts
  , SearchResult
  , StoreError
  )
import qualified Aapms.Store.Write as Write

spec :: Spec
spec = describe "graph-core/E001 cabal 可見度界線" $ do
  describe "L1 / L2 / E1: library exposed-modules / other-modules" $ do
    it "L1: exposed-modules 不含 Aapms.Store.Edit / .Node / .Row / .Walk" $ do
      lib <- librarySection <$> readCabalSource
      let exposed = moduleNamesIn (fieldSection "exposed-modules:" lib)
      filter (`elem` movedModules) exposed `shouldBe` []

    it "L2: other-modules 都含 Aapms.Store.Edit / .Node / .Row / .Walk" $ do
      lib <- librarySection <$> readCabalSource
      let other = moduleNamesIn (fieldSection "other-modules:" lib)
      sort (filter (`elem` movedModules) other) `shouldBe` sort movedModules

    it "E1: exposed-modules 11 項 + other-modules 4 項 = 15,對帳" $ do
      lib <- librarySection <$> readCabalSource
      let exposed = moduleNamesIn (fieldSection "exposed-modules:" lib)
          other = moduleNamesIn (fieldSection "other-modules:" lib)
      sort exposed `shouldBe` sort expectedExposed
      sort other `shouldBe` sort movedModules
      (length exposed + length other) `shouldBe` 15

  describe "L3: aapms-store-test stanza" $
    it "build-depends 不含 aapms-store 套件相依,hs-source-dirs 同時含 src 與 test" $ do
      src <- readCabalSource
      let testStanza = snd (T.breakOn "\ntest-suite" (normalizeEol src))
          deps = snd (T.breakOn "build-depends:" testStanza)
          dirsField = fieldSection "hs-source-dirs:" testStanza
          depNames = [T.strip t | t <- T.splitOn "," deps, not (T.null (T.strip t))]
      ("aapms-store" `elem` depNames) `shouldBe` False
      ("src" `T.isInfixOf` dirsField) `shouldBe` True
      ("test" `T.isInfixOf` dirsField) `shouldBe` True

  describe "L4: Aapms.Store.Index 匯出清單" $
    it "匯出清單那一段(module ... 到 ) where 之前)不含 vaultMarkdownFiles / statOf" $ do
      hdr <- indexModuleHeader
      ("vaultMarkdownFiles" `T.isInfixOf` hdr) `shouldBe` False
      ("statOf" `T.isInfixOf` hdr) `shouldBe` False

  describe "R1 / E2: 門面完整性" $
    it "E2: 只 import Aapms.Store(...)列出契約 E 的全部符號各引用一次,編譯即通過" $
      True `shouldBe` True

-- | R2:'Write.WriteResult'(經 "Aapms.Store.Write")與經 "Aapms.Store" 取得的
-- 'WriteResult' 是同一個型別——把前者的值餵給後者匯入的欄位選取器,能編譯就是證明。
_r2SameType :: Write.WriteResult -> (Id, FilePath, Revision, [IndexIssue])
_r2SameType wr = (wrId wr, wrPath wr, wrRevision wr, wrIssues wr)

-- | E2 / R1 的核心斷言:這個 tuple 本身就是證據——每一個成員都直接引用契約 E
-- 的一個函式\/值符號,少一項就編不過。__刻意不寫型別簽名__:每個成員各自保留它在
-- "Aapms.Store" 裡的真實型別(全部單型,寫簽名反而要手抄一遍簽名,徒增出錯機會);
-- 名稱清單抄自 design.md「### E. 落地」,不執行、不呼叫。
_contractEFunctions =
  ( readMarker
  , initVaultAt
  , openVault
  , closeVault
  , rebuildIndex
  , refreshStale
  , indexFile
  , unindexFile
  , lookupNode
  , lookupByName
  , listNodes
  , childrenOf
  , linksFrom
  , linksTo
  , loadLinkGraph
  , search
  , openVaultSet
  , lookupRef
  , listAcross
  , searchAcross
  , checkReferences
  , closeVaultSet
  , vaultSetIds
  , maxAttachedVaults
  , createTopicFile
  , createLevelFile
  , createPackFile
  , addSection
  , writeMeta
  , writeAssetFields
  , writeBody
  , addLink
  , removeLink
  , upsertLicense
  , deleteNode
  , allocateId
  )

-- | E2:契約 E 的全部型別符號各引用一次(型別層級,只需要名字在作用域內)。
type ContractETypesCheck =
  ( VaultKind
  , VaultMarker
  , VaultHandle
  , VaultSet
  , DanglingRef
  , DanglingReason
  , SectionPlacement
  , WriteResult
  , CreateResult
  , DeleteResult
  , DeleteMode
  , IndexIssue
  , NodeFilter
  , SearchQuery
  , SearchHit
  , FacetCounts
  , SearchResult
  , StoreError
  )

--------------------------------------------------------------------------------
-- cabal / 原始檔文字輔助(只做字串切段,不解讀語意)

movedModules :: [String]
movedModules = ["Aapms.Store.Edit", "Aapms.Store.Node", "Aapms.Store.Row", "Aapms.Store.Walk"]

expectedExposed :: [String]
expectedExposed =
  [ "Aapms.Store"
  , "Aapms.Store.Atomic"
  , "Aapms.Store.Create"
  , "Aapms.Store.Error"
  , "Aapms.Store.Index"
  , "Aapms.Store.Marker"
  , "Aapms.Store.MultiVault"
  , "Aapms.Store.Query"
  , "Aapms.Store.Schema"
  , "Aapms.Store.Tokenize"
  , "Aapms.Store.Write"
  ]

-- | @library@ stanza 的原始文字(從 @library@ 關鍵字到下一個 @test-suite@ 之前)。
librarySection :: Text -> Text
librarySection src =
  let afterLibrary = snd (T.breakOn "\nlibrary" (normalizeEol src))
      body = T.drop 1 afterLibrary
   in fst (T.breakOn "\ntest-suite" body)

-- | @startField@(如 @"exposed-modules:"@)這個 cabal 欄位的內容:從欄位標籤那一行
-- 的值(可能與標籤同一行)開始,收到下一行「縮排 <= 欄位標籤縮排、且非空白」為止——
-- 那一行必然是下一個欄位(cabal 的欄位值一律縮排得比欄位標籤更深)。__不假設欄位順序、
-- 不假設下一個欄位叫什麼名字__,單純用 cabal 語法本身的縮排規則畫邊界,插欄位、換順序
-- 都不影響。找不到 @startField@ 就回傳空字串。
fieldSection :: Text -> Text -> Text
fieldSection startField sect =
  case break (\l -> startField `T.isPrefixOf` T.stripStart l) (T.lines sect) of
    (_, []) -> ""
    (_, startLine : rest) ->
      let fieldIndent = T.length (T.takeWhile (== ' ') startLine)
          sameLineValue = T.drop (T.length startField) (T.stripStart startLine)
          isNextField l =
            let l' = T.stripStart l
             in not (T.null l') && T.length (T.takeWhile (== ' ') l) <= fieldIndent
          continuation = takeWhile (not . isNextField) rest
       in T.unlines (sameLineValue : continuation)

-- | 一個欄位段落裡,每行去頭尾空白後只留下 @Aapms.Store@ 開頭的模組名。
moduleNamesIn :: Text -> [String]
moduleNamesIn sect =
  [ T.unpack name
  | ln <- T.lines sect
  , let name = T.strip ln
  , not (T.null name)
  , "Aapms.Store" `T.isPrefixOf` name
  ]

normalizeEol :: Text -> Text
normalizeEol = T.filter (/= '\r')

-- | 讀 @aapms-store.cabal@;@cabal test@ 的工作目錄可能是套件目錄或專案根,兩個
-- 候選路徑都試。
readCabalSource :: IO Text
readCabalSource = readUtf8Source "aapms-store.cabal"

-- | "Aapms.Store.Index" 從檔案開頭到第一個 @) where@(不含)之間的文字——只有
-- module 宣告與匯出清單那一段,函式本體不在裡面。
indexModuleHeader :: IO Text
indexModuleHeader = do
  src <- readUtf8Source "src/Aapms/Store/Index.hs"
  pure (fst (T.breakOn ") where" (normalizeEol src)))

readUtf8Source :: FilePath -> IO Text
readUtf8Source rel = go [rel, "store/" <> rel]
  where
    go [] = fail ("找不到檔案:" <> rel)
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then TE.decodeUtf8 <$> BS.readFile c else go rest
