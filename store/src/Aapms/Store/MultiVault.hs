-- | 跨 vault 讀:'VaultSet' 的 @ATTACH@、UNION、'Aapms.Core.Id.Ref' 解析與懸空
-- 引用檢查(graph-core\/F009;ADR-017 第四條)。
--
-- == 讀跨、寫單一
--
-- ADR-017 第三條把「查詢」與「寫入」分成兩種範圍:查詢預設看遍全部生效的
-- vault、每筆結果帶自己的 'Aapms.Core.Id.VaultId';寫入永遠指定單一 vault。
-- 本模組是前者的落地,所以它__只有讀__:契約 E 的每一個寫入函式收的都是
-- 'Aapms.Store.Marker.VaultHandle',沒有任何一個收 'VaultSet',這件事由型別
-- 本身保證,不需要執行期檢查。
--
-- __本模組不決定「本次生效哪些 vault」__:那是 @workspace@ 子系統的職責
-- (它讀中樞註冊表、處理 @--vault@)。呼叫端把已經 'Aapms.Store.Marker.openVault'
-- 開好的把手清單交進來,本模組只負責把它們接成一個可查詢的整體。
--
-- == 短 id 只在 vault 內唯一(ADR-014)
--
-- 這是跨 vault 這條路上最容易安靜出錯的地方:兩個 vault 各自有一個
-- @ent-7f3b2a91@ 是完全合法的。任何以 'Aapms.Core.Id.Id' 單獨當鍵的合併、去重
-- 或 Map 索引都會讓其中一筆__消失__,而結果看起來仍然「正常」。跨 vault 的
-- 身分一律是 __('Aapms.Core.Id.VaultId', 'Aapms.Core.Id.Id') 這一對__,對外的
-- 定址形式是 @\<vault\>:\<id\>@('Aapms.Core.Id.Ref')。
--
-- == 排序與分頁
--
-- 跨 vault 的排序與分頁必須對__合併後的整體__成立,不是「各 vault 各自排完再
-- 接起來」——後者在兩個 vault 的排序鍵交錯時會給出完全不同的頁面內容。
--
-- __在哪一層合併是分案的__(ADR-017 第四條 2026-08-26 修訂):
--
-- * 'listAcross' __走 SQL__:重用 "Aapms.Store.Query" 的
--   'Aapms.Store.Query.whereOfIn' 條件片段,對加了 schema 前綴的 UNION 視圖
--   執行,排序與分頁在 SQL 層完成——與單一 vault 的
--   'Aapms.Store.Query.listNodes' 走同一條路。
-- * 'searchAcross' __走 Haskell__:各 vault 各自取命中,兩張 FTS 表 × N 個
--   vault 的 bm25 分數在 Haskell 合併去重後排序分頁——與單一 vault 的
--   'Aapms.Store.Query.search' 走同一條路。
--
-- == 'VaultSet' 的宣告在哪裡(P-002-search)
--
-- 'searchAcross' 現在是 P-002-search 的 @!@ 列:本體只做「跑真解譯器」
-- (@runEff (runVaultsIO vs (searchVaults q))@),整條流程住 pure 層的
-- "Aapms.Store.Search"。'VaultSet' 與它的生命週期因此搬到
-- "Aapms.Store.Effect.Vaults.IO" ——'Aapms.Store.Effect.Vaults.Vaults' 的真解譯器
-- 就是把效果跑在 'VaultSet' 上的那段程式,兩者分居兩個模組會形成模組環。本模組
-- 原樣 re-export 那四個名字,__契約 E 的簽名與呼叫端逐字不變__,'VaultSet' 也
-- 依舊不透明(建構子不匯出)。
module Aapms.Store.MultiVault
  ( -- * VaultSet
    VaultSet
  , maxAttachedVaults
  , openVaultSet
  , closeVaultSet
  , vaultSetIds

    -- * 跨 vault 查詢
  , lookupRef
  , listAcross
  , searchAcross

    -- * 懸空引用
  , DanglingRef (..)
  , DanglingReason (..)
  , checkReferences
  , renderDanglingRef
  ) where

