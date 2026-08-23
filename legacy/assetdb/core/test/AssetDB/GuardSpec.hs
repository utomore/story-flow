module AssetDB.GuardSpec (spec) where

import AssetDB.Guard (guardedTry)
import Control.Exception (AsyncException (..), ErrorCall (..), throwIO, try)
import Control.Monad (filterM, forM)
import Data.IORef
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum)
import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeFileName, (</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "guardedTry" $ do
    it "接得住一般例外" $ do
      r <- guardedTry (throwIO (ErrorCall "壞了") :: IO ())
      case r of
        Left _ -> pure ()
        Right () -> expectationFailure "一般例外應該被接住"

    it "成功時回 Right" $ do
      r <- guardedTry (pure (42 :: Int))
      either (const (-1)) id r `shouldBe` 42

    it "AsyncException 穿透" $ do
      -- 這條是整個模組存在的理由。裸的 try @SomeException 會把 Ctrl-C
      -- 記成「這一項失敗」,迴圈繼續跑下一項 —— 按幾次都停不下來。
      outer <-
        try (guardedTry (throwIO UserInterrupt :: IO ()) >> pure ()) ::
          IO (Either AsyncException ())
      case outer of
        Left UserInterrupt -> pure ()
        Left other -> expectationFailure ("拋出的不是 UserInterrupt:" <> show other)
        Right () -> expectationFailure "AsyncException 必須重新拋出,不能被接住"

    it "穿透時迴圈真的停得下來" $ do
      -- 上一條測的是型別層面的穿透,這條測的是實際後果:
      -- 中斷之後不會再有第二項被處理。
      seen <- newIORef (0 :: Int)
      let step i = do
            modifyIORef' seen (+ 1)
            if i == (2 :: Int) then throwIO UserInterrupt else pure ()
      _ <- try (mapM_ (guardedTry . step) [1 .. 5]) :: IO (Either AsyncException ())
      readIORef seen `shouldReturn` 2

  describe "結構指標:裸的 try @SomeException" $
    it "library 原始碼裡一個都不剩" $ do
      -- 指標 1 的回歸。下一次有人加回一個裸 try,這條就會紅 ——
      -- 不必再重新數一遍整個 repo(G-E003)。
      root <- repoRoot
      srcs <- concat <$> mapM (\p -> haskellFiles (root </> p </> "src")) packageDirs
      offenders <- forM srcs $ \f -> do
        body <- decodeUtf8Lenient <$> BS.readFile f
        pure (f, [l | l <- T.lines body, isNakedTry l])
      [f | (f, ls) <- offenders, not (null ls)] `shouldBe` []

-- | 「裸的 try」= 呼叫 @Control.Exception.try@ 而**沒有**明確指定一個具體的
-- 例外型別。
--
-- @try \@HttpException@ 這種寫法不算:它只接住自己認得的那一類,Ctrl-C 照樣
-- 穿過去。真正危險的是沒寫型別(推導成 @SomeException@)或明寫
-- @try \@SomeException@ 的版本 —— 那會把使用者的中斷記成「這一項失敗」。
--
-- 所以這條檢查同時是一個**寫法約定**:要用 @try@ 就得把型別寫出來,
-- 否則改用 'AssetDB.Guard.guardedTry'。全系統唯一合法的裸 @try@ 在
-- 'AssetDB.Guard' 裡,那個檔案由 'haskellFiles' 排除。
isNakedTry :: Text -> Bool
isNakedTry l = not (skip l) && go l > (0 :: Int)
  where
    -- 註解與 import 行不算 —— 它們提到 @try@ 不代表呼叫了它。
    skip s = T.isPrefixOf "--" (T.stripStart s) || T.isPrefixOf "import " s

    go t =
      let (lhs, rest) = T.breakOn "try" t
       in if T.null rest
            then 0
            else
              let rhs = T.drop 3 rest
                  boundedLeft = maybe True (not . identChar) (lastOf lhs)
                  boundedRight = maybe True (not . identChar) (firstOf rhs)
                  typed = case T.stripPrefix "@" (T.stripStart rhs) of
                    Just ty -> T.takeWhile identChar ty `notElem` ["", "SomeException"]
                    Nothing -> False
               in (if boundedLeft && boundedRight && not typed then 1 else 0) + go rhs

    identChar c = isAlphaNum c || c == '_' || c == '\''
    lastOf t = if T.null t then Nothing else Just (T.last t)
    firstOf t = if T.null t then Nothing else Just (T.head t)

packageDirs :: [FilePath]
packageDirs = ["core", "store", "archive", "ingest", "reorg", "project", "ai", "server", "cli"]

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles dir = do
  ok <- doesDirectoryExist dir
  if not ok
    then pure []
    else do
      names <- listDirectory dir
      paths <- forM names $ \n -> do
        let p = dir </> n
        isDir <- doesDirectoryExist p
        if isDir
          then haskellFiles p
          else pure [p | ".hs" `isSuffixOf` p, takeFileName p /= "Guard.hs"]
      pure (concat paths)

-- | 測試的工作目錄是套件目錄(@core\/@),但檢查的對象是整個 repo。
-- 往上走到九個套件目錄與 @.design\/@ 同時看得見的那一層。
repoRoot :: IO FilePath
repoRoot = go (16 :: Int) "."
  where
    go :: Int -> FilePath -> IO FilePath
    go 0 p = pure p
    go n p = do
      here <- doesDirectoryExist (p </> ".design")
      pkgs <- filterM (doesDirectoryExist . (p </>)) packageDirs
      if here && length pkgs == length packageDirs
        then pure p
        else go (n - 1) (p </> "..")
