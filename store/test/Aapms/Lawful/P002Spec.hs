-- | lawful 測試:P-002-search(qa 填入)。
--
-- 每條 @LAW-n@ 一個 @describe "P-002#LAW-n"@ 的 property test,每個 @EX-n@
-- 一個 @describe "P-002#EX-n"@ 的 example test。斷言逐字照 pipeline 檔的
-- @|-@ 行翻譯(@sort@ \/ @nub@ \/ @take@ \/ @drop@ \/ @all@ \/ @sum@ 等識別字
-- 對應到 @Data.List@ 與 @Data.Text@ 的同名函數)。
--
-- __效果怎麼跑__:pipeline 的 @=@ 列 @searchVaults@ 是效果程式,laws 一律
-- 透過觀察點 'simulateVaults'(@Vaults@ 的純解譯器跑到底)取值,測試不碰 IO。
--
-- __案例數__:@hspec-hedgehog@ 的 @Example (PropertyT IO ())@ instance 會把
-- hedgehog 的 @TestLimit@ 直接覆寫成 hspec 的 @maxSuccess@,因此
-- @withTests@ 寫在 property 上不會生效;等價寫法是
-- @modifyMaxSuccess (const 100)@ 包住整個模組(見 'spec')。
--
-- __尺寸__:全部 'Range' 上限都是常數 —— 最多 3 個 vault、每個 vault 最多 4
-- 個節點(id 取自固定的 'nodeSeeds',同一個 vault 內不重複),文字欄位取自
-- 固定字彙池,不產生無界結構。
--
-- __timeout__:整個模組經 'around_' 對每個 example 套 60 秒上限。
module Aapms.Lawful.P002Spec (spec) where

import Data.Aeson (Value (Null))
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian)
import System.Timeout (timeout)

import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (assert, forAll, hedgehog, modifyMaxSuccess, (===))

import Aapms.Core.AnyNode (AnyNode (..))
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (..), VaultId (..), parseId, renderIdPrefix)
import Aapms.Core.Meta
  ( Meta (..)
  , Revision (..)
  , Source (..)
  , Status (..)
  , TypeKey (..)
  )
import Aapms.Md.Document (DocKind (..))

import Aapms.Store.Effect.Vaults (inVault)
import Aapms.Store.Filter (passesFilter)
import Aapms.Store.Search (rankHits, searchVaults)
import Aapms.Store.Search.Internal (hitsPerVault, simulateVaults, structuralKeys)
import Aapms.Store.Tokenize (matchesQuery)
import Aapms.Store.Types
  ( FileIndex (..)
  , FileStat (..)
  , IndexState (..)
  , IndexedNode (..)
  , NodeFilter (..)
  , SearchHit (..)
  , SearchQuery (..)
  , SearchResult (..)
  , FacetCounts (..)
  , allNodesIn
  , emptyNodeFilter
  , emptySearchQuery
  , hitKey
  , keysOf
  , nodeKey
  , page
  , wide
  , withTags
  , withTypes
  )

--------------------------------------------------------------------------------
-- 固定值

fixedDay :: Day
fixedDay = fromGregorian 2026 1 1

fixedStat :: FileStat
fixedStat = FileStat 0 0

-- | 'Id' 的建構子沒有匯出,一律走型別層的 smart constructor 'parseId'。
mkId :: IdPrefix -> Text -> Id
mkId p hex = case parseId (renderIdPrefix p <> "-" <> hex) of
  Right (_, i) -> i
  Left e -> error ("P-002Spec:測試 id 不合法 " <> show e)

-- | 樣本 vault。id 的字典序 a \< b \< c,LAW-6 的「同 vault 遞增」才有觀察得到
-- 的順序。
vaultA, vaultB, vaultC :: VaultId
vaultA = VaultId "vlt-0000000a"
vaultB = VaultId "vlt-0000000b"
vaultC = VaultId "vlt-0000000c"

vaultPool :: [VaultId]
vaultPool = [vaultA, vaultB, vaultC]

-- | 集合外的 vault(LAW-13 \/ EX-12)。
vaultMissing :: VaultId
vaultMissing = VaultId "vlt-deadbeef"

typePool :: [TypeKey]
typePool = [TypeKey "character-fragment", TypeKey "asset-image"]

--------------------------------------------------------------------------------
-- 產生器

