-- | 前端型別定義的產生器。
--
-- == 為什麼不用 servant-openapi3 → openapi-typescript
--
-- 那條路徑要拖進 OpenAPI 的整套型別機器,再加一個 Node 工具鏈步驟,
-- 只為了描述四個端點與四個物件。這裡的 API 面積小到「產生器 + 一致性測試」
-- 更划算,而且沒有額外相依。
--
-- == 防漂移的機制
--
-- 這個模組的輸出與 "AssetDB.Server.Api" 的 @ToJSON@ instance 必須一致。
-- 保證方式不是靠紀律,而是 @TsTypesSpec@:它把每個型別的 JSON 實際欄位名
-- 抽出來,與這裡宣告的欄位比對。改了一邊沒改另一邊,測試就紅。
module AssetDB.Server.TsTypes
  ( tsDefinitions
  , tsFieldsOf
  , TsType (..)
  , TsField (..)
  ) where

import Data.Text (Text)
import Data.Text qualified as T

data TsField = TsField {tfName :: Text, tfType :: Text}
  deriving stock (Eq, Show)

data TsType = TsType {ttName :: Text, ttFields :: [TsField]}
  deriving stock (Eq, Show)

tsFieldsOf :: Text -> [Text]
tsFieldsOf name =
  concat [map tfName (ttFields t) | t <- types, ttName t == name]

types :: [TsType]
types =
  [ TsType
      "SearchItem"
      [ TsField "ulid" "string"
      , TsField "name" "string | null"
      , TsField "original" "string"
      , TsField "kind" "string"
      , TsField "pack" "string | null"
      , TsField "author" "string | null"
      , TsField "path" "string"
      , TsField "sha" "string | null"
      ]
  , TsType
      "SearchResponse"
      [ TsField "total" "number"
      , TsField "items" "SearchItem[]"
      ]
  , TsType
      "FacetValue"
      [ TsField "value" "string"
      , TsField "count" "number"
      ]
  , TsType
      "Facets"
      [ TsField "kinds" "FacetValue[]"
      , TsField "vendors" "FacetValue[]"
      , TsField "authors" "FacetValue[]"
      , TsField "packs" "FacetValue[]"
      ]
  , TsType
      "PackSummary"
      [ TsField "slug" "string"
      , TsField "name" "string"
      , TsField "vendor" "string | null"
      , TsField "author" "string | null"
      , TsField "license" "string | null"
      , TsField "status" "string"
      , TsField "ai" "string"
      , TsField "count" "number"
      ]
  , TsType
      "Health"
      [ TsField "assets" "number"
      , TsField "packs" "number"
      , TsField "named" "number"
      , TsField "thumbs" "number"
      , TsField "indexStale" "boolean"
      ]
  ]

tsDefinitions :: Text
tsDefinitions =
  T.unlines $
    [ "// 由 assetdb-server 產生,請勿手動編輯。"
    , "// 重新產生:cabal run assetdb-server -- --emit-types web/src/api/types.ts"
    , ""
    ]
      <> concatMap render types

render :: TsType -> [Text]
render TsType {..} =
  ["export interface " <> ttName <> " {"]
    <> [ "  " <> tfName f <> ": " <> tfType f <> ";"
       | f <- ttFields
       ]
    <> ["}", ""]
