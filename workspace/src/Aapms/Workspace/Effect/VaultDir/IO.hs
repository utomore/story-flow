{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | "Aapms.Workspace.Effect.VaultDir" 的__真解譯器__(shell)。
--
-- 建 marker 與空索引走 graph-core 的 @initVaultAtWith@;它__不逸出 IOException__
-- (建目錄失敗回 'Aapms.Workspace.Types.VaultInitFailed',不留半成品),這條紀律
-- 由 shell 的內部測試守(P-005 的決定)。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):效果的__描述__與純解譯器
-- ('Aapms.Workspace.Effect.VaultDir.runVaultDirPure')住 effects 層,兩者不共用
-- 模組(ADR-023-effectful-effects-layer)。
module Aapms.Workspace.Effect.VaultDir.IO
  ( runVaultDirIO
  ) where

import Data.List (sort)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  , removePathForcibly
  )

import Aapms.Store.Marker (indexDbPath, initVaultAtWith, markerDir)
import Aapms.Workspace.Effect.VaultDir (VaultDir (..))

-- | 以真的檔案系統跑 'VaultDir'。
--
-- 五個操作逐一對照舊碼(@Aapms.Workspace.Lifecycle@):
--
-- * @ListEntries@ → 'System.Directory.listDirectory' 的第一層名字,__排序後__
--   交出去(@listDirectory@ 的順序由檔案系統決定;純世界那一側是一份寫定的
--   清單,排序讓兩邊在同一組名字上給得出同一個結果)。目錄不存在回空清單——
--   「空目錄」與「還不存在」的區分由 @Markers@ 的 @DirExists@ 回答,不是這裡
-- * @MarkerDirExists@ → @.aapms@ 這個路徑存不存在,__目錄或普通檔案都算佔用__
--   (舊碼 @pathExists@:同名的檔案一樣會讓 @initVaultAt@ 寫不出去)
-- * @InitMarker@ → 'Aapms.Store.Marker.initVaultAtWith'(寫 marker + 建空索引);
--   失敗捧著 'Aapms.Store.Types.StoreError' 的原件,包成
--   'Aapms.Workspace.Types.VaultInitFailed' 是純層的事
-- * @RemoveMarkerDir@ → 'System.Directory.removePathForcibly'(撞號回滾;本來就
--   不在時什麼都不做)
-- * @RemoveIndexDb@ → 存在才刪,本來就沒有回 @False@ 不算失敗;__只刪
--   @index.db@ 一個檔__,marker 與素材一律不碰(ADR-017 決策五)
runVaultDirIO :: IOE :> es => Eff (VaultDir : es) a -> Eff es a
runVaultDirIO = interpret $ \_ op -> liftIO $ case op of
  ListEntries d -> entriesOf d
  MarkerDirExists d -> pathExists (markerDir d)
  InitMarker d kind name t -> initVaultAtWith d kind name t
  RemoveMarkerDir d -> removePathForcibly (markerDir d)
  RemoveIndexDb d -> removeIfExists (indexDbPath d)

-- | 私有:目錄第一層的名字(排序);不是既存目錄時回空清單。
entriesOf :: FilePath -> IO [FilePath]
entriesOf d = do
  exists <- doesDirectoryExist d
  if exists then sort <$> listDirectory d else pure []

-- | 私有:路徑存在,不論它是目錄還是普通檔案(舊碼 @pathExists@)。
pathExists :: FilePath -> IO Bool
pathExists fp = do
  isFile <- doesFileExist fp
  if isFile then pure True else doesDirectoryExist fp

-- | 私有:存在才刪一個檔,回「有沒有真的刪到」。
removeIfExists :: FilePath -> IO Bool
removeIfExists fp = do
  exists <- doesFileExist fp
  if exists
    then do
      removeFile fp
      pure True
    else pure False
