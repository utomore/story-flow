-- | P-027-fts-tokenize 的內部觀察點:只為 law 觀察而匯出,沒有 production 消費者
-- (boundary.md「測試與邊界」:住 @*.Internal@,只准 "Aapms.Store.Tokenize" 自己與測試 import)。
module Aapms.Store.Tokenize.Internal
  ( stripText
  , upperAscii
  , wordHits
  , runHits
  ) where

import Data.Text (Text)

import Aapms.Core.AnyNode (AnyNode)

-- | 去頭尾空白,路由與運算式的判斷對象。
stripText :: Text -> Text
stripText = error "P-027#stripText stub"

-- | ASCII 大寫化,寫出「不分大小寫」用;非 ASCII 字元原樣。
upperAscii :: Text -> Text
upperAscii = error "P-027#upperAscii stub"

-- | 一個詞在 trigram 路由下打不打得中這個節點。
wordHits :: Text -> AnyNode -> Bool
wordHits = error "P-027#wordHits stub"

-- | 一段中日韓在 cjk 路由下打不打得中這個節點。
runHits :: Text -> AnyNode -> Bool
runHits = error "P-027#runHits stub"
