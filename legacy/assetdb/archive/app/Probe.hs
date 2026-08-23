-- | @assetdb-archive-probe@ —— 診斷工具。
--
-- 把壓縮檔存取層**實際看到什麼**原樣印出來。廠商壓縮檔的內部結構千奇百怪
-- (三層同名資料夾、檔名裡有 @&@ 與 @#@、中文路徑、RAR 的 solid 壓縮),
-- 出問題時需要一個能直接指著某個檔案問「你到底解析成什麼」的工具。
--
-- @
-- assetdb-archive-probe <壓縮檔> [項目路徑]
-- assetdb-archive-probe --tools
-- @
module Main (main) where

import AssetDB.Archive
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = do
  -- GHC 在 Windows 上預設以系統 ANSI 字碼頁寫 stdout。素材路徑與素材包名稱
  -- 大量含有中文,不設這個的話輸出全部是亂碼 —— 而且重導向到檔案時同樣壞掉,
  -- 所以不是「終端機顯示問題」,是真的寫錯位元組。
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8

  args <- getArgs
  tools <- discoverTools
  case args of
    ["--tools"] -> TIO.putStrLn (describeTools tools)
    [path] -> listOne tools path
    [path, entry] -> readOne tools path (T.pack entry)
    _ -> do
      TIO.putStrLn "用法:assetdb-archive-probe <壓縮檔> [項目路徑]"
      TIO.putStrLn "     assetdb-archive-probe --tools"
      exitFailure

listOne :: ArchiveTools -> FilePath -> IO ()
listOne tools path = do
  r <- listEntries tools path
  case r of
    Left err -> TIO.putStrLn ("✗ " <> renderArchiveError err) >> exitFailure
    Right es -> do
      TIO.putStrLn $
        T.pack path
          <> "\n  項目 "
          <> tshow (length es)
          <> ",未壓縮總計 "
          <> tshow (sum (map aeSize es) `div` 1024)
          <> " KiB"

      -- 副檔名分佈,判斷這包裡到底有什麼
      let exts = tally [T.toLower (ext (aePath e)) | e <- es]
      TIO.putStrLn "  副檔名:"
      mapM_ (\(k, n) -> TIO.putStrLn ("    " <> pad 12 k <> tshow n)) (take 12 exts)

      -- 前幾筆的完整資訊,看路徑分隔符與編碼有沒有問題
      TIO.putStrLn "  前 8 筆:"
      mapM_ (TIO.putStrLn . ("    " <>) . describe) (take 8 (sortOn aePath es))
  where
    describe e =
      pad 8 (tshow (aeSize e))
        <> pad 12 (maybe "-" hexish (aeCrc32 e))
        <> aePath e
    hexish = T.pack . show

readOne :: ArchiveTools -> FilePath -> Text -> IO ()
readOne tools path entry = do
  r <- readEntry tools path entry
  case r of
    Left err -> TIO.putStrLn ("✗ " <> renderArchiveError err) >> exitFailure
    Right bs -> do
      TIO.putStrLn (entry <> "\n  位元組 " <> tshow (BS.length bs))
      TIO.putStrLn ("  前 16 位元組 " <> tshow (BS.unpack (BS.take 16 bs)))

--------------------------------------------------------------------------------

ext :: Text -> Text
ext p = case T.breakOnEnd "." (last' (T.splitOn "/" p)) of
  (pre, suf) | not (T.null pre) -> "." <> suf
  _ -> "(無)"
  where
    last' xs = if null xs then "" else last xs

tally :: [Text] -> [(Text, Int)]
tally xs = sortOn (negate . snd) [(k, length g) | (k, g) <- groups]
  where
    groups = [(k, filter (== k) xs) | k <- uniq xs]
    uniq = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - T.length t)) " "

tshow :: Show a => a -> Text
tshow = T.pack . show
