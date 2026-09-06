{-# LANGUAGE DataKinds #-}

-- | 索引重建的 stage 本體(P-001-index-rebuild)。
--
-- 本模組住 pure 層:'indexDocument' 與 'staleFiles' 是純函數,'indexPath' \/
-- 'refresh' \/ 'rebuild' 是只帶效果__描述__的 @Eff@ 程式(不帶
-- 'Effectful.IOE')。真解譯器(directory、sqlite)住 shell,
-- "Aapms.Store.Index" 的 @rebuildIndex@ 是進入點。
module Aapms.Store.Indexing
  ( -- * 單檔的純核心
    indexDocument

    -- * 指紋比對
  , staleFiles

    -- * 效果程式
  , indexPath
  , refresh
  , rebuild
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Effectful (Eff, (:>))

import Aapms.Core.Id (VaultId)
import Aapms.Core.Registry (TypeRegistry)
import Aapms.Store.Effect.Index (Index)
import Aapms.Store.Effect.VaultFs (VaultFs)
import Aapms.Store.Types (FileIndex, FileStat, IndexIssue, StoreError)

-- | 一份檔的純核心:解析 → 依種類轉節點 → 樹驗證與 Meta 警告 → 該檔的
-- 'FileIndex';解析或樹失敗回 'Left',警告進 issues。
indexDocument :: TypeRegistry -> VaultId -> FilePath -> FileStat -> Text -> Either StoreError (FileIndex, [IndexIssue])
indexDocument _reg _vid _p _st _txt = error "P-001#indexDocument stub"

-- | (磁碟指紋, 索引指紋) → (要重索引的, 磁碟上已消失的)。
staleFiles :: Map FilePath FileStat -> Map FilePath FileStat -> ([FilePath], [FilePath])
staleFiles _disk _rec = error "P-001#staleFiles stub"

-- | 單檔:取指紋 → 讀檔 → 純核心 → 整檔替換;解析失敗的檔回 issues 不進索引。
indexPath :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> FilePath -> Eff es (Either StoreError [IndexIssue])
indexPath _reg _vid _p = error "P-001#indexPath stub"

-- | 過時刷新:列檔 → 取指紋 → 比對索引指紋 → 對過時的重索引、消失的移除記錄。
refresh :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> Eff es (Either StoreError [IndexIssue])
refresh _reg _vid = error "P-001#refresh stub"

-- | 純的整條:清空索引,列檔,對每個路徑走 'indexPath',收集 issues。
rebuild :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> Eff es (Either StoreError [IndexIssue])
rebuild _reg _vid = error "P-001#rebuild stub"
