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
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (Eff, (:>))

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName)
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (VaultId)
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..), Status (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Core.Registry (TypeRegistry)
import Aapms.Core.Registry.Build (checkMeta)
import Aapms.Core.Tree (buildTree)
import Aapms.Md.Document (DocKind (..), Document, docKind)
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Store.Effect.Index (Index, fileStats, filterNodes, locateId, removeFile, replaceFile)
import Aapms.Store.Effect.VaultFs (VaultFs, listMarkdown, readMarkdown, statFile)
import Aapms.Store.Types
  ( FileIndex (..)
  , FileStat
  , IndexIssue (..)
  , IndexedNode (..)
  , Located (..)
  , NodeFilter (..)
  , StoreError
  , emptyNodeFilter
  )

--------------------------------------------------------------------------------
-- 單檔的純核心

-- | 一份檔的純核心:解析 → 依種類轉節點 → 樹驗證與 Meta 警告 → 該檔的
-- 'FileIndex';解析或樹失敗回 'Left',警告進 issues。
--
-- 撞名(''DuplicateAssetName'')__不在這裡__:那是跨檔的事實,由
-- 'indexPath' 拿索引現況判定(P-001-index-rebuild LAW-6)。
indexDocument :: TypeRegistry -> VaultId -> FilePath -> FileStat -> Text -> Either IndexIssue (FileIndex, [IndexIssue])
indexDocument reg vid p st txt = case parseDocument txt of
  Left e -> Left (ParseFailed p e)
  Right doc -> do
    (kind, nodes) <- planNodes vid p doc
    let fi =
          FileIndex
            { fiPath = p
            , fiKind = kind
            , fiStat = st
            , fiReference = isReferencePath p
            , fiNodes = nodes
            }
    pure (fi, metaIssues reg p nodes)

-- | 依檔案種類把 'Document' 轉成該檔的索引節點,並填好 owner。
--
-- owner 逐條對照舊碼 "Aapms.Store.Index" 寫 @nodes.owner@ 時傳給
-- @insertNodeRow@ 的值:主題檔的片段指向主體、@pack.md@ 的 asset 指向 pack,
-- 其餘(檔案層主體、Level 檔的場景節點、@licenses.md@ 的每一則授權)都是
-- 'Nothing'。
--
-- 每個節點的 'Aapms.Core.Meta.metaVault' 一律覆寫成呼叫端給的 vault id
-- (LAW-7):vault 的身分是 marker 裡的 id,不信檔案自己寫的。
planNodes :: VaultId -> FilePath -> Document -> Either IndexIssue (DocKind, [IndexedNode])
planNodes vid p doc = case docKind doc of
  TopicDoc -> case toTopic doc of
    Left e -> Left (ParseFailed p e)
    Right (mainE, frags) ->
      let mainN = reVault (NEntity mainE)
          mainId = metaId (anyMeta mainN)
       in Right
            ( TopicDoc
            , IndexedNode mainN Nothing
                : [IndexedNode (reVault (NEntity f)) (Just mainId) | f <- frags]
            )
  LevelDoc -> case toLevel doc of
    Left e -> Left (ParseFailed p e)
    Right (lvl, nodes) -> case buildTree lvl nodes of
      Left errs -> Left (TreeInvalid p errs)
      Right _tree ->
        Right
          ( LevelDoc
          , IndexedNode (reVault (NLevel lvl)) Nothing
              : [IndexedNode (reVault (NNode n)) Nothing | n <- nodes]
          )
  PackDoc -> case toPack doc of
    Left e -> Left (ParseFailed p e)
    Right (pck, assets) ->
      let pckN = reVault (NPack pck)
          pckId = metaId (anyMeta pckN)
       in Right
            ( PackDoc
            , IndexedNode pckN Nothing
                : [IndexedNode (reVault (NAsset a)) (Just pckId) | a <- assets]
            )
  LicenseDoc -> case toLicenses doc of
    Left e -> Left (ParseFailed p e)
    Right lics ->
      Right (LicenseDoc, [IndexedNode (reVault (NLicense l)) Nothing | l <- lics])
  where
    reVault = withVault vid

-- | 覆寫節點的 vault 欄(LAW-7)。
withVault :: VaultId -> AnyNode -> AnyNode
withVault vid = \case
  NEntity e -> NEntity e {entMeta = setV (entMeta e)}
  NAsset a -> NAsset a {astMeta = setV (astMeta a)}
  NPack pk -> NPack pk {pckMeta = setV (pckMeta pk)}
  NLicense l -> NLicense l {licMeta = setV (licMeta l)}
  NLevel lvl -> NLevel lvl {lvlMeta = setV (lvlMeta lvl)}
  NNode n -> NNode n {nodMeta = setV (nodMeta n)}
  where
    setV m = m {metaVault = vid}

-- | 對一份檔的全部節點跑 'checkMeta',有警告的轉成 'MetaWarningsFound'。
-- __不擋索引__('checkMeta' 的契約是只回警告)。
metaIssues :: TypeRegistry -> FilePath -> [IndexedNode] -> [IndexIssue]
metaIssues reg p nodes =
  [ MetaWarningsFound p (metaId (anyMeta n)) ws
  | IndexedNode n _ <- nodes
  , let ws = checkMeta reg n
  , not (null ws)
  ]

-- | 「是 reference」由路徑決定(design.md:在 @library\/reference\/@ 之下),
-- 對照舊碼 "Aapms.Store.Index" 的 @isReferencePath@。
isReferencePath :: FilePath -> Bool
isReferencePath p = "library/reference/" `T.isInfixOf` T.pack (map slash p)
  where
    slash '\\' = '/'
    slash c = c

--------------------------------------------------------------------------------
-- 指紋比對

-- | (磁碟指紋, 索引指紋) → (要重索引的, 磁碟上已消失的)。
--
-- 兩份清單都依路徑遞增('Data.Map.Strict.Map' 的鍵序)。
staleFiles :: Map FilePath FileStat -> Map FilePath FileStat -> ([FilePath], [FilePath])
staleFiles disk rec = (todo, gone)
  where
    todo = [p | (p, st) <- Map.toList disk, Map.lookup p rec /= Just st]
    gone = [p | p <- Map.keys rec, not (Map.member p disk)]

--------------------------------------------------------------------------------
-- 效果程式

-- | 單檔:取指紋 → 讀檔 → 純核心 → 整檔替換;解析失敗的檔回 issues 不進索引。
indexPath :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> FilePath -> Eff es (Either StoreError [IndexIssue])
indexPath reg vid p =
  statFile p >>= \case
    Left e -> pure (Left e)
    Right st ->
      readMarkdown p >>= \case
        Left e -> pure (Left e)
        Right txt -> Right . snd <$> place reg vid p st txt

-- | 把一份檔整檔放進索引,回 (這個檔最後在不在索引裡, 問題清單)。
--
-- 先 @removeFile p@ 再判定,對照舊碼 @indexOne@ 一個 transaction 內
-- 「DELETE 舊列 → INSERT 新列」:失敗時該檔的舊記錄一起消失,
-- 「整檔要嘛全進要嘛不進」對增量刷新也成立(否則 LAW-5 會留下已經不該在的
-- 舊記錄)。
place :: Index :> es => TypeRegistry -> VaultId -> FilePath -> FileStat -> Text -> Eff es (Bool, [IndexIssue])
place reg vid p st txt = do
  removeFile p
  case indexDocument reg vid p st txt of
    Left issue -> pure (False, [issue])
    Right (fi, warnings) -> do
      holders <- nameHolders
      case verdict p holders (namesOf fi) of
        Reject nm -> pure (False, [DuplicateAssetName p nm])
        Accept evicted -> do
          mapM_ (removeFile . fst) evicted
          replaceFile fi
          pure (True, [DuplicateAssetName q nm | (q, nm) <- evicted] ++ warnings)

-- | 撞名的裁決(P-001-index-rebuild 的決定:整檔回滾,路徑字母序先到者保留
-- 名字)。
data Verdict
  = -- | 這個檔輸掉的那個名字:它被字母序更前的檔佔走,或同一份檔裡自己重複
    Reject LogicalName
  | -- | 這個檔進索引;附帶要一起退場的 (檔, 名字) ——它們的路徑字母序在後,
    -- 依規則本來就不該保留這個名字
    Accept [(FilePath, LogicalName)]

-- | 「字母序先到者保留名字」是一條__全域__規則,不是處理順序的副產物:
-- 從空索引依路徑遞增重建時佔住名字的一定是更前的檔(所以 'rebuild' 永遠不會
-- 走到 @evict@),但增量刷新可能先看到字母序更後的檔,此時新來的檔贏,舊的那
-- 份整檔退場——少了這一條,'refresh' 與 'rebuild' 會在撞名的 vault 上分岔
-- (LAW-5)。
verdict :: FilePath -> [(LogicalName, FilePath)] -> [LogicalName] -> Verdict
verdict p holders = go [] []
  where
    go _ evicted [] = Accept (reverse evicted)
    go seen evicted (nm : rest)
      | nm `elem` seen = Reject nm
      | otherwise = case lookup nm holders of
          Just q
            | q < p -> Reject nm
            | otherwise -> go (nm : seen) ((q, nm) : evicted) rest
          Nothing -> go (nm : seen) evicted rest

-- | 這份檔裡已命名 asset 的邏輯名稱,依文件順序。
namesOf :: FileIndex -> [LogicalName]
namesOf fi = [nm | IndexedNode (NAsset a) _ <- fiNodes fi, nm <- maybe [] pure (astName a)]

-- | 索引裡目前每個已命名 asset 的 (邏輯名稱, 所在檔)。
--
-- 索引效果沒有「照名字查 asset」的操作(舊碼的
-- @SELECT count(*) FROM assets WHERE name = ?@ 在效果層沒有對應的 op),
-- 所以拿 @filterNodes@ 取全部節點、再用 @locateId@ 問所在檔。過濾條件刻意放到
-- 最寬:列出全部狀態(空的 @nfStatus@ 會排除 'Missing')、連 reference 的
-- pack 也算——名字的唯一性不看狀態。
nameHolders :: Index :> es => Eff es [(LogicalName, FilePath)]
nameHolders = do
  ns <- filterNodes allNodes
  concat <$> traverse holderOf ns
  where
    allNodes =
      emptyNodeFilter
        { nfStatus = [Draft, Canon, Deprecated, Missing]
        , nfIncludeReference = True
        }
    holderOf n = case inNode n of
      NAsset a -> case astName a of
        Nothing -> pure []
        Just nm ->
          locateId (metaId (anyMeta (inNode n))) >>= \case
            Nothing -> pure []
            Just loc -> pure [(nm, locPath loc)]
      _ -> pure []

-- | 過時刷新:列檔 → 取指紋 → 比對索引指紋 → 對過時的重索引、消失的移除記錄。
--
-- __只回報這次刷新真的改動到索引的問題__:一份始終進不了索引的壞檔(它在索引
-- 裡沒有記錄,所以每次都算「過時」)不會每刷新一次就再被念一遍。
-- LAW-4「檔案沒變時刷新是恆等,__且不回報任何問題__」對含壞檔的 vault 也因此
-- 成立;'rebuild' 則照樣把每一則問題都列出來。
refresh :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> Eff es (Either StoreError [IndexIssue])
refresh reg vid =
  listMarkdown >>= \ps ->
    diskStats ps >>= \case
      Left e -> pure (Left e)
      Right disk -> do
        recorded <- fileStats
        let (todo, gone) = staleFiles disk recorded
        mapM_ removeFile gone
        go recorded [] todo
  where
    go _ acc [] = pure (Right (concat (reverse acc)))
    go recorded acc (p : rest) =
      statFile p >>= \case
        Left e -> pure (Left e)
        Right st ->
          readMarkdown p >>= \case
            Left e -> pure (Left e)
            Right txt -> do
              (entered, issues) <- place reg vid p st txt
              let unchanged = not entered && not (Map.member p recorded)
              go recorded (if unchanged then acc else issues : acc) rest

-- | 磁碟上這些路徑的指紋;任何 'StoreError' 直接中止。
diskStats :: VaultFs :> es => [FilePath] -> Eff es (Either StoreError (Map FilePath FileStat))
diskStats = go Map.empty
  where
    go m [] = pure (Right m)
    go m (p : rest) =
      statFile p >>= \case
        Left e -> pure (Left e)
        Right st -> go (Map.insert p st m) rest

-- | 純的整條:清空索引,列檔,對每個路徑走 'indexPath',收集 issues。
rebuild :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> Eff es (Either StoreError [IndexIssue])
rebuild reg vid = do
  recorded <- fileStats
  mapM_ removeFile (Map.keys recorded)
  ps <- listMarkdown
  go [] ps
  where
    go acc [] = pure (Right (concat (reverse acc)))
    go acc (p : rest) =
      indexPath reg vid p >>= \case
        Left e -> pure (Left e)
        Right issues -> go (issues : acc) rest
