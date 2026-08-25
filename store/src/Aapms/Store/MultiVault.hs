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

import Data.Text (Text)
import Database.SQLite.Simple (Connection)
import Aapms.Core.AnyNode (AnyNode)
import Aapms.Core.Id (Id, Ref, VaultId)
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Meta)
import Aapms.Store.Error (StoreError)
import Aapms.Store.Marker (VaultHandle)
import Aapms.Store.Query (NodeFilter, SearchQuery, SearchResult)

--------------------------------------------------------------------------------
-- VaultSet

-- | 一組被接成整體、__只供讀取__的 vault(契約 E 寫的是 @data VaultSet@,
-- 不透明)。
--
-- 建構子與內部欄位都__不匯出__:'VaultSet' 的表示法不是契約的一部分,只有
-- 'vaultSetIds' / 'listAcross' / 'searchAcross' / 'lookupRef' /
-- 'checkReferences' 這幾個出口的行為才是。骨架裡的兩個欄位(去重後的把手清單、
-- 'VaultSet' 自己的讀連線)是為了讓型別編得過而寫的最小表示,__impl 可以依
-- 2026-08-26 A1 裁決的落地方式增刪欄位__,不受「不得改動骨架型別」的限制——這是本
-- spec 對這一個不透明型別的明文豁免。
data VaultSet = VaultSet [VaultHandle] Connection

-- | 一個 'VaultSet' 最多接幾個 vault。
--
-- SQLite 的 @SQLITE_MAX_ATTACHED@ 預設是 10(main 之外可以再 @ATTACH@ 10 個),
-- 契約卡則寫「第 11 個 vault 回 'Aapms.Store.Error.StoreError' 的
-- @TooManyVaults@ 並列出 10」——以__契約卡__為準,上限是 10 個 vault。
maxAttachedVaults :: Int
maxAttachedVaults = undefined

-- | 把一組已經開好的 vault 把手接成一個 'VaultSet'。
--
-- __同一個 'Aapms.Store.Marker.vmId' 出現兩次有兩種成因,處置不同__
-- (2026-08-26 A5 裁決,契約 G):
--
-- * 兩筆的 'Aapms.Store.Marker.vhRoot' __相同__(同一個路徑被傳兩次)——無害的
--   呼叫端疏忽(預設 vault 又被顯式指定一次),__保序去重、只留第一個__,
--   上限也以去重後的數量計。
-- * 兩筆的 'Aapms.Store.Marker.vhRoot' __不同__——依 ADR-017,vault 的身分就是
--   marker 裡的 id,撞號代表有人複製了整個 vault 目錄,此時任何跨 vault 的
--   'Aapms.Core.Id.Ref' 解析都是不確定的,回
--   'Aapms.Store.Error.VaultIdCollision' 並列出__兩個路徑__。靜默去重會把這種
--   情況一起吞掉,症狀是「搜尋結果少了一個 vault 的東西」。
--
-- 去重之後的數量超過 'maxAttachedVaults' 時回 'Aapms.Store.Error.TooManyVaults'。
--
-- __不接管把手的生命週期__:'closeVaultSet' 不會關掉任何一個
-- 'Aapms.Store.Marker.VaultHandle',呼叫端仍然要自己
-- 'Aapms.Store.Marker.closeVault';反過來,'openVaultSet' 之後那些把手照樣可以
-- 單獨拿去做單一 vault 的查詢與__寫入__。
openVaultSet :: [VaultHandle] -> IO (Either StoreError VaultSet)
openVaultSet = undefined

-- | 釋放 'VaultSet' 自己持有的資源(它自己的讀連線),__不__關閉任何
-- 'Aapms.Store.Marker.VaultHandle'。
--
-- 契約 E 原本沒有這個函式(2026-08-26 A2 裁決後已回寫):@openVaultSet@ 自己持有連線,少了
-- 對稱的關閉在 Windows 上會鎖住 @index.db@,連暫存目錄都刪不掉。對不持有任何
-- 資源的實作而言它是 no-op,兩種實作下呼叫端的用法都一樣。
closeVaultSet :: VaultSet -> IO ()
closeVaultSet = undefined

-- | 這個 'VaultSet' 實際涵蓋哪些 vault,依 'openVaultSet' 收到的順序、已去重。
--
-- 'VaultSet' 不透明,少了這個出口就沒有任何辦法從公開介面觀察「去重與上限
-- 到底怎麼作用」(2026-08-26 A2 裁決後已回寫契約 E)。
vaultSetIds :: VaultSet -> [VaultId]
vaultSetIds (VaultSet _ _) = undefined

--------------------------------------------------------------------------------
-- 跨 vault 查詢

-- | 解析一個 'Aapms.Core.Id.Ref' 到它指向的節點。
--
-- 第二個參數是__不帶 vault 的 'Aapms.Core.Id.Ref' 的預設 vault__(契約 E):
-- @refVault = Nothing@ 時以它為準,@refVault = Just v@ 時以 @v@ 為準,即使
-- @v@ 就是預設 vault 也一樣。目標 vault 不在這個 'VaultSet' 裡、或在裡面但查
-- 不到那個 id 時,兩種情況都回 'Nothing'(要區分兩者請用 'checkReferences')。
lookupRef :: VaultSet -> VaultId -> Ref -> IO (Maybe (VaultId, AnyNode))
lookupRef = undefined

-- | 跨 vault 的條件列舉,語意與單一 vault 的 'Aapms.Store.Query.listNodes'
-- 完全相同,差別只在:結果涵蓋全部 vault、每筆帶自己的
-- 'Aapms.Core.Id.VaultId',而排序與分頁對__合併後的整體__成立。
listAcross :: VaultSet -> NodeFilter -> IO [(VaultId, Meta)]
listAcross = undefined

-- | 跨 vault 的全文檢索,語意與單一 vault 的 'Aapms.Store.Query.search' 完全
-- 相同,差別同 'listAcross';每筆 'Aapms.Store.Query.shVault' 是該筆命中真正
-- 所屬的 vault。
--
-- 相關度分數逐 vault 計算(各自的索引各自算 bm25),合併只影響排序與分頁,
-- 不改變任何一筆的分數。
--
-- __facet 同一條路__:逐 vault 呼叫 'Aapms.Store.Query.search' 拿各自的
-- 'Aapms.Store.Query.FacetCounts',再在 Haskell 合併(同值求和、濾掉計數 0、
-- 依「計數遞減、同計數值遞增」重排)。__不__重用 "Aapms.Store.Query" 的私有
-- @computeFacets@——那是單一 vault 專用的函式。
searchAcross :: VaultSet -> SearchQuery -> IO SearchResult
searchAcross = undefined

--------------------------------------------------------------------------------
-- 懸空引用

-- | 一筆指不到目標的關聯(契約 E 的 @DanglingRef@;形狀由本 feature 定,
-- 2026-08-26 A3 裁決,已回寫契約 E)。
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
checkReferences = undefined

-- | 繁中訊息,__說出下一步該做什麼__(契約 G 對 @render*@ 的要求;
-- 'Aapms.Store.Schema.renderIndexIssue' 是同一個模式的先例)。
renderDanglingRef :: DanglingRef -> Text
renderDanglingRef = undefined
