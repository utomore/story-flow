-- | HTTP API 的型別與路由定義。
module AssetDB.Server.Api
  ( Api
  , api
  , SearchResponse (..)
  , SearchItem (..)
  , PackSummary (..)
  , Health (..)
  , PNG
  , ThumbResponse
  ) where

import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Network.HTTP.Media qualified as M
import Servant

--------------------------------------------------------------------------------
-- 回應型別

-- | 搜尋結果與**總數**。
--
-- 總數不是可有可無:虛擬化網格要先知道總高度才能畫出正確的捲動條,
-- 否則捲動時列高會一直跳。
data SearchResponse = SearchResponse
  { srTotal :: Int
  , srItems :: [SearchItem]
  }
  deriving stock (Eq, Show)

data SearchItem = SearchItem
  { siUlid :: Text
  , siName :: Maybe Text
  , siOriginal :: Text
  , siKind :: Text
  , siPack :: Maybe Text
  , siAuthor :: Maybe Text
  , siPath :: Text
  , siSha :: Maybe Text
  }
  deriving stock (Eq, Show)

data PackSummary = PackSummary
  { psSlug :: Text
  , psName :: Text
  , psVendor :: Maybe Text
  , psAuthor :: Maybe Text
  , psLicense :: Maybe Text
  , psStatus :: Text
  , psAi :: Text
  , psCount :: Int
  }
  deriving stock (Eq, Show)

data Health = Health
  { hAssets :: Int
  , hPacks :: Int
  , hNamed :: Int
  , hThumbs :: Int
  , hIndexStale :: Bool
  }
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- JSON
--
-- 全部手寫。這些欄位名是**前端的合約** —— 交給 Generic 的前綴剝除規則
-- 決定,會在有人重新命名 Haskell 欄位時無聲改掉 API。
-- AssetDB.Server.TsTypes 產生對應的 TypeScript 定義,兩者必須一起改,
-- 而 TsTypesSpec 會在它們不一致時失敗。

instance ToJSON SearchResponse where
  toJSON SearchResponse {..} = object ["total" .= srTotal, "items" .= srItems]

instance ToJSON SearchItem where
  toJSON SearchItem {..} =
    object
      [ "ulid" .= siUlid
      , "name" .= siName
      , "original" .= siOriginal
      , "kind" .= siKind
      , "pack" .= siPack
      , "author" .= siAuthor
      , "path" .= siPath
      , "sha" .= siSha
      ]

instance ToJSON PackSummary where
  toJSON PackSummary {..} =
    object
      [ "slug" .= psSlug
      , "name" .= psName
      , "vendor" .= psVendor
      , "author" .= psAuthor
      , "license" .= psLicense
      , "status" .= psStatus
      , "ai" .= psAi
      , "count" .= psCount
      ]

instance ToJSON Health where
  toJSON Health {..} =
    object
      [ "assets" .= hAssets
      , "packs" .= hPacks
      , "named" .= hNamed
      , "thumbs" .= hThumbs
      , "indexStale" .= hIndexStale
      ]

--------------------------------------------------------------------------------
-- PNG 內容型別

data PNG

instance Accept PNG where
  contentType _ = "image" M.// "png"

instance MimeRender PNG BS.ByteString where
  mimeRender _ = BL.fromStrict

--------------------------------------------------------------------------------
-- 路由

-- | 共用的查詢參數。**必須接受續體參數**而不是寫成前綴同義字 ——
-- @:>@ 是右結合的,而完全套用的同義字會強制成左結合,型別對不上。
type SearchParams a =
  QueryParam "q" Text
    :> QueryParams "kind" Text
    :> QueryParams "pack" Text
    :> QueryParams "vendor" Text
    :> QueryParams "author" Text
    :> QueryParams "category" Text
    :> QueryFlag "named"
    :> QueryFlag "reference"
    :> QueryFlag "excluded"
    :> a

-- | 縮圖回應。縮圖路徑是內容定址的,同一個 sha 永遠對應同一份位元組,
-- 所以回應帶著長效的 @Cache-Control@ —— 標頭寫在型別裡,漏掉就編譯不過。
type ThumbResponse = Headers '[Header "Cache-Control" Text] BS.ByteString

type Api =
  "api"
    :> ( "search" :> SearchParams (QueryParam "limit" Int :> QueryParam "offset" Int :> Get '[JSON] SearchResponse)
          :<|> "facets" :> SearchParams (Get '[JSON] Value)
          :<|> "packs" :> Get '[JSON] [PackSummary]
          :<|> "health" :> Get '[JSON] Health
       )
    :<|> "thumb" :> Capture "sha" Text :> Capture "size" Int :> Get '[PNG] ThumbResponse
    -- 前端的靜態檔案。放在最後,因為 Raw 會吃掉所有未匹配的路徑。
    :<|> Raw

api :: Proxy Api
api = Proxy
