-- | lawful 測試:P-002-search 的 law 在 __sqlite 真解譯器__ 上再驗一次。
--
-- P-002-search 的決定:「LAW-4 同時是 sqlite 解譯器的驗收:conductor 對真解譯器
-- 也跑一份同歸屬的測試」——理由是純解譯器用 'matchesQuery' 定義 @ftsMatch@,
-- 只在純側跑等於套套邏輯;sqlite 側跑才證明兩個解譯器一致。因此本模組的歸屬
-- 字串與 "Aapms.Lawful.P002Spec" __相同__(同一條 law 的另一個解譯器),
-- @it@ 的文字註明「sqlite」以區分。
--
-- __三條 law__:
--
-- * __LAW-4__(必要):有文字條件時,sqlite 的命中集合等於逐節點以
--   'matchesQuery' 與 @passesFilter@('visibleNodes')判定的__純參考__。右邊
--   逐字照 pipeline 檔的 @|-@ 行,是純的;左邊換成真解譯器。這一條同時驗到
--   「FTS 的 @MATCH@ 與 'matchesQuery' 一致」和「SQL 的 @WHERE@ 與
--   @passesFilter@ 一致」。
-- * __LAW-2__(照搬得動):沒有文字條件時退化成結構查詢,右邊的
--   'structuralKeys' 同樣是純參考,可以逐字照搬。
-- * __LAW-1__(__形狀相同、參考換成同一個解譯器__):pipeline 的 @|-@ 行右邊是
--   純的 @hitsPerVault m (wide q)@。它__不能__逐字搬到 sqlite 上——P-002 的決定
--   寫明「純解譯器的分數是常數 1.0,真解譯器的分數是 sqlite @bm25()@ 取負」,
--   而 @rankHits@ 比的是四欄全等的 'SearchHit',分數與片段本來就不同。這裡改用
--   __同一個解譯器__ 的逐 vault 版本當右邊(每個把手各開一個單 vault
--   'VaultSet' 各查一次再串接),驗的仍是「跨 vault 的命中等於各 vault 各自命中
--   的聯集,合併只影響排序與分頁」。歸因時請把這一點算進去:它紅只證明跨
--   vault 合併有問題,不證明兩個解譯器分岔。
--
-- __三個前提直接建構,不過濾__(sqlite 的 schema 比記憶體索引嚴格):
--
-- * 全 vault 內節點 id 唯一(@nodes.id@ 是主鍵)——'nodeSeeds' 取子序列,加上
--   固定的 @pck-00000005@,同一個 vault 內兩兩相異。
-- * 邏輯名稱唯一(@assets.name UNIQUE@)——'namePoolFor' 讓兩個 asset seed 各自
--   只抽得到__自己那一個__名稱,同一個 vault 內不可能撞名(這是本模組與
--   "Aapms.Lawful.P002Spec" 的產生器__唯一__的差別:純側沒有這個約束)。
-- * 'fiPath' 是 @\/@ 分隔的相對路徑(@topics.md@ \/ @pack\/pack.md@),
--   'metaCreated' \/ 'metaUpdated' 固定 @2026-01-01@,@%Y-%m-%d@ 往返得回來。
--
-- __案例數__:每個案例都要真的開 sqlite vault、建 schema、灌索引列,因此
-- @modifyMaxSuccess (const 30)@;每個 example 套 'around_' 120 秒上限。
module Aapms.Lawful.P002SqliteSpec (spec) where

import Data.Aeson (Value (Null))
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)

import Effectful (runEff)
import Hedgehog (Gen, evalIO)
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
import Aapms.Core.Pack (AiDisclosure (..), Pack (..))
import Aapms.Md.Document (DocKind (..))

