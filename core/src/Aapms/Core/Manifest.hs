-- | 兩份 manifest 的型別:@assets/manifest.json@(schema 2)與
-- @story/manifest.json@(graph-core\/F003)。
--
-- __遊戲本體只 import 這一組__(design.md「對外契約」開頭一段):'Manifest' \/
-- 'StoryManifest' 是 @project@ 產出、遊戲本體消費的邊界契約,不是內部索引結構
-- 的鏡射。本模組只定型別、'manifestIndex'、'imageMeta' \/ 'audioMeta' 型別化
-- 讀取;誰產生 manifest、誰做授權判斷不在範圍內(見 F003「明確不做」)。
--
-- 'ImageMeta' \/ 'AudioMeta' 的 'Data.Aeson.FromJSON' \/ 'Data.Aeson.ToJSON'
-- 實例依專案慣例集中在 "Aapms.Core.Json"(全系統唯一的 aeson 編碼規則,不在此
-- 開孤兒實例)。但 'imageMeta' \/ 'audioMeta' 本身要能在這個模組裡直接把
-- 'Data.Aeson.Value' 讀成型別化的值——而 "Aapms.Core.Json" 反過來 import 本模組
-- 建立實例,兩個模組不能互相 import。解法是把「怎麼從物件解出這兩個型別」寫成
-- 本模組匯出的 'parseImageMeta' \/ 'parseAudioMeta' 兩個純函式:'imageMeta' \/
-- 'audioMeta' 直接用它們(不經型別類別),"Aapms.Core.Json" 的
-- @instance FromJSON ImageMeta@ 等實例再委派回同一份函式——邏輯仍然只有一份。
module Aapms.Core.Manifest
  ( -- * AssetKey
    AssetKey (..)

    -- * schema 版本常數
  , currentSchemaVersion
  , currentStoryManifestSchemaVersion

    -- * assets/manifest.json
  , Manifest (..)
  , ManifestAsset (..)
  , ManifestPack (..)
  , ManifestLicense (..)

    -- * story/manifest.json
  , StoryManifest (..)
  , StoryManifestEntry (..)

    -- * kind 專屬 meta 型別化讀取
  , ImageMeta (..)
  , AudioMeta (..)
  , imageMeta
  , audioMeta
  , parseImageMeta
  , parseAudioMeta

    -- * 索引
  , manifestIndex
  ) where

import Data.Aeson (Value, (.:), (.:?), withObject)
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Aapms.Core.Asset (Sha256)
import Aapms.Core.Id (Id, Ref, VaultId)
import Aapms.Core.Meta (Revision, TypeKey)

-- | manifest \/ @Assets.hs@ 查表用的不透明字串鍵。JSON 是純字串,與
-- 'Aapms.Core.Asset.LogicalName' 的文字相同但型別上互不相通——'AssetKey' 不經
-- "Aapms.Core.Naming" 的任何驗證函式。
newtype AssetKey = AssetKey Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | @assets/manifest.json@ 目前支援的 schema 版本。
currentSchemaVersion :: Int
currentSchemaVersion = 2

-- | @story/manifest.json@ 目前支援的 schema 版本(獨立於 'currentSchemaVersion',
-- 待確認假設 ASM-4)。
currentStoryManifestSchemaVersion :: Int
currentStoryManifestSchemaVersion = 2

-- | @assets/manifest.json@,遊戲啟動時建表的入口資料。
data Manifest = Manifest
  { mSchemaVersion :: Int
  , mProject :: Text
  , mGeneratedAt :: UTCTime
  , mAssets :: [ManifestAsset]
  , mPacks :: [ManifestPack]
  -- ^ 出現在 'mAssets' 的 pack,去重(待確認假設 ASM-3)
  , mLicenses :: [ManifestLicense]
  -- ^ 出現在 'mAssets' 的 license,去重(待確認假設 ASM-3)
  }
  deriving stock (Eq, Show)

-- | 一筆素材。'maPack' \/ 'maLicense' 是**跨 vault 的 'Ref'**(F003 階段一閘門
-- 裁決 ASM-2,取代先前「同一個 vault 內的短 id」的假設):短 id 只在單一 vault 內
-- 唯一,專案的素材未來可能來自兩個 vault,JSON 編碼為 @"\<vault\>:\<id\>"@
-- (本 vault 內時可省略 vault 段,見 'Aapms.Core.Id.parseRef')。
data ManifestAsset = ManifestAsset
  { maId :: Id
  , maKey :: AssetKey
  , maPath :: Text
  , maType :: TypeKey
  , maSha256 :: Sha256
  , maVault :: VaultId
  , maPack :: Maybe Ref
  , maLicense :: Maybe Ref
  , maMeta :: Value
  -- ^ kind 專屬 JSON;型別化讀取見 'imageMeta' \/ 'audioMeta'
  }
  deriving stock (Eq, Show)

