-- | 作用範圍裁決:一道指令對哪些 vault 生效(design.md「內部模組劃分」的 Scope)。
--
-- 擁有的事實(唯一真相來源):__ADR-017 的三種範圍規則__——「讀跨、寫單一、管線
-- 逐一」,以及 @refs@ 的遞移展開、擋環與保序去重。
--
-- 三個函式對應 ADR-017 決策三那張表:
--
-- > 函式              selector = Nothing              selector = Just X
-- > resolveRead       全部已註冊 vault;不看當前目錄   {X} ∪ refs*(X)
-- > resolveWrite      從起點向上探測 .aapms/          目標 = X
-- > resolvePipeline   全部 vmKind 相符者,各跑一次     {X};kind 不符即錯
--
-- 四條共用性質(design.md 契約 C):
--
-- 1. __marker 是真相__:每個候選 vault 的 marker 都重讀一次,中樞的
--    'Aapms.Workspace.Types.veName' \/ 'Aapms.Workspace.Types.veKind' 只是快取。
-- 2. __不可達不中止__:路徑不見 \/ marker 壞 \/ id 漂移 \/ @refs@ 指向未註冊的
--    vault,一律進 @*Issues@ 並把該 vault 排除,其餘照跑。整道指令只在「中樞載不
--    起來」或「__寫入目標決定不了__」時才失敗。
-- 3. __@refs@ 遞移展開對環是安全的__:@A → B → A@ 的結果是 @{A, B}@。
-- 4. __@refs@ 展開進來的一律唯讀__:只出現在 'Aapms.Workspace.Types.rsVaults' \/
--    'Aapms.Workspace.Types.wsRead',__永遠不會__成為 'Aapms.Workspace.Types.wsTarget',
--    也不會進 'Aapms.Workspace.Types.psRuns'。
--
-- __本模組不自己碰檔案系統__(除了把 'resolveWrite' 的起點正規化):路徑 → 權威
-- 身分一律經 'Aapms.Workspace.Discovery' 的 @readVaultRef@ \/ @readVaultRefAt@ \/
-- @detectVault@。marker 的讀取、@.aapms@ 這個名字、正規化的定義都住在那裡。
--
-- __明確不做__(契約卡):不判斷 ATTACH 上限(@maxAttachedVaults@ \/
-- @TooManyVaults@ 屬 graph-core 的 @Aapms.Store.MultiVault@);不開任何 vault、
-- 不開索引;不決定「這個指令屬於讀還是寫」——呼叫端('service')選函式。
module Aapms.Workspace.Scope
  ( -- * 三個裁決函式
    resolveRead
  , resolveWrite
  , resolvePipeline
  ) where

import Data.Text (Text)

import Aapms.Store.Schema (VaultKind)
import Aapms.Workspace.Types
  ( Hub
  , PipelineScope
  , ReadScope
  , WorkspaceError
  , WriteScope
  )

-- | 查詢類指令的作用範圍(ADR-017 決策三:__讀跨__)。
--
-- * @Nothing@:全部已註冊 vault,__與當前目錄無關__;__不展開 @refs@__
--   (無 @--vault@ 時範圍本來就是全部,展開不增加任何能力)。
-- * @Just s@:先經 @lookupSelector@ 把字串解析成中樞的一列(解不開時
--   'Aapms.Workspace.Types.VaultSelectorNotFound' \/
--   'Aapms.Workspace.Types.VaultSelectorAmbiguous' __原樣透傳__),再以它為種子
--   做 @refs@ 遞移展開,結果是 @{X} ∪ refs*(X)@。
--
-- 任一候選 vault 不可達(路徑不見 \/ marker 壞 \/ id 漂移)時仍回 @Right@:該
-- vault 不進 'Aapms.Workspace.Types.rsVaults',對應的
-- 'Aapms.Workspace.Types.ScopeIssue' 進 'Aapms.Workspace.Types.rsIssues'。
-- 種子自己不可達也一樣(空清單 + 一則 issue),而且__不展開它的 @refs@__——
-- 身分不確定時任何跨 vault 的解析都是不確定的。
--
-- 'Aapms.Workspace.Types.rsVaults' __保序去重__(以 @vmId@,保留首次出現的位置)。
resolveRead :: Hub -> Maybe Text -> IO (Either WorkspaceError ReadScope)
resolveRead = undefined

-- | 寫入類指令的作用範圍(ADR-017 決策三:__寫單一__)。第三參數是向上探測的
-- 起點,通常是行程的當前目錄。
--
-- 'Aapms.Workspace.Types.wsTarget' __恒經由 @readVaultRefAt@ 產生__,兩條路只差
-- 在起點路徑怎麼來:
--
-- * @Nothing@:@detectVault@ 從第三參數逐層向上;一路到檔案系統根都沒有
--   @.aapms\/@ 時回 'Aapms.Workspace.Types.NoWriteTarget',帶__正規化後的起點__。
-- * @Just s@:@lookupSelector@ 取中樞那一列,起點換成該列的
--   'Aapms.Workspace.Types.vePath';另加一道 __id 守門__——目標 marker 的 @vmId@
--   與該列的 'Aapms.Workspace.Types.veId' 不符時是硬失敗(F003 的待確認假設 A1),
--   因為註冊表指的位置上已經不是使用者點名的那個 vault,靜默寫下去就是寫錯庫。
--
-- 因此寫入目標這一路__完全不走 @readVaultRef@__:它的失敗型別是
-- 'Aapms.Workspace.Types.ScopeIssue'(降級),而寫入目標的失敗是硬錯誤——兩者
-- 不需要轉換,只要不混用。'Aapms.Workspace.Types.wsIssues' 因此__只__裝 @refs@
-- 展開產生的降級紀錄,恒不含描述 'Aapms.Workspace.Types.wsTarget' 的那一則。
--
-- 'Aapms.Workspace.Types.wsRead' = @{目標} ∪ refs*(目標)@,目標排第一,保序去重;
-- 展開進來的一律唯讀。目標可以是__未註冊__的 vault(向上探測到、中樞裡沒有那一
-- 列),此時 'Aapms.Workspace.Types.vrEntry' 是 @Nothing@。
resolveWrite :: Hub -> Maybe Text -> FilePath -> IO (Either WorkspaceError WriteScope)
resolveWrite = undefined

-- | 管線類指令的作用範圍(ADR-017 決策三:對每個符合 @kind@ 的 vault __各跑一次__,
-- 每次只寫自己的索引)。第二參數是這條管線只對哪種 vault 有意義。
--
-- * @Nothing@:全部已註冊且 marker 的 @vmKind@ 與第二參數相符的 vault。kind
--   不符__不是 issue__(那是「這條管線與它無關」,不是降級)。
-- * @Just s@:'Aapms.Workspace.Types.psRuns' 恰好是 @{X}@;@X@ 的 @vmKind@ 與第二
--   參數不符時回 'Aapms.Workspace.Types.VaultKindMismatch',帶 vault id、__要求的__
--   kind、__實際的__ kind 三個值。
--
-- __不展開 @refs@__(兩條路都不展開):管線每一次執行都寫自己的索引,而 @refs@
-- 展開進來的一律唯讀。@X@ 不可達時仍回 @Right@(空清單 + 一則 issue)——marker
-- 讀不到就判不了 kind,不能倒過來回 'Aapms.Workspace.Types.VaultKindMismatch'。
resolvePipeline :: Hub -> VaultKind -> Maybe Text -> IO (Either WorkspaceError PipelineScope)
resolvePipeline = undefined
