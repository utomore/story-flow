-- | 伺服器實作。
module AssetDB.Server.App
  ( ServerConfig (..)
  , runServer
  , application
  , serverSettings
  , defaultHost
  , defaultSearchLimit
  , maxSearchLimit
  , isLoopbackHost
  , resolveServerDb
  , dbMissingMessage
  , startupBanner
  , countAssets
  , isThumbSha
  , thumbCacheControl
  ) where

import AssetDB.PathText (ThumbSize (..), thumbPath)
import AssetDB.Server.Api
import AssetDB.Store
import AssetDB.Store.Index (ftsStale)
import AssetDB.Store.Search
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isHexDigit)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple
import Network.Wai qualified
import Network.Wai.Application.Static (defaultWebAppSettings, ssIndices)
import Network.Wai.Handler.Warp qualified as Warp
import Servant
import System.Directory (doesFileExist, makeAbsolute)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import WaiAppStatic.Types (unsafeToPiece)

data ServerConfig = ServerConfig
  { scDbPath :: FilePath
  , scCacheRoot :: FilePath
  , scWebRoot :: FilePath
  , -- | 要綁定的網路介面。預設 'defaultHost' —— 這台機器很可能同時在
    -- 工作室區網上,而本服務**沒有任何身分驗證**,預設值就該是最小暴露面。
    scHost :: String
  , scPort :: Int
  , -- | 允許對不存在的路徑建立新資料庫。預設 False:「使用者打錯路徑」
    -- 遠比「這是第一次啟動」常見,而自動建檔會把打錯的路徑變成一個
    -- 查詢全回 0 筆的空庫,前端顯示成「素材庫是空的」。
    scInit :: Bool
  }
  deriving stock (Eq, Show)

-- | 預設只綁定回送介面。
--
-- Warp 的預設是 @*@(所有介面),對一個沒有驗證機制的服務來說,那等於
-- 「同網段的任何人都能翻整個素材庫」。要開放得是使用者明講的決定
-- (@--host@),不是我們替他選的預設值。
defaultHost :: String
defaultHost = "127.0.0.1"

-- | 這個位址是否只有本機連得到。決定啟動時要不要印警告。
isLoopbackHost :: String -> Bool
isLoopbackHost h = h `elem` ["127.0.0.1", "::1", "localhost"]

-- | @\/api\/search@ 未帶 limit 時的預設筆數。
--
-- 各入口的分頁預設刻意不同,不是漏改(enhance-0006):web 前端一頁抓
-- 120 筆(Grid.tsx 的 @PAGE@,它總是明帶 limit,用不到這個預設)、CLI
-- 預設 20(一個終端機畫面;Cli\/Options.hs)、store 層函式庫預設 50
-- (Store\/Search.hs 的 'AssetDB.Store.Search.emptyQuery')。60 取「不帶
-- 參數打 API 時一眼看得完、又夠填滿一個瀏覽器畫面」的量。
defaultSearchLimit :: Int
defaultSearchLimit = 60

-- | limit 的伺服器端上限。limit 是使用者可控的查詢字串,沒有上限的話
-- 一個 @limit=1000000@ 會讓伺服器把整個素材庫序列化成 JSON 送出去。
-- 500 約是前端四頁的量,正常操作到不了。
maxSearchLimit :: Int
maxSearchLimit = 500

-- | Warp 設定。抽成獨立函式是為了讓「預設綁在哪」可被測試 ——
-- 'runServer' 之後會阻塞在 Warp 上,測不動。
serverSettings :: ServerConfig -> Warp.Settings
serverSettings cfg =
  Warp.setHost (fromString (scHost cfg)) $
    Warp.setPort (scPort cfg) Warp.defaultSettings

runServer :: ServerConfig -> IO ()
runServer cfg =
  resolveServerDb cfg >>= \case
    Left err -> hPutStrLn stderr err >> exitFailure
    Right dbPath ->
      withStore dbPath $ \st -> do
        _ <- initSchema st
        n <- countAssets st
        putStrLn (startupBanner (scHost cfg) (scPort cfg) dbPath n)
        Warp.runSettings (serverSettings cfg) (application cfg st)