import Aapms.Store.Effect.Index (replaceFile)
import Aapms.Store.Effect.Index.Sqlite (runIndexSqlite)
import Aapms.Store.Effect.Vaults.IO (runVaultsIO)
import Aapms.Store.Fixtures (orDie, testRegistry, writeFiles)
import Aapms.Store.Marker (VaultHandle (..), closeVault, openVault)
import Aapms.Store.MultiVault (VaultSet, closeVaultSet, openVaultSet)
import Aapms.Store.Search (rankHits, searchVaults)
import Aapms.Store.Search.Internal (structuralKeys, visibleNodes)
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
  , emptyNodeFilter
  , hitKey
  , nodeKey
  , wide
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
  Left e -> error ("P-002SqliteSpec:測試 id 不合法 " <> show e)

vaultA, vaultB, vaultC :: VaultId
vaultA = VaultId "vlt-0000000a"
vaultB = VaultId "vlt-0000000b"
vaultC = VaultId "vlt-0000000c"

vaultPool :: [VaultId]
vaultPool = [vaultA, vaultB, vaultC]

typePool :: [TypeKey]
typePool = [TypeKey "character-fragment", TypeKey "asset-image"]

--------------------------------------------------------------------------------
-- 產生器(與 "Aapms.Lawful.P002Spec" 同源,差別只在 'namePoolFor')

-- | 一個 vault 裡最多四個節點的身分。前綴兩 ent 兩 ast,'nfPrefixes' 才篩得動;
-- 同一個 vault 內取子序列,所以 id 不重複(@nodes.id@ 是主鍵),跨 vault 則會
-- 重複。
nodeSeeds :: [(IdPrefix, Text)]
nodeSeeds =
  [ (PEnt, "00000001")
  , (PEnt, "00000002")
  , (PAst, "00000003")
  , (PAst, "00000004")
  ]

-- | 節點文字欄位的字彙池。刻意與 'queryTextPool' 有交集,查詢才真的打得到東西。
titlePool :: [Text]
titlePool = ["魔法藥水瓶", "琳達", "金門建築", "travel guide", ""]

summaryPool :: [Text]
summaryPool = ["", "藥水 potion", "開場"]

bodyPool :: [Text]
bodyPool = ["", "travel-book frame", "藥水"]

-- | 每個 asset seed __自己那一個__候選名稱(外加 'Nothing')。
--
-- @assets.name@ 在 sqlite 索引裡是 @UNIQUE@:純側的產生器讓兩個 asset 各自從
-- 同一個池子抽,同一個 vault 內抽到同一個名稱就會撞主鍵,那是產生器沒建好前提
-- 而不是兩個解譯器分岔。這裡把池子依 seed 切開,__直接建構__滿足唯一性的值。
namePoolFor :: Text -> [Maybe LogicalName]
namePoolFor "00000003" = [Nothing, Just (LogicalName "ui_gui_travel-book-frame_001")]
namePoolFor _ = [Nothing, Just (LogicalName "ui_gui_map_001")]

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

-- | 一個節點。@metaVault@ 一定等於它所在的 vault(marker 的 @id@ 與 map 的鍵
-- 也是同一個值),真解譯器從 @meta_info.vault_id@ 填回來的 @metaVault@ 才對得上。
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
      nm <- Gen.element (namePoolFor hex)
      pure (assetOf m nm body)
    _ -> pure (entityOf m body)

-- | pack 檔的檔案層主體。id 與 'nodeSeeds' 的四個都不同。
packSeed :: Text
packSeed = "00000005"

packId :: Id
packId = mkId PPck packSeed

packNodeAt :: VaultId -> AnyNode
packNodeAt v =
  NPack
    Pack
      { pckMeta = (baseMeta v PPck packSeed) {metaType = TypeKey "asset-pack"}
      , pckVendor = Nothing
      , pckArchive = Nothing
      , pckSha256 = Nothing
      , pckLicense = Nothing
      , pckAuthor = Nothing
      , pckSourceUrl = Nothing
      , pckAiDisclosure = AiUnknown
      , pckBody = ""
      }

