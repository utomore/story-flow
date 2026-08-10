-- | 素材包中繼資料目錄。
--
-- == 為什麼需要一個外部檔案
--
-- 掃描能自動得到的只有「這個壓縮檔存在、裡面有這些內容」。
-- 作者、授權、AI 使用揭露、購買來源 —— 這些**無法從檔名或內容推導**,
-- 而且盤點證實廠商壓縮檔裡有沒有這些資訊完全看運氣:
-- Crusenho 附了完整 @License.txt@,四個 Effects 包什麼都沒有。
--
-- 所以這些資訊是資料,由人維護。放在版控裡的一個檔案,而不是 migration ——
-- 使用者每買一包新素材就要加一筆,不該需要改程式碼。
--
-- == 這個格式就是 @pack.toml@
--
-- 重構之後每個素材包會有自己的 @library\/packs\/\<vendor\>\/\<slug\>\/pack.toml@。
-- 這裡的每一個 @[[pack]]@ 區塊就是那個檔案的內容,只是暫時集中在一份目錄裡 ——
-- 因為現在的素材庫還是舊結構,沒有地方放個別的 @pack.toml@。
module AssetDB.Ingest.Catalogue
  ( Catalogue (..)
  , PackEntry (..)
  , parseCatalogue
  , ApplyResult (..)
  , applyCatalogue
  ) where

import AssetDB.Store
import Control.Monad (forM)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple
import Toml (decode)
import Toml.Schema

newtype Catalogue = Catalogue {catPacks :: [PackEntry]}
  deriving stock (Eq, Show)

