{-# LANGUAGE DataKinds #-}

-- | P-029-scope-resolve 的觀察點:把純解譯器跑到底,以及三個參考實作。
--
-- 這些簽名__沒有 production 消費者__,只為 law 的觀察而匯出(rules\/boundary.md
-- 「測試與邊界」),所以住 @.Internal@:只有 "Aapms.Workspace.Resolve" 自己與測試
-- 准 import。
--
-- 三個參考實作__不呼叫 "Aapms.Workspace.Resolve"__:它們直接讀
-- 'Aapms.Workspace.Types.MarkerWorld' 與 'Aapms.Workspace.Types.Hub' 算答案。拿受測
-- 程式當參考就沒有參考可言,law 會恆真。
module Aapms.Workspace.Resolve.Internal
  ( -- * 純解譯器跑到底
    simulateScope

    -- * 參考實作
  , readableIds
  , reachable
  , nearestRoot
  ) where

import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, listToMaybe)
import qualified Data.Set as Set
import Effectful (Eff, runPureEff)
import System.FilePath (equalFilePath, takeDirectory, (</>))

import Aapms.Core.Id (VaultId)
import Aapms.Store.Types (VaultMarker (..))
import Aapms.Workspace.Effect.Markers (Markers, runMarkersPure)
import Aapms.Workspace.Types
  ( Hub
  , MarkerWorld (..)
  , VaultEntry (..)
  , hubVaults
  , worldDirs
  , worldMarker
  )

-- | 觀察:純解譯器跑到底。
--
-- 效果堆疊只有 'Markers' 一層,跑完就沒有效果了,所以拿得到裸的結果——里程碑
-- @=@ 列的 law 因此完全不碰 IO。
simulateScope :: MarkerWorld -> Eff '[Markers] a -> a
simulateScope w act = runPureEff (runMarkersPure w act)

-- | 觀察:中樞順序下 marker 讀得到且 id 相符的列。
--
-- 「讀得到且相符」= 路徑是既存目錄、那裡的 marker 讀數是 @Right@、marker 的 id
-- 與中樞那一列相同。與 'Aapms.Workspace.Resolve.refOfEntry' 的三種降級互為反面。
-- 中樞若有兩列同 id,只留第一次出現的位置(對應裁決那一側的保序去重)。
readableIds :: MarkerWorld -> Hub -> [VaultId]
readableIds w h = nubOrd [veId e | e <- hubVaults h, isJust (entryMarker w e)]

-- | 觀察:參考實作,自種子沿 @refs@ 的 BFS 可達集合(首次入隊序,種子第一,
-- 不可達的不展開)。
--
-- 種子__一律在結果裡__(它是給定的);其餘每個 @refs@ 目標拿中樞那一列去查
-- marker,查不到(未註冊)或不可達的都跳過__且不展開它的 @refs@__。visited 單調
-- 成長,所以對環安全。
--
-- 種子的 marker 先走中樞;種子不在中樞時(向上探測到的未註冊 vault,
-- 'Aapms.Workspace.Types.wsTarget' 允許這種)退而在世界裡找 id 相同的那份
-- marker——那是唯一還拿得到它 @refs@ 的地方。
reachable :: MarkerWorld -> Hub -> VaultId -> [VaultId]
reachable w h seed = seed : go (Set.singleton seed) (maybe [] vmRefs seedMarker)
  where
    seedMarker = case find ((== seed) . veId) (hubVaults h) of
      Just e -> entryMarker w e
      Nothing -> listToMaybe [m | Right m <- Map.elems (mwMarkers w), vmId m == seed]

    go _ [] = []
    go visited (t : rest)
      | Set.member t visited = go visited rest
      | otherwise = case find ((== t) . veId) (hubVaults h) >>= entryMarker w of
          Nothing -> go visited' rest
          Just m -> t : go visited' (rest ++ vmRefs m)
      where
        visited' = Set.insert t visited

-- | 觀察:參考實作,起點往上第一層有 @.aapms@ 目錄的。
--
-- 起點自己那一層也算命中;走到 'System.FilePath.takeDirectory' 的不動點都沒有
-- 就是 @Nothing@。路徑長度只減不增,所以一定終止。
nearestRoot :: MarkerWorld -> FilePath -> Maybe FilePath
nearestRoot w = climb
  where
    climb d
      | dirIn w (d </> ".aapms") = Just d
      | up == d = Nothing
      | otherwise = climb up
      where
        up = takeDirectory d

--------------------------------------------------------------------------------
-- 私有

-- | 私有:中樞一列的權威 marker,不可達(路徑不見 \/ 讀不到 \/ id 漂移)是
-- @Nothing@。
entryMarker :: MarkerWorld -> VaultEntry -> Maybe VaultMarker
entryMarker w e
  | not (dirIn w (vePath e)) = Nothing
  | otherwise = case worldMarker w (vePath e) of
      Just (Right m) | vmId m == veId e -> Just m
      _ -> Nothing

-- | 私有:路徑是不是世界裡的既存目錄(與純解譯器的 @DirExists@ 同一套比對)。
dirIn :: MarkerWorld -> FilePath -> Bool
dirIn w p = any (equalFilePath p) (worldDirs w)

-- | 私有:保序去重。
nubOrd :: Ord a => [a] -> [a]
nubOrd = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs
