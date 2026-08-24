-- | graph-core\/F007:"Aapms.Store.Query".'search'(全文檢索出口本身,不含 facet
-- ——facet 見 "Aapms.Store.FacetSpec")。
--
-- __spec 對照__(每條 law\/example 對回
-- @.design\/subsystems\/graph-core\/features\/F007-store-fts-dual-index.md@):
--
-- @
-- L12 無文字條件時退化成 listNodes,分數 0、片段空                -> test_L12
-- L13 有文字條件時每筆命中 shScore > 0                            -> test_L13
-- L14 命中 id 相異、分數非遞增、同分 id 遞增、重複查詢逐筆相同    -> test_L14
-- L15 srTotal 與分頁無關,>= 命中數;命中數 <= nfLimit             -> test_L15
-- L19 每筆 shVault 等於本 vault 的 vmId                            -> test_L19
-- L20 對同一檔案連續 indexFile 兩次,search 結果與一次相同         -> test_L20
-- L21 unindexFile 之後,該檔案節點不再出現在任何 search 結果       -> test_L21
-- L22 schema_version 改壞後 openVault + rebuildIndex 結果不變      -> test_L22
-- L24 純 ASCII 查詢,search t 與 search (toUpper t) 結果相同        -> test_L24
-- E6  二字中文"藥水"命中含"魔法藥水瓶"的節點,snippet 含"藥水"     -> test_E6
-- E7  二字中文"琳達"命中同名角色主體                               -> test_E7
-- E8  英文子字串"travel-book"命中 name 含該字串的 asset            -> test_E8
-- E9  三字以上中文"魔法藥水"走 trigram 並有分數                    -> test_E9
-- E10 標題同含"藥水"與 potion,查詢"藥水 potion" 只回一筆           -> test_E10
-- E12 emptySearchQuery 退化成純結構查詢                            -> test_E12
-- E13 查無此文字時空結果、不是錯誤                                 -> test_E13
-- E14 純 ASCII 二字查詢"ui"因雙索引已知代價回空結果                -> test_E14
-- @
module Aapms.Store.SearchSpec (spec) where

import Control.Monad (forM_)
import Data.List (nub, sortBy)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (execute_)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Id (VaultId (..), renderId)
import Aapms.Core.Meta (Meta (..))
import Aapms.Store.Fixtures
import Aapms.Store.Gens (genNonCjkText)
import Aapms.Store.Index (indexFile, unindexFile, rebuildIndex)
import Aapms.Store.Marker
import Aapms.Store.Query
import Aapms.Store.Schema (IndexIssue (..), VaultKind (StoryVault))

