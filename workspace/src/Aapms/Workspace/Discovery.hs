-- | vault 的探測與身分解析(design.md「內部模組劃分」的 Discovery)。
--
-- 擁有的事實(唯一真相來源):__「這個字串 \/ 這個目錄指的是哪個 vault」__。
--
-- __vault 的身分不屬於本模組__:@id@ \/ @kind@ \/ @name@ \/ @refs@ 屬各 vault 的
-- marker(graph-core 的 @Aapms.Store.Marker.readMarker@)。中樞 @[[vaults]]@ 存的
-- 是__快取__('Aapms.Workspace.Types.veName' \/ 'Aapms.Workspace.Types.veKind'),
-- 本模組__每次重讀真相__:'readVaultRef' \/ 'readVaultRefAt' 回傳的
-- 'Aapms.Workspace.Types.vrMarker' 一律來自檔案。
--
-- __明確不做__(契約卡):不展開 @refs@、不決定作用範圍(那是 F003 的 Scope)、
-- 不開索引、不寫入任何 marker(那是 F004 的 Lifecycle)。本模組不建立、不修改、
-- 不刪除任何檔案或目錄。
module Aapms.Workspace.Discovery
  ( -- * 向上探測
    detectVault

    -- * selector 解析
  , lookupSelector

    -- * 路徑 → 權威身分
  , readVaultRef
  , readVaultRefAt
  ) where

import Data.Text (Text)

import Aapms.Workspace.Types
  ( Hub
  , ScopeIssue
  , VaultEntry
  , VaultRef
  , WorkspaceError
  )

-- | ADR-008 的 git 式向上探測:從給定目錄逐層往上,回__第一個__(最近的)含
-- @.aapms\/@ 子目錄的那一層的絕對路徑;一路到檔案系統根都沒有時回 @Nothing@。
--
-- 起點先正規化(@canonicalizePath@)再往上走,回傳的路徑同樣是正規化後的絕對
-- 路徑。起點自己那一層也算命中。@.aapms@ 必須是__目錄__:同名的普通檔案不算
-- 命中,繼續往上找。
--
-- 起點不存在時不是錯誤——照樣往上走,找得到就回,找不到回 @Nothing@。
--
-- __它只決定寫入目標,不影響查詢範圍__(ADR-017 決策三)。本函式不讀 marker,
-- 也不判斷該 vault 的 marker 是否合法——那是 'readVaultRefAt' 的事。
detectVault :: FilePath -> IO (Maybe FilePath)
detectVault = undefined

-- | 把 @--vault@ 的字串解析成中樞裡的一列。
--
-- 兩階段,__先比 'Aapms.Workspace.Types.veId' 的完整字串,再比
-- 'Aapms.Workspace.Types.veName'__:id 階段有命中時,name 階段完全不參與;
-- 兩階段都逐字精確比對(不去空白、不忽略大小寫、不做前綴或子字串比對)。
--
-- 任一階段的命中集合:恰好一列 → @Right@ 該列;兩列以上 →
-- @Left ('Aapms.Workspace.Types.VaultSelectorAmbiguous' s es)@,@es@ __含全部__
-- 撞名的列(順序同中樞),使用者才知道改用哪個 id;兩階段都沒命中 →
-- @Left ('Aapms.Workspace.Types.VaultSelectorNotFound' s)@。
--
-- 純函式,只看 'Aapms.Workspace.Hub.hubVaults';不讀檔案、不碰
-- @[[projects]]@ \/ @[llm]@ \/ @[tools]@。
lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry
lookupSelector = undefined

-- | 中樞的一列 + 它指的路徑 → 權威身分(design.md「模組間公開介面」的
-- @Scope → Discovery@)。
--
-- 成功時 'Aapms.Workspace.Types.vrEntry' 是 @Just@ 傳入的那一列、
-- 'Aapms.Workspace.Types.vrPath' 是正規化後的絕對路徑、
-- 'Aapms.Workspace.Types.vrMarker' __來自檔案__。
--
-- 三種降級(依序判定,互斥),一律回 'Aapms.Workspace.Types.ScopeIssue' 讓呼叫端
-- 把該 vault 排除而__不中止整道指令__:
--
-- * 路徑不是既存目錄 → 'Aapms.Workspace.Types.VaultPathMissing'
-- * marker 讀不開 → 'Aapms.Workspace.Types.VaultMarkerBroken',捧著 graph-core
--   @StoreError@ 的__原件__(訊息由對方的 @renderStoreError@ 產生,這一層不翻譯)
-- * marker 的 id 與中樞那列不符 → 'Aapms.Workspace.Types.VaultIdDrift',帶中樞
--   那列與 marker 裡__實際__的 id
--
-- 未註冊的 vault(向上探測到、中樞裡沒有那一列)走 'readVaultRefAt':
-- 'Aapms.Workspace.Types.ScopeIssue' 的三個建構子都要求一列
-- 'Aapms.Workspace.Types.VaultEntry',表達不出「沒有那一列」的失敗(見 F002 的
-- 待確認假設 A1)。
readVaultRef :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)
readVaultRef = undefined

-- | 只知道路徑時的「路徑 → 權威身分」:先讀 marker 取權威 id,再拿那個 id 回中樞
-- 反查,決定 'Aapms.Workspace.Types.vrEntry'。
--
-- 'Aapms.Workspace.Types.vrEntry' 是 @Just e@ 當且僅當 'Aapms.Workspace.Hub.hubVaults'
-- 裡有一列的 'Aapms.Workspace.Types.veId' 等於 marker 的 @vmId@(__身分就是 marker
-- 的 id__,路徑不參與比對);否則 @Nothing@,那就是一個未註冊的 vault。
--
-- 失敗一律是 @Left ('Aapms.Workspace.Types.MarkerUnreadable' root e)@——路徑不存在
-- 與 marker 解不開都走這一條,@e@ 是 graph-core 回的原件。這是__硬失敗__而不是
-- 降級:本函式的呼叫情境是「決定寫入目標」,而 ADR-017 的降級規則只放過查詢範圍
-- 裡的個別 vault,決定不了寫入目標時整道指令就該失敗。
readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)
readVaultRefAt = undefined
