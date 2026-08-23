-- | 資料庫健康檢查與待辦清單。
module AssetDB.Cli.Doctor (runDoctor) where

import AssetDB.Ingest.Report (humanBytes)
import AssetDB.Store
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Database.SQLite.Simple

runDoctor :: FilePath -> IO ()
runDoctor dbPath =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    let conn = storeConn st

    TIO.putStrLn "── 索引概況 ──"
    section conn
      [ ("素材庫根目錄", "SELECT COUNT(*) FROM roots")
      , ("素材包", "SELECT COUNT(*) FROM packs")
      , ("壓縮檔", "SELECT COUNT(*) FROM archives")
      , ("資源", "SELECT COUNT(*) FROM assets")
      , ("唯一內容(blobs)", "SELECT COUNT(*) FROM blobs")
      ]

    dup <- scalar conn "SELECT COUNT(*) FROM assets WHERE sha256 IS NOT NULL"
    uniq <- scalar conn "SELECT COUNT(*) FROM blobs"
    bytes <- scalarI conn "SELECT COALESCE(SUM(bytes),0) FROM blobs"
    TIO.putStrLn ""
    TIO.putStrLn ("  去重後總量 " <> humanBytes bytes)
    TIO.putStrLn
      ( "  重複內容 " <> tshow (dup - uniq) <> " 筆"
          <> "(" <> tshow dup <> " 筆資源指向 " <> tshow uniq <> " 份唯一內容)"
      )

    TIO.putStrLn ""
    TIO.putStrLn "── 待辦 ──"

    -- 沒有 SHA-256 的資源不能作為重構刪除閘門的依據。
    noHash <- scalar conn "SELECT COUNT(*) FROM assets WHERE sha256 IS NULL"
    warnIf (noHash > 0) ("有 " <> tshow noHash <> " 筆資源沒有內容雜湊,無法作為刪除依據")

    -- draft 的素材包不可用於建專案。
    draft <- scalar conn "SELECT COUNT(*) FROM packs WHERE status = 'draft'"
    warnIf (draft > 0) ("有 " <> tshow draft <> " 個素材包是 draft(缺授權或作者),不可用於建專案")

    unknownAi <- scalar conn "SELECT COUNT(*) FROM packs WHERE ai_disclosure = 'unknown'"
    warnIf (unknownAi > 0) ("有 " <> tshow unknownAi <> " 個素材包的 AI 使用揭露未填,發行前必須交代")

    unnamed <- scalar conn "SELECT COUNT(*) FROM assets WHERE logical_name IS NULL"
    warnIf (unnamed > 0) ("有 " <> tshow unnamed <> " 筆資源尚未指定邏輯名稱")

    uncat <- scalar conn "SELECT COUNT(*) FROM assets a WHERE NOT EXISTS (SELECT 1 FROM asset_categories c WHERE c.asset_id = a.id)"
    warnIf (uncat > 0) ("有 " <> tshow uncat <> " 筆資源未分類")

    if noHash == 0 && draft == 0 && unknownAi == 0
      then TIO.putStrLn "  沒有阻擋性問題。"
      else pure ()

    unreadByArchive conn
    redundantArchives conn
    coverageReport conn

--------------------------------------------------------------------------------

-- | 哪些壓縮檔有讀不到內容的項目。
--
-- 沒有 SHA-256 的項目在重構時無法證明「已存在於壓縮檔內」,
-- 對應的散檔因此會被保留而不是刪除。知道是哪幾包才能決定要不要處理。
unreadByArchive :: Connection -> IO ()
unreadByArchive conn = do
  rows <-
    query_
      conn
      "SELECT ar.rel_path, COUNT(*) FROM assets a \
      \JOIN archives ar ON ar.id = a.archive_id \
      \WHERE a.sha256 IS NULL GROUP BY ar.rel_path ORDER BY 2 DESC" ::
      IO [(Text, Int)]
  case rows of
    [] -> pure ()
    _ -> do
      TIO.putStrLn ""
      TIO.putStrLn "── 讀不到內容的項目 ──"
      mapM_ (\(p, n) -> TIO.putStrLn ("  " <> pad 6 (tshow n) <> p)) rows
      samples <-
        query_
          conn
          "SELECT entry_path FROM assets WHERE sha256 IS NULL ORDER BY entry_path LIMIT 8" ::
          IO [Only Text]
      TIO.putStrLn "  樣本:"
      mapM_ (\(Only p) -> TIO.putStrLn ("    " <> p)) samples

