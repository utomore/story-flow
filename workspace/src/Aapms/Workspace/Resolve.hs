{-# LANGUAGE DataKinds #-}

-- | 作用範圍的__純裁決__(P-029-scope-resolve)。
--
-- 擁有的事實(唯一真相來源):「這次指令對哪些 vault 生效」——selector 的解析
-- 規則、對中樞每一列重讀 marker 的三種降級、@refs@ 的遞移展開與保序去重,以及
-- 「讀跨、寫單一、管線逐一」的分流(ADR-008、ADR-017)。
--
-- 整條是 "Aapms.Workspace.Effect.Markers" 的程式:marker 的讀取、目錄存在與否、
-- 路徑正規化、向上探測是那個效果的四個操作,__本模組一行 IO 都沒有__,純解譯器
-- 跑在一張「路徑 → marker 讀數」的表上(P-029 的決定)。
--
-- __明確不做__:不開索引、不寫任何檔、不判 ATTACH 上限
-- (@TooManyVaults@ 屬 graph-core);不決定「這個指令屬於讀還是寫」——呼叫端以
-- 'Aapms.Workspace.Types.ScopeKind' 選。
module Aapms.Workspace.Resolve
  ( -- * selector 解析
    lookupSelector

    -- * 路徑 → 權威身分
  , refOfEntry
  , refAt

    -- * refs 展開
  , expandRefGraph

    -- * 三種範圍
  , scopeRead
  , scopeWrite
  , scopePipeline

    -- * 純的整條
  , resolveScope
  ) where

import Data.Either (partitionEithers)
import Data.List (find)
import qualified Data.Set as Set
import Data.Text (Text)
import Effectful (Eff, (:>))

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Types (VaultKind, VaultMarker (..))
import Aapms.Workspace.Effect.Markers (Markers, canonicalPath, detectRoot, dirExists, readMarkerAt)
import Aapms.Workspace.Types
  ( Hub
  , PipelineScope (..)
  , ReadScope (..)
  , Scope (..)
  , ScopeIssue (..)
  , ScopeKind (..)
  , VaultEntry (..)
  , VaultRef (..)
  , WorkspaceError (..)
  , WriteScope (..)
  , hubVaults
  )

-- | 把 @--vault@ 的字串解析成中樞裡的一列。
--
-- 兩階段,__先比 'veId' 的完整字串,再比 'veName'__:id 階段有命中時,name 階段
-- 完全不參與;兩階段都逐字精確比對(不去空白、不忽略大小寫、不做前綴或子字串
-- 比對)。
--
-- 任一階段的命中集合:恰好一列 → @Right@ 該列;兩列以上 →
-- @Left ('VaultSelectorAmbiguous' s es)@,@es@ __含全部__撞名的列(順序同中樞);
-- 兩階段都沒命中 → @Left ('VaultSelectorNotFound' s)@。
--
-- 純函式,只看 'hubVaults';不讀檔案、不碰 @[[projects]]@ \/ @[llm]@ \/ @[tools]@。
--
-- (自 "Aapms.Workspace.Discovery" 搬進純層,行為逐字不變;該模組原地 re-export。)
lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry
lookupSelector hub s = case byId of
  [e] -> Right e
  es@(_ : _ : _) -> Left (VaultSelectorAmbiguous s es)
  [] -> case byName of
    [e] -> Right e
    es@(_ : _ : _) -> Left (VaultSelectorAmbiguous s es)
    [] -> Left (VaultSelectorNotFound s)
  where
    entries = hubVaults hub
    byId = filter ((== VaultId s) . veId) entries
    byName = filter ((== s) . veName) entries

-- | 對中樞一列重讀 marker:路徑不見 → 'Aapms.Workspace.Types.VaultPathMissing'、
-- 壞 → 'Aapms.Workspace.Types.VaultMarkerBroken'、id 不符 →
-- 'Aapms.Workspace.Types.VaultIdDrift',依此順序。
--
-- 三種降級__依序判定、互斥__:先問路徑是不是既存目錄,再讀 marker,最後比 id。
-- 成功時 'Aapms.Workspace.Types.vrEntry' 是 @Just@ 傳進來的那一列,
-- 'Aapms.Workspace.Types.vrMarker' __一律來自 marker__。
refOfEntry :: Markers :> es => VaultEntry -> Eff es (Either ScopeIssue VaultRef)
refOfEntry e = do
  p <- canonicalPath (vePath e)
  exists <- dirExists p
  if not exists
    then pure (Left (VaultPathMissing e p))
    else do
      markerR <- readMarkerAt p
      pure $ case markerR of
        Left err -> Left (VaultMarkerBroken e err)
        Right m
          | vmId m /= veId e -> Left (VaultIdDrift e (vmId m))
          | otherwise -> Right (VaultRef (Just e) p m)

-- | 對一個路徑讀 marker 並以 id 回填中樞那一列;讀不到一律
-- 'Aapms.Workspace.Types.MarkerUnreadable'。
--
-- 與 'refOfEntry' 相反:身分先來自 marker,再拿那個 id 回中樞反查決定
-- 'Aapms.Workspace.Types.vrEntry'(查不到 = 未註冊的 vault,@Nothing@)。
-- 失敗__不降級__:這條路的呼叫情境是「決定寫入目標」,決定不了就該硬失敗。
refAt :: Markers :> es => Hub -> FilePath -> Eff es (Either WorkspaceError VaultRef)
refAt hub p = do
  p' <- canonicalPath p
  markerR <- readMarkerAt p'
  pure $ case markerR of
    Left err -> Left (MarkerUnreadable p' err)
    Right m -> Right (VaultRef (find ((== vmId m) . veId) (hubVaults hub)) p' m)

-- | 自種子沿 @vmRefs@ 廣度優先展開,visited 擋環;未註冊目標 →
-- 'Aapms.Workspace.Types.RefVaultNotRegistered' 一次;不可達的不展開它的 @refs@。
--
-- 種子排第一,其餘依__首次入隊序__。visited 以「走到它時用的
-- 'Aapms.Core.Id.VaultId'」為鍵、單調成長,所以任何 @refs@ 圖(含環)都終止。
-- 不可達的節點只留一則 issue,__不展開它的 @refs@__——身分不確定時任何以它為
-- 起點的關係都不確定。
expandRefGraph :: Markers :> es => Hub -> VaultRef -> Eff es ([VaultRef], [ScopeIssue])
expandRefGraph hub seed = loop (Set.singleton seedId) [seed] [] initialQueue
  where
    seedId = vmId (vrMarker seed)
    initialQueue = [(seedId, t) | t <- vmRefs (vrMarker seed)]

    loop _visited out issues [] = pure (nubOn (vmId . vrMarker) out, issues)
    loop visited out issues ((src, t) : rest)
      | Set.member t visited = loop visited out issues rest
      | otherwise =
          let visited' = Set.insert t visited
          in case find ((== t) . veId) (hubVaults hub) of
               Nothing ->
                 loop visited' out (issues ++ [RefVaultNotRegistered src t]) rest
               Just e -> do
                 r <- refOfEntry e
                 case r of
                   Left iss -> loop visited' out (issues ++ [iss]) rest
                   Right ref ->
                     let newEdges = [(vmId (vrMarker ref), t') | t' <- vmRefs (vrMarker ref)]
                     in loop visited' (out ++ [ref]) issues (rest ++ newEdges)

-- | 無 selector = 全部已註冊(不展開);有 = 種子 ∪ @refs*@。
--
-- selector 解不開時__原樣透傳__那個硬錯;種子自己不可達時仍是 @Right@:空清單
-- 加恰好那一則 issue,而且不展開它的 @refs@。
scopeRead :: Markers :> es => Hub -> Maybe Text -> Eff es (Either WorkspaceError ReadScope)
scopeRead hub Nothing = do
  (vaults, issues) <- walkAll hub
  pure (Right (ReadScope vaults issues))
scopeRead hub (Just s) = case lookupSelector hub s of
  Left err -> pure (Left err)
  Right e -> do
    seedR <- refOfEntry e
    case seedR of
      Left iss -> pure (Right (ReadScope [] [iss]))
      Right seed -> do
        (vaults, issues) <- expandRefGraph hub seed
        pure (Right (ReadScope vaults issues))

-- | 目標來自 selector 或探測,恒不來自 @refs@;目標的失敗是硬錯。
--
-- 'Aapms.Workspace.Types.wsRead' 是「對同一個種子做讀取展開」的結果,目標排
-- 第一;'Aapms.Workspace.Types.wsIssues' 因此__只__裝 @refs@ 展開的降級紀錄,
-- 恒不含描述目標本身的那一則(目標的失敗已經在上面回 @Left@ 了)。
scopeWrite :: Markers :> es => Hub -> Maybe Text -> FilePath -> Eff es (Either WorkspaceError WriteScope)
scopeWrite hub sel start = do
  targetR <- writeTarget hub sel start
  case targetR of
    Left err -> pure (Left err)
    Right target -> do
      (reads', issues) <- expandRefGraph hub target
      pure (Right (WriteScope target reads' issues))

-- | 無 selector = 全部已註冊且 kind 相符;有 = 恰好一個,kind 不符回
-- 'Aapms.Workspace.Types.VaultKindMismatch'。
--
-- 兩條路都__不展開 @refs@__:管線每一次執行都寫自己的索引,展開進來的一律唯讀。
-- 指名的那個不可達時仍是 @Right@(空清單加一則 issue)——marker 讀不到就判不了
-- kind,不能倒過來回 'Aapms.Workspace.Types.VaultKindMismatch'。
scopePipeline :: Markers :> es => Hub -> VaultKind -> Maybe Text -> Eff es (Either WorkspaceError PipelineScope)
scopePipeline hub k Nothing = do
  (vaults, issues) <- walkAll hub
  let runs = filter ((== k) . vmKind . vrMarker) vaults
  pure (Right (PipelineScope runs issues))
scopePipeline hub k (Just s) = case lookupSelector hub s of
  Left err -> pure (Left err)
  Right e -> do
    r <- refOfEntry e
    case r of
      Left iss -> pure (Right (PipelineScope [] [iss]))
      Right ref
        | vmKind (vrMarker ref) /= k ->
            pure (Left (VaultKindMismatch (vmId (vrMarker ref)) k (vmKind (vrMarker ref))))
        | otherwise -> pure (Right (PipelineScope [ref] []))

-- | 純的整條:依 'ScopeKind' 走 'scopeRead' \/ 'scopeWrite' \/ 'scopePipeline'。
resolveScope
  :: Markers :> es
  => Hub
  -> ScopeKind
  -> Maybe Text
  -> FilePath
  -> Eff es (Either WorkspaceError Scope)
resolveScope hub kind sel start = case kind of
  ForRead -> fmap (fmap SRead) (scopeRead hub sel)
  ForWrite -> fmap (fmap SWrite) (scopeWrite hub sel start)
  ForPipeline k -> fmap (fmap SPipeline) (scopePipeline hub k sel)

--------------------------------------------------------------------------------
-- 私有

-- | 私有:寫入目標的裁決,恒經 'refAt'(硬失敗通道),__恒不來自 @refs@__。
--
-- 兩條路只差在起點路徑怎麼來:沒有 selector 時從第三參數向上探測,一路到不動點
-- 都沒有 @.aapms@ 就是 'Aapms.Workspace.Types.NoWriteTarget'(帶正規化後的起
-- 點);有 selector 時起點換成中樞那一列的 'vePath',另加一道 __id 守門__:目標
-- marker 的 id 與那一列不符是硬失敗,因為註冊表指的位置上已經不是使用者點名的
-- 那個 vault。
writeTarget :: Markers :> es => Hub -> Maybe Text -> FilePath -> Eff es (Either WorkspaceError VaultRef)
writeTarget hub Nothing start = do
  mRoot <- detectRoot start
  case mRoot of
    Nothing -> do
      s' <- canonicalPath start
      pure (Left (NoWriteTarget s'))
    Just root -> refAt hub root
writeTarget hub (Just s) _start = case lookupSelector hub s of
  Left err -> pure (Left err)
  Right e -> do
    r <- refAt hub (vePath e)
    case r of
      Left err -> pure (Left err)
      Right ref
        | vmId (vrMarker ref) /= veId e ->
            pure (Left (WriteTargetIdDrift (veId e) (vrPath ref) (vmId (vrMarker ref))))
        | otherwise -> pure (Right ref)

-- | 私有:__不展開 @refs@__,依中樞順序重讀每一列,保序去重(以 marker 的 id)。
walkAll :: Markers :> es => Hub -> Eff es ([VaultRef], [ScopeIssue])
walkAll hub = do
  results <- mapM refOfEntry (hubVaults hub)
  let (issues, refs) = partitionEithers results
  pure (nubOn (vmId . vrMarker) refs, issues)

-- | 私有:保序去重,保留鍵第一次出現的位置。
nubOn :: Ord k => (a -> k) -> [a] -> [a]
nubOn key = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member k seen = go seen xs
      | otherwise = x : go (Set.insert k seen) xs
      where
        k = key x
