-- | Asset —— 素材圖譜的一等節點(ADR-012)。
--
-- 對外身分是 'LogicalName'(命名文法,ADR-019),圖譜內部身分是共用 'Meta' 的
-- id。兩者職責不同:'astName' 可能因命名決策改動,id 從掃描進來那一刻起不變
-- (ADR-014)。
module Aapms.Core.Asset
  ( Sha256 (..)
  , LogicalName (..)
  , Asset (..)
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Aapms.Core.Id (Ref)
import Aapms.Core.Meta (Meta)

-- | 內容雜湊,ADR-013(pack.md 為真相)的內容定址依據。
newtype Sha256 = Sha256 Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | 命名文法(ADR-019)產生的邏輯名稱,如 @ui_gui_travel-book-frame_001@。
--
-- 建構文法由 registry-family-and-naming(#2)的 @mkLogicalName@ 守;本型別
-- 只是容器,建構子匯出(委派決策記錄:具名純量一律可直接建構)。
newtype LogicalName = LogicalName Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | 素材節點。'astMeta' 之外的專屬欄位只有真的素材專屬的那幾個(ADR-012)。
--
-- 'astKindMeta' 是 kind 專屬 JSON(image / audio / …),型別化讀取由
-- manifest-schema-v2(#3)的 @imageMeta@ \/ @audioMeta@ 提供;本 feature 只
-- 存原始 'Value',不開新表、不開新欄位。
data Asset = Asset
  { astMeta :: Meta
  , astName :: Maybe LogicalName
  , astSha256 :: Sha256
  , astEntry :: Text
  , astExt :: Maybe Text
  , astKindMeta :: Value
  , astLicense :: Maybe Ref
  , astAuthor :: Maybe Text
  , astBody :: Text
  }
  deriving stock (Show, Eq)
