-- | 中樞 @[[projects]]@ 的註冊與移除,以及 @prj-@ 配號
-- (design.md「內部模組劃分」的 Projects)。
--
-- 擁有的事實(唯一真相來源):__這台機器上有哪些專案__——也就是中樞
-- @[[projects]]@ 那個陣列裡有哪幾列、每一列的 @id@ \/ @name@ \/ @path@ 是什麼。
--
-- __專案裡面裝什麼不屬於本模組__(契約卡「明確不做」):@assets\/manifest.json@ 與
-- @story\/manifest.json@ 是 @project@ 子系統的真相,本模組__不讀、不產生、不同步、
-- 不驗證__它們;它只回答「這台機器上有哪些專案、它們在哪」。專案__不需要 marker__
-- (system.md 對外介面第 5 節:「專案不需要 marker,由中樞註冊 + 目錄內的 manifest
-- 自述」),所以本模組與 @.aapms\/@ \/ @readMarker@ \/ 索引完全無關。
--
-- 走的是生命週期管線的同一條路,節點型別換成專案:
--
-- @
-- 前置檢查(名稱、路徑)→ 配號(newId PPrj + salt 遞增重試)→ Hub 值追加一列
--   → saveHub 原子寫回
-- @
--
-- 撤除走同一條路的反向:selector → 從 'Hub' 值刪整列 → 'saveHub'。
-- __專案目錄本身任何情況都不碰__(ADR-017 決策五的分層界線:中樞是註冊表,
-- 目錄是真相;@forgetProject@ 只動註冊表,搬到另一台機器重新註冊就能繼續用)。
--
-- 型別一律去 'Aapms.Workspace.Types' 取,本模組__不轉出__任何型別(W1 \/ W2 \/ W3
-- 立下的慣例)。
module Aapms.Workspace.Projects
  ( -- * 註冊
    registerProject

    -- * 撤除
  , forgetProject

    -- * 配號(純函式,時間由呼叫端給)
  , allocateProjectId
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)

import Aapms.Core.Id (Id)
import Aapms.Workspace.Types
  ( Hub
  , HubLocation
  , ProjectEntry
  , WorkspaceError
  )

-- | 把一個既有目錄註冊成中樞 @[[projects]]@ 的一列,並寫回 @config.toml@。
--
-- 參數:中樞位置、__已載入__的中樞快照、專案根目錄、專案名。
--
-- 順序固定四步,前置檢查__先名稱後路徑__(契約 F 的
-- 'Aapms.Workspace.Types.ProjectPathMissing' 帶著__專案名__,名稱還沒過關就報路徑
-- 錯誤只會印出一個空名):
--
-- 1. 名稱去前後空白後長度為 0 → @Left ('Aapms.Workspace.Types.InvalidName' 原字串)@,
--    __不寫任何檔案__
-- 2. 路徑正規化(@canonicalizePath@,同 W2 對 @vrPath@ 的裁定)後不是既存目錄 →
--    @Left ('Aapms.Workspace.Types.ProjectPathMissing' 名稱 正規化後的路徑)@
-- 3. 配號:@newId PPrj 名稱 現在時刻 salt@,自 @salt = 0@ 起,候選與中樞既有的
--    'Aapms.Workspace.Types.peId' __撞號就 salt + 1 重算__,不靜默照發
--    (同 graph-core @allocateId@ 的做法)
-- 4. 'Aapms.Workspace.Hub.upsertProject' 追加一列 → 'Aapms.Workspace.Hub.saveHub'
--    原子寫回;寫入失敗 → @Left ('Aapms.Workspace.Types.HubWriteFailed' …)@ 原樣捧出
--
-- 成功時回__新的__ 'Hub'(呼叫端後續一律用它,舊快照作廢)與剛加進去的那一列。
-- 存進中樞的 'Aapms.Workspace.Types.peName' 是__去除前後空白後__的名稱,
-- 'Aapms.Workspace.Types.pePath' 是__正規化後的絕對路徑__——兩者都是
-- 'Aapms.Workspace.Hub.loadHub' 的合規判準要求的形狀(空名與非絕對路徑都會讓
-- 下一次載入回 @HubMalformed@)。
--
-- __同一個路徑註冊兩次得到兩列、兩個不同的 id__(見 spec 的待確認假設 A1):
-- 本模組不做路徑去重,「這兩列其實是同一個專案」不是註冊表擁有的事實。
registerProject
  :: HubLocation
  -> Hub
  -> FilePath
  -> Text
  -> IO (Either WorkspaceError (Hub, ProjectEntry))
