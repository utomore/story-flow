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

import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

import Aapms.Store.Types (FileStat, StoreError, VaultFiles)

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
runVaultFsPure :: VaultFiles -> Eff (VaultFs : es) a -> Eff es a
runVaultFsPure _vf _act = error "P-001#runVaultFsPure stub"
