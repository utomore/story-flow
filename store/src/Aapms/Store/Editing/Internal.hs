{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | P-003-node-write 的觀察點:三個純解譯器串起來跑到底、連續配號,以及九個
-- 「要解析才算得出來」的觀察點。
--
-- 只有 law 用得到它們,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
--
-- __為什麼九個解析類觀察點住這裡而不是 "Aapms.Store.Types"__(P-003 REV-2):
-- 'documentAt' \/ 'sectionBytes' \/ 'metaAt' \/ 'assetAt' \/ 'licensesAt' \/
-- 'assetIdsAt' \/ 'packAt' \/ 'levelAt' \/ 'levelOf' 非 import "Aapms.Md.Parse"
-- \/ "Aapms.Md.Render" 不可,而那兩個模組在模組表是 __pure__ 層;
-- "Aapms.Store.Types" 是 types 層,不得 import 上層(rules\/boundary.md「四層」)。
-- 本模組是 pure 層,import 得起來。
module Aapms.Store.Editing.Internal
  ( simulateWrite
  , allocateN

    -- * 解析類觀察點(P-003-node-write)
  , documentAt
  , sectionBytes
  , metaAt
  , assetAt
  , licensesAt
  , assetIdsAt
  , packAt
  , levelAt
  , levelOf
  ) where

import qualified Data.ByteString as BS
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (gets, modify, runState)

import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix, fnv1a64, newId)
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Md.Document (DocKind (..), Document (..), Section (..))
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Md.Render (renderSection)
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
  , locatedFile
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

-- 解析類觀察點(P-003-node-write REV-2:自 "Aapms.Store.Types" 原樣搬進 pure 層)-

-- | 記憶體 vault 裡某檔解析後的文件。
documentAt :: VaultFiles -> FilePath -> Maybe Document
documentAt vf p = do
  (_, txt) <- Map.lookup p vf
  hush (parseDocument txt)

-- | 'Either' 丟掉錯誤。本模組私有。
hush :: Either e a -> Maybe a
hush = either (const Nothing) Just

-- | 一份文件裡每一個節點的 'Meta',檔案層主體在前;解析失敗回空清單。本模組私有。
metasOf :: Document -> [Meta]
metasOf d = case docKind d of
  TopicDoc -> either (const []) (\(mainE, frags) -> entMeta mainE : map entMeta frags) (toTopic d)
  LevelDoc -> either (const []) (\(lvl, ns) -> lvlMeta lvl : map nodMeta ns) (toLevel d)
  PackDoc -> either (const []) (\(pck, as) -> pckMeta pck : map astMeta as) (toPack d)
  LicenseDoc -> either (const []) (map licMeta) (toLicenses d)

-- | 某檔每一節渲染後的位元組。
sectionBytes :: VaultFiles -> FilePath -> [(Id, Text)]
sectionBytes vf p =
  maybe [] (map (\s -> (secId s, renderSection s)) . docSections) (documentAt vf p)

-- | 從檔案重讀節點目前的 'Meta'。
metaAt :: VaultFiles -> IndexState -> Id -> Maybe Meta
metaAt vf ix i = do
  p <- locatedFile ix i
  d <- documentAt vf p
  find ((== i) . metaId) (metasOf d)

-- | 從 pack 檔重讀 asset 目前的欄位。
assetAt :: VaultFiles -> IndexState -> Id -> Maybe Asset
assetAt vf ix i = do
  p <- locatedFile ix i
  d <- documentAt vf p
  (_, assets) <- hush (toPack d)
  find ((== i) . metaId . astMeta) assets

-- | @licenses.md@ 解出的授權清單。
--
-- 記憶體 vault 裡__每一份__ @LicenseDoc@ 都算(路徑遞增),不寫死
-- @library\/licenses.md@ ——這個觀察點的簽名沒有路徑參數。
licensesAt :: VaultFiles -> [License]
licensesAt vf =
  concat
    [ either (const []) id (toLicenses d)
    | p <- Map.keys vf
    , d <- maybe [] pure (documentAt vf p)
    , docKind d == LicenseDoc
    ]

-- | 某 pack 檔的 asset id 依文件順序。
assetIdsAt :: VaultFiles -> FilePath -> [Id]
assetIdsAt vf p =
  maybe [] (either (const []) (map (metaId . astMeta) . snd) . toPack) (documentAt vf p)

-- | 某 pack 檔的檔案層 'Aapms.Core.Pack.Pack'。
packAt :: VaultFiles -> FilePath -> Maybe Pack
packAt vf p = documentAt vf p >>= fmap fst . hush . toPack

-- | 某 Level 檔解出的場景與節點。
levelAt :: VaultFiles -> FilePath -> Maybe (Level, [Node])
levelAt vf p = documentAt vf p >>= levelOf

-- | Level 檔文件解出的場景與節點。
levelOf :: Document -> Maybe (Level, [Node])
levelOf = hush . toLevel
