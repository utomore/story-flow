-- | @aapms-service@ 的錯誤語彙(design.md「內部模組劃分」的 Types)。
--
-- 擁有的事實(唯一真相來源):__錯誤語彙__——'errorCode' 的 snake_case 識別碼與
-- 'renderServiceError' 的繁中訊息。三個殼(CLI \/ HTTP \/ MCP)共用的 @code@ 與
-- 訊息只有這一份(system.md 全域錯誤策略第 1 條)。
--
-- __本模組不得 import 本套件的任何其他模組__(design.md「Types 為什麼要獨立」):
-- 'ServiceError' 捧著下層的 'StoreError' \/ 'WorkspaceError' \/ 'RegistryError',
-- 而其餘六個模組每一個都回 @Either 'ServiceError' a@;型別定義與錯誤型別若分居
-- 兩處就是相依環。本模組只依賴 @aapms-core@ \/ @aapms-store@ \/ @aapms-workspace@
-- 的型別。
--
-- __建構子逐波擴充__(build-log D1 \/ 配號表):F001 只寫契約 F 的前四個建構子
-- (執行環境開得起來所需的那些);'ValidationFailed' 起的九個屬 F003–F006 的範圍,
-- 由編排者在該波的白名單裡明確授權後加入。這與 @aapms-workspace@ 的 Types「一次
-- 寫齊」相反,理由是本子系統的波次__不平行__(build-log 排程表),沒有併發互蓋
-- 的風險,而分波加入能讓每一波的 -Wincomplete-patterns 直接指出還沒處理的建構子。
module Aapms.Service.Types
  ( -- * 契約 F:錯誤
    ServiceError (..)
  , errorCode
  , renderServiceError
  ) where

import Data.Text (Text)

import Aapms.Core.Registry (RegistryError)
import Aapms.Store.Error (StoreError)
import Aapms.Workspace.Types (WorkspaceError)

-- | @aapms-service@ 的__唯一__錯誤型別(design.md 契約 F)。不得另立平行的錯誤
-- 型別再橋接——多一個型別就是多一套 @render*@,@shell@ 也會看到兩種形狀。
--
-- 下層錯誤__原樣包、不重寫訊息__:四個建構子都捧著下層的錯誤原件,訊息由對方的
-- @render*@ 產生。本層擁有的是 @code@(哪一類失敗),不是訊息。
data ServiceError
  = -- | graph-core 的落地失敗,原件。訊息委派
    -- 'Aapms.Store.Error.renderStoreError'
    StoreFailed StoreError
  | -- | @aapms-workspace@ 的工作區設定失敗,原件。訊息委派
    -- 'Aapms.Workspace.Types.renderWorkspaceError'
    WorkspaceFailed WorkspaceError
  | -- | 型別註冊表__定位不到__(三層都沒找到,或環境變數指向不存在的目錄):
    -- 'Aapms.Types.Loader.locateRegistry' 回的原件。與 'RegistryLoadFailed' 分成
    -- 兩個建構子是因為 @code@ 要分得出「去裝\/去設環境變數」與「型別宣告寫錯了」
    RegistryUnavailable RegistryError
  | -- | 型別註冊表__載入失敗__(目錄找到了但內容不合規):
    -- 'Aapms.Types.Loader.loadRegistry' 回的原件
    RegistryLoadFailed RegistryError
  deriving stock (Show, Eq)

-- | 機器用的穩定識別碼:snake_case、__不帶產品前綴__(legacy MCP 的
-- @story_flow_*@ 在此退場)。
--
-- 規則只有一條:__建構子名的 snake_case__(@StoreFailed@ → @store_failed@)。
-- 規則寫下來而不是逐條列舉,是為了讓 F003–F006 加建構子時不必回頭問「這個該叫
-- 什麼」——@code@ 表因此不是一份要維護的對照表,而是建構子名的函數。
--
-- 責任範圍是 'ServiceError' 的__全部__建構子;回傳恒非空、兩兩相異。
errorCode :: ServiceError -> Text
errorCode = undefined

-- | 繁中訊息,__每一則說出下一步該做什麼__(system.md 全域錯誤策略第 2 條)。
--
-- 四個建構子__一律逐字委派下層的 @render*@__,本層一個字都不加:
-- 'Aapms.Store.Error.renderStoreError' \/
-- 'Aapms.Workspace.Types.renderWorkspaceError' \/
-- 'Aapms.Core.Registry.renderRegistryError'。加前綴會讓同一則訊息在 @service@
-- 與在下層各長一個樣,而下層的訊息已經寫過「下一步」。
--
-- 兩個註冊表建構子因此渲染成__相同__的文字;分辨它們是 'errorCode' 的責任。
renderServiceError :: ServiceError -> Text
renderServiceError = undefined