-- | 啟動前的資料庫路徑檢查,回傳絕對路徑或使用者看得懂的錯誤訊息。
--
-- 抽成獨立函式是為了讓「拒絕自動建檔」可被測試 —— 'runServer' 之後會阻塞
-- 在 Warp 上,測不動。
resolveServerDb :: ServerConfig -> IO (Either String FilePath)
resolveServerDb cfg = do
  abs' <- makeAbsolute (scDbPath cfg)
  exists <- doesFileExist abs'
  pure $
    if exists || scInit cfg
      then Right abs'
      else Left (dbMissingMessage abs')

dbMissingMessage :: FilePath -> String
dbMissingMessage p =
  unlines
    [ "找不到資料庫:" <> p
    , "伺服器不會自動建立新資料庫 —— 路徑打錯時建出來的空庫,查詢會全部回 0 筆,"
    , "看起來就像素材庫是空的。"
    , "請確認路徑是否正確,或加上 --init 明確要求建立一個新資料庫。"
    ]

-- | 啟動訊息帶上實際綁定的介面、連到的絕對路徑與筆數。「連到空資料庫」
-- 因此在啟動當下就看得見,不必等前端查詢回 0 筆才發現。
--
-- 綁定位址同樣印出來:@--host@ 開放區網是一個沒有回饋的動作,不印的話
-- 使用者不會知道自己剛把一個無驗證的服務放上區網。
startupBanner :: String -> Int -> FilePath -> Int -> String
startupBanner host port dbPath n =
  unlines $
    [ "assetdb-server  http://" <> host <> ":" <> show port
    , "資料庫:" <> dbPath
    , "assets:" <> show n <> " 筆"
    ]
      <> [ "⚠ 綁定 " <> host <> ":同網段的其他機器都連得到,而本服務沒有任何身分驗證。"
         | not (isLoopbackHost host)
         ]

countAssets :: Store -> IO Int
countAssets st = do
  rows <- query_ (storeConn st) "SELECT COUNT(*) FROM assets" :: IO [Only Int]
  pure (case rows of (Only n : _) -> n; _ -> 0)

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
        , sqLimit = maybe defaultSearchLimit (min maxSearchLimit) lim
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
    thumbH sha size
      -- sha 直接參與檔案路徑的組合。servant 的 Capture 會把 %2F 解碼回 '/',
      -- 所以「呼叫端只會傳合法 sha」是呼叫端的紀律,不是伺服器的保證 ——
      -- 外部輸入在用之前自己驗一次。
      | not (isThumbSha sha) = throwError (utf8Err err400 "sha 必須是 64 位十六進位字串")
      | otherwise = do
          -- 路徑規則與產生端(ingest)共用 core 的 thumbPath(enhance-0012),
          -- 規則分家的症狀是縮圖找不到卻不報錯。
          let p = thumbPath (scCacheRoot cfg) sha (if size >= 512 then Thumb512 else Thumb128)
          ok <- liftIO (doesFileExist p)
          if ok
            then addHeader thumbCacheControl <$> liftIO (BS.readFile p)
            else throwError (utf8Err err404 "找不到縮圖")

    staticH =
      serveDirectoryWith
        (defaultWebAppSettings (scWebRoot cfg))
          { ssIndices = [unsafeToPiece "index.html"]
          }

-- | 縮圖 sha 的合法形狀:剛好 64 位十六進位字元(對應 @blobs.sha256@)。
isThumbSha :: Text -> Bool
isThumbSha sha = T.length sha == 64 && T.all isHexDigit sha

-- | 縮圖的快取策略。內容定址代表同一個 URL 的位元組永遠不變,
-- 所以可以給到 @immutable@ —— 瀏覽器連 revalidation 都不必發。
thumbCacheControl :: Text
thumbCacheControl = "public, max-age=31536000, immutable"

-- | @errBody@ 是 lazy 'BL.ByteString'。用 'OverloadedStrings' 直接塞中文會
-- 逐字元截成低位元組,訊息變亂碼;明確走 UTF-8 編碼。
utf8Err :: ServerError -> Text -> ServerError
utf8Err e msg = e {errBody = BL.fromStrict (encodeUtf8 msg)}

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
