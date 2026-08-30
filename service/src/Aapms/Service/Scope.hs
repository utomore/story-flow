-- | 範圍取得(design.md「內部模組劃分」的 Scope)。
--
-- 擁有的事實(唯一真相來源):__範圍與 handle 的對應__——@aapms-workspace@ 裁決
-- 出「這道指令對哪些 vault 生效」之後,誰要被 'Aapms.Service.Monad.handleFor'
-- 開起來、誰要被 @ATTACH@ 進同一個 'VaultSet'。
--
-- 三個函式是三條資料流管線共用的前段(design.md 資料流管線),也是__範圍解析的
-- 結果進入本套件的唯一三個口__(design.md 模組間公開介面):Read \/ Write \/
-- Machine 一律經這裡拿到開好的 handle,不自己呼叫
-- 'Aapms.Workspace.Scope.resolveRead' 那一組。
--
-- __明確不做__:不判斷 @ATTACH@ 上限(@maxAttachedVaults@ \/ @TooManyVaults@ 屬
-- graph-core 的 "Aapms.Store.MultiVault");不決定「這道指令屬於讀還是寫」——
-- 呼叫端選函式;不解讀 selector(@aapms-workspace@ 的裁決)。
--
-- __'ScopeIssue' 不從這三個口出來__:三個簽名都是 design.md 模組間公開介面表的
-- 原文,沒有一個帶 @['ScopeIssue']@。這不是遺漏——讀取路徑上 'ScopeIssue' 只要
-- 「不中止」就夠了(design.md 契約 D),而要__呈現__它們的兩個操作
-- (@workspaceDoctor@ \/ @vaultCheck@,F002)走的是本機管線,直接呼叫
-- 'Aapms.Workspace.Lifecycle.checkVaults',不經過本模組。
module Aapms.Service.Scope
  ( -- * 模組間公開介面:Read \/ Write \/ Machine → Scope
    withRead
  , withWrite
  , withPipeline
  ) where

import Aapms.Store.Marker (VaultHandle)
import Aapms.Store.MultiVault (VaultSet, openVaultSet)
import Aapms.Store.Schema (VaultKind)
import Aapms.Workspace.Scope (resolvePipeline, resolveRead, resolveWrite)
import Aapms.Workspace.Types
  ( PipelineScope (psRuns)
  , ReadScope (rsVaults)
  , VaultRef
  , WriteScope (wsRead, wsTarget)
  )

import Aapms.Service.Monad
  ( ServiceM
  , askCwd
  , askHub
  , askSelector
  , handleFor
  , liftStore
  , liftWorkspace
  )

-- | 讀取範圍(ADR-017:__讀跨__)。把 'Aapms.Workspace.Scope.resolveRead' 的裁決
-- 換成一個開好的 'VaultSet',連同它涵蓋的 'VaultRef' 清單一起交給第一參數。
--
-- 'VaultRef' 清單與 'VaultSet' 描述的是__同一組 vault、同一個順序__:呼叫端要的
-- 是 marker 上的 @id@ \/ @kind@ \/ @name@(投影 @nvVault@ 時用得到),而
-- 'VaultSet' 只是查詢用的把手。
--
-- 範圍為空(一個 vault 都沒註冊)時仍呼叫第一參數,給一個空的 'VaultSet'——
-- 「沒有東西可查」是合法的查詢結果,不是錯誤。
--
-- 'VaultSet' 在第一參數結束時(含例外路徑)必定被
-- 'Aapms.Store.MultiVault.closeVaultSet';被 @ATTACH@ 的那些 'VaultHandle'
-- __不__被關閉,它們留在快取裡由 'Aapms.Service.Monad.closeEnv' 收。
withRead :: (VaultSet -> [VaultRef] -> ServiceM a) -> ServiceM a
withRead k = do
  hub <- askHub
  sel <- askSelector
  scope <- liftWorkspace (resolveRead hub sel)
  handles <- mapM handleFor (rsVaults scope)
  vs <- liftStore (openVaultSet handles)
  finallyCloseVaultSet vs (k vs (rsVaults scope))

-- | 寫入範圍(ADR-017:__寫單一__)。第一參數收到的是寫入目標那一個 vault 的
-- handle,以及讀取範圍(目標 + @refs@ 展開)組成的 'VaultSet' ——關聯目標檢查
-- 走後者,落地只走前者。
--
-- 沒有寫入目標時__到此為止__:'Aapms.Workspace.Types.NoWriteTarget' 原樣包成
-- 'Aapms.Service.Types.WorkspaceFailed',第一參數不被呼叫,程式不猜
-- (design.md 契約 E)。
--
-- 'VaultSet' 的生命週期同 'withRead'。
withWrite :: (VaultHandle -> VaultSet -> ServiceM a) -> ServiceM a
withWrite k = do
  hub <- askHub
  sel <- askSelector
  cwd <- askCwd
  scope <- liftWorkspace (resolveWrite hub sel cwd)
  targetHandle <- handleFor (wsTarget scope)
  readHandles <- mapM handleFor (wsRead scope)
  vs <- liftStore (openVaultSet readHandles)
  finallyCloseVaultSet vs (k targetHandle vs)

-- | 管線範圍(ADR-017:對每個符合 @kind@ 的 vault __各跑一次__)。第一參數是這條
-- 管線只對哪種 vault 有意義,第二參數收到的是那些 vault 的 handle,__依
-- 'Aapms.Workspace.Types.psRuns' 的順序__。
--
-- __不組 'VaultSet'__:管線的每一次執行都只寫自己的索引,跨 vault 的查詢在這條
-- 路上沒有意義。
--
-- 符合條件的 vault 一個都沒有時仍呼叫第二參數,給一個空清單。
withPipeline :: VaultKind -> ([VaultHandle] -> ServiceM a) -> ServiceM a
withPipeline kind k = do
  hub <- askHub
  sel <- askSelector
  scope <- liftWorkspace (resolvePipeline hub kind sel)
  handles <- mapM handleFor (psRuns scope)
  k handles

-- | 私有 helper:結束時(含短路路徑)保證
-- 'Aapms.Store.MultiVault.closeVaultSet' 恰好被呼叫一次。
--
-- 走 'Aapms.Service.Monad.finallyService' ——本模組__不__自己攔截短路:
-- 'ServiceM' 只有 @Functor@ \/ @Applicative@ \/ @Monad@ \/ @MonadIO@ 四個實例
-- (L25),攔截的能力收斂在 'Aapms.Service.Monad' 匯出的那一個組合子裡。
finallyCloseVaultSet :: VaultSet -> ServiceM a -> ServiceM a
finallyCloseVaultSet = undefined
