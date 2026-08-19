{-# LANGUAGE ScopedTypeVariables #-}
-- | 知識建檔與行銷資訊。
--
-- == 為什麼不需要獨立的子系統
--
-- 知識文件與行銷素材看起來是兩個新功能,實際上它們是同一張圖上的節點:
-- @notes@ 是節點,@links@ 是邊,而素材與專案早就在同一張圖上了。
--
-- 所以「這篇筆記描述哪個素材」「這張截圖宣傳哪個專案」用的是與
-- 「這個關卡使用哪些 tileset」完全相同的機制 —— 不是類比,是同一段程式碼。
module AssetDB.Ingest.Notes
  ( NoteDoc (..)
  , parseFrontMatter
  , frontJson
  , importNotes
  , listNotes
  , linkEntities
  , entityLinks
  , tableOf
  , reindexNotes
  ) where

import AssetDB.Id (newULID, unULID)
import AssetDB.Store
import AssetDB.Store.Tokenize
import AssetDB.Types (LinkRel, NoteKind, TextEnum (..))
import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, takeFileName, (</>))

data NoteDoc = NoteDoc
  { ndTitle :: Text
  , ndBody :: Text
  , ndFront :: [(Text, Text)]
  , ndSource :: Text
  }
  deriving stock (Eq, Show)

-- | 解析 YAML 風格的 front matter。
--
-- 刻意只支援 @key: value@ 這一種形式,不引入 YAML 函式庫。
-- 筆記的 front matter 只需要標題、標籤、日期這幾個純量欄位;
-- 支援巢狀結構只會讓人開始把資料塞進文件裡,而那些資料應該進資料庫。
--
-- 沒有 front matter 時,標題取自第一個 Markdown 標題,再退回檔名。
parseFrontMatter :: Text -> Text -> NoteDoc
parseFrontMatter source raw =
  case T.stripPrefix "---" (T.stripStart raw) of
    Just rest
      | (block, body) <- T.breakOn "\n---" rest
      , not (T.null body) ->
          let front = [kv l | l <- T.lines block, T.isInfixOf ":" l]
              content = T.drop 4 body
           in NoteDoc (titleFrom front content) (T.strip content) front source
    _ -> NoteDoc (titleFrom [] raw) (T.strip raw) [] source
  where
    kv l = let (k, v) = T.breakOn ":" l in (T.strip k, T.strip (T.drop 1 v))

    titleFrom :: [(Text, Text)] -> Text -> Text
    titleFrom front content =
      case lookup "title" front of
        Just t | not (T.null t) -> unquote t
        _ -> case [T.strip h | l <- T.lines content, Just h <- [T.stripPrefix "# " l]] of
          (h : _) -> h
          [] -> T.pack (takeFileName (T.unpack source))

    unquote t = maybe t id (T.stripSuffix "\"" =<< T.stripPrefix "\"" t)

--------------------------------------------------------------------------------

-- | 匯入一個目錄裡的 Markdown 檔案。
--
-- 以 @source_path@ 為識別鍵重複匯入是更新而不是新增 —— 筆記會被反覆編輯,
-- 每次匯入都新增一筆會讓同一份文件散成好幾個版本。
importNotes :: Store -> NoteKind -> FilePath -> IO [(Text, Text)]
importNotes st kind dir = do
  ok <- doesDirectoryExist dir
  if not ok
    then pure []
    else do
      names <- listDirectory dir
      let mds = [n | n <- names, takeExtension n `elem` [".md", ".markdown"]]
      now <- T.pack . iso8601Show <$> getCurrentTime
      forM mds $ \n -> do
        raw <- decodeUtf8Lenient <$> BS.readFile (dir </> n)
        let doc = parseFrontMatter (T.pack n) raw
        u <- unULID <$> newULID
        -- 部分唯一索引的 ON CONFLICT **必須重複同樣的 WHERE 述詞**,
        -- 否則 SQLite 認不出要用哪個索引來解衝突。
        execute
          (storeConn st)
          "INSERT INTO notes (ulid, kind, title, body_md, front_matter_json, source_path, created_at, updated_at) \
          \VALUES (?,?,?,?,?,?,?,?) \
          \ON CONFLICT (source_path) WHERE source_path IS NOT NULL DO UPDATE SET \
          \  title = excluded.title, body_md = excluded.body_md, \
          \  front_matter_json = excluded.front_matter_json, updated_at = excluded.updated_at"
          ( u
          , toTextEnum kind
          , ndTitle doc
          , ndBody doc
          , frontJson (ndFront doc)
          , ndSource doc
          , now
          , now
          )
        pure (ndTitle doc, ndSource doc)

-- | front matter → 存進 @notes.front_matter_json@ 的 JSON 文字。
--
-- 交給 aeson,不手刻拼接:值裡的反斜線與控制字元都要合法轉義,
-- 手刻版本只處理了雙引號,寫出來的是不合法的 JSON(ingest/E002)。
-- 重複的 key 後者為準 —— 與 JSON 物件的語意一致。
frontJson :: [(Text, Text)] -> Text
frontJson = decodeUtf8Lenient . BL.toStrict . Aeson.encode . Map.fromList

listNotes :: Store -> Maybe NoteKind -> IO [(Text, Text, Text, Text)]
listNotes st mk =
  query
    (storeConn st)
    "SELECT ulid, kind, title, COALESCE(source_path,'') FROM notes \
    \WHERE (? IS NULL OR kind = ?) ORDER BY kind, title"
    (fmap toTextEnum mk, fmap toTextEnum mk)

