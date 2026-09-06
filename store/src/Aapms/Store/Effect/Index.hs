{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | 一個 vault 的索引列讀寫,寫成 effectful 的__效果描述__(ADR-023)。
--
-- 三條里程碑共用同一個效果:P-001-index-rebuild 用它整檔替換記錄,
-- P-002-search 用它查 FTS 與結構條件,P-003-node-write 用它定位、查碰撞與被引用。
-- 效果本身__只認單一 vault__;跨 vault 由 "Aapms.Store.Effect.Vaults" 的
-- @inVault@ 對每個 vault 各跑一次(P-002 的決定)。
--
-- 真解譯器(sqlite)住 shell,純解譯器 'runIndexPure' 跑在記憶體裡的
-- 'Aapms.Store.Types.IndexState' 上,是三條里程碑 law 的觀察點。
module Aapms.Store.Effect.Index
  ( -- * 效果描述
    Index (..)

    -- * 索引維護(P-001-index-rebuild)
  , replaceFile
  , removeFile
  , fileStats

    -- * 查詢(P-002-search)
  , ftsMatch
  , filterNodes

    -- * 寫入路徑(P-003-node-write)
  , locateId
  , idTaken
  , referrers

    -- * 純解譯器(觀察點)
  , runIndexPure
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

import Aapms.Core.AnyNode (AnyNode)
import Aapms.Core.Id (Id)
import Aapms.Core.Link (Link)
import Aapms.Store.Types
  ( FileIndex
  , FileStat
  , IndexState
  , Located
  , NodeFilter
  , SearchRoute
  )

-- | 一個 vault 的索引的八個操作。
data Index :: Effect where
  ReplaceFile :: FileIndex -> Index m ()
  RemoveFile :: FilePath -> Index m ()
  FileStats :: Index m (Map FilePath FileStat)
  FtsMatch :: SearchRoute -> Text -> NodeFilter -> Index m [(Id, Double)]
  FilterNodes :: NodeFilter -> Index m [AnyNode]
  LocateId :: Id -> Index m (Maybe Located)
  IdTaken :: Id -> Index m Bool
  Referrers :: [Id] -> Index m [(Id, Link)]

makeEffect_ ''Index

-- | 以檔案為單位整檔替換索引裡的記錄。
replaceFile :: Index :> es => FileIndex -> Eff es ()

-- | 移除一個檔案的全部記錄。
removeFile :: Index :> es => FilePath -> Eff es ()

-- | 索引裡記錄的每個檔的指紋。
fileStats :: Index :> es => Eff es (Map FilePath FileStat)

-- | 一個 vault 內依路由查雙 FTS,結構條件同時套用,回命中與正分數。
ftsMatch :: Index :> es => SearchRoute -> Text -> NodeFilter -> Eff es [(Id, Double)]

-- | 一個 vault 內符合結構條件的全部節點,不分頁。
filterNodes :: Index :> es => NodeFilter -> Eff es [AnyNode]

-- | 在索引裡找節點所在檔、錨點(檔案層主體為 'Nothing')與文件種類。
locateId :: Index :> es => Id -> Eff es (Maybe Located)

-- | 配號的碰撞查詢。
idTaken :: Index :> es => Id -> Eff es Bool

-- | 指向這些節點的關聯(來源 id、關聯),刪除前的被引用檢查。
referrers :: Index :> es => [Id] -> Eff es [(Id, Link)]

-- | 觀察:'Index' 的純解譯器,回最終索引狀態。
runIndexPure :: IndexState -> Eff (Index : es) a -> Eff es (a, IndexState)
runIndexPure _ix _act = error "P-001#runIndexPure stub"
