-- | 全文索引的填充。
--
-- @assets_fts@ 與 @assets_cjk@ 是 **contentless** 的 FTS5 表:它們不儲存原文,
-- 只儲存倒排索引,而索引內容來自跨表 JOIN(資源 + 素材包 + 作者 + 標籤)。
-- 這代表沒有任何觸發器能自動維護它們 —— 必須明確重建。
--
-- 重建是**全量**的。6,393 筆在毫秒級完成,而增量更新需要在每個寫入點
-- 記得同步兩張索引表,那是一種遲早會漏掉某一處的設計。
--
-- == 索引什麼、不索引什麼
--
-- 索引:邏輯名稱、廠商原始檔名、壓縮檔內路徑、標籤、素材包名、作者。
-- 這些都是**該筆資源自己的屬性** —— 搜「Crusenho」要找到他的素材是合理的。
--
-- **不索引素材包的 notes。** 那是關於「這一包」的說明,不是關於某一筆素材的。
-- 把它攤進每一筆會讓 Crusenho 的 notes(「唯一明確要求署名的授權」)
-- 使得搜尋「授權」吐出全部 1,693 筆 —— 那是雜訊,不是搜尋。
-- @notes@ 欄位保留在索引 schema 裡是給未來的**逐筆**筆記用的。
module AssetDB.Store.Index
  ( reindexFts
  , ftsRowCount
  , ftsStale
  ) where

import AssetDB.Store.Tokenize
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple

-- | 重建兩張全文索引。回傳寫入的列數。
reindexFts :: Connection -> IO Int
reindexFts conn = do
  rows <-
    query_
      conn
      "SELECT a.id, \
      \       COALESCE(a.logical_name,''), \
      \       COALESCE(a.original_name,''), \
      \       COALESCE(a.entry_path, a.rel_path, ''), \
      \       COALESCE((SELECT GROUP_CONCAT(t.name,' ') FROM asset_tags at \
      \                 JOIN tags t ON t.id = at.tag_id WHERE at.asset_id = a.id), ''), \
      \       COALESCE(p.name,''), \
      \       COALESCE(au.name, ''), \
      \       '' \
      \FROM assets a \
      \LEFT JOIN packs p ON p.id = a.pack_id \
      \LEFT JOIN authors au ON au.id = COALESCE(a.author_id, p.author_id) \
      \WHERE a.status <> 'archived'" ::
      IO [(Int, Text, Text, Text, Text, Text, Text, Text)]

  withTransaction conn $ do
    -- contentless FTS5 不能用 DELETE FROM。這是官方指定的清空指令。
    execute_ conn "INSERT INTO assets_fts(assets_fts) VALUES('delete-all')"
    execute_ conn "INSERT INTO assets_cjk(assets_cjk) VALUES('delete-all')"

    mapM_ (insertRow conn) rows
  pure (length rows)

insertRow :: Connection -> (Int, Text, Text, Text, Text, Text, Text, Text) -> IO ()
insertRow conn (rid, logical, orig, path, tags, pack, author, notes) = do
  execute
    conn
    "INSERT INTO assets_fts(rowid, logical_name, original_name, entry_path, tags, pack, author, notes) \
    \VALUES (?,?,?,?,?,?,?,?)"
    (rid, logical, orig, path, tags, pack, author, notes)

  -- 中日韓索引吃的是同一批文字的 n-gram 展開。寫入與查詢共用
  -- AssetDB.Store.Tokenize —— 這是這個設計唯一需要守住的不變量。
  let blob = T.unwords [logical, orig, path, tags, pack, author, notes]
  if hasCJK blob
    then do
      let CjkIndex {..} = cjkIndex blob
      execute conn "INSERT INTO assets_cjk(rowid, uni, bi) VALUES (?,?,?)" (rid, cjkUni, cjkBi)
    else
      -- 沒有中日韓字元就不寫。索引裡塞空列只會讓 rowid 對不上,
      -- 而且讓「有多少筆需要中日韓索引」這個數字失去意義。
      pure ()

ftsRowCount :: Connection -> IO (Int, Int)
ftsRowCount conn = do
  a <- scalar "SELECT COUNT(*) FROM assets_fts"
  c <- scalar "SELECT COUNT(*) FROM assets_cjk"
  pure (a, c)
  where
    scalar q = do
      rows <- query_ conn q :: IO [Only Int]
      pure (case rows of (Only n : _) -> n; _ -> 0)

-- | 索引是否落後於資源表。
--
-- contentless FTS 沒有辦法自我檢查,所以只能比對筆數。
-- 這不是嚴謹的一致性檢查,但足以抓到「掃描完忘記重建索引」這個實際會發生的情況。
ftsStale :: Connection -> IO Bool
ftsStale conn = do
  (ftsN, _) <- ftsRowCount conn
  rows <- query_ conn "SELECT COUNT(*) FROM assets WHERE status <> 'archived'" :: IO [Only Int]
  pure (case rows of (Only n : _) -> n /= ftsN; _ -> False)