-- | 內容完全被其他壓縮檔涵蓋的壓縮檔。
--
-- 廠商常常同時提供 Free 與 Full 版,Free 通常是 Full 的子集。
-- 這裡只報告,**不建議刪除** —— 廠商原始下載檔是溯源證據,
-- 而且 Free 與 Full 可能有不同授權條款。是否保留是人的決定。
redundantArchives :: Connection -> IO ()
redundantArchives conn = do
  rows <-
    query_
      conn
      "SELECT ar.rel_path, COUNT(*) AS total, \
      \  SUM(CASE WHEN EXISTS ( \
      \    SELECT 1 FROM assets e2 WHERE e2.archive_id IS NOT NULL \
      \      AND e2.archive_id <> e1.archive_id AND e2.sha256 = e1.sha256 \
      \  ) THEN 1 ELSE 0 END) AS elsewhere \
      \FROM assets e1 JOIN archives ar ON ar.id = e1.archive_id \
      \WHERE e1.sha256 IS NOT NULL \
      \GROUP BY e1.archive_id HAVING elsewhere > 0 ORDER BY (1.0*elsewhere/total) DESC, total DESC" ::
      IO [(Text, Int, Int)]
  case rows of
    [] -> pure ()
    _ -> do
      TIO.putStrLn ""
      TIO.putStrLn "── 與其他壓縮檔的內容重疊 ──"
      mapM_ describe rows
      TIO.putStrLn "  (僅供參考。廠商原始下載檔是溯源證據,是否保留由你決定)"
  where
    describe (p, total, elsewhere) =
      let pct = (100 * elsewhere) `div` max 1 total
          mark = if elsewhere == total then "完全涵蓋 " else "         "
       in TIO.putStrLn
            ( "  " <> mark <> pad 5 (tshow pct <> "%")
                <> pad 12 (tshow elsewhere <> "/" <> tshow total)
                <> p
            )

-- | **重構刪除閘門的證據。**
--
-- 對每一個散檔問:它的 SHA-256 是否確實存在於某個壓縮檔內的項目?
-- 是,才可以刪。這裡只報告,不刪任何東西。
coverageReport :: Connection -> IO ()
coverageReport conn = do
  total <- scalar conn "SELECT COUNT(*) FROM assets WHERE root_id IS NOT NULL"
  if total == 0
    then pure ()
    else do
      covered <-
        scalar
          conn
          "SELECT COUNT(*) FROM assets l WHERE l.root_id IS NOT NULL AND l.sha256 IS NOT NULL \
          \AND EXISTS (SELECT 1 FROM assets e WHERE e.archive_id IS NOT NULL AND e.sha256 = l.sha256)"
      TIO.putStrLn ""
      TIO.putStrLn "── 散檔覆蓋率(重構刪除閘門的依據)──"
      TIO.putStrLn ("  散檔總數      " <> tshow total)
      TIO.putStrLn ("  雜湊已在壓縮檔 " <> tshow covered)
      TIO.putStrLn ("  未覆蓋        " <> tshow (total - covered))
      uncovered <-
        query_
          conn
          "SELECT rel_path FROM assets l WHERE l.root_id IS NOT NULL \
          \AND NOT EXISTS (SELECT 1 FROM assets e WHERE e.archive_id IS NOT NULL AND e.sha256 = l.sha256) \
          \ORDER BY rel_path LIMIT 20" ::
          IO [Only Text]
      case uncovered of
        [] -> TIO.putStrLn "  全部散檔都能在壓縮檔內找到相同內容。"
        _ -> do
          TIO.putStrLn "  未覆蓋的散檔(最多列 20 筆):"
          mapM_ (\(Only p) -> TIO.putStrLn ("    " <> p)) uncovered

--------------------------------------------------------------------------------

section :: Connection -> [(Text, Query)] -> IO ()
section conn rows =
  mapM_
    (\(label, q) -> scalar conn q >>= \n -> TIO.putStrLn ("  " <> pad 18 label <> tshow n))
    rows

scalar :: Connection -> Query -> IO Int
scalar conn q = do
  rows <- query_ conn q
  pure (case rows of (Only n : _) -> n; _ -> 0)

scalarI :: Connection -> Query -> IO Integer
scalarI conn q = do
  rows <- query_ conn q
  pure (case rows of (Only n : _) -> n; _ -> 0)

warnIf :: Bool -> Text -> IO ()
warnIf cond msg = if cond then TIO.putStrLn ("  ⚠ " <> msg) else pure ()

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - T.length t)) " "

tshow :: Show a => a -> Text
tshow = T.pack . show
