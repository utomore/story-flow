-- | 關聯圖的遍歷與推論。衝突偵測第 1 層(P4)的純函式基礎。
--
-- 關聯圖沒有樹那樣的無環保證(@derivedFrom@ 完全可能被寫成環),因此每個
-- 走訪函式都同時有__深度上限__與__已訪集合__兩道保險。
module StoryFlow.Core.Graph
  ( LinkGraph
  , buildGraph
  , follow
  , supersededSet
  , contradictionPairs
  ) where

import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Set (Set)
import qualified Data.Set as S
import StoryFlow.Core.Id (Id, Ref (..), localRef)
import StoryFlow.Core.Link (Link (..), LinkKind (Contradicts, Supersedes))
import StoryFlow.Core.Meta (Meta (..))

-- | 來源端持有,與儲存格式一致(關聯只存在來源端)。
type LinkGraph = M.Map Id [Link]

buildGraph :: [Meta] -> LinkGraph
buildGraph ms = M.fromListWith (flip (++)) [(metaId m, metaLinks m) | m <- ms]

-- | 順著指定的關聯種類走,最多 @depth@ 層,回傳可達集合(不含起點)。
--
-- 只有本 Vault 的參照能繼續往下走——跨 Vault 的 target 會被收進結果,
-- 但它的關聯不在這張圖裡,無從展開。
follow :: [LinkKind] -> Int -> Id -> LinkGraph -> Set Ref
follow kinds depth start g =
  S.delete (localRef start) (loop 0 (S.singleton start) [start] S.empty)
  where
    loop d visited frontier acc
      | d >= depth || null frontier = acc
      | otherwise =
          let targets =
                [ linkTarget l
                | i <- frontier
                , l <- M.findWithDefault [] i g
                , linkKind l `elem` kinds
                ]
              acc' = foldr S.insert acc targets
              next =
                nub
                  [ refId r
                  | r <- targets
                  , isNothing (refVault r)
                  , not (S.member (refId r) visited)
                  ]
           in loop (d + 1) (foldr S.insert visited next) next acc'

-- | 被 @supersedes@ 指到的一律視為過時,遞移閉包。
--
-- ADR-0005:B 被 A 取代後不再當比對基準;而 B 又取代了 C 時,C 當然也過時。
supersededSet :: LinkGraph -> Set Ref
supersededSet g = go (S.fromList seeds) seeds
  where
    seeds =
      [ linkTarget l
      | ls <- M.elems g
      , l <- ls
      , linkKind l == Supersedes
      ]

    go acc [] = acc
    go acc (r : rest)
      | isNothing (refVault r)
      , let more =
              [ linkTarget l
              | l <- M.findWithDefault [] (refId r) g
              , linkKind l == Supersedes
              , not (S.member (linkTarget l) acc)
              ] =
          go (foldr S.insert acc more) (more ++ rest)
      | otherwise = go acc rest

-- | 所有已知矛盾對。
--
-- @contradicts@ 語意對稱,但儲存只在來源端,因此輸出正規化為
-- (較小 id, 較大 id) 以免同一對出現兩次。跨 Vault 的 target 無法比較先後,
-- 保持原方向。
contradictionPairs :: LinkGraph -> [(Id, Ref)]
contradictionPairs g =
  sort . nub $
    [ normalize src (linkTarget l)
    | (src, ls) <- M.toList g
    , l <- ls
    , linkKind l == Contradicts
    ]
  where
    normalize src tgt
      | isNothing (refVault tgt)
      , refId tgt < src =
          (refId tgt, localRef src)
      | otherwise = (src, tgt)
