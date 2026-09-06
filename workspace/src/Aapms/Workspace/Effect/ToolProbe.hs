{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | 本機外部工具的探測,寫成 effectful 的__效果描述__(ADR-023)。
--
-- 只有兩個操作:問一個路徑存不存在且可執行、把 @PATH@ 拆成目錄清單。
-- 「三層候選清單怎麼排」與「命中即停」是純的,住
-- "Aapms.Workspace.Tools.Plan"(P-006-workspace-doctor)。
--
-- __不執行找到的檔案__:不查版本、不測試解壓能力,所以這個效果一個外部行程都不
-- 啟動。純解譯器 'runToolProbePure' 跑在
-- 'Aapms.Workspace.Types.ToolWorld' 上。
module Aapms.Workspace.Effect.ToolProbe
  ( -- * 效果描述
    ToolProbe (..)

    -- * 操作(P-006-workspace-doctor)
  , isExecutable
  , pathDirs

    -- * 純解譯器(觀察點)
  , runToolProbePure
  ) where

import Effectful (Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.TH (makeEffect_)

import Aapms.Workspace.Types (ToolWorld, executables, twPathDirs)

-- | 外部工具探測的兩個操作。
data ToolProbe :: Effect where
  IsExecutable :: FilePath -> ToolProbe m Bool
  PathDirs :: ToolProbe m [FilePath]

makeEffect_ ''ToolProbe

-- | 存在且可執行(目錄不算),不存在不拋。
isExecutable :: ToolProbe :> es => FilePath -> Eff es Bool

-- | @PATH@ 拆成目錄清單。
pathDirs :: ToolProbe :> es => Eff es [FilePath]

-- | 觀察:'ToolProbe' 的純解譯器(可執行檔集合、@PATH@ 目錄)。
--
-- 兩個操作的純語意:
--
-- * @IsExecutable@ 是「這個路徑在不在
--   'Aapms.Workspace.Types.executables' 裡」,比對__逐字__(不走
--   'System.FilePath.equalFilePath'、不正規化):候選路徑是
--   'Aapms.Workspace.Tools.Plan.probes' 逐字拼出來的,世界那一側也逐字給,
--   兩邊同一套字串才對得起來。目錄不會出現在可執行檔集合裡,所以「目錄不算」
--   在純世界是自動成立的。
-- * @PathDirs@ 直接捧出 'Aapms.Workspace.Types.twPathDirs',__保序__。
--
-- 世界是不可變的參數,所以這個解譯器一個字都寫不出去——「診斷唯讀」在純這一側
-- 由型別本身守住。
runToolProbePure :: ToolWorld -> Eff (ToolProbe : es) a -> Eff es a
runToolProbePure tw = interpret $ \_ op -> case op of
  IsExecutable p -> pure (p `elem` executables tw)
  PathDirs -> pure (twPathDirs tw)