-- | 一個素材包的完整中繼資料。
--
-- 'peArchive' 以**基本檔名**比對,不是完整路徑 ——
-- 重構會改變目錄結構,但廠商的壓縮檔檔名不會變。
data PackEntry = PackEntry
  { peArchive :: Text
  , peName :: Text
  , peSlug :: Text
  , peVendor :: Maybe Text
  , peAuthor :: Maybe Text
  , peAuthorUrl :: Maybe Text
  , peAuthorContact :: Maybe Text
  , peLicense :: Maybe Text
  -- ^ 對應 @licenses.name@。授權定義本身在資料庫的種子資料裡,
  -- 這裡只是引用 —— 同一份授權涵蓋多個素材包時不必重複描述。
  , peAi :: Maybe Text
  , peSourceUrl :: Maybe Text
  , peVersion :: Maybe Text
  , pePrice :: Maybe Double
  , peAcquired :: Maybe Text
  , peKind :: Maybe Text
  -- ^ @packs@(預設)/ @reference@ / @studio@。決定重構後落在
  -- @library\/packs\/@ 還是 @library\/reference\/@。
  --
  -- 做成明確欄位而不是從路徑或授權推測:「金門建築是參考資料」這件事
  -- 是人的判斷,不該由 @現實資源@ 這個資料夾名稱間接決定 —— 那個資料夾
  -- 重構後就不存在了。
  , peNotes :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromValue Catalogue where
  fromValue =
    parseTableFromValue $
      Catalogue <$> reqKey "pack"

instance FromValue PackEntry where
  fromValue =
    parseTableFromValue $
      PackEntry
        <$> reqKey "archive"
        <*> reqKey "name"
        <*> reqKey "slug"
        <*> optKey "vendor"
        <*> optKey "author"
        <*> optKey "author_url"
        <*> optKey "author_contact"
        <*> optKey "license"
        <*> optKey "ai"
        <*> optKey "source_url"
        <*> optKey "version"
        <*> optKey "price_usd"
        <*> optKey "acquired"
        <*> optKey "kind"
        <*> optKey "notes"

parseCatalogue :: Text -> Either Text Catalogue
parseCatalogue src =
  case decode src of
    Success _ c -> Right c
    Failure errs -> Left (T.pack (unlines errs))

--------------------------------------------------------------------------------

data ApplyResult = ApplyResult
  { arMatched :: [(Text, Bool)]
  -- ^ (壓縮檔名, 是否升級為 ready)
  , arMissingArchive :: [Text]
  -- ^ 目錄裡有但資料庫裡找不到的壓縮檔 —— 通常是還沒掃描,或檔名打錯。
  , arMissingLicense :: [Text]
  -- ^ 引用了不存在的授權名稱。
  }
  deriving stock (Eq, Show)

-- | 把目錄套用到資料庫。
--
-- 只寫入,不刪除:目錄裡沒提到的素材包保持原狀。
-- 這讓目錄可以逐步補齊,而不是一次要寫完 26 包。
applyCatalogue :: Store -> Catalogue -> IO ApplyResult
applyCatalogue st (Catalogue entries) = do
  now <- T.pack . iso8601Show <$> getCurrentTime
  let conn = storeConn st
  results <- withTransaction conn $ forM entries (applyOne conn now)
  pure
    ApplyResult
      { arMatched = [(a, ready) | Right (a, ready) <- results]
      , arMissingArchive = [a | Left (MissingArchive a) <- results]
      , arMissingLicense = [l | Left (MissingLicense l) <- results]
      }

data ApplyProblem = MissingArchive Text | MissingLicense Text

applyOne :: Connection -> Text -> PackEntry -> IO (Either ApplyProblem (Text, Bool))
applyOne conn now PackEntry {..} = do
  packRows <-
    query
      conn
      "SELECT p.id FROM packs p JOIN archives a ON a.pack_id = p.id \
      \WHERE a.rel_path = ? OR a.rel_path LIKE ('%/' || ?)"
      (peArchive, peArchive) ::
      IO [Only Int]
  case packRows of
    [] -> pure (Left (MissingArchive peArchive))
    (Only packId : _) -> do
      mAuthorId <- traverse (ensureAuthor conn peAuthorUrl peAuthorContact) peAuthor
      mLicenseId <- traverse (findLicense conn) peLicense
      case (peLicense, mLicenseId) of
        (Just l, Just Nothing) -> pure (Left (MissingLicense l))
        _ -> do
          let licenseId = mLicenseId >>= id
              -- 授權與作者都齊備才升級。CHECK 約束也會擋,
              -- 但在這裡先算出來才能回報「哪幾包還沒好」。
              ready = licenseId /= Nothing && mAuthorId /= Nothing
          execute
            conn
            "UPDATE packs SET name=?, slug=?, vendor=?, author_id=?, license_id=?, \
            \  source_url=?, version=?, price_usd=?, acquired=?, \
            \  ai_disclosure=COALESCE(?,ai_disclosure), kind=COALESCE(?,kind), \
            \  notes=?, status=?, updated_at=? \
            \WHERE id=?"
            [ SQLText peName
            , SQLText peSlug
            , maybeText peVendor
            , maybe SQLNull (SQLInteger . fromIntegral) mAuthorId
            , maybe SQLNull (SQLInteger . fromIntegral) licenseId
            , maybeText peSourceUrl
            , maybeText peVersion
            , maybe SQLNull SQLFloat pePrice
            , maybeText peAcquired
            , maybeText peAi
            , maybeText peKind
            , maybeText peNotes
            , SQLText (if ready then "ready" else "draft")
            , SQLText now
            , SQLInteger (fromIntegral packId)
            ]
          pure (Right (peArchive, ready))

ensureAuthor :: Connection -> Maybe Text -> Maybe Text -> Text -> IO Int
ensureAuthor conn url contact name = do
  execute conn "INSERT OR IGNORE INTO authors (name,url,contact) VALUES (?,?,?)" (name, url, contact)
  -- 已存在時補上先前缺的欄位,但不覆蓋已有的值。
  execute
    conn
    "UPDATE authors SET url = COALESCE(url,?), contact = COALESCE(contact,?) WHERE name = ?"
    (url, contact, name)
  rows <- query conn "SELECT id FROM authors WHERE name = ?" (Only name)
  case rows of
    (Only i : _) -> pure i
    [] -> ioError (userError ("ensureAuthor:剛插入的作者找不到 " <> T.unpack name))

findLicense :: Connection -> Text -> IO (Maybe Int)
findLicense conn name = do
  rows <- query conn "SELECT id FROM licenses WHERE name = ?" (Only name)
  pure (case rows of (Only i : _) -> Just i; [] -> Nothing)

maybeText :: Maybe Text -> SQLData
maybeText = maybe SQLNull SQLText