spec :: Spec
spec = describe "graph-core/F007 search" $ do
  describe "L12-L15/L19/L24: search 的通用行為(property)" $ do
    -- hspec-hedgehog 的 'hedgehog' 產生 'PropertyT IO ()',那不是 'IO a'——不能塞
    -- 在 'withIndexedAssetVault'/'withFtsVault' 這類 (VaultHandle -> IO a) -> IO a
    -- 的 callback 裡當回傳值。正確接法是用 'around' 把 fixture 的取得/收尾交給
    -- hspec,讓 'it' 直接吃 'VaultHandle -> PropertyT IO ()'
    -- (hspec-core 的 @Example a => Example (arg -> a)@ 疊上 hspec-hedgehog 的
    -- @Example (PropertyT IO ())@)。
    around withIndexedAssetVault $
      it "L12: 無文字條件(Nothing 或去頭尾空白後為空字串)時退化成 listNodes,分數與片段皆為預設值" $
        \vh -> hedgehog $ do
          txt <- forAll genEmptyish
          let filt = emptyNodeFilter {nfIncludeReference = True}
          r <- evalIO (search vh (emptySearchQuery {sqText = txt, sqFilter = filt}))
          expected <- evalIO (listNodes vh filt)
          map shMeta (srHits r) === expected
          map shScore (srHits r) === replicate (length expected) 0
          map shSnippet (srHits r) === replicate (length expected) ""

    around withFtsVault $ do
      it "L13: 有文字條件時,每筆命中的 shScore > 0" $
        \vh -> hedgehog $ do
          q <- forAll genQueryCandidate
          r <- evalIO (search vh (emptySearchQuery {sqText = Just q}))
          assert (all (> 0) (map shScore (srHits r)))

      it "L14: 命中節點 id 兩兩相異、分數非遞增、同分時 id 遞增、重複查詢逐筆相同" $
        \vh -> hedgehog $ do
          q <- forAll genQueryCandidate
          r1 <- evalIO (search vh (emptySearchQuery {sqText = Just q}))
          r2 <- evalIO (search vh (emptySearchQuery {sqText = Just q}))
          let rids = map (renderId . metaId . shMeta) (srHits r1)
          rids === nub rids
          let scores = map shScore (srHits r1)
          scores === sortBy (flip compare) scores
          assert (isSortedWithinTies (srHits r1))
          r1 === r2

      it "L15: srTotal 與分頁無關,srTotal >= 命中數,命中數 <= nfLimit" $
        \vh -> hedgehog $ do
          q <- forAll genQueryCandidate
          lim <- forAll (Gen.int (Range.linear 0 5))
          off <- forAll (Gen.int (Range.linear 0 5))
          let filt = emptyNodeFilter {nfLimit = lim, nfOffset = off}
          r <- evalIO (search vh (emptySearchQuery {sqText = Just q, sqFilter = filt}))
          rBase <- evalIO (search vh (emptySearchQuery {sqText = Just q}))
          srTotal r === srTotal rBase
          assert (srTotal r >= length (srHits r))
          assert (length (srHits r) <= lim)

      it "L19: 每筆 shVault 等於本 vault 的 vmId" $
        \vh -> hedgehog $ do
          q <- forAll genQueryCandidate
          r <- evalIO (search vh (emptySearchQuery {sqText = Just q}))
          let VaultId vaultText = vmId (vhMarker vh)
              matches h = case shVault h of
                VaultId t -> t == vaultText
          assert (all matches (srHits r))

      it "L24: 純 ASCII 查詢字串,search 對 t 與對 T.toUpper t 回相同的 srHits" $
        \vh -> hedgehog $ do
          t <- forAll genNonCjkText
          r1 <- evalIO (search vh (emptySearchQuery {sqText = Just t}))
          r2 <- evalIO (search vh (emptySearchQuery {sqText = Just (T.toUpper t)}))
          srHits r1 === srHits r2

  describe "L20-L22: 索引維護與 search 的一致性" $ do
    it "L20: 對同一檔案連續 indexFile 兩次,search vh q 的結果與只做一次時相同" $
      withStoryVault $ \vh ->
        forM_ storyVaultFiles $ \(rel, _) -> do
          _ <- orDie =<< indexFile vh rel
          forM_ ([Nothing, Just "藥水", Just "  "] :: [Maybe Text]) $ \txt -> do
            r1 <- search vh (emptySearchQuery {sqText = txt})
            _ <- orDie =<< indexFile vh rel
            r2 <- search vh (emptySearchQuery {sqText = txt})
            r2 `shouldBe` r1

    it "L21: unindexFile 之後,該檔案的節點不再出現在任何 search 結果的 srHits 裡" $
      withIndexedStoryVault $ \vh -> do
        _ <- orDie =<< unindexFile vh "levels/test-classroom.md"
        let removedIds = [idOf "lvl-00000001", idOf "nod-00000001", idOf "nod-00000002"]
            filt = emptyNodeFilter {nfIncludeReference = True}
        forM_ ([Nothing, Just "測試場景", Just "開場"] :: [Maybe Text]) $ \txt -> do
          r <- search vh (emptySearchQuery {sqText = txt, sqFilter = filt})
          let hitIds = map (metaId . shMeta) (srHits r)
          forM_ removedIds $ \rid -> hitIds `shouldNotContain` [rid]

    it "L22: schema_version 被改壞後重開 + rebuildIndex,search 結果不變且回報一筆 SchemaRebuilt" $
      withTempVault $ \dir -> do
        _ <- orDie =<< initVaultAt dir StoryVault "story-fixture"
        writeFiles dir storyVaultFiles
        (vh1, _issues1) <- orDie =<< openVault testRegistry dir
        _ <- orDie =<< rebuildIndex vh1
        let filt = emptyNodeFilter {nfIncludeReference = True}
        baseline <- search vh1 (emptySearchQuery {sqFilter = filt})
        execute_ (vhConn vh1) "UPDATE meta_info SET value = '0' WHERE key = 'schema_version'"
        closeVault vh1

        (vh2, issues2) <- orDie =<< openVault testRegistry dir
        any isSchemaRebuilt issues2 `shouldBe` True
        _ <- orDie =<< rebuildIndex vh2
        rebuilt <- search vh2 (emptySearchQuery {sqFilter = filt})
        rebuilt `shouldBe` baseline
        closeVault vh2

  describe "Examples" $ do
    it "E6: 二字中文\"藥水\"命中含\"魔法藥水瓶\"的節點,snippet 含\"藥水\"(契約卡驗收標準)" $
      withFtsVault $ \vh -> do
        r <- search vh (emptySearchQuery {sqText = Just "藥水"})
        case filter ((== idOf "ast-00000101") . metaId . shMeta) (srHits r) of
          [h] -> do
            shScore h `shouldSatisfy` (> 0)
            shSnippet h `shouldSatisfy` T.isInfixOf "藥水"
          hits -> expectationFailure ("預期恰一筆 ast-00000101,得到 " <> show (length hits) <> " 筆")

    it "E7: 二字中文\"琳達\"命中同名角色主體(契約卡驗收標準)" $
      withFtsVault $ \vh -> do
        r <- search vh (emptySearchQuery {sqText = Just "琳達"})
        case filter ((== idOf "ent-00000101") . metaId . shMeta) (srHits r) of
          [h] -> shScore h `shouldSatisfy` (> 0)
          hits -> expectationFailure ("預期恰一筆 ent-00000101,得到 " <> show (length hits) <> " 筆")

    it "E8: 英文子字串\"travel-book\"命中 name 含該字串的 asset(\"-\" 不被當運算子)" $
      withFtsVault $ \vh -> do
        r <- search vh (emptySearchQuery {sqText = Just "travel-book"})
        map (metaId . shMeta) (srHits r) `shouldContain` [idOf "ast-00000101"]

    it "E9: 三字以上中文\"魔法藥水\"走 trigram 並有分數" $
      withFtsVault $ \vh -> do
        r <- search vh (emptySearchQuery {sqText = Just "魔法藥水"})
        case filter ((== idOf "ast-00000101") . metaId . shMeta) (srHits r) of
          [h] -> shScore h `shouldSatisfy` (> 0)
          hits -> expectationFailure ("預期恰一筆 ast-00000101,得到 " <> show (length hits) <> " 筆")

    it "E10: 節點的 title 同時含\"藥水\"與 potion,查詢\"藥水 potion\" 只回一筆" $
      withFtsVault $ \vh -> do
        r <- search vh (emptySearchQuery {sqText = Just "藥水 potion"})
        length (filter ((== idOf "ast-00000102") . metaId . shMeta) (srHits r)) `shouldBe` 1

    it "E12: emptySearchQuery 退化成純結構查詢" $
      withIndexedAssetVault $ \vh -> do
        r <- search vh emptySearchQuery
        expected <- listNodes vh emptyNodeFilter
        map shMeta (srHits r) `shouldBe` expected
        map shScore (srHits r) `shouldBe` replicate (length expected) 0
        map shSnippet (srHits r) `shouldBe` replicate (length expected) ""
        srFacets r `shouldBe` Nothing

    it "E13: 查無此文字時 srHits 為空、srTotal 為 0,不是錯誤" $
      withFtsVault $ \vh -> do
        r <- search vh (emptySearchQuery {sqText = Just "這個詞不存在於任何節點"})
        srHits r `shouldBe` []
        srTotal r `shouldBe` 0

    it "E14: 純 ASCII 二字查詢\"ui\"因雙索引的已知代價回空結果(LIKE 已退場)" $
      withFtsVault $ \vh -> do
        r <- search vh (emptySearchQuery {sqText = Just "ui"})
        srHits r `shouldBe` []

