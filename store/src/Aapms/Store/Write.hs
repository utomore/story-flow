-- | 圖譜寫入的唯一 shell 進入點(P-003-node-write 的 @!@ 列)。
--
-- 十一種寫入請求收成一個 'Aapms.Store.Types.WriteOp' sum type、一個
-- 'Aapms.Store.Types.WriteOutcome'、一條進入點(P-003-node-write 的決定)。
-- 整條紀律(定位 → 重讀 → 樂觀鎖 → 純編輯 → 寫檔前驗證 → 原子寫入 → 單檔
-- 索引)住 pure 層的 'Aapms.Store.Editing.applyWrite',是不帶 'Effectful.IOE'
-- 的效果程式;本模組只負責把三個真解譯器接上去。
--
-- __舊的十二個直接 IO 函數已退場__(2026-09-06 退場波):@createTopicFile@ \/
-- @createLevelFile@ \/ @createPackFile@ \/ @addSection@ \/ @deleteNode@(原
-- @Aapms.Store.Create@)與 @writeMeta@ \/ @writeAssetFields@ \/ @writeBody@ \/
-- @addLink@ \/ @removeLink@ \/ @upsertLicense@ \/ @allocateId@ 各自捧著一份與
-- 'Aapms.Store.Editing.applyWrite' 平行的實作,兩份會漂移;一件事只留一份。
-- 對應關係逐條是 'Aapms.Store.Types.WriteOp' 的十一個建構子,配號則是
-- 'Aapms.Store.Editing.allocateFreshId'。
module Aapms.Store.Write
  ( -- * 結果(定義在型別層的 "Aapms.Store.Types",由本模組帶進門面)
    WriteResult (..)

    -- * asset 的人給欄位(同上,定義在 "Aapms.Store.Types")
  , AssetPatch (..)

    -- * 唯一進入點(P-003-node-write 的 ! 列)
  , applyWriteIO
  ) where

import Aapms.Store.Editing (applyWrite)
import Aapms.Store.Effect.Clock.IO (runClockIO)
import Aapms.Store.Effect.Index.Sqlite (runIndexSqlite)
import Aapms.Store.Effect.VaultFs.IO (runVaultFsIO)
import Aapms.Store.Error (StoreError, trySqlite)
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..))
import Aapms.Store.Types (AssetPatch (..), WriteOp, WriteOutcome, WriteResult (..))
import Effectful (runEff)

-- 唯一進入點(P-003-node-write 的 ! 列)-------------------------------------------

-- | 十一種寫入請求的唯一進入點:以 handle 的根目錄、連線與系統時鐘跑
-- 'Aapms.Store.Editing.applyWrite' 的三個真解譯器(@directory@、@sqlite@、
-- 系統時鐘)。
--
-- 形狀照 'Aapms.Store.Index.rebuildIndex':整段 'Effectful.runEff' 包在
-- 'Aapms.Store.Error.trySqlite' 裡,SQLite 例外收斂成
-- 'Aapms.Store.Types.SqliteError',內層自己回的 'Left' 以 @flatten@ 攤平。
applyWriteIO :: VaultHandle -> WriteOp -> IO (Either StoreError WriteOutcome)
applyWriteIO vh op =
  flatten
    <$> trySqlite
      ( runEff
          ( runVaultFsIO
              (vhRoot vh)
              ( runIndexSqlite
                  (vhConn vh)
                  (runClockIO (applyWrite (vhRegistry vh) (vmId (vhMarker vh)) op))
              )
          )
      )
  where
    flatten = either Left id