-- | 一個 vault 裡最多四個節點的身分。前綴兩 ent 兩 ast,'nfPrefixes' 才篩得動;
-- 同一個 vault 內取子序列,所以 id 不重複(索引本來的不變量),跨 vault 則會
-- 重複,LAW-5 的「(vault, id) 兩兩相異」才不是恆真。
nodeSeeds :: [(IdPrefix, Text)]
nodeSeeds =
  [ (PEnt, "00000001")
  , (PEnt, "00000002")
  , (PAst, "00000003")
  , (PAst, "00000004")
  ]

-- | 節點文字欄位的字彙池。刻意與 'queryTextPool' 有交集,查詢才真的打得到東西
-- (LAW-3 \/ LAW-4 的 hits 若恆為空,斷言會退化成恆真)。
titlePool :: [Text]
titlePool = ["魔法藥水瓶", "琳達", "金門建築", "travel guide", ""]

summaryPool :: [Text]
summaryPool = ["", "藥水 potion", "開場"]

bodyPool :: [Text]
bodyPool = ["", "travel-book frame", "藥水"]

namePool :: [Maybe LogicalName]
namePool =
  [ Nothing
  , Just (LogicalName "ui_gui_travel-book-frame_001")
  , Just (LogicalName "ui_gui_map_001")
  ]

queryTextPool :: [Text]
queryTextPool =
  [ "藥水"
  , "travel-book"
  , "琳達"
  , "potion"
  , "魔法藥水"
  , "canon"
  , "這個詞不存在於任何節點"
  ]

blankTextPool :: [Text]
blankTextPool = ["", "   "]