import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe, isNothing, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection, Query (..), query)
import Effectful (runEff)
import Aapms.Core.AnyNode (AnyNode)
import Aapms.Core.Id (Id, Ref (..), VaultId (..), parseId, renderId, renderRef)
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta (Meta (metaId))
import Aapms.Store.Effect.Vaults.IO
  ( VaultSet
  , closeVaultSet
  , findHandle
  , maxAttachedVaults
  , openVaultSet
  , runVaultsIO
  , vaultSetConn
  , vaultSetEntries
  , vaultSetIds
  )
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..))
import Aapms.Store.Query
  ( NodeFilter (..)
  , SearchQuery
  , SearchResult
  , baseFromIn
  , loadLinkGraph
  , lookupNode
  , whereOfIn
  )
import Aapms.Store.Search (searchVaults)
import Aapms.Store.Row
  ( LinkRow (..)
  , NodeRow (..)
  , groupPairs
  , inList
  , nodeColumns
  , rowToMeta
  , toLink
  )
import Aapms.Store.Row.Sql (sInt, sText)

--------------------------------------------------------------------------------
-- 跨 vault 查詢

-- | 解析一個 'Aapms.Core.Id.Ref' 到它指向的節點。
--
-- 第二個參數是__不帶 vault 的 'Aapms.Core.Id.Ref' 的預設 vault__(契約 E):
-- @refVault = Nothing@ 時以它為準,@refVault = Just v@ 時以 @v@ 為準,即使
-- @v@ 就是預設 vault 也一樣。目標 vault 不在這個 'VaultSet' 裡、或在裡面但查
-- 不到那個 id 時,兩種情況都回 'Nothing'(要區分兩者請用 'checkReferences')。
lookupRef :: VaultSet -> VaultId -> Ref -> IO (Maybe (VaultId, AnyNode))
lookupRef vs defVault (Ref mv i) =
  let target = fromMaybe defVault mv
   in case findHandle vs target of
        Nothing -> pure Nothing
        Just h -> fmap ((,) target) <$> lookupNode h i

-- | 跨 vault 的條件列舉,語意與單一 vault 的 'Aapms.Store.Query.listNodes'
-- 完全相同,差別只在:結果涵蓋全部 vault、每筆帶自己的
-- 'Aapms.Core.Id.VaultId',而排序與分頁對__合併後的整體__成立。
listAcross :: VaultSet -> NodeFilter -> IO [(VaultId, Meta)]
listAcross vs filt
  | null aliased = pure []
  | otherwise = crossListIds (vaultSetConn vs) aliased filt >>= hydratePairs vs
  where
    aliased = vaultSetEntries vs

-- | 對 @ATTACH@ 好的每個 schema 各組一段 @SELECT@,以 @UNION ALL@ 接起來,
-- 排序與分頁在整段 compound @SELECT@ 上完成(ADR-017 第四條修訂:'listAcross'
-- 走 SQL)。回傳的是尚未 hydrate 的 (vault, id) 配對,依全域順序排好、切好頁。
crossListIds :: Connection -> [(VaultId, VaultHandle, Text)] -> NodeFilter -> IO [(VaultId, Id)]
crossListIds conn aliased filt = do
  let perVault (VaultId vidText, _, prefix) =
        let (cond, args) = whereOfIn prefix filt
            sqlPart = "SELECT ? AS vid, n.id AS nid " <> baseFromIn prefix <> " WHERE 1 = 1" <> cond
         in (sqlPart, sText vidText : args)
      parts = map perVault aliased
      sql =
        T.intercalate " UNION ALL " (map fst parts)
          <> " ORDER BY nid ASC, vid ASC LIMIT ? OFFSET ?"
      params = concatMap snd parts ++ [sInt (nfLimit filt), sInt (nfOffset filt)]
  rows <- query conn (Query sql) params :: IO [(Text, Text)]
  pure [(VaultId v, i) | (v, idText) <- rows, Right (_, i) <- [parseId idText]]

-- | 把 (vault, id) 配對逐 vault 批次 hydrate 成 'Meta',再依原始順序組回去。
hydratePairs :: VaultSet -> [(VaultId, Id)] -> IO [(VaultId, Meta)]
hydratePairs vs pairs = do
  let byVault = M.fromListWith (flip (++)) [(v, [i]) | (v, i) <- pairs]
  tables <-
    mapM
      ( \(v, ids) -> case findHandle vs v of
          Nothing -> pure (v, M.empty)
          Just h -> (,) v <$> hydrateMap h ids
      )
      (M.toList byVault)
  let tableOf = M.fromList tables
  pure
    [ (v, m)
    | (v, i) <- pairs
    , Just innerMap <- [M.lookup v tableOf]
    , Just m <- [M.lookup i innerMap]
    ]

