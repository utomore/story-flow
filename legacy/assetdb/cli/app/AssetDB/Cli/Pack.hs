module AssetDB.Cli.Pack (runPackList, runPackApply) where

import AssetDB.Ingest.Catalogue
import AssetDB.Store
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Text.IO qualified as TIO
import Database.SQLite.Simple
import System.Exit (exitFailure)

runPackList :: FilePath -> IO ()
runPackList dbPath =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    rows <-
      query_
        (storeConn st)
        "SELECT p.status, p.name, COALESCE(a.name,'—'), COALESCE(l.name,'—'), p.ai_disclosure, \
        \  (SELECT COUNT(*) FROM assets x WHERE x.pack_id = p.id) \
        \FROM packs p \
        \LEFT JOIN authors a ON a.id = p.author_id \
        \LEFT JOIN licenses l ON l.id = p.license_id \
        \ORDER BY p.status DESC, p.name" ::
        IO [(Text, Text, Text, Text, Text, Int)]
    mapM_ render rows
    let draft = length [() | (s, _, _, _, _, _) <- rows, s == "draft"]
    TIO.putStrLn ""
    TIO.putStrLn
      ( tshow (length rows) <> " 個素材包,"
          <> (if draft == 0 then "全部可用於建專案。" else tshow draft <> " 個是 draft(缺授權或作者)。")
      )
  where
    render (status, name, author, license, ai, n) =
      TIO.putStrLn
        ( pad 7 (if status == "ready" then "ready" else "draft")
            <> pad 6 (tshow n)
            <> pad 40 (ellipsis 38 name)
            <> pad 24 (ellipsis 22 author)
            <> pad 26 (ellipsis 24 license)
            <> ai
        )

runPackApply :: FilePath -> FilePath -> IO ()
runPackApply dbPath cataloguePath = do
  -- 明確以 UTF-8 解碼。Data.Text.IO.readFile 用的是 locale 編碼,
  -- Windows 上可能是 CP950 —— 那會把 packs.toml 裡的中文解成亂碼,
  -- 或直接因為無法解碼而拋例外。TOML 規格本身就規定 UTF-8。
  --
  -- 用 lenient 而不是嚴格版:檔案真的被存成 CP950 時(繁中 Windows 上很容易
  -- 發生),嚴格版拋的是 UnicodeException,而使用者看到的是一個英文例外而不是
  -- 「這個檔案的編碼不對」。壞掉的位元組變成替代字元,TOML 解析器接著會指出
  -- 是哪一行 —— 那才是可行動的訊息(G-E003)。
  src <- decodeUtf8Lenient <$> BS.readFile cataloguePath
  case parseCatalogue src of
    Left err -> TIO.putStrLn ("✗ 目錄解析失敗:\n" <> err) >> exitFailure
    Right cat ->
      withStore dbPath $ \st -> do
        _ <- initSchema st
        r <- applyCatalogue st cat

        let ready = length [() | (_, True) <- arMatched r]
            stillDraft = [a | (a, False) <- arMatched r]

        TIO.putStrLn (tshow (length (arMatched r)) <> " 個素材包已套用,其中 " <> tshow ready <> " 個升級為 ready")

        report "目錄裡有但資料庫找不到的壓縮檔(先跑 scan?)" (arMissingArchive r)
        report "引用了不存在的授權名稱" (arMissingLicense r)
        report "欄位值不合法,這幾包沒有套用" [a <> " —— " <> why | (a, why) <- arRejected r]
        report "仍是 draft(缺授權或作者)" stillDraft

        if null (arMissingArchive r) && null (arMissingLicense r) && null (arRejected r)
          then pure ()
          else exitFailure
  where
    report _ [] = pure ()
    report title xs = do
      TIO.putStrLn ""
      TIO.putStrLn ("⚠ " <> title <> ":")
      mapM_ (\x -> TIO.putStrLn ("    " <> x)) xs

--------------------------------------------------------------------------------

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - displayWidth t)) " "

-- | 中文字在等寬終端機佔兩格。不算進去的話含中文的欄位會全部歪掉。
displayWidth :: Text -> Int
displayWidth = sum . map w . T.unpack
  where
    w c = if fromEnum c > 0x1100 then 2 else 1

ellipsis :: Int -> Text -> Text
ellipsis n t = if T.length t <= n then t else T.take (n - 1) t <> "…"

tshow :: Show a => a -> Text
tshow = T.pack . show
