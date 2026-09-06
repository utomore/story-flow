{-# LANGUAGE DataKinds #-}

-- | P-001-index-rebuild 的觀察點:兩個純解譯器串起來跑到底。
--
-- 只有 law 用得到它,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
module Aapms.Store.Indexing.Internal
  ( simulate
  , clashesEarlier
  ) where

import Data.Either (isRight)
import qualified Data.Map.Strict as Map
import Effectful (Eff, runPureEff)

import Aapms.Core.Asset (Asset (..), LogicalName)
import Aapms.Core.AnyNode (AnyNode (..))
import Aapms.Store.Effect.Index (Index)
import Aapms.Store.Effect.VaultFs (VaultFs, runVaultFsPure)
import Aapms.Core.Id (VaultId)
import Aapms.Core.Registry (TypeRegistry)
import Aapms.Store.Indexing (indexDocument)
import Aapms.Store.Simulate (runIndexPure)
import Aapms.Store.Types
  ( FileIndex (..)
  , IndexState
  , IndexedNode (..)
  , VaultFiles
  , fileAt
  , vaultPaths
  )

-- | 觀察:'Aapms.Store.Effect.VaultFs.runVaultFsPure' 與
-- 'Aapms.Store.Simulate.runIndexPure' 串起來跑到底,回結果與最終索引。
simulate :: VaultFiles -> IndexState -> Eff '[VaultFs, Index] a -> (a, IndexState)
simulate vf ix act = runPureEff (runIndexPure ix (runVaultFsPure vf act))

-- | 觀察:這個檔某個已命名 asset 的邏輯名稱,已被路徑字母序更前、純核心成功的
-- 檔用掉——撞名回滾的判準(P-001-index-rebuild REV-1)。
--
-- 判準寫成「__從空索引依路徑遞增走一遍之後,這個檔有沒有留在索引裡__」,而不是
-- 「有沒有更前的檔提到同一個名字」:
--
-- * 更前的那個檔自己也可能因為撞名整檔回滾,它沒佔住的名字不算被用掉;
-- * 同一份檔裡兩個 asset 用同一個名字,一樣是整檔回滾(否則
--   'Aapms.Store.Types.assetNames' 會出現重複,違反 LAW-8)。
--
-- 兩點都是「先到者保留名字 + 整檔進退」這條決定的直接後果,所以判準與
-- 'Aapms.Store.Indexing.rebuild' 的行為逐字一致(LAW-6)。純核心本身就失敗的檔
-- 回 'False' ——它沒有名字可以被誰搶走。
clashesEarlier :: TypeRegistry -> VaultId -> VaultFiles -> FilePath -> Bool
clashesEarlier reg vid vf p = case Map.lookup p vf of
  Nothing -> False
  Just (st, txt) ->
    isRight (indexDocument reg vid p st txt) && p `notElem` accepted reg vid vf

-- | 從空索引依路徑遞增重建之後,留在索引裡的路徑。
accepted :: TypeRegistry -> VaultId -> VaultFiles -> [FilePath]
accepted reg vid vf = go [] (vaultPaths vf)
  where
    go _ [] = []
    go taken (q : rest) =
      let (st, txt) = fileAt vf q
       in case indexDocument reg vid q st txt of
            Left _ -> go taken rest
            Right (fi, _) ->
              let ns = namesOf fi
               in if clashes taken ns
                    then go taken rest
                    else q : go (taken ++ ns) rest

-- | 這些名字與已經被佔走的名字重複,或它們自己就有重複。
clashes :: [LogicalName] -> [LogicalName] -> Bool
clashes taken = go taken
  where
    go _ [] = False
    go seen (nm : rest) = nm `elem` seen || go (nm : seen) rest

namesOf :: FileIndex -> [LogicalName]
namesOf fi = [nm | IndexedNode (NAsset a) _ <- fiNodes fi, nm <- maybe [] pure (astName a)]
