-- | 中樞 @config.toml@ 四段的解析與序列化、原子寫入,以及對 'Hub' 值的純增刪
-- (design.md「內部模組劃分」的 Hub)。
--
-- 擁有的事實(唯一真相來源):__中樞記了什麼__——@[[vaults]]@ \/ @[[projects]]@ \/
-- @[llm]@ \/ @[tools]@ 的檔案格式。
--
-- __vault 的身分不屬於本模組__:@id@ \/ @kind@ \/ @name@ \/ @refs@ 屬各 vault 的
-- marker(graph-core)。本模組存的是__快取__,'Aapms.Workspace.Discovery'
-- (F002)每次重讀真相。
--
-- __不建立任何目錄或檔案__:'saveHub' 只覆寫既有位置的 @config.toml@,中樞目錄
-- 與 @cache\/@ 的建立是 F004 的 @setupHub@。
module Aapms.Workspace.Hub
  ( -- * 載入與寫回
    loadHub
  , saveHub

    -- * 契約 B 的四個 getter(自 'Aapms.Workspace.Types' 轉出)
  , hubVaults
  , hubProjects
  , hubLlm
  , hubTools

    -- * 對 'Hub' 值的純增刪(design.md「模組間公開介面」:Lifecycle \/ Projects → Hub)
  , upsertVault
  , removeVault
  , upsertProject
  , removeProject
  ) where

import Aapms.Core.Id (Id, VaultId)
import Aapms.Workspace.Types
  ( Hub
  , HubLocation
  , ProjectEntry
  , VaultEntry
  , WorkspaceError
  , hubLlm
  , hubProjects
  , hubTools
  , hubVaults
  )

-- | 讀 @\<hlPath\>\/config.toml@ 並解析四段。
--
-- * 檔案不存在 → @Left ('Aapms.Workspace.Types.HubNotFound' fp)@,
--   __不回空中樞__(system.md 全域錯誤策略第 3 條)
-- * 讀不進來或 TOML 解不開 → @Left ('Aapms.Workspace.Types.HubUnreadable' fp _)@
-- * 解得開但欄位不合規 → @Left ('Aapms.Workspace.Types.HubMalformed' fp _)@
--
-- 成功時 'Aapms.Workspace.Types.hubSourceText' 帶著這次讀到的原始檔案文字,
-- 'saveHub' 靠它保住註解與空白行。
loadHub :: HubLocation -> IO (Either WorkspaceError Hub)
loadHub = undefined

-- | 把 'Hub' 原子寫回 @\<hlPath\>\/config.toml@(沿用
-- 'Aapms.Store.Atomic.atomicWriteText',__不另寫一份__)。
--
-- __既有列的相對順序、使用者寫的註解與空白行原樣保留__(ADR-017 決策二的
-- 「可手寫」):序列化自己寫,不用泛型 encoder。寫入失敗回
-- @Left ('Aapms.Workspace.Types.HubWriteFailed' fp _)@。
saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())
saveHub = undefined

-- | 依 'Aapms.Workspace.Types.veId' 覆寫既有列;沒有該 id 時__追加到末尾__。
-- 純函式,不碰檔案。
upsertVault :: VaultEntry -> Hub -> Hub
upsertVault = undefined

-- | 依 'Aapms.Workspace.Types.veId' 刪整列;沒有該 id 時原樣回傳。純函式,不碰檔案。
removeVault :: VaultId -> Hub -> Hub
removeVault = undefined

-- | 依 'Aapms.Workspace.Types.peId' 覆寫既有列;沒有該 id 時__追加到末尾__。
-- 純函式,不碰檔案。
upsertProject :: ProjectEntry -> Hub -> Hub
upsertProject = undefined

-- | 依 'Aapms.Workspace.Types.peId' 刪整列;沒有該 id 時原樣回傳。純函式,不碰檔案。
removeProject :: Id -> Hub -> Hub
removeProject = undefined