--------------------------------------------------------------------------------
-- 產生器

-- | 空、Nothing、純空白——L12 的定義域邊界。
genEmptyish :: Gen (Maybe Text)
genEmptyish = Gen.element [Nothing, Just "", Just "   ", Just "\t \n "]

-- | 混合命中\/不命中、中文\/英文\/中英混合的代表性查詢字串(L13-L15/L19 用)。
genQueryCandidate :: Gen Text
genQueryCandidate =
  Gen.element ["藥水", "travel-book", "魔法藥水", "琳達", "藥水 potion", "xyzxyz", "ui"]

-- | L14:分數相同的相鄰兩筆,id(以 'renderId' 比較)必須遞增。
isSortedWithinTies :: [SearchHit] -> Bool
isSortedWithinTies hits = all ok (zip hits (drop 1 hits))
  where
    ok (a, b) =
      shScore a /= shScore b || renderId (metaId (shMeta a)) < renderId (metaId (shMeta b))

-- | L22:openVault 回報的 'IndexIssue' 是否含一筆 schema 重建紀錄。
isSchemaRebuilt :: IndexIssue -> Bool
isSchemaRebuilt (SchemaRebuilt _ _) = True
isSchemaRebuilt _ = False

--------------------------------------------------------------------------------
-- 自訂 fixture:二字中文\/三字以上中文\/中英混合\/英文子字串(E6~E10、E13、E14)。
--
-- 'Aapms.Store.Fixtures' 既有的 storyVaultFiles\/assetVaultFiles 不含中文詞彙,
-- 這裡另建一組專供 F007 全文檢索用的最小混合 vault:一個角色主體 + 一個 pack.md
-- (兩個 asset)。

