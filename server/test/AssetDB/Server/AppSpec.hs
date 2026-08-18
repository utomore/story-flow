module AssetDB.Server.AppSpec (spec) where

import AssetDB.Server.App
import AssetDB.Store
import Data.Aeson (Key, Value (..), decode)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple (execute, execute_, lastInsertRowId, withTransaction)
import Network.HTTP.Types (Query, ResponseHeaders, hCacheControl, renderQuery, statusCode)
import Network.Wai
  ( Application
  , defaultRequest
  , pathInfo
  , queryString
  , rawQueryString
  , requestMethod
  , responseToStream
  )
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (ResponseReceived (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (isAbsolute, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "resolveServerDb" $ do
    it "對不存在的路徑且未帶 --init 時失敗,而且不建檔" $
      withSystemTempDirectory "assetdb-server-test" $ \dir -> do
        let path = dir </> "missing.sqlite"
        r <- resolveServerDb (cfg path False)
        case r of
          Right p -> expectationFailure ("應該要失敗,卻回傳 " <> p)
          Left err -> do
            err `shouldSatisfy` ("找不到資料庫" `isInfixOf`)
            err `shouldSatisfy` ("--init" `isInfixOf`)
        -- 靜默建檔正是 bug-0002 的病灶,檢查是否真的沒動到磁碟
        doesFileExist path `shouldReturn` False

    it "帶 --init 時接受不存在的路徑,交由 withStore 建立新庫" $
      withSystemTempDirectory "assetdb-server-test" $ \dir -> do
        let path = dir </> "fresh.sqlite"
        r <- resolveServerDb (cfg path True)
        case r of
          Left err -> expectationFailure ("不該失敗:" <> err)
          Right p -> p `shouldSatisfy` isAbsolute
        withStore path $ \st -> initSchema st >>= \ms -> ms `shouldNotBe` []
        doesFileExist path `shouldReturn` True

    it "資料庫存在時回傳絕對路徑" $
      withSystemTempDirectory "assetdb-server-test" $ \dir -> do
        let path = dir </> "existing.sqlite"
        withStore path $ \st -> initSchema st >> pure ()
        r <- resolveServerDb (cfg path False)
        case r of
          Left err -> expectationFailure ("不該失敗:" <> err)
          Right p -> do
            p `shouldSatisfy` isAbsolute
            p `shouldSatisfy` ("existing.sqlite" `isInfixOf`)

  describe "countAssets" $
    it "回報 assets 表的實際筆數" $
      withSystemTempDirectory "assetdb-server-test" $ \dir ->
        withStore (dir </> "counted.sqlite") $ \st -> do
          _ <- initSchema st
          countAssets st `shouldReturn` 0
          insertAssets st 3
          countAssets st `shouldReturn` 3

  -- bug-0004:Warp 的預設 host 是 *(所有介面),而本服務沒有任何身分驗證。
  describe "serverSettings" $ do
    it "預設只綁定 127.0.0.1" $ do
      defaultHost `shouldBe` "127.0.0.1"
      Warp.getHost (serverSettings (cfg "db.sqlite" False)) `shouldBe` "127.0.0.1"

    it "明確指定 --host 0.0.0.0 時綁定所有介面" $
      Warp.getHost (serverSettings (cfg "db.sqlite" False) {scHost = "0.0.0.0"})
        `shouldBe` "0.0.0.0"

    it "port 一併寫進 Settings" $
      Warp.getPort (serverSettings (cfg "db.sqlite" False) {scPort = 9000}) `shouldBe` 9000

  describe "startupBanner" $ do
    it "包含 host、port、db 絕對路徑與 assets 筆數" $ do
      let banner = startupBanner "127.0.0.1" 8787 "C:/lib/.assetdb/assetdb.sqlite" 5721
      banner `shouldSatisfy` ("C:/lib/.assetdb/assetdb.sqlite" `isInfixOf`)
      banner `shouldSatisfy` ("5721" `isInfixOf`)
      banner `shouldSatisfy` ("8787" `isInfixOf`)
      banner `shouldSatisfy` ("127.0.0.1" `isInfixOf`)

    -- 開放區網是個沒有回饋的動作。不印警告,使用者不會知道自己剛把一個
    -- 無驗證的服務放上區網。
    it "綁定非回送介面時附上警告" $ do
      startupBanner "0.0.0.0" 8787 "db" 0 `shouldSatisfy` ("⚠" `isInfixOf`)
      startupBanner "127.0.0.1" 8787 "db" 0 `shouldNotSatisfy` ("⚠" `isInfixOf`)

  -- bug-0005
  describe "isThumbSha" $ do
    it "接受 64 位十六進位字串" $
      isThumbSha (T.replicate 64 "a") `shouldBe` True

    it "拒絕含路徑分隔符、長度不符或非十六進位的輸入" $ do
      isThumbSha "../../etc/passwd" `shouldBe` False
      isThumbSha (T.replicate 63 "a") `shouldBe` False
      isThumbSha (T.replicate 65 "a") `shouldBe` False
      isThumbSha (T.replicate 63 "a" <> "/") `shouldBe` False
      isThumbSha (T.replicate 63 "a" <> "z") `shouldBe` False
      isThumbSha "" `shouldBe` False

  describe "thumbH" $ do
    it "對含路徑分隔符的 sha 回 400" $
      withThumbApp $ \app _ -> do
        (st, _) <- runGet app ["thumb", "../../secret", "128"]
        st `shouldBe` 400

    it "對長度不符的 sha 回 400" $
      withThumbApp $ \app _ -> do
        (st, _) <- runGet app ["thumb", "abc", "128"]
        st `shouldBe` 400

    it "對合法 64 位 hex sha 正常回應" $
      withThumbApp $ \app sha -> do
        (st, _) <- runGet app ["thumb", sha, "128"]
        st `shouldBe` 200

    it "縮圖不存在時回 404,而不是 400" $
      withThumbApp $ \app _ -> do
        (st, _) <- runGet app ["thumb", T.replicate 64 "b", "128"]
        st `shouldBe` 404

    it "回應包含正確的 Cache-Control 標頭" $
      withThumbApp $ \app sha -> do
        (_, hdrs) <- runGet app ["thumb", sha, "128"]
        thumbCacheControl `shouldBe` "public, max-age=31536000, immutable"
        lookup hCacheControl hdrs `shouldBe` Just (encodeUtf8 thumbCacheControl)

  -- enhance-0013 T1。health 是最基本的存活檢查,而且它的欄位名是前端的合約
  -- (見 TsTypes.hs)—— 改掉任何一個欄位名,前端的健康列就變成空白。
  describe "GET /api/health" $ do
    it "回 200" $
      withApiApp 0 $ \app _ -> do
        (st, _, _) <- runGetFull app ["api", "health"] []
        st `shouldBe` 200

    it "回傳前端契約上的五個欄位,一個不多一個不少" $
      withApiApp 0 $ \app _ -> do
        (_, _, body) <- runGetFull app ["api", "health"] []
        case decode body of
          Just (Object o) ->
            KM.keys o `shouldMatchList` ["assets", "packs", "named", "thumbs", "indexStale"]
          other -> expectationFailure ("預期一個 JSON 物件,收到 " <> show other)

    it "各項計數反映資料庫的實際內容" $
      withApiApp 0 $ \app st -> do
        seedHealthFixture st
        (_, _, body) <- runGetFull app ["api", "health"] []
        field body "assets" `shouldBe` Just (Number 3)
        field body "packs" `shouldBe` Just (Number 1)
        -- 三筆裡有兩筆已指定邏輯名稱
        field body "named" `shouldBe` Just (Number 2)
        -- 四份內容有縮圖,第五份是 failed,不該算進去
        field body "thumbs" `shouldBe` Just (Number 4)

    it "有資料但沒建索引時回報索引過期" $
      withApiApp 0 $ \app st -> do
        seedHealthFixture st
        (_, _, body) <- runGetFull app ["api", "health"] []
        field body "indexStale" `shouldBe` Just (Bool True)

    it "空資料庫不算索引過期" $
      withApiApp 0 $ \app _ -> do
        (_, _, body) <- runGetFull app ["api", "health"] []
        field body "indexStale" `shouldBe` Just (Bool False)

  -- enhance-0013 T2。夾制是**伺服器端**的防線:limit 是使用者可控的查詢字串,
  -- 一個 limit=1000000 會讓伺服器把整個素材庫序列化成 JSON 送出去。
  --
  -- 60 / 500 已收斂為 App.hs 的具名常數(enhance-0006 T1)。下面的斷言
  -- 仍用字面值:鎖的是**對外行為**,常數改值時測試必須跟著紅,
  -- 而不是斷言跟著常數一起漂走。
  describe "GET /api/search 的分頁夾制" $ do
    it "具名常數與對外行為的字面值一致(enhance-0006 T1)" $ do
      defaultSearchLimit `shouldBe` 60
      maxSearchLimit `shouldBe` 500

    it "未指定 limit 時採預設值 60" $
      withApiApp 501 $ \app _ -> do
        (_, _, body) <- runGetFull app ["api", "search"] []
        itemCount body `shouldBe` 60

    it "limit 超過上限時夾制到 500,而不是照單全收" $
      withApiApp 501 $ \app _ -> do
        (_, _, body) <- runGetFull app ["api", "search"] [("limit", Just "9999")]
        itemCount body `shouldBe` 500

    it "上限以內的 limit 原樣採用" $
      withApiApp 501 $ \app _ -> do
        (_, _, body) <- runGetFull app ["api", "search"] [("limit", Just "7")]
        itemCount body `shouldBe` 7

    -- 這條鎖的是**端點的對外行為**,不是 mkQuery 裡的 max 0 ——
    -- SQLite 自己就把負的 OFFSET 當 0,所以拿掉那個夾制這條測試照樣會過。
    -- 留著是因為「負的 offset 回第一頁而不是 400 或例外」本身是個契約:
    -- 前端算 offset 時少減一次就會送出負值。
    it "負的 offset 回傳第一頁,而不是錯誤" $
      withApiApp 501 $ \app _ -> do
        (sa, _, a) <- runGetFull app ["api", "search"] [("limit", Just "3"), ("offset", Just "-5")]
        (_, _, b) <- runGetFull app ["api", "search"] [("limit", Just "3"), ("offset", Just "0")]
        sa `shouldBe` 200
        itemCount a `shouldBe` 3
        field a "items" `shouldBe` field b "items"

    it "total 回報符合條件的總數,不受 limit 影響" $
      withApiApp 501 $ \app _ -> do
        -- 虛擬化網格靠 total 算捲動條高度。夾制的是回傳筆數,不是總數 ——
        -- 兩者一起被夾制的話,捲動條會停在第 500 筆。
        (_, _, body) <- runGetFull app ["api", "search"] [("limit", Just "10")]
        field body "total" `shouldBe` Just (Number 501)
        itemCount body `shouldBe` 10

  describe "GET /api/facets 的夾制" $
    it "facets 不吃 limit/offset,帶了也不影響結果" $
      withApiApp 501 $ \app _ -> do
        -- facets 走的是同一個 mkQuery,但續體裡沒有 limit/offset,
        -- 所以永遠以 Nothing 呼叫 —— 計數必須涵蓋全部 501 筆而不是前 60 筆。
        (st, _, body) <- runGetFull app ["api", "facets"] [("limit", Just "10")]
        st `shouldBe` 200
        case field body "kinds" of
          Just (Array ks) -> length ks `shouldBe` 1
          other -> expectationFailure ("預期 kinds 是陣列,收到 " <> show other)

cfg :: FilePath -> Bool -> ServerConfig
cfg path doInit =
  ServerConfig
    { scDbPath = path
    , scCacheRoot = "cache"
    , scWebRoot = "web"
    , scHost = defaultHost
    , scPort = 8787
    , scInit = doInit
    }

-- | 起一個帶著一張真縮圖的 'application',並把那張圖的 sha 交給測試。
withThumbApp :: (Application -> Text -> IO a) -> IO a
withThumbApp k =
  withSystemTempDirectory "assetdb-thumb-test" $ \dir -> do
    let sha = T.replicate 64 "a"
        cacheRoot = dir </> "cache" </> "thumbs"
        shard = cacheRoot </> T.unpack (T.take 2 sha)
    createDirectoryIfMissing True shard
    BS.writeFile (shard </> T.unpack (sha <> "_128.png")) "\137PNG fake"
    withStore (dir </> "thumbs.sqlite") $ \st -> do
      _ <- initSchema st
      let c = (cfg (dir </> "thumbs.sqlite") False) {scCacheRoot = cacheRoot, scWebRoot = dir </> "web"}
      k (application c st) sha

-- | 起一個帶著 API 的 'application' 與它背後的 'Store',並先塞 @n@ 筆 asset。
--
-- 與 'withThumbApp' 分開是因為兩者關心的東西不同:那個要一張真的縮圖檔,
-- 這個要一個有內容的資料庫。
withApiApp :: Int -> (Application -> Store -> IO a) -> IO a
withApiApp n k =
  withSystemTempDirectory "assetdb-api-test" $ \dir ->
    withStore (dir </> "api.sqlite") $ \st -> do
      _ <- initSchema st
      insertAssets st n
      let c = (cfg (dir </> "api.sqlite") False) {scCacheRoot = dir </> "cache", scWebRoot = dir </> "web"}
      k (application c st) st

-- | 最小的 WAI 驅動器:送一個 GET,取回狀態碼與標頭。
--
-- 只為了測 thumb 端點的狀態碼與 Cache-Control 而存在。@wai-extra@ 的
-- @Network.Wai.Test@ 做的是同一件事,但為了這十行拉進一整個套件不划算。
runGet :: Application -> [Text] -> IO (Int, ResponseHeaders)
runGet app segs = do
  (st, hdrs, _) <- runGetFull app segs []
  pure (st, hdrs)

-- | 同上,但帶查詢字串而且**收得到回應主體** —— JSON 端點的斷言需要它。
runGetFull :: Application -> [Text] -> Query -> IO (Int, ResponseHeaders, BL.ByteString)
runGetFull app segs qs = do
  ref <- newIORef Nothing
  let req =
        defaultRequest
          { pathInfo = segs
          , requestMethod = "GET"
          , queryString = qs
          , rawQueryString = renderQuery True qs
          }
  _ <- app req $ \res -> do
    let (st, hdrs, withBody) = responseToStream res
    body <- withBody $ \stream -> do
      chunks <- newIORef mempty
      stream (\b -> modifyIORef' chunks (<> b)) (pure ())
      toLazyByteString <$> readIORef chunks
    writeIORef ref (Just (statusCode st, hdrs, body))
    pure ResponseReceived
  readIORef ref >>= maybe (fail "handler 沒有產生回應") pure

-- | 取出 JSON 物件的一個頂層欄位。回 'Nothing' 同時涵蓋「不是物件」與
-- 「沒有這個欄位」—— 兩種情況在斷言裡都是失敗,不必分開。
field :: BL.ByteString -> Key -> Maybe Value
field body k = case decode body of
  Just (Object o) -> KM.lookup k o
  _ -> Nothing

-- | 搜尋回應裡的 @items@ 長度。取不到時回 -1,讓斷言顯示出「根本沒解析成功」
-- 而不是安靜地變成 0(0 是一個合法的筆數)。
itemCount :: BL.ByteString -> Int
itemCount body = case field body "items" of
  Just (Array xs) -> length xs
  _ -> -1

-- | health 的四個計數各自有不同來源,所以固定資料刻意讓它們**兩兩不相等**
-- (assets 3 / packs 1 / named 2 / thumbs 4)—— 數字撞在一起的話,handler
-- 把兩個查詢接錯線也測不出來。
seedHealthFixture :: Store -> IO ()
seedHealthFixture st = do
  let conn = storeConn st
  execute_ conn "INSERT INTO roots (id, path, label, kind) VALUES (1, '/tmp/r', 'r', 'packs')"
  execute_
    conn
    "INSERT INTO packs (id, ulid, slug, name, root_id, rel_dir, created_at, updated_at) \
    \VALUES (1, '01PACK', 'demo', 'Demo', 1, 'vendor/demo', 't', 't')"
  execute_
    conn
    "INSERT INTO blobs (sha256, bytes, kind, thumb_status, first_seen) VALUES \
    \  ('aa', 1, 'image', 'ok', 't'), \
    \  ('bb', 1, 'image', 'ok', 't'), \
    \  ('cc', 1, 'image', 'ok', 't'), \
    \  ('dd', 1, 'image', 'ok', 't'), \
    \  ('ee', 1, 'image', 'failed', 't')"
  execute_
    conn
    "INSERT INTO assets (ulid, kind, root_id, rel_path, original_name, logical_name, created_at, updated_at) VALUES \
    \  ('01A', 'image', 1, 'a.png', 'a.png', 'spr_gui_frame', 't', 't'), \
    \  ('01B', 'image', 1, 'b.png', 'b.png', 'spr_gui_panel', 't', 't'), \
    \  ('01C', 'image', 1, 'c.png', 'c.png', NULL, 't', 't')"

-- | 直接塞最小可用的 asset 列。這裡只在乎 COUNT 與筆數,不走完整的 ingest 路徑。
--
-- @n <= 0@ 時**什麼都不做**,連 roots 都不建 —— 呼叫端可能接著自己塞一組
-- 指定 id 的固定資料('seedHealthFixture'),先佔掉 rowid 1 會讓它撞主鍵。
insertAssets :: Store -> Int -> IO ()
insertAssets st n
  | n <= 0 = pure ()
  | otherwise = do
      execute_ (storeConn st) "INSERT INTO roots (path, label, kind) VALUES ('/tmp/r', 'r', 'packs')"
      rootId <- lastInsertRowId (storeConn st)
      -- 分頁夾制的測試需要五百多筆。逐筆 autocommit 會是五百次 fsync;
      -- 包成一個交易之後整組插入是毫秒等級。
      withTransaction (storeConn st) $
        mapM_
          ( \i ->
              execute
                (storeConn st)
                "INSERT INTO assets \
                \  (ulid, kind, root_id, rel_path, original_name, created_at, updated_at) \
                \VALUES (?, 'image', ?, ?, ?, '2026-08-16T00:00:00Z', '2026-08-16T00:00:00Z')"
                ( "01TEST" <> show i :: String
                , rootId
                , "a" <> show i <> ".png" :: String
                , "a" <> show i <> ".png" :: String
                )
          )
          [1 .. n]