-- | 一份記憶體索引:entity 放主題檔、asset 放 pack 檔。路徑都是 @\/@ 分隔的
-- 相對路徑。
mkIndexStateWith :: Bool -> Bool -> Maybe VaultId -> [AnyNode] -> IndexState
mkIndexStateWith refTopics refPack owner ns =
  IndexState (Map.fromList (topics <> packs))
  where
    ents = [n | n@(NEntity _) <- ns]
    asts = [n | n@(NAsset _) <- ns]
    free n = IndexedNode {inNode = n, inOwner = Nothing}
    owned n = IndexedNode {inNode = n, inOwner = Just packId}
    packRows = case owner of
      Nothing -> map free asts
      Just v -> free (packNodeAt v) : map owned asts
    topics =
      [ ("topics.md", FileIndex "topics.md" TopicDoc fixedStat refTopics (map free ents))
      | not (null ents)
      ]
    packs =
      [ ("pack/pack.md", FileIndex "pack/pack.md" PackDoc fixedStat refPack packRows)
      | not (null asts)
      ]

-- | 產生器側的一份索引:每個檔的 @fiReference@ 各自取 'True' \/ 'False',
-- pack 檔的 asset 各半有無 @inOwner@。
genIndexState :: VaultId -> [AnyNode] -> Gen IndexState
genIndexState v ns = do
  refTopics <- Gen.bool
  refPack <- Gen.bool
  hasOwner <- Gen.bool
  pure (mkIndexStateWith refTopics refPack (if hasOwner then Just v else Nothing) ns)

