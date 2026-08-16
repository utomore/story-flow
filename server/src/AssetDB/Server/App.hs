-- | 伺服器實作。
module AssetDB.Server.App
  ( ServerConfig (..)
  , runServer
  , application
  ) where

import AssetDB.Server.Api
import AssetDB.Store
import AssetDB.Store.Index (ftsStale)
import AssetDB.Store.Search
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Database.SQLite.Simple
import Network.Wai qualified
import Network.Wai.Application.Static (defaultWebAppSettings, ssIndices)
import Network.Wai.Handler.Warp qualified as Warp
import Servant
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import WaiAppStatic.Types (unsafeToPiece)

data ServerConfig = ServerConfig
  { scDbPath :: FilePath
  , scCacheRoot :: FilePath
  , scWebRoot :: FilePath
  , scPort :: Int
  }

runServer :: ServerConfig -> IO ()
runServer cfg =
  withStore (scDbPath cfg) $ \st -> do
    _ <- initSchema st
    putStrLn ("assetdb-server  http://localhost:" <> show (scPort cfg))
    Warp.run (scPort cfg) (application cfg st)

application :: ServerConfig -> Store -> Network.Wai.Application
application cfg st = serve api (handlers cfg st)

handlers :: ServerConfig -> Store -> Server Api
handlers cfg st =
  ( searchH :<|> facetsH :<|> packsH :<|> healthH
  )
    :<|> thumbH
    :<|> staticH
  where
    conn = storeConn st

    mkQuery q kinds packs vendors authors cats named ref excluded lim off =
      emptyQuery
        { sqText = q
        , sqKinds = kinds
        , sqPacks = packs
        , sqVendors = vendors
        , sqAuthors = authors
        , sqCategories = cats
        , sqNamedOnly = named
        , sqIncludeReference = ref
        , sqIncludeExcluded = excluded
        , sqLimit = maybe 60 (min 500) lim
        , sqOffset = maybe 0 (max 0) off
        }

    searchH q k p v a c named ref exc lim off = liftIO $ do
      let sq = mkQuery q k p v a c named ref exc lim off
      total <- searchCount conn sq
      hits <- search conn sq
      pure (SearchResponse total (map toItem hits))

    facetsH q k p v a c named ref exc = liftIO $ do
      fc <- facetCounts conn (mkQuery q k p v a c named ref exc Nothing Nothing)
      pure $
        object
          [ "kinds" .= pairs (fcKinds fc)
          , "vendors" .= pairs (fcVendors fc)
          , "authors" .= pairs (fcAuthors fc)
          , "packs" .= pairs (fcPacks fc)
          , "categories" .= pairs (fcCategories fc)
          ]

    pairs xs = [object ["value" .= v, "count" .= n] | (v, n) <- xs]

    packsH = liftIO $ do
      rows <-
        query_
          conn
          "SELECT p.slug, p.name, p.vendor, a.name, l.name, p.status, p.ai_disclosure, \
          \       (SELECT COUNT(*) FROM assets x WHERE x.pack_id = p.id) \
          \FROM packs p \
          \LEFT JOIN authors a ON a.id = p.author_id \
          \LEFT JOIN licenses l ON l.id = p.license_id \
          \ORDER BY p.name"
      pure [PackSummary s n vd au li stt ai c | (s, n, vd, au, li, stt, ai, c) <- rows]

    healthH = liftIO $ do
      let scalar q' = do
            r <- query_ conn q' :: IO [Only Int]
            pure (case r of (Only x : _) -> x; _ -> 0)
      Health
        <$> scalar "SELECT COUNT(*) FROM assets"
        <*> scalar "SELECT COUNT(*) FROM packs"
        <*> scalar "SELECT COUNT(*) FROM assets WHERE logical_name IS NOT NULL"
        <*> scalar "SELECT COUNT(*) FROM blobs WHERE thumb_status='ok'"
        <*> ftsStale conn

    -- 縮圖以內容雜湊定址,所以可以無限期快取。
    thumbH sha size = do
      let s = if size >= 512 then "512" else "128"
          p = scCacheRoot cfg </> T.unpack (T.take 2 sha) </> T.unpack (sha <> "_" <> s <> ".png")
      ok <- liftIO (doesFileExist p)
      if ok
        then liftIO (BS.readFile p)
        else throwError err404 {errBody = "no thumbnail"}

    staticH =
      serveDirectoryWith
        (defaultWebAppSettings (scWebRoot cfg))
          { ssIndices = [unsafeToPiece "index.html"]
          }

toItem :: SearchHit -> SearchItem
toItem SearchHit {..} =
  SearchItem
    { siUlid = hitUlid
    , siName = hitLogical
    , siOriginal = hitOriginal
    , siKind = hitKind
    , siPack = hitPack
    , siAuthor = hitAuthor
    , siPath = hitPath
    , siSha = hitSha
    }