--------------------------------------------------------------------------------
-- 關聯圖

-- | 建立一條邊。@(src, dst, rel)@ 三元組唯一,重複建立是無操作。
--
-- 失敗回 'Left' 帶著人看得懂的訊息 —— 型別字串與 ULID 都來自
-- CLI 使用者的輸入,打錯不該是例外或崩潰。
linkEntities :: Store -> Text -> Text -> Text -> Text -> LinkRel -> Maybe Text -> IO (Either Text ())
linkEntities st srcType srcUlid dstType dstUlid rel notes =
  case (,) <$> tableOf srcType <*> tableOf dstType of
    Left e -> pure (Left e)
    Right (srcTbl, dstTbl) -> do
      srcId <- resolve srcTbl srcUlid
      dstId <- resolve dstTbl dstUlid
      case (srcId, dstId) of
        (Just s, Just d) -> do
          execute
            (storeConn st)
            "INSERT OR IGNORE INTO links (src_type, src_id, dst_type, dst_id, rel, notes) \
            \VALUES (?,?,?,?,?,?)"
            (srcType, s, dstType, d, toTextEnum rel, notes)
          pure (Right ())
        _ -> pure (Left "找不到來源或目標實體")
  where
    resolve tbl u = do
      rows <- query (storeConn st) (Query ("SELECT id FROM " <> tbl <> " WHERE ulid = ?")) (Only u)
      pure (case rows of (Only i : _) -> Just (i :: Int); _ -> Nothing)

-- | 實體型別 → 資料表名。這個字串會拼進 SQL,而型別字串正是使用者在
-- CLI 打的(@assetdb link --from foo:xxx@)—— 未知型別回 'Left',
-- 由呼叫端轉成友善訊息,不是 'error' 崩潰。
tableOf :: Text -> Either Text Text
tableOf = \case
  "asset" -> Right "assets"
  "project" -> Right "projects"
  "note" -> Right "notes"
  "collection" -> Right "collections"
  "pack" -> Right "packs"
  other -> Left ("未知的實體型別 " <> other <> ",可用:asset、project、note、collection、pack")

-- | 某個實體的所有邊,**雙向**。
--
-- 「改這張 tileset 會影響哪些關卡」是從目標端出發的查詢,
-- 與「這個關卡用了哪些 tileset」一樣常見。只做單向等於做了一半。
--
-- 回傳的對端識別是 **ULID**,不是內部整數 id —— 對外一律 ULID
-- (ADR-003),整數 id 不出這個模組。
entityLinks :: Store -> Text -> Text -> IO (Either Text [(Text, Text, Text, Text)])
entityLinks st entType ulid = case tableOf entType of
  Left e -> pure (Left e)
  Right tbl -> do
    rows <-
      query
        conn
        ( Query
            ( "SELECT 'out', l.rel, l.dst_type, l.dst_id FROM links l \
              \JOIN " <> tbl <> " e ON e.id = l.src_id \
              \WHERE l.src_type = ? AND e.ulid = ? \
              \UNION ALL \
              \SELECT 'in', l.rel, l.src_type, l.src_id FROM links l \
              \JOIN " <> tbl <> " e ON e.id = l.dst_id \
              \WHERE l.dst_type = ? AND e.ulid = ?"
            )
        )
        (entType, ulid, entType, ulid) ::
        IO [(Text, Text, Text, Int)]
    Right <$> forM rows toUlid
  where
    conn = storeConn st
    -- 每條邊查一次對端的 ULID。一個實體的邊是個位數的量,
    -- 不值得為它組五張表的 CASE 聯集。
    toUlid (d, r, t, i) = do
      u <- case tableOf t of
        Left _ -> pure Nothing
        Right tbl' -> do
          rs <- query conn (Query ("SELECT ulid FROM " <> tbl' <> " WHERE id = ?")) (Only i) :: IO [Only Text]
          pure (case rs of (Only x : _) -> Just x; _ -> Nothing)
      -- 資料列損壞(未知型別或懸空 id)時退回原始整數,讓問題看得見。
      pure (d, r, t, maybe (T.pack (show i)) id u)

--------------------------------------------------------------------------------

-- | 重建筆記的全文索引。
--
-- 筆記內容全部是繁體中文,所以 bigram 索引在這裡不是備援而是**主力** ——
-- trigram 對中文的三字元下限會讓「行銷」「素材」這種詞完全搜不到。
reindexNotes :: Store -> IO Int
reindexNotes st = do
  let conn = storeConn st
  rows <- query_ conn "SELECT id, title, body_md FROM notes" :: IO [(Int, Text, Text)]
  withTransaction conn $ do
    execute_ conn "INSERT INTO notes_fts(notes_fts) VALUES('delete-all')"
    execute_ conn "INSERT INTO notes_cjk(notes_cjk) VALUES('delete-all')"
    forM_ rows $ \(rid, title, body) -> do
      execute conn "INSERT INTO notes_fts(rowid, title, body_md) VALUES (?,?,?)" (rid, title, body)
      let blob = title <> " " <> body
      if hasCJK blob
        then do
          let CjkIndex {..} = cjkIndex blob
          execute conn "INSERT INTO notes_cjk(rowid, uni, bi) VALUES (?,?,?)" (rid, cjkUni, cjkBi)
        else pure ()
  pure (length rows)