genIndexMap :: Gen (Map VaultId IndexState)
genIndexMap = do
  vs <- Gen.subsequence vaultPool
  entries <-
    mapM
      ( \v -> do
          seeds <- Gen.subsequence nodeSeeds
          ns <- mapM (genNode v) seeds
          st <- genIndexState v ns
          pure (v, st)
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
  owner <- Gen.element [Nothing, Just packId]
  lim <- Gen.int (Range.linear 0 8)
  off <- Gen.int (Range.linear 0 4)
  pure
    emptyNodeFilter
      { nfPrefixes = prefixes
      , nfTypes = types
      , nfStatus = status
      , nfTags = tags
      , nfOwner = owner
      , nfNamedOnly = named
      , nfIncludeReference = incRef
      , nfLimit = lim
      , nfOffset = off
      }

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

-- | @given sqText q == Just t and not (null (words t))@:字彙池裡每一則都有非空
-- 的 @words@,直接建構。
genTextQuery :: Gen (Text, SearchQuery)
genTextQuery = do
  t <- Gen.element queryTextPool
  q <- genSearchQuery
  pure (t, q {sqText = Just t})

--------------------------------------------------------------------------------
-- sqlite 真解譯器的架設

-- | @.aapms\/config.toml@:@id@ 逐字等於 map 的鍵,真解譯器填回來的
-- @metaVault@ 才與產生器建構的 'metaVault' 相同。
markerToml :: VaultId -> Text
markerToml (VaultId v) =
  T.unlines
    [ "id   = \"" <> v <> "\""
    , "kind = \"story\""
    , "name = \"p002-sqlite\""
    , "refs = []"
    ]

fileIndexes :: IndexState -> [FileIndex]
fileIndexes (IndexState m) = Map.elems m

-- | 開一個暫存 vault,並__走效果本身__把 'IndexState' 灌進索引(不經
-- @rebuildIndex@:law 的定義域是 'IndexState',從 markdown 走一遍會多一層轉換)。
openLoadedVault :: FilePath -> VaultId -> IndexState -> IO VaultHandle
openLoadedVault dir v ix = do
  writeFiles dir [(".aapms/config.toml", markerToml v)]
  (h, _issues) <- orDie =<< openVault testRegistry dir
  runEff (runIndexSqlite (vhConn h) (mapM_ replaceFile (fileIndexes ix)))
  pure h

-- | 每個 @(vid, ix)@ 各開一個暫存 vault,順序與 map 的鍵序相同。
withLoadedVaults :: Map VaultId IndexState -> ([VaultHandle] -> IO a) -> IO a
withLoadedVaults m act = go (Map.toList m) []
  where
    go [] acc = act (reverse acc)
    go ((v, ix) : rest) acc =
      withSystemTempDirectory "aapms-p002s" $ \dir -> do
        h <- openLoadedVault dir v ix
        r <- go rest (h : acc)
        closeVault h
        pure r

withLoadedVaultSet :: Map VaultId IndexState -> (VaultSet -> IO a) -> IO a
withLoadedVaultSet m act = withLoadedVaults m $ \hs -> withSetOf hs act

withSetOf :: [VaultHandle] -> (VaultSet -> IO a) -> IO a
withSetOf hs act = do
  vs <- orDie =<< openVaultSet hs
  r <- act vs
  closeVaultSet vs
  pure r

-- | @=@ 列 'searchVaults' 跑在 'Vaults' 的真解譯器上。
runSearch :: VaultSet -> SearchQuery -> IO SearchResult
runSearch vs q = runEff (runVaultsIO vs (searchVaults q))

-- | LAW-1 的右邊:__同一個解譯器__ 的逐 vault 版本(每個把手各開一個單 vault
-- 'VaultSet' 各查一次再串接)。見模組說明。
hitsPerVaultSqlite :: [VaultHandle] -> SearchQuery -> IO [SearchHit]
hitsPerVaultSqlite hs q =
  concat <$> mapM (\h -> withSetOf [h] (fmap srHits . flip runSearch q)) hs

--------------------------------------------------------------------------------
-- spec

-- | 每個 example 120 秒上限(每個案例都要開 sqlite);逾時視同失敗。
perItemTimeout :: IO () -> IO ()
perItemTimeout act = do
  r <- timeout (120 * 1000000) act
  maybe (expectationFailure "P-002 sqlite 測試逾時(120 秒)") pure r

spec :: Spec
spec = around_ perItemTimeout . modifyMaxSuccess (const 30) $ do
  describe "P-002#LAW-1" $
    it "equiv(sqlite):跨 vault 的命中等於各 vault 各自命中的聯集,合併只影響排序與分頁" $
      hedgehog $ do
        m <- forAll genIndexMap
        q <- forAll genSearchQuery
        (across, perVault) <- evalIO $ withLoadedVaults m $ \hs -> do
          hitsAcross <- withSetOf hs (fmap srHits . flip runSearch (wide q))
          hitsEach <- hitsPerVaultSqlite hs (wide q)
          pure (hitsAcross, hitsEach)
        rankHits across === rankHits perVault

  describe "P-002#LAW-2" $
    it "relation(sqlite):沒有文字條件時退化成結構查詢,分數 0、片段空" $
      hedgehog $ do
        -- given isNothing (sqText q):產生器直接把 sqText 設成 Nothing。
        m <- forAll genIndexMap
        q <- forAll genNoTextQuery
        hits <- evalIO $ withLoadedVaultSet m (fmap srHits . flip runSearch (wide q))
        assert (sort (map hitKey hits) == sort (structuralKeys m (sqFilter q)))
        assert (all (== 0) (map shScore hits))
        assert (all T.null (map shSnippet hits))

  describe "P-002#LAW-4" $
    it "equiv(sqlite):有文字條件時命中集合等於 matchesQuery 與 passesFilter 的純參考" $
      hedgehog $ do
        -- given sqText q == Just t and not (null (words t))
        m <- forAll genIndexMap
        (t, q) <- forAll genTextQuery
        hits <- evalIO $ withLoadedVaultSet m (fmap srHits . flip runSearch (wide q))
        sort (map hitKey hits)
          === sort
            ( map
                nodeKey
                (filter (matchesQuery t . snd) (visibleNodes (sqFilter q) m))
            )