hydrateMap :: VaultHandle -> [Id] -> IO (M.Map Id Meta)
hydrateMap h ids = M.fromList . map (\m -> (metaId m, m)) <$> hydrateIds h ids

-- | 依一批 id 批次撈回 'Meta'(含 tags\/aliases\/links),__逐字比照__
-- "Aapms.Store.Query" 私有的 @metasFor@ 這一套組裝方式(同樣的三段 SQL、同樣的
-- 'rowToMeta'):@metasFor@ 沒有匯出,但它用到的每一塊建材
-- ('rowToMeta' \/ 'toLink' \/ 'groupPairs' \/ 'LinkRow') 都有匯出。這裡__不能__
-- 改用 'Aapms.Store.Row.hydrateMeta' 逐列查詢——那個函式對 tags\/aliases 的
-- SQL 加了 @ORDER BY rowid@,與 @metasFor@ 沒有排序的批次查詢在同一份資料上
-- 可能給出不同的實際列序,'Meta' 的 @metaTags@\/@metaLinks@ 是 list 而非
-- set,order 不同會讓 'listAcross' 與單一 vault 'Aapms.Store.Query.listNodes'
-- 的 'Meta' 不相等(LAW-4\/LAW-19\/EX-11 靠這個抓到)。
hydrateIds :: VaultHandle -> [Id] -> IO [Meta]
hydrateIds _ [] = pure []
hydrateIds h ids = do
  let idTexts = map renderId ids
      conn = vhConn h
      vid = vmId (vhMarker h)
      n = length idTexts
  rows <-
    query
      conn
      (Query ("SELECT " <> nodeColumns <> " FROM nodes WHERE id IN " <> inList n))
      (map sText idTexts) ::
      IO [NodeRow]
  aliases <- grouped conn "SELECT node_id, alias FROM node_aliases WHERE node_id IN " idTexts
  tags <- grouped conn "SELECT node_id, tag FROM node_tags WHERE node_id IN " idTexts
  linkRows <-
    query
      conn
      ( Query
          ( "SELECT src, dst_vault, dst, kind, note FROM links WHERE src IN "
              <> inList n
              <> " ORDER BY rowid"
          )
      )
      (map sText idTexts) ::
      IO [LinkRow]
  let linksByNode = groupPairs [(renderId s, [l]) | (s, l) <- mapMaybe toLink linkRows]
  pure
    [ m
    | r <- rows
    , Just m <-
        [ rowToMeta
            vid
            r
            (M.findWithDefault [] (nrId r) aliases)
            (M.findWithDefault [] (nrId r) tags)
            (M.findWithDefault [] (nrId r) linksByNode)
        ]
    ]
  where
    grouped conn sql idTexts = do
      rs <- query conn (Query (sql <> inList (length idTexts))) (map sText idTexts) :: IO [(Text, Text)]
      pure (groupPairs [(k, [v]) | (k, v) <- rs])

-- | 跨 vault 的全文檢索(P-002-search 的 @!@ 列)。
--
-- __本體只做「跑真解譯器」__:整條流程(路由 → 雙 FTS 與結構條件 → 合併去重 →
-- 片段 → 跨 vault 合併 → 排序 → 切窗 → facet 合併)住 pure 層的
-- 'Aapms.Store.Search.searchVaults',效果由
-- 'Aapms.Store.Effect.Vaults.IO.runVaultsIO'(內含
-- 'Aapms.Store.Effect.Index.Sqlite.runIndexSqlite')落地。
--
-- 語意與單一 vault 的 'Aapms.Store.Query.search' 完全相同,差別同 'listAcross';
-- 每筆 'Aapms.Store.Types.shVault' 是該筆命中真正所屬的 vault。相關度分數逐
-- vault 計算(各自的索引各自算 bm25),合併只影響排序與分頁,不改變任何一筆的
-- 分數。
searchAcross :: VaultSet -> SearchQuery -> IO SearchResult
searchAcross vs q = runEff (runVaultsIO vs (searchVaults q))

