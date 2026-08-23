-- | Pack —— 素材包,與故事側「檔案層主體」對稱的節點(ADR-012)。
--
-- pack.md 的檔案層 frontmatter 就是一個 @type: asset-pack@ 的節點:
-- @characters/琳達.md@ 的主體是 character、節是 character-fragment;
-- @packs/kenney/ui-pack/pack.md@ 的主體是 asset-pack、節是 asset-image。
module Aapms.Core.Pack
  ( AiDisclosure (..)
  , Author (..)
  , Pack (..)
  ) where

import Data.Text (Text)
import Aapms.Core.Asset (Sha256)
import Aapms.Core.Id (Ref)
import Aapms.Core.Meta (Meta)

-- | AI 揭露(沿用 assetdb)。文字表示 unknown \/ none \/ assisted \/ generated;
-- 缺漏視為 'AiUnknown'。
data AiDisclosure
  = AiUnknown
  | AiNone
  | AiAssisted
  | AiGenerated
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | 素材包的作者資訊。獨立於 'Meta' 之外,因為它不是節點,是 'Pack' 的一個欄位。
data Author = Author
  { authorName :: Text
  , authorUrl :: Maybe Text
  , authorContact :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | @pckArchive = Nothing@ 表示散檔目錄(@studio/@、@reference/\<topic\>/@),
-- 此時各 asset 的 @astEntry@ 是相對該目錄的路徑。
data Pack = Pack
  { pckMeta :: Meta
  , pckVendor :: Maybe Text
  , pckArchive :: Maybe FilePath
  , pckSha256 :: Maybe Sha256
  , pckLicense :: Maybe Ref
  , pckAuthor :: Maybe Author
  , pckSourceUrl :: Maybe Text
  , pckAiDisclosure :: AiDisclosure
  , pckBody :: Text
  }
  deriving stock (Show, Eq)