-- | 頂層去重清單裡的一筆 pack。'mpId' \/ 'mpLicense' 是 'Ref'(2026-08-23 二輪
-- 裁決,見 F003「已裁決假設」ASM-2 補述):manifest 內部的引用圖整個 vault 化,
-- 讓 'ManifestAsset.maPack' 與這裡的 'mpId' 形狀一致——兩個 vault 各有一筆
-- @pck-11223344@ 時仍是兩筆可區分的項目,不必先剝掉 vault 前綴再比對就會撞名。
data ManifestPack = ManifestPack
  { mpId :: Ref
  , mpTitle :: Text
  , mpVendor :: Maybe Text
  , mpSourceUrl :: Maybe Text
  , mpLicense :: Maybe Ref
  }
  deriving stock (Eq, Show)

-- | 頂層去重清單裡的一筆 license。'mlId' 是 'Ref',理由同 'ManifestPack.mpId'。
data ManifestLicense = ManifestLicense
  { mlId :: Ref
  , mlTitle :: Text
  , mlCommercial :: Bool
  , mlAttributionRequired :: Bool
  , mlCreditText :: Maybe Text
  , mlModificationAllowed :: Maybe Bool
  , mlRedistributionAllowed :: Maybe Bool
  , mlResaleAllowed :: Maybe Bool
  , mlNftAllowed :: Maybe Bool
  , mlSourceUrl :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @story/manifest.json@。
data StoryManifest = StoryManifest
  { smSchemaVersion :: Int
  , smProject :: Text
  , smGeneratedAt :: UTCTime
  , smEntities :: [StoryManifestEntry]
  }
  deriving stock (Eq, Show)

data StoryManifestEntry = StoryManifestEntry
  { smeRef :: Ref
  -- ^ @\<vault\>:\<id\>@,不複製任何位元組
  , smeTitle :: Text
  , smeSummary :: Text
  , smePurpose :: Text
  -- ^ 這筆 Entity 在本專案的用途(project 產出時填寫的自由文字)
  , smeRevision :: Revision
  }
  deriving stock (Eq, Show)

-- | 圖片 kind 專屬 meta(原樣沿用舊 @AssetDB.Manifest@)。
data ImageMeta = ImageMeta
  { imWidth :: Int
  , imHeight :: Int
  , imHasAlpha :: Bool
  , imColorCount :: Maybe Int
  }
  deriving stock (Eq, Show)

-- | 音訊 kind 專屬 meta(原樣沿用舊 @AssetDB.Manifest@)。
data AudioMeta = AudioMeta
  { amDurationMs :: Int
  , amSampleRate :: Int
  , amChannels :: Int
  }
  deriving stock (Eq, Show)

-- | 以 'maKey' 建表。
manifestIndex :: Manifest -> Map AssetKey ManifestAsset
manifestIndex m = Map.fromList [(maKey a, a) | a <- mAssets m]

-- | 型別化讀取:相符 kind 的 'Value' 回 'Just',欄位缺漏或型別不符回
-- 'Nothing'(待確認假設 ASM-1:同時適用於 'ManifestAsset' 的 @meta@ 欄位與
-- "Aapms.Core.Asset" 的 @astKindMeta@ 兩處)。
imageMeta :: Value -> Maybe ImageMeta
imageMeta = parseMaybe parseImageMeta

audioMeta :: Value -> Maybe AudioMeta
audioMeta = parseMaybe parseAudioMeta

-- | 供本模組的 'imageMeta' 與 "Aapms.Core.Json" 的 @instance FromJSON ImageMeta@
-- 共用的解析邏輯——見模組頂端說明為什麼不能改用型別類別內的
-- @instance FromJSON ImageMeta@ 直接呼叫。
parseImageMeta :: Value -> Parser ImageMeta
parseImageMeta = withObject "ImageMeta" $ \o ->
  ImageMeta
    <$> o .: "width"
    <*> o .: "height"
    <*> o .: "hasAlpha"
    <*> o .:? "colorCount"

parseAudioMeta :: Value -> Parser AudioMeta
parseAudioMeta = withObject "AudioMeta" $ \o ->
  AudioMeta
    <$> o .: "durationMs"
    <*> o .: "sampleRate"
    <*> o .: "channels"
