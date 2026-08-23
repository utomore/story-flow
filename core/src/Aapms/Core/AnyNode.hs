-- | 任一節點的統一視角(ADR-012)。
--
-- @service@ 與 @store@ 對「不知道是哪種節點」的情境用它——例如 @lookupNode@
-- 回傳的東西可能是六種節點中的任何一種。
module Aapms.Core.AnyNode
  ( AnyNode (..)
  , anyMeta
  , prefixOf
  ) where

import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (IdPrefix (..))
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta)
import Aapms.Core.Pack (Pack (..))

data AnyNode
  = NEntity Entity
  | NAsset Asset
  | NPack Pack
  | NLicense License
  | NLevel Level
  | NNode Node
  deriving stock (Show, Eq)

anyMeta :: AnyNode -> Meta
anyMeta = \case
  NEntity e -> entMeta e
  NAsset a -> astMeta a
  NPack p -> pckMeta p
  NLicense l -> licMeta l
  NLevel lvl -> lvlMeta lvl
  NNode n -> nodMeta n

-- | 對應的 'IdPrefix'。與 'anyMeta' 分開提供而不是靠 @idPrefix . metaId . anyMeta@
-- 反推:節點種類是型別上就知道的事實,不必繞去解析 id 字串。
prefixOf :: AnyNode -> IdPrefix
prefixOf = \case
  NEntity _ -> PEnt
  NAsset _ -> PAst
  NPack _ -> PPck
  NLicense _ -> PLic
  NLevel _ -> PLvl
  NNode _ -> PNod
