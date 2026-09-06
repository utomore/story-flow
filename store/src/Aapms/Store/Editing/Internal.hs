{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | P-003-node-write 的觀察點:三個純解譯器串起來跑到底,與連續配號。
--
-- 只有 law 用得到它們,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
module Aapms.Store.Editing.Internal
  ( simulateWrite
  , allocateN
  ) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (gets, modify, runState)

import Aapms.Core.Id (Id, IdPrefix, fnv1a64, newId)
import Aapms.Store.Effect.Clock (Clock, runClockPure)
import Aapms.Store.Effect.Index (Index)
import Aapms.Store.Effect.VaultFs (VaultFs (..))
import Aapms.Store.Simulate (runIndexPure)
import Aapms.Store.Types
  ( FileStat (..)
  , IndexState
  , VaultFiles
  , WriteRun (..)
  , StoreError (..)
  , indexedIds
  , vaultPaths
  )

-- | 觀察:三個純解譯器串起來跑到底,回結果、最終檔案表、最終索引。
--
-- 效果清單 @'[VaultFs, Index, Clock]@ 由左往右剝:'runVaultFsWrite' 帶出最終
-- 檔案表,'Aapms.Store.Simulate.runIndexPure' 帶出最終索引,
-- 'Aapms.Store.Effect.Clock.runClockPure' 固定時刻。
--
-- __為什麼不是 'Aapms.Store.Effect.VaultFs.runVaultFsPure'__:那一個是唯讀的
-- (簽名不帶狀態出口,@WriteMarkdown@ 一律失敗),P-001-index-rebuild 的整條只讀
-- 不寫用得上;P-003 要看寫完之後的檔案表,所以本模組另有一個帶狀態出口的解譯器。
simulateWrite :: UTCTime -> VaultFiles -> IndexState -> Eff '[VaultFs, Index, Clock] a -> WriteRun a
simulateWrite t vf0 ix0 act =
  let ((a, vf1), ix1) = runPureEff (runClockPure t (runIndexPure ix0 (runVaultFsWrite vf0 act)))
   in WriteRun {runResult = a, runFiles = vf1, runIndex = ix1}

-- | 可寫的 'VaultFs' 純解譯器,帶出最終檔案表。本模組私有。
--
-- 六個操作對照 'Aapms.Store.Effect.VaultFs.runVaultFsPure',只有寫與刪不同:
--
-- * @WriteMarkdown@ 覆蓋(或新增)該路徑,指紋由內容算('statOfText'),所以
--   「內容變了指紋一定變」是結構上的結果——單檔重索引才看得出檔案動過。
-- * @DeleteMarkdown@ 移除該路徑;路徑本來就不在時回
--   'Aapms.Store.Types.FileWriteFailed'(對照真解譯器刪不存在的檔會失敗)。
runVaultFsWrite :: VaultFiles -> Eff (VaultFs : es) a -> Eff es (a, VaultFiles)
runVaultFsWrite vf0 = reinterpret (runState vf0) $ \_ op -> case op of
  ListMarkdown -> gets vaultPaths
  StatFile p -> gets (statAt p)
  ReadMarkdown p -> gets (textAt p)
  FileExists p -> gets (hasFile p)
  WriteMarkdown p txt -> do
    modify (insertFile p txt)
    pure (Right ())
  DeleteMarkdown p -> do
    present <- gets (hasFile p)
    if present
      then do
        modify (dropFile p)
        pure (Right ())
      else pure (Left (FileWriteFailed p missingText))

-- | 記憶體 vault 裡查不到路徑時的訊息,與唯讀解譯器
-- 'Aapms.Store.Effect.VaultFs.runVaultFsPure' 一致。
missingText :: Text
missingText = "記憶體 vault 裡沒有這個路徑"

statAt :: FilePath -> VaultFiles -> Either StoreError FileStat
statAt p = maybe (Left (FileReadFailed p missingText)) (Right . fst) . Map.lookup p

textAt :: FilePath -> VaultFiles -> Either StoreError Text
textAt p = maybe (Left (FileReadFailed p missingText)) (Right . snd) . Map.lookup p

hasFile :: FilePath -> VaultFiles -> Bool
hasFile = Map.member

insertFile :: FilePath -> Text -> VaultFiles -> VaultFiles
insertFile p txt = Map.insert p (statOfText txt, txt)

dropFile :: FilePath -> VaultFiles -> VaultFiles
dropFile = Map.delete

-- | 記憶體 vault 的指紋:內容的 FNV-1a 當 mtime、UTF-8 位元組數當 size。
--
-- 真解譯器的指紋來自檔案系統;純解譯器沒有檔案系統,只能由內容決定。重點是
-- __內容不同指紋就不同__ ——'Aapms.Store.Types.statsDistinguish' 要的正是這條。
statOfText :: Text -> FileStat
statOfText txt =
  FileStat
    { fsMtime = fromIntegral (fnv1a64 bytes)
    , fsSize = fromIntegral (BS.length bytes)
    }
  where
    bytes = TE.encodeUtf8 txt

-- | 觀察:同一個 t 連續配 n 次、每次寫進索引後拿到的 id。
--
-- 逐次重跑 'Aapms.Store.Editing.allocateFreshId' 的 salt 迴圈(每次都從
-- @salt = 0@ 起算),並把上一次拿到的 id 當成「已被佔用」——這正是「配完就寫進
-- 索引,下一次再配」的語意。@n <= 0@ 回空清單。
allocateN :: Int -> IdPrefix -> Text -> UTCTime -> IndexState -> [Id]
allocateN n pre c t ix = go n (indexedIds ix)
  where
    go k taken
      | k <= 0 = []
      | otherwise =
          let i = alloc (0 :: Int) taken
           in i : go (k - 1) (i : taken)
    alloc salt taken =
      let candidate = newId pre c t salt
       in if candidate `elem` taken then alloc (salt + 1) taken else candidate