--------------------------------------------------------------------------------
-- 懸空引用

-- | 一筆指不到目標的關聯(契約 E 的 @DanglingRef@;形狀由本 feature 定,
-- 2026-08-26 ASM-3 裁決,已回寫契約 E)。
--
-- 本子系統的定位是「只說出發生了什麼,不決定怎麼辦」:懸空引用要不要擋、要不
-- 要修,是 @service@ 的事,這裡只把它描述完整。
data DanglingRef = DanglingRef
  { drSource :: Id
  -- ^ 發出這筆關聯的節點(一定在 'checkReferences' 的那個 vault 裡)
  , drLink :: Link
  -- ^ 原樣保留的關聯:'Aapms.Core.Link.linkKind' \/
  -- 'Aapms.Core.Link.linkTarget' \/ 'Aapms.Core.Link.linkNote' 都是檔案裡寫的
  -- 那一份,'Aapms.Core.Link.linkTarget' 的 @refVault@ 可能是 'Nothing'
  , drTarget :: Ref
  -- ^ 已經套用預設 vault 之後的目標,@refVault@ 恆為 @Just@ ——「它到底去找了
  -- 哪個 vault」是診斷這種問題時最先要知道的事
  , drReason :: DanglingReason
  }
  deriving stock (Show, Eq)

-- | 懸空的兩種成因。分開是因為修法不同:vault 沒掛上是__呼叫端的 vault 集合__
-- 不完整(補一個 @--vault@ 或註冊一個 vault 就好,資料本身沒問題);節點查不到
-- 才是__資料__的問題。
data DanglingReason
  = -- | 'drTarget' 的 vault 不在這個 'VaultSet' 裡
    TargetVaultAbsent
  | -- | vault 在這個 'VaultSet' 裡,但它查不到 'drTarget' 的那個 id
    TargetNodeMissing
  deriving stock (Show, Eq)

-- | 列出__指定的那一個 vault__ 指出去、在這個 'VaultSet' 裡解析不到的全部
-- 關聯(契約 E:「本 vault 指出去的懸空引用」)。
--
-- 不帶 vault 的目標以該 vault 自己的 'Aapms.Store.Marker.vmId' 為預設,與
-- 'lookupRef' 同一套規則。第二個參數的 vault __不必__屬於這個 'VaultSet';
-- 不屬於時它自己指向自己的關聯也照樣走 'TargetVaultAbsent'。
checkReferences :: VaultSet -> VaultHandle -> IO [DanglingRef]
checkReferences vs h = do
  graph <- loadLinkGraph h
  let selfVid = vmId (vhMarker h)
      entries = [(s, l) | (s, ls) <- M.toList graph, l <- ls]
      classify (s, l) = do
        let Ref mv i = linkTarget l
            w = fromMaybe selfVid mv
            t = Ref (Just w) i
        if w `notElem` vaultSetIds vs
          then pure (Just (DanglingRef s l t TargetVaultAbsent))
          else do
            found <- lookupRef vs selfVid t
            pure $
              if isNothing found
                then Just (DanglingRef s l t TargetNodeMissing)
                else Nothing
  catMaybes <$> mapM classify entries

-- | 繁中訊息,__說出下一步該做什麼__(契約 G 對 @render*@ 的要求;
-- 'Aapms.Store.Schema.renderIndexIssue' 是同一個模式的先例)。
renderDanglingRef :: DanglingRef -> Text
renderDanglingRef DanglingRef {..} = case drReason of
  TargetVaultAbsent ->
    "節點 "
      <> renderId drSource
      <> " 的關聯("
      <> renderLinkKind (linkKind drLink)
      <> " -> "
      <> renderRef drTarget
      <> ")指向的 vault 不在目前查詢的集合裡;請加入該 vault,或改用 --vault 註冊後再試"
  TargetNodeMissing ->
    "節點 "
      <> renderId drSource
      <> " 的關聯("
      <> renderLinkKind (linkKind drLink)
      <> " -> "
      <> renderRef drTarget
      <> ")指向的節點不存在於該 vault 的索引裡;請確認 id 是否正確,或該節點是否已被刪除"