baseMeta :: VaultId -> IdPrefix -> Text -> Meta
baseMeta v p hex =
  Meta
    { metaId = mkId p hex
    , metaVault = v
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

entityOf :: Meta -> Text -> AnyNode
entityOf m body = NEntity Entity {entMeta = m, entBody = body}

assetOf :: Meta -> Maybe LogicalName -> Text -> AnyNode
assetOf m nm body =
  NAsset
    Asset
      { astMeta = m
      , astName = nm
      , astSha256 = Sha256 "0000000000000000"
      , astEntry = "a.png"
      , astExt = Just "png"
      , astKindMeta = Null
      , astLicense = Nothing
      , astAuthor = Nothing
      , astBody = body
      }

-- | 一個節點。@metaVault@ 一定等於它所在的 vault,LAW-9 的
-- @metaVault (shMeta h) == shVault h@ 才在定義域裡。
genNode :: VaultId -> (IdPrefix, Text) -> Gen AnyNode
genNode v (p, hex) = do
  title <- Gen.element titlePool
  summary <- Gen.element summaryPool
  body <- Gen.element bodyPool
  tags <- Gen.subsequence ["canon", "角色"]
  aliases <- Gen.subsequence ["Linda", "琳"]
  st <- Gen.element [Draft, Canon]
  ty <- Gen.element typePool
  let m =
        (baseMeta v p hex)
          { metaTitle = title
          , metaSummary = summary
          , metaTags = tags
          , metaAliases = aliases
          , metaStatus = st
          , metaType = ty
          }
  case p of
    PAst -> do
      nm <- Gen.element namePool
      pure (assetOf m nm body)
    _ -> pure (entityOf m body)

-- | 一份記憶體索引:entity 放主題檔、asset 放 pack 檔。
--
-- @fiReference@ 一律 'False':pipeline 檔沒有任何觀察點把「這一檔是不是
-- reference」交給 'passesFilter'(它只吃 'NodeFilter' 與 'AnyNode'),
-- 因此 @nfIncludeReference@ 對 LAW-2 \/ LAW-4 的參考側是觀察不到的。
mkIndexState :: [AnyNode] -> IndexState
mkIndexState ns = IndexState (Map.fromList (topics <> packs))
  where
    ents = [n | n@(NEntity _) <- ns]
    asts = [n | n@(NAsset _) <- ns]
    wrap n = IndexedNode {inNode = n, inOwner = Nothing}
    topics =
      [ ("topics.md", FileIndex "topics.md" TopicDoc fixedStat False (map wrap ents))
      | not (null ents)
      ]
    packs =
      [ ("pack/pack.md", FileIndex "pack/pack.md" PackDoc fixedStat False (map wrap asts))
      | not (null asts)
      ]

genIndexMap :: Gen (Map VaultId IndexState)
genIndexMap = do
  vs <- Gen.subsequence vaultPool
  entries <-
    mapM
      ( \v -> do
          seeds <- Gen.subsequence nodeSeeds
          ns <- mapM (genNode v) seeds
          pure (v, mkIndexState ns)
      )
      vs
  pure (Map.fromList entries)

genNodeFilter :: Gen NodeFilter
genNodeFilter = do
  prefixes <- Gen.subsequence [PEnt, PAst]
  types <- Gen.subsequence typePool
  status <- Gen.subsequence [Draft, Canon]
  tags <- Gen.subsequence ["canon", "角色"]
  named <- Gen.bool
  incRef <- Gen.bool
  lim <- Gen.int (Range.linear 0 8)
  off <- Gen.int (Range.linear 0 4)
  pure
    emptyNodeFilter
      { nfPrefixes = prefixes
      , nfTypes = types
      , nfStatus = status
      , nfTags = tags
      , nfNamedOnly = named
      , nfIncludeReference = incRef
      , nfLimit = lim
      , nfOffset = off
      }

-- | 一般的查詢:文字條件可有可無,可能只有空白。
genSearchQuery :: Gen SearchQuery
genSearchQuery = do
  txt <-
    Gen.frequency
      [ (1, pure Nothing)
      , (3, Just <$> Gen.element queryTextPool)
      , (1, Just <$> Gen.element blankTextPool)
      ]
  nf <- genNodeFilter
  fs <- Gen.bool
  pure SearchQuery {sqText = txt, sqFilter = nf, sqFacets = fs}

-- | @given isNothing (sqText q)@:直接建構滿足前提的值。
genNoTextQuery :: Gen SearchQuery
genNoTextQuery = do
  q <- genSearchQuery
  pure q {sqText = Nothing}

-- | @given sqFacets q@:直接建構滿足前提的值。
genFacetQuery :: Gen SearchQuery
genFacetQuery = do
  q <- genSearchQuery
  pure q {sqFacets = True}

-- | 有文字條件的查詢,連同那段文字。字彙池裡每一則都有非空的 @words@,
-- 因此 @given sqText q == Just t and not (null (words t))@ 直接成立。
genTextQuery :: Gen (Text, SearchQuery)
genTextQuery = do
  t <- Gen.element queryTextPool
  q <- genSearchQuery
  pure (t, q {sqText = Just t})

--------------------------------------------------------------------------------
-- Example 用的具體索引

entAt :: VaultId -> Text -> Text -> Text -> [Text] -> AnyNode
entAt v hex title body tags =
  entityOf ((baseMeta v PEnt hex) {metaTitle = title, metaTags = tags}) body

astAt :: VaultId -> Text -> Maybe Text -> Text -> AnyNode
astAt v hex nm title =
  assetOf
    ((baseMeta v PAst hex) {metaTitle = title, metaType = TypeKey "asset-image"})
    (LogicalName <$> nm)
    ""

one :: VaultId -> [AnyNode] -> Map VaultId IndexState
one v ns = Map.fromList [(v, mkIndexState ns)]

two :: VaultId -> [AnyNode] -> VaultId -> [AnyNode] -> Map VaultId IndexState
two v1 n1 v2 n2 = Map.fromList [(v1, mkIndexState n1), (v2, mkIndexState n2)]

-- | EX-1:標題「魔法藥水瓶」的 asset。
mPotion :: Map VaultId IndexState
mPotion = one vaultA [astAt vaultA "00000001" Nothing "魔法藥水瓶"]

idPotion :: Id
idPotion = mkId PAst "00000001"

-- | EX-2 \/ EX-3:@name@ 為 @ui_gui_travel-book-frame_001@ 的 asset。
mTravel :: Map VaultId IndexState
mTravel =
  one vaultA [astAt vaultA "00000002" (Just "ui_gui_travel-book-frame_001") ""]

idTravel :: Id
idTravel = mkId PAst "00000002"

-- | EX-4:@title@ 同時含「藥水」與 @potion@。
mMixed :: Map VaultId IndexState
mMixed = one vaultA [entAt vaultA "00000001" "藥水 potion" "" []]

idMixed :: Id
idMixed = mkId PEnt "00000001"

-- | EX-5 \/ EX-6 \/ EX-13:一般的多節點索引。
mPlain :: Map VaultId IndexState
mPlain =
  two
    vaultA
    [ entAt vaultA "00000001" "琳達" "" ["canon"]
    , astAt vaultA "00000003" (Just "ui_gui_map_001") "地圖"
    ]
    vaultB
    [entAt vaultB "00000002" "魔法藥水瓶" "" []]

-- | EX-7:A 有 @ent-00000001@ 與 @ent-00000003@,B 有 @ent-00000002@。
mPaging :: Map VaultId IndexState
mPaging =
  two
    vaultA
    [entAt vaultA "00000001" "甲" "" [], entAt vaultA "00000003" "丙" "" []]
    vaultB
    [entAt vaultB "00000002" "乙" "" []]

-- | EX-8:同一個 id @ent-0000abcd@ 同時在 A 與 B。
mShared :: Map VaultId IndexState
mShared =
  two
    vaultA
    [entAt vaultA "0000abcd" "琳達" "" []]
    vaultB
    [entAt vaultB "0000abcd" "琳達" "" []]

idShared :: Id
idShared = mkId PEnt "0000abcd"

-- | EX-9 \/ EX-10 \/ EX-11:兩個 vault 各兩個 @canon@ 節點。
mCanon :: Map VaultId IndexState
mCanon =
  two
    vaultA
    [ entAt vaultA "00000001" "琳達" "" ["canon"]
    , entAt vaultA "00000002" "金門建築" "" ["canon"]
    ]
    vaultB
    [ entAt vaultB "00000003" "魔法藥水瓶" "" ["canon"]
    , entAt vaultB "00000004" "travel guide" "" ["canon"]
    ]

-- | EX-14:兩個 vault 各有一筆「琳達」。
mLinda :: Map VaultId IndexState
mLinda =
  two
    vaultA
    [entAt vaultA "00000001" "琳達" "" []]
    vaultB
    [entAt vaultB "00000002" "琳達登場" "" []]

facetQuery :: SearchQuery
facetQuery = emptySearchQuery {sqFacets = True}

textQuery :: Text -> SearchQuery
textQuery t = emptySearchQuery {sqText = Just t}

--------------------------------------------------------------------------------
-- spec

-- | 每個 example 60 秒上限;逾時視同失敗。
perItemTimeout :: IO () -> IO ()
perItemTimeout act = do
  r <- timeout (60 * 1000000) act
  maybe (expectationFailure "P-002 測試逾時(60 秒)") pure r

spec :: Spec
spec = around_ perItemTimeout . modifyMaxSuccess (const 100) $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-002#LAW-1" $
    it "equiv:跨 vault 的命中等於各 vault 各自命中的聯集,合併只影響排序與分頁" $
      hedgehog $ do
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        rankHits (srHits (simulateVaults m (searchVaults (wide q))))
          === rankHits (hitsPerVault m (wide q))

  describe "P-002#LAW-2" $
    it "relation:沒有文字條件時退化成結構查詢,分數 0、片段空" $
      hedgehog $ do
        -- given isNothing (sqText q):產生器直接把 sqText 設成 Nothing。
        m <- forAll genIndexMap
        q <- forAll genNoTextQuery
        let hits = srHits (simulateVaults m (searchVaults (wide q)))
        assert (sort (map hitKey hits) == sort (structuralKeys m (sqFilter q)))
        assert (all (== 0) (map shScore hits))
        assert (all T.null (map shSnippet hits))

  describe "P-002#LAW-3" $
    it "bound:有文字條件時每筆分數為正" $
      hedgehog $ do
        -- given sqText q == Just t and not (null (words t)):產生器從字彙池取
        -- 一段非空白的文字,直接設成 sqText。
        m <- forAll genIndexMap
        (_t, q) <- forAll genTextQuery
        let hits = srHits (simulateVaults m (searchVaults (wide q)))
        assert (all (> 0) (map shScore hits))

  describe "P-002#LAW-4" $
    it "equiv:有文字條件時命中集合等於 matchesQuery 與 passesFilter 的純參考" $
      hedgehog $ do
        -- given sqText q == Just t and not (null (words t))
        m <- forAll genIndexMap
        (t, q) <- forAll genTextQuery
        let hits = srHits (simulateVaults m (searchVaults (wide q)))
        sort (map hitKey hits)
          === sort
            ( map
                nodeKey
                ( filter
                    (passesFilter (sqFilter q) . snd)
                    (filter (matchesQuery t . snd) (allNodesIn m))
                )
            )

  describe "P-002#LAW-5" $
    it "invariant:命中的 (vault, id) 兩兩相異" $
      hedgehog $ do
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        let hits = srHits (simulateVaults m (searchVaults q))
        nub (map hitKey hits) === map hitKey hits

  describe "P-002#LAW-6" $
    it "invariant:命中已排序,分數遞減、同分 id 遞增、再同 vault 遞增" $
      hedgehog $ do
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        let hits = srHits (simulateVaults m (searchVaults q))
        rankHits hits === hits

  describe "P-002#LAW-7" $
    it "relation:分頁是對整體切窗,不是各 vault 各切再接" $
      hedgehog $ do
        -- given j >= 0 and k >= 0:產生器的 Range 下界是 0。
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        j <- forAll (Gen.int (Range.linear 0 6))
        k <- forAll (Gen.int (Range.linear 0 6))
        srHits (simulateVaults m (searchVaults (page j k q)))
          === take k (drop j (srHits (simulateVaults m (searchVaults (wide q)))))

  describe "P-002#LAW-8" $
    it "invariant:總數不隨分頁變,且等於不分頁時的命中數" $
      hedgehog $ do
        -- given j >= 0 and k >= 0
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        j <- forAll (Gen.int (Range.linear 0 6))
        k <- forAll (Gen.int (Range.linear 0 6))
        srTotal (simulateVaults m (searchVaults (page j k q)))
          === length (srHits (simulateVaults m (searchVaults (wide q))))

  describe "P-002#LAW-9" $
    it "relation:每筆的 shVault 等於它 meta 的 vault,且在集合裡" $
      hedgehog $ do
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        let hits = srHits (simulateVaults m (searchVaults q))
        mapM_
          (\h -> assert (metaVault (shMeta h) == shVault h && elem (shVault h) (keysOf m)))
          hits

  describe "P-002#LAW-10" $
    it "relation:facet 只在要求時出現;fcVaults 的計數加總等於總數" $
      hedgehog $ do
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        let r = simulateVaults m (searchVaults (wide q))
        assert
          ( (isJust (srFacets r) == sqFacets q)
              && maybe True ((== srTotal r) . sum . map snd . fcVaults) (srFacets r)
          )

  describe "P-002#LAW-11" $
    it "invariant:fcTypes 不因 nfTypes 改變" $
      hedgehog $ do
        -- given sqFacets q:產生器直接把 sqFacets 設成 True。
        m <- forAll genIndexMap
        q <- forAll genFacetQuery
        ts <- forAll (Gen.subsequence typePool)
        let r = simulateVaults m (searchVaults (wide q))
            r2 = simulateVaults m (searchVaults (wide (withTypes ts q)))
        fmap fcTypes (srFacets r2) === fmap fcTypes (srFacets r)

  describe "P-002#LAW-12" $
    it "invariant:fcTags 不因 nfTags 改變" $
      hedgehog $ do
        -- given sqFacets q
        m <- forAll genIndexMap
        q <- forAll genFacetQuery
        tags <- forAll (Gen.subsequence ["canon", "角色", "主角"])
        let r = simulateVaults m (searchVaults (wide q))
            r2 = simulateVaults m (searchVaults (wide (withTags tags q)))
        fmap fcTags (srFacets r2) === fmap fcTags (srFacets r)

  describe "P-002#LAW-13" $
    it "relation:只認集合裡的 vault,inVault 對集合外的回 Nothing" $
      hedgehog $ do
        m <- forAll genIndexMap
        v <- forAll (Gen.element (vaultMissing : vaultPool))
        isJust (simulateVaults m (inVault v (pure ()))) === Map.member v m

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-002#EX-1" $
    it "中文二字命中該 asset,分數為正,片段含「藥水」" $ do
      let hits = srHits (simulateVaults mPotion (searchVaults (textQuery "藥水")))
      map hitKey hits `shouldBe` [(vaultA, idPotion)]
      all ((> 0) . shScore) hits `shouldBe` True
      all (T.isInfixOf "藥水" . shSnippet) hits `shouldBe` True

  describe "P-002#EX-2" $
    it "英文邏輯名稱命中,- 不被當運算子" $ do
      let hits = srHits (simulateVaults mTravel (searchVaults (textQuery "travel-book")))
      map hitKey hits `shouldBe` [(vaultA, idTravel)]

  describe "P-002#EX-3" $
    it "純 ASCII 二字查詢是空結果而不是錯誤" $ do
      let r = simulateVaults mTravel (searchVaults (textQuery "ui"))
      srHits r `shouldBe` []
      srTotal r `shouldBe` 0

  describe "P-002#EX-4" $
    it "同一節點被兩張表命中只出現一筆" $ do
      let hits = srHits (simulateVaults mMixed (searchVaults (textQuery "藥水 potion")))
      map hitKey hits `shouldBe` [(vaultA, idMixed)]

  describe "P-002#EX-5" $
    it "emptySearchQuery 退化成結構查詢,分數 0、片段空、無 facet" $ do
      let r = simulateVaults mPlain (searchVaults emptySearchQuery)
          hits = srHits r
      sort (map hitKey hits)
        `shouldBe` sort (structuralKeys mPlain (sqFilter emptySearchQuery))
      map shScore hits `shouldBe` map (const 0) hits
      map shSnippet hits `shouldBe` map (const "") hits
      srFacets r `shouldBe` Nothing

  describe "P-002#EX-6" $
    it "只有空白的文字條件視同沒有文字條件" $ do
      let r = simulateVaults mPlain (searchVaults (textQuery "   "))
          hits = srHits r
      r `shouldBe` simulateVaults mPlain (searchVaults emptySearchQuery)
      sort (map hitKey hits)
        `shouldBe` sort (structuralKeys mPlain (sqFilter emptySearchQuery))
      map shScore hits `shouldBe` map (const 0) hits
      map shSnippet hits `shouldBe` map (const "") hits
      srFacets r `shouldBe` Nothing

  describe "P-002#EX-7" $
    it "視窗跨過 vault 邊界:page 1 1 取到 B 的 ent-00000002" $ do
      let hits =
            srHits (simulateVaults mPaging (searchVaults (page 1 1 emptySearchQuery)))
      map hitKey hits `shouldBe` [(vaultB, mkId PEnt "00000002")]

  describe "P-002#EX-8" $
    it "同一個 id 在兩個 vault 各出現一次,A 在前" $ do
      let hits = srHits (simulateVaults mShared (searchVaults emptySearchQuery))
      map hitKey hits `shouldBe` [(vaultA, idShared), (vaultB, idShared)]
      map shVault hits `shouldBe` [vaultA, vaultB]

  describe "P-002#EX-9" $
    it "跨 vault 的 tag 計數相加;fcVaults 加總等於 srTotal" $ do
      let r = simulateVaults mCanon (searchVaults facetQuery)
      fmap fcTags (srFacets r) `shouldBe` Just [("canon", 4)]
      fmap (sum . map snd . fcVaults) (srFacets r) `shouldBe` Just (srTotal r)

  describe "P-002#EX-10" $
    it "fcTypes 與不加型別條件時逐筆相同" $ do
      let r = simulateVaults mCanon (searchVaults facetQuery)
          r2 =
            simulateVaults
              mCanon
              (searchVaults (withTypes [TypeKey "character-fragment"] facetQuery))
      fmap fcTypes (srFacets r2) `shouldBe` fmap fcTypes (srFacets r)

  describe "P-002#EX-11" $
    it "fcTags 與不加標籤條件時逐筆相同" $ do
      let r = simulateVaults mCanon (searchVaults facetQuery)
          r2 = simulateVaults mCanon (searchVaults (withTags ["canon"] facetQuery))
      fmap fcTags (srFacets r2) `shouldBe` fmap fcTags (srFacets r)

  describe "P-002#EX-12" $
    it "集合裡沒有這個 vault 時 inVault 回 Nothing" $
      simulateVaults mCanon (inVault vaultMissing (pure ())) `shouldBe` Nothing

  describe "P-002#EX-13" $
    it "誰都不命中的查詢是空結果" $ do
      let r =
            simulateVaults mPlain (searchVaults (textQuery "這個詞不存在於任何節點"))
      srHits r `shouldBe` []
      srTotal r `shouldBe` 0

  describe "P-002#EX-14" $
    it "rankHits 後與逐 vault 各查再串接的結果相同" $ do
      let q = wide (textQuery "琳達")
      rankHits (srHits (simulateVaults mLinda (searchVaults q)))
        `shouldBe` rankHits (hitsPerVault mLinda q)
