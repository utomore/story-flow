-- | 全量重建的 shell 進入點(P-001-index-rebuild 的 @!@ 列)。
--
-- __整檔替換而非逐筆 diff__:一份 @.md@ 的所有節點一起進退。正確性上遠比
-- 「算出哪一節被改了」可靠,而檔案級的重新索引成本本來就很低。
--
-- ADR-022(寫鎖預算)合規性:讀檔、@stat@、@parseDocument@\/@to*@\/@buildTree@\/
-- @checkMeta@ 等純函式解析全部在交易__外__先算完;交易內只有已經算好的
-- INSERT\/DELETE。每個檔案各自一個短交易,不是整個 vault 一個大交易——這條
-- 現在住 'Aapms.Store.Effect.Index.Sqlite.runIndexSqlite'。
--
-- __本模組只剩一條進入點__(P-001-index-rebuild 的決定,2026-09-06 退場波):
-- 舊的 @indexFile@ \/ @unindexFile@ \/ @refreshStale@ 與它們共用的 @indexOne@
-- 直接 IO 路徑已經退場。過時刷新不另立進入點:它是
-- 'Aapms.Store.Indexing.refresh'(第 17 列),與 'Aapms.Store.Indexing.rebuild'
-- 共用同一組真解譯器,呼叫端直接跑效果程式即可。單檔索引同理走
-- 'Aapms.Store.Indexing.indexPath'。
module Aapms.Store.Index
  ( -- * 全量
    rebuildIndex
  ) where

import Aapms.Store.Effect.Index.Sqlite (runIndexSqlite)
import Aapms.Store.Effect.VaultFs.IO (runVaultFsIO)
import Aapms.Store.Error (StoreError, trySqlite)
import Aapms.Store.Indexing (rebuild)
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..))
import Aapms.Store.Schema (IndexIssue)
import Effectful (runEff)

-- 全量重建 ---------------------------------------------------------------------

-- | 掃描 Vault 下所有 @.md@ 並從零建立索引。__單檔解析\/驗證失敗不中斷__:
-- 作者手改壞一份檔案不該讓整個索引建不起來,問題收集成 'IndexIssue' 一次
-- 回報。SQLite 層的錯誤則會中止——那不是資料的問題。
--
-- __P-001-index-rebuild 的 @!@ 列__:本體只做「跑真解譯器」。整條流程(清空
-- 索引 → 列檔 → 逐檔取指紋、讀檔、解析、樹驗證與 Meta 警告、撞名裁決 →
-- 整檔替換)住 pure 層的 'Aapms.Store.Indexing.rebuild',是不帶
-- 'Effectful.IOE' 的效果程式;檔案系統與 sqlite 由
-- 'Aapms.Store.Effect.VaultFs.IO.runVaultFsIO' 與
-- 'Aapms.Store.Effect.Index.Sqlite.runIndexSqlite' 落地。
--
-- 'Aapms.Core.Registry.TypeRegistry' 與 vault id 都從把手上拿(@vhRegistry@ 與
-- @vhMarker@ 的 @vmId@);外層包一層 'Aapms.Store.Error.trySqlite',讓 SQLite
-- 的例外收斂成 'Aapms.Store.Types.SqliteError' 而不是往上拋。
rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])
rebuildIndex vh =
  flatten
    <$> trySqlite
      ( runEff
          ( runVaultFsIO
              (vhRoot vh)
              (runIndexSqlite (vhConn vh) (rebuild (vhRegistry vh) (vmId (vhMarker vh))))
          )
      )
  where
    flatten = either Left id