ftsCharacterMd :: Text
ftsCharacterMd =
  T.unlines
    [ "---"
    , "id: ent-00000101"
    , "vault: fts-fixture"
    , "type: character"
    , "title: 琳達"
    , "summary: F007 fixture 用的二字中文標題角色"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-24"
    , "updated: 2026-08-24"
    , "---"
    , ""
    , "琳達是本 fixture 用來驗證二字中文標題命中的角色主體。"
    ]

ftsPackMd :: Text
ftsPackMd =
  T.unlines
    [ "---"
    , "id: pck-00000101"
    , "vault: fts-fixture"
    , "type: asset-pack"
    , "title: FTS 測試 Pack"
    , "status: canon"
    , "source: scan"
    , "revision: 1"
    , "created: 2026-08-24"
    , "updated: 2026-08-24"
    , "---"
    , ""
    , "F007 全文檢索 fixture。"
    , ""
    , "## 魔法藥水瓶 {#ast-00000101}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "name: ui_gui_travel-book-frame_001"
    , "entry: PNG/potion.png"
    , "sha256: \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
    , "```"
    , ""
    , "一瓶魔法藥水,裝在玻璃瓶裡。"
    , ""
    , "## 藥水 potion {#ast-00000102}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: PNG/bottle.png"
    , "sha256: \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\""
    , "```"
    , ""
    , "中英雙語標題,測試兩張 FTS 表都命中時的分數合併去重。"
    ]

ftsVaultFiles :: [(FilePath, Text)]
ftsVaultFiles =
  [ ("characters/fts-linda.md", ftsCharacterMd)
  , ("packs/fts-vendor/pack.md", ftsPackMd)
  ]

-- | 專供全文檢索 Examples(E6~E10、E13、E14)用的 vault:混合角色與 asset-pack
-- 兩種節點,已完整 'rebuildIndex'。
withFtsVault :: (VaultHandle -> IO a) -> IO a
withFtsVault act = withTempVault $ \dir -> do
  _ <- orDie =<< initVaultAt dir StoryVault "fts-fixture"
  writeFiles dir ftsVaultFiles
  (h, _issues) <- orDie =<< openVault testRegistry dir
  _ <- orDie =<< rebuildIndex h
  result <- act h
  closeVault h
  pure result
