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
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing, listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (gets, modify, runState)
import Effectful.TH (makeEffect_)

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Id (Id, Ref (..))
import Aapms.Core.Link (Link (..))
import Aapms.Core.Meta (Meta (..))
import Aapms.Md.Document (DocKind (..))
import Aapms.Store.Filter (passesFilter)
import Aapms.Store.Tokenize (matchesQuery)
import Aapms.Store.Types
  ( FileIndex (..)
  , FileStat
  , IndexState (..)
  , IndexedNode (..)
  , Located (..)
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
--
-- 八個操作的純語意都跑在 'IndexState'(路徑 → 'FileIndex')上:
--
-- * @ReplaceFile@ \/ @RemoveFile@ \/ @FileStats@ 是 P-001-index-rebuild 的
--   「整檔進退」:一個路徑一組記錄。
-- * @FtsMatch@ 依 P-002-search 的決定,以 'Aapms.Store.Tokenize.matchesQuery'
--   (P-027-fts-tokenize 的純參考)與 'passesFilter' 判定,分數固定 @1.0@
--   ——law 只用到「正」與排序鍵,bm25 的絕對值是 sqlite 的實作細節。
--   'SearchRoute' 參數在純側不影響結果:'matchesQuery' 自己就依
--   'Aapms.Store.Tokenize.routeOf' 走同一套路由,真解譯器才拿它選表。
-- * @FilterNodes@ 是同一組結構條件,不套 @nfLimit@ \/ @nfOffset@(分頁由
--   "Aapms.Store.Search" 對整體做)。
-- * @LocateId@ \/ @IdTaken@ \/ @Referrers@ 是 P-003-node-write 的定位、配號
--   碰撞與被引用查詢。
runIndexPure :: IndexState -> Eff (Index : es) a -> Eff es (a, IndexState)
runIndexPure ix0 = reinterpret (runState ix0) $ \_ op -> case op of
  ReplaceFile fi -> modify (replaceIn fi)
  RemoveFile p -> modify (removeIn p)
  FileStats -> gets statsIn
  FtsMatch _route txt nf -> gets (ftsIn txt nf)
  FilterNodes nf -> gets (filterIn nf)
  LocateId i -> gets (locateIn i)
  IdTaken i -> gets (takenIn i)
  Referrers is -> gets (referrersIn is)

--------------------------------------------------------------------------------
-- 純解譯器的私有語意

replaceIn :: FileIndex -> IndexState -> IndexState
replaceIn fi (IndexState m) = IndexState (Map.insert (fiPath fi) fi m)

removeIn :: FilePath -> IndexState -> IndexState
removeIn p (IndexState m) = IndexState (Map.delete p m)

statsIn :: IndexState -> Map FilePath FileStat
statsIn (IndexState m) = Map.map fiStat m

-- | 索引裡的每一列:(節點所在的檔, 節點),路徑遞增、檔內依文件順序。
--
-- __同一個 id 只留第一列__:真索引的 @nodes.id@ 是主鍵,一個 id 不可能有兩列。
-- 記憶體模型不強制這件事,所以在這裡把它補回來——少了它,一份「同一個 id 出現
-- 在兩個檔」的 'IndexState' 會讓 P-002-search#LAW-5(命中的 (vault, id) 兩兩
-- 相異)在沒有 bug 的情況下也紅。
rowsIn :: IndexState -> [(FileIndex, IndexedNode)]
rowsIn (IndexState m) = go Set.empty [(fi, n) | fi <- Map.elems m, n <- fiNodes fi]
  where
    go _ [] = []
    go seen (row@(_, n) : rest)
      | i `Set.member` seen = go seen rest
      | otherwise = row : go (Set.insert i seen) rest
      where
        i = idOf n

idOf :: IndexedNode -> Id
idOf = metaId . anyMeta . inNode

filterIn :: NodeFilter -> IndexState -> [AnyNode]
filterIn nf st = [inNode n | (fi, n) <- rowsIn st, passesFilter nf fi n]

ftsIn :: Text -> NodeFilter -> IndexState -> [(Id, Double)]
ftsIn txt nf st =
  [ (idOf n, 1.0)
  | (fi, n) <- rowsIn st
  , passesFilter nf fi n
  , matchesQuery txt (inNode n)
  ]

locateIn :: Id -> IndexState -> Maybe Located
locateIn i st =
  listToMaybe
    [ Located {locPath = fiPath fi, locAnchor = anchorOf fi n, locKind = fiKind fi}
    | (fi, n) <- rowsIn st
    , idOf n == i
    ]

-- | 錨點:檔案層主體是 'Nothing',其餘是節點自己的 id。
--
-- 「哪一個是檔案層主體」由檔案種類決定,對照 "Aapms.Store.Index" 寫索引時
-- 傳給 @insertNodeRow@ 的 @anchorId@:主題檔是沒有 owner 的那個 'NEntity'、
-- Level 檔是 'NLevel'、@pack.md@ 是 'NPack';@licenses.md@ 的每個授權都是一節,
-- 沒有檔案層主體。
anchorOf :: FileIndex -> IndexedNode -> Maybe Id
anchorOf fi n
  | isFileBody = Nothing
  | otherwise = Just (idOf n)
  where
    isFileBody = case (fiKind fi, inNode n) of
      (TopicDoc, NEntity _) -> isNothing (inOwner n)
      (LevelDoc, NLevel _) -> True
      (PackDoc, NPack _) -> True
      _ -> False

takenIn :: Id -> IndexState -> Bool
takenIn i st = any ((== i) . idOf . snd) (rowsIn st)

-- | 指向這些 id 的關聯。跨 vault 的 'Ref' 只有在指名的正是本 vault 時才算——
-- 索引一次只認一個 vault,別的 vault 的同名 id 不是這裡的節點。
referrersIn :: [Id] -> IndexState -> [(Id, Link)]
referrersIn is st =
  [ (idOf n, l)
  | (_, n) <- rowsIn st
  , let m = anyMeta (inNode n)
  , l <- metaLinks m
  , refId (linkTarget l) `elem` is
  , maybe True (== metaVault m) (refVault (linkTarget l))
  ]
