-- | @assets/manifest.json@ 的 schema。
--
-- == 這個模組是整個技術選型的理由
--
-- 這份 schema 有兩個讀者:資源管理系統(產生它)與**遊戲本體**(消費它)。
-- 因為兩邊都是 Haskell,兩邊 @import AssetDB.Manifest@ 用的是同一個型別,
-- 所以 schema 改動會在編譯期爆炸,而不是在執行期變成黑畫面。
--
-- 換成 Python 或 TypeScript 後端,這裡就會是兩份手寫、緩慢漂移的 parser。
--
-- == 為什麼 metadata 是開放的 'Value'
--
-- 'maMeta' 刻意不是封閉的 sum type。加入音效時,@width@/@height@ 換成
-- @durationMs@/@sampleRate@,如果 metadata 是封閉型別,這個檔案、資料庫 schema、
-- 前端型別會一起要改。開放 JSON + 型別化的存取函式('imageMeta' / 'audioMeta')
-- 讓「加一種 kind」變成純粹的加法。
module AssetDB.Manifest
  ( -- * 頂層
    Manifest (..)
  , currentSchemaVersion
  , manifestIndex
  , lookupAsset

  , AssetKey (..)

    -- * 條目
  , ManifestAsset (..)
  , ManifestPack (..)
  , ManifestLicense (..)

    -- * kind 專屬 metadata
  , ImageMeta (..)
  , AudioMeta (..)
  , imageMeta
  , audioMeta
  ) where

import AssetDB.Id (ULID)
import AssetDB.Naming (LogicalName, logicalNameText)
import AssetDB.Types (AssetKind)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time.Clock (UTCTime)

-- | 遞增規則:**只在破壞相容性時遞增**。純粹新增可選欄位不算破壞。
--
-- 遊戲端載入時應該檢查這個值。版本不符要直接拒絕載入並給出明確訊息,
-- 而不是讓缺欄位變成執行期的 @Nothing@ 連鎖。
currentSchemaVersion :: Int
currentSchemaVersion = 1

data Manifest = Manifest
  { mSchemaVersion :: Int
  , mProject :: Text
  , mGeneratedAt :: UTCTime
  , mAssets :: [ManifestAsset]
  , mPacks :: [ManifestPack]
  -- ^ 出現在 'mAssets' 裡的素材包,去重後列出。授權稽核與致謝名單用。
  , mLicenses :: [ManifestLicense]
  }
  deriving stock (Eq, Show)

-- | 遊戲端的素材查表 key。
--
-- 產生的 .hs@ 把每個邏輯名稱變成一個這種型別的常數,
-- 所以「素材名稱打錯」從執行期黑畫面變成編譯錯誤。
newtype AssetKey = AssetKey {unAssetKey :: Text}
  deriving newtype (Eq, Ord, Show, ToJSON, FromJSON)

-- | 一筆素材。
data ManifestAsset = ManifestAsset
  { maId :: ULID
  -- ^ 永久識別碼。**關聯與追溯用這個**,不要用 'maKey' 或路徑
  -- —— 那兩者都可能因為重新命名而改變。
  , maKey :: LogicalName
  -- ^ 遊戲載入器的查表 key。等於檔名去掉副檔名。
  , maPath :: Text
  -- ^ 專案根目錄的相對路徑,永遠用 @/@ 分隔(跨平台)。
  , maKind :: AssetKind
  , maSha256 :: Text
  -- ^ 內容雜湊。讓 @assetdb doctor@ 能分辨「素材被改過」與「來源更新了」。
  , maPack :: Maybe Text
  , maLicense :: Maybe Text
  , maMeta :: Value
  -- ^ kind 專屬欄位。用 'imageMeta' / 'audioMeta' 取型別化的視圖。
  }
  deriving stock (Eq, Show)

data ManifestPack = ManifestPack
  { mpName :: Text
  , mpVendor :: Maybe Text
  , mpSourceUrl :: Maybe Text
  , mpVersion :: Maybe Text
  , mpLicense :: Maybe Text
  }
  deriving stock (Eq, Show)

data ManifestLicense = ManifestLicense
  { mlName :: Text
  , mlCommercial :: Bool
  -- ^ 是否允許商業使用。建專案時的授權閘門依據這個欄位。
  , mlAttributionRequired :: Bool
  , mlNotes :: Maybe Text
  }
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- 查表

-- | 建成 key → 素材 的表。遊戲啟動時做一次,之後 O(log n) 查詢。
manifestIndex :: Manifest -> Map Text ManifestAsset
manifestIndex m =
  Map.fromList [(logicalNameText (maKey a), a) | a <- mAssets m]

lookupAsset :: LogicalName -> Manifest -> Maybe ManifestAsset
lookupAsset k m = Map.lookup (logicalNameText k) (manifestIndex m)

--------------------------------------------------------------------------------
-- kind 專屬 metadata

