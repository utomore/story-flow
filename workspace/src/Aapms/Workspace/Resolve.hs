{-# LANGUAGE DataKinds #-}

-- | 作用範圍的__純裁決__(P-029-scope-resolve)。
--
-- 擁有的事實(唯一真相來源):「這次指令對哪些 vault 生效」——selector 的解析
-- 規則、對中樞每一列重讀 marker 的三種降級、@refs@ 的遞移展開與保序去重,以及
-- 「讀跨、寫單一、管線逐一」的分流(ADR-008、ADR-017)。
--
-- 整條是 "Aapms.Workspace.Effect.Markers" 的程式:marker 的讀取、目錄存在與否、
-- 路徑正規化、向上探測是那個效果的四個操作,__本模組一行 IO 都沒有__,純解譯器
-- 跑在一張「路徑 → marker 讀數」的表上(P-029 的決定)。
--
-- __明確不做__:不開索引、不寫任何檔、不判 ATTACH 上限
-- (@TooManyVaults@ 屬 graph-core);不決定「這個指令屬於讀還是寫」——呼叫端以
-- 'Aapms.Workspace.Types.ScopeKind' 選。
module Aapms.Workspace.Resolve
  ( -- * selector 解析
    lookupSelector

    -- * 路徑 → 權威身分
  , refOfEntry
  , refAt

    -- * refs 展開
  , expandRefGraph

    -- * 三種範圍
  , scopeRead
  , scopeWrite
  , scopePipeline

    -- * 純的整條
  , resolveScope
  ) where

import Data.Text (Text)
import Effectful (Eff, (:>))

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Types (VaultKind)
import Aapms.Workspace.Effect.Markers (Markers)
import Aapms.Workspace.Types
  ( Hub
  , PipelineScope
  , ReadScope
  , Scope (..)
  , ScopeIssue
  , ScopeKind (..)
  , VaultEntry (..)
  , VaultRef
  , WorkspaceError (..)
  , WriteScope
  , hubVaults
  )

-- | 把 @--vault@ 的字串解析成中樞裡的一列。
--
-- 兩階段,__先比 'veId' 的完整字串,再比 'veName'__:id 階段有命中時,name 階段
-- 完全不參與;兩階段都逐字精確比對(不去空白、不忽略大小寫、不做前綴或子字串
-- 比對)。
--
-- 任一階段的命中集合:恰好一列 → @Right@ 該列;兩列以上 →
-- @Left ('VaultSelectorAmbiguous' s es)@,@es@ __含全部__撞名的列(順序同中樞);
-- 兩階段都沒命中 → @Left ('VaultSelectorNotFound' s)@。
--
-- 純函式,只看 'hubVaults';不讀檔案、不碰 @[[projects]]@ \/ @[llm]@ \/ @[tools]@。
--
-- (自 "Aapms.Workspace.Discovery" 搬進純層,行為逐字不變;該模組原地 re-export。)
lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry
lookupSelector hub s = case byId of
  [e] -> Right e
  es@(_ : _ : _) -> Left (VaultSelectorAmbiguous s es)
  [] -> case byName of
    [e] -> Right e
    es@(_ : _ : _) -> Left (VaultSelectorAmbiguous s es)
    [] -> Left (VaultSelectorNotFound s)
  where
    entries = hubVaults hub
    byId = filter ((== VaultId s) . veId) entries
    byName = filter ((== s) . veName) entries

-- | 對中樞一列重讀 marker:路徑不見 → 'Aapms.Workspace.Types.VaultPathMissing'、
-- 壞 → 'Aapms.Workspace.Types.VaultMarkerBroken'、id 不符 →
-- 'Aapms.Workspace.Types.VaultIdDrift',依此順序。
refOfEntry :: Markers :> es => VaultEntry -> Eff es (Either ScopeIssue VaultRef)
refOfEntry _e = error "P-029#refOfEntry stub"

-- | 對一個路徑讀 marker 並以 id 回填中樞那一列;讀不到一律
-- 'Aapms.Workspace.Types.MarkerUnreadable'。
refAt :: Markers :> es => Hub -> FilePath -> Eff es (Either WorkspaceError VaultRef)
refAt _hub _p = error "P-029#refAt stub"

-- | 自種子沿 @vmRefs@ 廣度優先展開,visited 擋環;未註冊目標 →
-- 'Aapms.Workspace.Types.RefVaultNotRegistered' 一次;不可達的不展開它的 @refs@。
expandRefGraph :: Markers :> es => Hub -> VaultRef -> Eff es ([VaultRef], [ScopeIssue])
expandRefGraph _hub _seed = error "P-029#expandRefGraph stub"

-- | 無 selector = 全部已註冊(不展開);有 = 種子 ∪ @refs*@。
scopeRead :: Markers :> es => Hub -> Maybe Text -> Eff es (Either WorkspaceError ReadScope)
scopeRead _hub _sel = error "P-029#scopeRead stub"

-- | 目標來自 selector 或探測,恒不來自 @refs@;目標的失敗是硬錯。
scopeWrite :: Markers :> es => Hub -> Maybe Text -> FilePath -> Eff es (Either WorkspaceError WriteScope)
scopeWrite _hub _sel _start = error "P-029#scopeWrite stub"

-- | 無 selector = 全部已註冊且 kind 相符;有 = 恰好一個,kind 不符回
-- 'Aapms.Workspace.Types.VaultKindMismatch'。
scopePipeline :: Markers :> es => Hub -> VaultKind -> Maybe Text -> Eff es (Either WorkspaceError PipelineScope)
scopePipeline _hub _k _sel = error "P-029#scopePipeline stub"

-- | 純的整條:依 'ScopeKind' 走 'scopeRead' \/ 'scopeWrite' \/ 'scopePipeline'。
resolveScope
  :: Markers :> es
  => Hub
  -> ScopeKind
  -> Maybe Text
  -> FilePath
  -> Eff es (Either WorkspaceError Scope)
resolveScope hub kind sel start = case kind of
  ForRead -> fmap (fmap SRead) (scopeRead hub sel)
  ForWrite -> fmap (fmap SWrite) (scopeWrite hub sel start)
  ForPipeline k -> fmap (fmap SPipeline) (scopePipeline hub k sel)
