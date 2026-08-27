-- | License —— 授權節點(ADR-012)。
--
-- 存好八個授權維度、查得到;授權閘門的判斷屬 @project@ 子系統,本模組只是
-- 存放與存取的容器。@licenses.md@ 的檔案層是容器不是節點,每節一個
-- 'License',由 aapms-md(#4)負責解析。
module Aapms.Core.License
  ( License (..)
  ) where

import Data.Text (Text)
import Aapms.Core.Meta (Meta)

data License = License
  { licMeta :: Meta
  , licCommercial :: Bool
  , licAttributionRequired :: Bool
  , licCreditText :: Maybe Text
  , licModificationAllowed :: Maybe Bool
  , licRedistributionAllowed :: Maybe Bool
  , licResaleAllowed :: Maybe Bool
  , licNftAllowed :: Maybe Bool
  , licSourceUrl :: Maybe Text
  , licFullText :: Maybe Text
  }
  deriving stock (Show, Eq)