registerProject = undefined

-- | 把一列從中樞 @[[projects]]@ 移除並寫回 @config.toml@。
--
-- 參數:中樞位置、__已載入__的中樞快照、selector(非空)。
--
-- selector 的比對規則與 'Aapms.Workspace.Discovery.lookupSelector' __同一套__
-- (W2 閘門對 vault 那一組的裁定):兩階段,先比
-- 'Aapms.Workspace.Types.peId' 的完整字串、再比 'Aapms.Workspace.Types.peName',
-- 兩階段都__逐字精確比對__(不去前後空白、不忽略大小寫、不做前綴或子字串比對);
-- id 階段有命中時 name 階段完全不參與。
--
-- 差別只有一處:契約 F __沒有__ project 版的 @Ambiguous@ 建構子,所以命中兩列以上時
-- 回 @Left ('Aapms.Workspace.Types.ProjectSelectorNotFound' selector)@ 並__不刪任何
-- 一列__——寧可不動,也不靜默挑一列刪掉(見 spec 的待確認假設 A2)。
-- 兩階段都沒命中同樣是 @ProjectSelectorNotFound@。
--
-- 命中恰好一列時:'Aapms.Workspace.Hub.removeProject' 刪整列 →
-- 'Aapms.Workspace.Hub.saveHub' 原子寫回,回新的 'Hub' 與__被移除的那一列__。
--
-- __專案目錄本身完全未動__:本模組不刪除、不建立、不修改任何 @config.toml@ 以外的
-- 檔案或目錄。
forgetProject
  :: HubLocation
  -> Hub
  -> Text
  -> IO (Either WorkspaceError (Hub, ProjectEntry))
forgetProject = undefined

-- | 配一個在給定清單裡不撞號的 @prj-@ id。__純函式__:相同輸入必得相同輸出,
-- __時間由呼叫端給__('registerProject' 自己取 @getCurrentTime@ 再傳進來,
-- __它的對外簽名不變__)。
--
-- 參數:中樞既有的那些列(比對 'Aapms.Workspace.Types.peId' 用)、專案名
-- (已去除前後空白,當作 @newId@ 的內容)、時間。
--
-- 自 @salt = 0@ 起算 @newId PPrj 名稱 時間 salt@,候選與清單裡任何一列的
-- 'Aapms.Workspace.Types.peId' 相同就 @salt + 1@ 重算,回__第一個不撞的__候選;
-- __不靜默照發__。
--
-- __為什麼它是公開的而不是藏在 'registerProject' 裡__(見 spec 的待確認假設 A5):
-- 契約 D 的 'registerProject' 簽名沒有時間參數,時間只能在函式內部取樣;而藏起來
-- 取樣的話,呼叫端就無法預先造出碰撞,salt 重試迴圈__永遠測不到__——碰撞在正常
-- 情況下幾乎不發生,那段程式碼可能永遠是錯的而沒人知道。graph-core 的
-- 'Aapms.Store.Write.allocateId' 為同一個理由把時間放到呼叫端(2026-08-25 G8 裁決)。
-- 把配號抽成這個純函式,契約 D 的簽名一個字不動,而「撞號時以 salt 遞增重試」
-- 這條驗收標準變成可以直接斷言的。
allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id
allocateProjectId = undefined
