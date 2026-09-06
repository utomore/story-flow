{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | vault 目錄裡 Markdown 的讀寫,寫成 effectful 的__效果描述__(ADR-023)。
--
-- 本模組住 effects 層:'VaultFs' 是純資料(指令 GADT),'Eff' 是描述型別而不是
-- 執行能力,沒有任何簽名帶 'Effectful.IOE'。真解譯器(@directory@)住 shell,
-- 純解譯器 'runVaultFsPure' 跑在記憶體裡的 'VaultFiles' 上,是 P-001 / P-003
-- 兩條里程碑 law 的觀察點。
module Aapms.Store.Effect.VaultFs
  ( -- * 效果描述
    VaultFs (..)

    -- * 操作(P-001-index-rebuild、P-003-node-write)
  , listMarkdown
  , statFile
  , readMarkdown
  , fileExists
  , writeMarkdown
  , deleteMarkdown

    -- * 純解譯器(觀察點)
  , runVaultFsPure
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.TH (makeEffect_)

import Aapms.Store.Types (FileStat, StoreError (..), VaultFiles, vaultPaths)

-- | vault 目錄的六個操作。@ListMarkdown@ 已排序、略過 @.@ 開頭目錄。
data VaultFs :: Effect where
  ListMarkdown :: VaultFs m [FilePath]
  StatFile :: FilePath -> VaultFs m (Either StoreError FileStat)
  ReadMarkdown :: FilePath -> VaultFs m (Either StoreError Text)
  FileExists :: FilePath -> VaultFs m Bool
  WriteMarkdown :: FilePath -> Text -> VaultFs m (Either StoreError ())
  DeleteMarkdown :: FilePath -> VaultFs m (Either StoreError ())

makeEffect_ ''VaultFs

-- | 列出 vault 下全部 @.md@ 的相對路徑,略過 @.@ 開頭目錄,已排序。
listMarkdown :: VaultFs :> es => Eff es [FilePath]

-- | 取一個檔的 mtime 與 size 當指紋。
statFile :: VaultFs :> es => FilePath -> Eff es (Either StoreError FileStat)

-- | 讀一個檔的全文。
readMarkdown :: VaultFs :> es => FilePath -> Eff es (Either StoreError Text)

-- | 找空檔名時探測。
fileExists :: VaultFs :> es => FilePath -> Eff es Bool

-- | 原子寫入(真解譯器:暫存檔 + rename)。
writeMarkdown :: VaultFs :> es => FilePath -> Text -> Eff es (Either StoreError ())

-- | 刪整份檔(刪除檔案層主體時)。
deleteMarkdown :: VaultFs :> es => FilePath -> Eff es (Either StoreError ())

-- | 觀察:'VaultFs' 的純解譯器,跑在記憶體裡的檔案表上。
--
-- * @ListMarkdown@ 回 'Aapms.Store.Types.vaultPaths'('Data.Map.Strict.Map' 的
--   鍵序,已是字母序遞增)。__不再過濾副檔名與 @.@ 開頭目錄__:記憶體 vault
--   沒有目錄可走,它「就是」那份已經列好的清單;真解譯器(@directory@)才要
--   自己走目錄樹並過濾。P-001-index-rebuild 的 LAW-3 / LAW-6 以
--   'Aapms.Store.Types.vaultPaths' 為分母,兩者必須逐字相同。
-- * @StatFile@ \/ @ReadMarkdown@ 查不到路徑時回
--   'Aapms.Store.Types.FileReadFailed',與真解譯器讀不到檔時同一個建構子。
-- * 本解譯器的簽名不帶狀態出口,所以是__唯讀__的:@WriteMarkdown@ \/
--   @DeleteMarkdown@ 一律回 'Aapms.Store.Types.FileWriteFailed'。
--   P-001-index-rebuild 的整條流程只讀不寫;會寫的 P-003-node-write 另有自己
--   帶檔案表出口的解譯器。
runVaultFsPure :: VaultFiles -> Eff (VaultFs : es) a -> Eff es a
runVaultFsPure vf = interpret $ \_ op -> case op of
  ListMarkdown -> pure (vaultPaths vf)
  StatFile p -> pure $ case Map.lookup p vf of
    Nothing -> Left (FileReadFailed p missing)
    Just (st, _) -> Right st
  ReadMarkdown p -> pure $ case Map.lookup p vf of
    Nothing -> Left (FileReadFailed p missing)
    Just (_, txt) -> Right txt
  FileExists p -> pure (Map.member p vf)
  WriteMarkdown p _ -> pure (Left (FileWriteFailed p readOnly))
  DeleteMarkdown p -> pure (Left (FileWriteFailed p readOnly))
  where
    missing = "記憶體 vault 裡沒有這個路徑"
    readOnly = "runVaultFsPure 是唯讀的純解譯器"
