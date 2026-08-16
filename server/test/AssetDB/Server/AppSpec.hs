module AssetDB.Server.AppSpec (spec) where

import AssetDB.Server.App
import AssetDB.Store
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Database.SQLite.Simple (execute, execute_, lastInsertRowId)
import Network.HTTP.Types (ResponseHeaders, hCacheControl, statusCode)
import Network.Wai
  ( Application
  , defaultRequest
  , pathInfo
  , requestMethod
  , responseHeaders
  , responseStatus
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

-- | 最小的 WAI 驅動器:送一個 GET,取回狀態碼與標頭。
--
-- 只為了測 thumb 端點的狀態碼與 Cache-Control 而存在。@wai-extra@ 的
-- @Network.Wai.Test@ 做的是同一件事,但為了這十行拉進一整個套件不划算。
runGet :: Application -> [Text] -> IO (Int, ResponseHeaders)
runGet app segs = do
  ref <- newIORef Nothing
  _ <- app defaultRequest {pathInfo = segs, requestMethod = "GET"} $ \res -> do
    writeIORef ref (Just (statusCode (responseStatus res), responseHeaders res))
    pure ResponseReceived
  readIORef ref >>= maybe (fail "handler 沒有產生回應") pure

-- | 直接塞最小可用的 asset 列。這裡只在乎 COUNT,不走完整的 ingest 路徑。
insertAssets :: Store -> Int -> IO ()
insertAssets st n = do
  execute_ (storeConn st) "INSERT INTO roots (path, label, kind) VALUES ('/tmp/r', 'r', 'packs')"
  rootId <- lastInsertRowId (storeConn st)
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
