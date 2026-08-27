-- | 規劃所需的資料庫快照。
--
-- 規劃器是**純函數**,不碰資料庫也不碰檔案系統。這個模組是唯一的 IO 邊界:
-- 把要用到的資料一次讀出來,之後的推導全部可測。
--
-- 這不是形式主義。重構會搬動 3.42 GB 並刪除五千多個檔案 ——
-- 「刪除清單是怎麼算出來的」必須能在測試裡完整重現,而不是只能對著
-- 真實素材庫跑一次看結果。
module AssetDB.Reorg.Snapshot
  ( Snapshot (..)
  , PackRow (..)
  , LooseRow (..)
  , loadSnapshot
  ) where

import AssetDB.Store
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.SQLite.Simple

data Snapshot = Snapshot
  { snPacks :: [PackRow]
  , snLoose :: [LooseRow]
  , snArchivedBy :: Map Text Text
  -- ^ 壓縮檔內項目的 @SHA-256 → 壓縮檔相對路徑@。
  --
  -- 刪除閘門就是對這張表做查詢:散檔的雜湊查得到才可以刪,
  -- 而查到的值就是**寫進計畫的證據** ——「這個檔案可以刪,因為它的內容
  -- 存在於 X 壓縮檔裡」。只存一個 Set 的話計畫只能說「可以刪」,
  -- 說不出憑什麼。
  --
  -- 一次撈成 Map 而不是每筆做一次 SQL:5,429 次子查詢會慢到不可用。
  }
  deriving stock (Eq, Show)

data PackRow = PackRow
  { prSlug :: Text
  , prName :: Text
  , prVendor :: Maybe Text
  , prAuthor :: Maybe Text
  , prLicense :: Maybe Text
  , prKind :: Text
  , prStatus :: Text
  , prAi :: Text
  , prSourceUrl :: Maybe Text
  , prVersion :: Maybe Text
  , prNotes :: Maybe Text
  , prArchiveRel :: Text
  -- ^ 壓縮檔相對於掃描根目錄的路徑。
  , prArchiveSha :: Text
  , prArchiveBytes :: Integer
  , prEntryCount :: Int
  }
  deriving stock (Eq, Show)

-- | 15 個欄位,遠超過 sqlite-simple 對 tuple 的 10 個上限。
-- 手寫 instance 的另一個好處是欄位順序與 SELECT 直接對齊,
-- 少一層「第 11 個元素是哪一欄」的心算。
instance FromRow PackRow where
  fromRow =
    PackRow
      <$> field -- slug
      <*> field -- name
      <*> field -- vendor
      <*> field -- author
      <*> field -- license
      <*> field -- kind
      <*> field -- status
      <*> field -- ai_disclosure
      <*> field -- source_url
      <*> field -- version
      <*> field -- notes
      <*> field -- archive rel_path
      <*> field -- archive sha256
      <*> field -- archive bytes
      <*> field -- entry_count

data LooseRow = LooseRow
  { lrRelPath :: Text
  , lrSha :: Maybe Text
  , lrBytes :: Integer
  }
  deriving stock (Eq, Show)

loadSnapshot :: Store -> IO Snapshot
loadSnapshot st = do
  let conn = storeConn st
  packs <-
    query_
      conn
      "SELECT p.slug, p.name, p.vendor, a.name, l.name, p.kind, p.status, p.ai_disclosure, \
      \       p.source_url, p.version, p.notes, ar.rel_path, ar.sha256, ar.bytes, \
      \       COALESCE(ar.entry_count,0) \
      \FROM packs p \
      \JOIN archives ar ON ar.pack_id = p.id \
      \LEFT JOIN authors a ON a.id = p.author_id \
      \LEFT JOIN licenses l ON l.id = p.license_id \
      \ORDER BY ar.rel_path"
  loose <-
    query_
      conn
      "SELECT rel_path, sha256, COALESCE((SELECT bytes FROM blobs b WHERE b.sha256 = assets.sha256), 0) \
      \FROM assets WHERE root_id IS NOT NULL ORDER BY rel_path"
  -- MIN() 讓同一份內容出現在多個壓縮檔時取字典序最小的那個。
  -- 選哪一個不重要,重要的是**確定性** —— 同樣的資料庫必須產生同樣的計畫,
  -- 否則審核過的計畫與實際執行的計畫可能不同。
  shas <-
    query_
      conn
      "SELECT a.sha256, MIN(ar.rel_path) FROM assets a \
      \JOIN archives ar ON ar.id = a.archive_id \
      \WHERE a.sha256 IS NOT NULL GROUP BY a.sha256"
  pure
    Snapshot
      { snPacks = packs
      , snLoose = map toLoose loose
      , snArchivedBy = Map.fromList shas
      }
  where
    toLoose (p, sha, bytes) = LooseRow p sha bytes