data ImageMeta = ImageMeta
  { imWidth :: Int
  , imHeight :: Int
  , imHasAlpha :: Bool
  , imColorCount :: Maybe Int
  -- ^ 唯一色數。Cainos 的手繪素材有 2,700+ 色,像素圖標常常在 32 色以內
  -- —— 這個數字是區分「手繪」與「色盤像素」風格最便宜的訊號。
  }
  deriving stock (Eq, Show)

data AudioMeta = AudioMeta
  { amDurationMs :: Int
  , amSampleRate :: Int
  , amChannels :: Int
  }
  deriving stock (Eq, Show)

-- | 取出圖片 metadata。kind 不符或欄位缺漏時回傳 'Nothing'。
imageMeta :: ManifestAsset -> Maybe ImageMeta
imageMeta = parseMaybe parseJSON . maMeta

audioMeta :: ManifestAsset -> Maybe AudioMeta
audioMeta = parseMaybe parseJSON . maMeta

--------------------------------------------------------------------------------
-- JSON
--
-- 全部手寫。這是跨越工具與遊戲的合約,欄位名不該由 Generic 的
-- 前綴剝除規則間接決定 —— 那種寫法在有人重新命名 Haskell 欄位時會無聲改掉線上格式。

instance ToJSON Manifest where
  toJSON Manifest {..} =
    object
      [ "schemaVersion" .= mSchemaVersion
      , "project" .= mProject
      , "generatedAt" .= mGeneratedAt
      , "assets" .= mAssets
      , "packs" .= mPacks
      , "licenses" .= mLicenses
      ]

instance FromJSON Manifest where
  parseJSON = withObject "Manifest" $ \o -> do
    ver <- o .: "schemaVersion"
    checkVersion ver
    Manifest ver
      <$> o .: "project"
      <*> o .: "generatedAt"
      <*> o .: "assets"
      <*> o .:? "packs" .!= []
      <*> o .:? "licenses" .!= []

checkVersion :: Int -> Parser ()
checkVersion ver
  | ver == currentSchemaVersion = pure ()
  | otherwise =
      fail $
        "manifest schemaVersion 是 "
          <> show ver
          <> ",本程式支援 "
          <> show currentSchemaVersion
          <> "。請重新產生 manifest(assetdb sync)。"

instance ToJSON ManifestAsset where
  toJSON ManifestAsset {..} =
    object
      [ "id" .= maId
      , "key" .= maKey
      , "path" .= maPath
      , "kind" .= maKind
      , "sha256" .= maSha256
      , "pack" .= maPack
      , "license" .= maLicense
      , "meta" .= maMeta
      ]

instance FromJSON ManifestAsset where
  parseJSON = withObject "ManifestAsset" $ \o ->
    ManifestAsset
      <$> o .: "id"
      <*> o .: "key"
      <*> o .: "path"
      <*> o .: "kind"
      <*> o .: "sha256"
      <*> o .:? "pack"
      <*> o .:? "license"
      <*> o .:? "meta" .!= Null

instance ToJSON ManifestPack where
  toJSON ManifestPack {..} =
    object
      [ "name" .= mpName
      , "vendor" .= mpVendor
      , "sourceUrl" .= mpSourceUrl
      , "version" .= mpVersion
      , "license" .= mpLicense
      ]

instance FromJSON ManifestPack where
  parseJSON = withObject "ManifestPack" $ \o ->
    ManifestPack
      <$> o .: "name"
      <*> o .:? "vendor"
      <*> o .:? "sourceUrl"
      <*> o .:? "version"
      <*> o .:? "license"

instance ToJSON ManifestLicense where
  toJSON ManifestLicense {..} =
    object
      [ "name" .= mlName
      , "commercial" .= mlCommercial
      , "attributionRequired" .= mlAttributionRequired
      , "notes" .= mlNotes
      ]

instance FromJSON ManifestLicense where
  parseJSON = withObject "ManifestLicense" $ \o ->
    ManifestLicense
      <$> o .: "name"
      <*> o .: "commercial"
      <*> o .:? "attributionRequired" .!= False
      <*> o .:? "notes"

instance ToJSON ImageMeta where
  toJSON ImageMeta {..} =
    object
      [ "width" .= imWidth
      , "height" .= imHeight
      , "hasAlpha" .= imHasAlpha
      , "colorCount" .= imColorCount
      ]

instance FromJSON ImageMeta where
  parseJSON = withObject "ImageMeta" $ \o ->
    ImageMeta
      <$> o .: "width"
      <*> o .: "height"
      <*> o .:? "hasAlpha" .!= False
      <*> o .:? "colorCount"

instance ToJSON AudioMeta where
  toJSON AudioMeta {..} =
    object
      [ "durationMs" .= amDurationMs
      , "sampleRate" .= amSampleRate
      , "channels" .= amChannels
      ]

instance FromJSON AudioMeta where
  parseJSON = withObject "AudioMeta" $ \o ->
    AudioMeta
      <$> o .: "durationMs"
      <*> o .: "sampleRate"
      <*> o .: "channels"
