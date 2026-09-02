-- | graph-core/F003 STEP-1~STEP-8 的對照測試:兩份 manifest 型別、JSON 編碼、
-- 'manifestIndex'、'imageMeta' \/ 'audioMeta'。golden file 讀檔屬 test-suite 的
-- 相依,不是 library(F003 委派指示)。
module Aapms.Core.ManifestSpec (spec) where

import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Time (UTCTime (..), fromGregorian)
import System.Directory (doesFileExist)
import Test.Hspec

import Aapms.Core.Fixtures (idOf, refOf, vaultOf)
import Aapms.Core.Id (Ref (..))
import Aapms.Core.Manifest
import Aapms.Core.Meta (Revision (..), TypeKey (..))
import Aapms.Core.Asset (Sha256 (..))
import Aapms.Core.Json ()

-- 樣本資料 ---------------------------------------------------------------

sampleGeneratedAt :: UTCTime
sampleGeneratedAt = UTCTime (fromGregorian 2026 8 23) 0

sampleManifestAsset :: ManifestAsset
sampleManifestAsset =
  ManifestAsset
    { maId = idOf "ast-3f9c1d20"
    , maKey = AssetKey "ui_gui_travel-book-frame_001"
    , maPath = "sprites/ui_gui_travel-book-frame_001.png"
    , maType = TypeKey "asset-image"
    , maSha256 = Sha256 "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a1"
    , maVault = vaultOf "vlt-a0c4e1f8"
    , maPack = Just (refOf "vlt-a0c4e1f8:pck-11223344")
    , maLicense = Just (refOf "vlt-a0c4e1f8:lic-55667788")
    , maMeta = object ["width" .= (512 :: Int), "height" .= (512 :: Int), "hasAlpha" .= True, "colorCount" .= (128 :: Int)]
    }

-- | 沒有 pack \/ license 的第二筆(audio),用來驗證 'maPack' \/ 'maLicense'
-- 為 'Nothing' 時仍恰好有 9 個鍵(值是 null,不是省略鍵)。
sampleManifestAsset2 :: ManifestAsset
sampleManifestAsset2 =
  ManifestAsset
    { maId = idOf "ast-7ad20c31"
    , maKey = AssetKey "sfx_ui_button-click_001"
    , maPath = "audio/sfx_ui_button-click_001.ogg"
    , maType = TypeKey "asset-audio"
    , maSha256 = Sha256 "3b241101707d52a324d3540c8bcffbca8ea0d1e1e2a3e1c3e1b6b6b3f7a2b0f"
    , maVault = vaultOf "vlt-a0c4e1f8"
    , maPack = Nothing
    , maLicense = Nothing
    , maMeta = object ["durationMs" .= (240 :: Int), "sampleRate" .= (44100 :: Int), "channels" .= (2 :: Int)]
    }

samplePack :: ManifestPack
samplePack =
  ManifestPack
    { mpId = refOf "vlt-a0c4e1f8:pck-11223344"
    , mpTitle = "Kenney UI Pack"
    , mpVendor = Just "Kenney"
    , mpSourceUrl = Just "https://kenney.nl/assets/ui-pack"
    , mpLicense = Just (refOf "vlt-a0c4e1f8:lic-55667788")
    }

sampleLicense :: ManifestLicense
sampleLicense =
  ManifestLicense
    { mlId = refOf "vlt-a0c4e1f8:lic-55667788"
    , mlTitle = "CC0"
    , mlCommercial = True
    , mlAttributionRequired = False
    , mlCreditText = Nothing
    , mlModificationAllowed = Just True
    , mlRedistributionAllowed = Just True
    , mlResaleAllowed = Just True
    , mlNftAllowed = Just True
    , mlSourceUrl = Just "https://creativecommons.org/publicdomain/zero/1.0/"
    }

sampleManifest :: Manifest
sampleManifest =
  Manifest
    { mSchemaVersion = currentSchemaVersion
    , mProject = "Circle"
    , mGeneratedAt = sampleGeneratedAt
    , mAssets = [sampleManifestAsset, sampleManifestAsset2]
    , mPacks = [samplePack]
    , mLicenses = [sampleLicense]
    }

sampleStoryEntry :: StoryManifestEntry
sampleStoryEntry =
  StoryManifestEntry
    { smeRef = refOf "vlt-9d2e5b70:ent-7f3b2a91"
    , smeTitle = "琳達"
    , smeSummary = "旅店老闆娘,知道鎮上所有的八卦"
    , smePurpose = "主角的資訊來源與旁白視角"
    , smeRevision = Revision 3
    }

sampleStoryManifest :: StoryManifest
sampleStoryManifest =
  StoryManifest
    { smSchemaVersion = currentStoryManifestSchemaVersion
    , smProject = "Circle"
    , smGeneratedAt = sampleGeneratedAt
    , smEntities = [sampleStoryEntry]
    }

-- 輔助 ---------------------------------------------------------------------

-- | 編碼後最上層的鍵(對照 JsonSpec 的同名輔助)。
keysOf :: (ToJSON a) => a -> [String]
keysOf x = case toJSON x of
  Object o -> map K.toString (KM.keys o)
  _ -> []

-- | golden 檔案可能從專案根目錄或 @core/@ 底下跑(對照 CabalSpec 的作法)。
readGolden :: FilePath -> IO BS.ByteString
readGolden name = go ["core/test/golden/" <> name, "test/golden/" <> name]
  where
    go [] = fail ("找不到 golden 檔案:" <> name)
    go (p : rest) = do
      ok <- doesFileExist p
      if ok then BS.readFile p else go rest

-- | 把一份 JSON 物件的 @schemaVersion@ 換成指定值,供 STEP-6 製造非法版本輸入。
withSchemaVersion :: Int -> Value -> Value
withSchemaVersion n (Object o) = Object (KM.insert "schemaVersion" (Number (fromIntegral n)) o)
withSchemaVersion _ v = v

spec :: Spec
spec = do
  describe "STEP-1 型別建構" $ do
    it "ManifestAsset / Manifest / ManifestPack / ManifestLicense 全部欄位可存取" $ do
      maId sampleManifestAsset `shouldBe` idOf "ast-3f9c1d20"
      maKey sampleManifestAsset `shouldBe` AssetKey "ui_gui_travel-book-frame_001"
      maPath sampleManifestAsset `shouldBe` "sprites/ui_gui_travel-book-frame_001.png"
      maType sampleManifestAsset `shouldBe` TypeKey "asset-image"
      maVault sampleManifestAsset `shouldBe` vaultOf "vlt-a0c4e1f8"
      maPack sampleManifestAsset `shouldBe` Just (refOf "vlt-a0c4e1f8:pck-11223344")
      maLicense sampleManifestAsset2 `shouldBe` Nothing
      mProject sampleManifest `shouldBe` "Circle"
      length (mAssets sampleManifest) `shouldBe` 2
      mpId samplePack `shouldBe` refOf "vlt-a0c4e1f8:pck-11223344"
      mlId sampleLicense `shouldBe` refOf "vlt-a0c4e1f8:lic-55667788"

    it "StoryManifest / StoryManifestEntry 全部欄位可存取" $ do
      smProject sampleStoryManifest `shouldBe` "Circle"
      smeRef sampleStoryEntry `shouldBe` refOf "vlt-9d2e5b70:ent-7f3b2a91"
      smeTitle sampleStoryEntry `shouldBe` "琳達"
      smeRevision sampleStoryEntry `shouldBe` Revision 3

    it "ImageMeta / AudioMeta 可建構" $ do
      imWidth (ImageMeta 1 2 True Nothing) `shouldBe` 1
      imColorCount (ImageMeta 1 2 True (Just 9)) `shouldBe` Just 9
      amChannels (AudioMeta 1 2 3) `shouldBe` 3

    it "AssetKey 可比較與排序(Ord)" $ do
      compare (AssetKey "a") (AssetKey "b") `shouldBe` LT
      sort [AssetKey "b", AssetKey "a"] `shouldBe` [AssetKey "a", AssetKey "b"]
      (AssetKey "a" == AssetKey "a") `shouldBe` True

  describe "STEP-2 JSON 欄位名" $ do
    it "toJSON ManifestAsset 恰好九個鍵(id/key/path/type/sha256/vault/pack/license/meta)" $ do
      keysOf sampleManifestAsset
        `shouldMatchList` ["id", "key", "path", "type", "sha256", "vault", "pack", "license", "meta"]
      -- pack / license 為 Nothing 時鍵仍在(值是 null,不是省略)
      keysOf sampleManifestAsset2
        `shouldMatchList` ["id", "key", "path", "type", "sha256", "vault", "pack", "license", "meta"]

    it "toJSON StoryManifestEntry 恰好五個鍵(ref/title/summary/purpose/revision)" $
      keysOf sampleStoryEntry `shouldMatchList` ["ref", "title", "summary", "purpose", "revision"]

    it "Manifest / StoryManifest round-trip(decode . encode == Just x)" $ do
      decode (encode sampleManifest) `shouldBe` Just sampleManifest
      decode (encode sampleStoryManifest) `shouldBe` Just sampleStoryManifest

  describe "ManifestAsset pack / license 為 Ref(F003 階段一閘門 ASM-2)" $ do
    it "toJSON 編碼為 \"<vault>:<id>\"" $ do
      keysOf sampleManifestAsset `shouldMatchList` ["id", "key", "path", "type", "sha256", "vault", "pack", "license", "meta"]
      case toJSON sampleManifestAsset of
        Object o -> do
          KM.lookup "pack" o `shouldBe` Just (String "vlt-a0c4e1f8:pck-11223344")
          KM.lookup "license" o `shouldBe` Just (String "vlt-a0c4e1f8:lic-55667788")
        other -> expectationFailure ("預期物件,得到:" <> show other)

    -- 'Aapms.Core.Id.parseRef' 對不帶 vault 前綴的裸 id 不會拒絕:單段輸入被視為
    -- 「本 vault」參照(refVault = Nothing),而不是報錯。因此 FromJSON 也正確
    -- 接受裸 id,不需要另外拒絕——這條測試證明的是「正確處理」而非「拒絕」。
    it "FromJSON 接受不帶 vault 前綴的裸 id,視為本 vault 參照(refVault = Nothing)" $ do
      let bareIdJson =
            object
              [ "id" .= idOf "ast-3f9c1d20"
              , "key" .= AssetKey "ui_gui_travel-book-frame_001"
              , "path" .= ("sprites/x.png" :: String)
              , "type" .= TypeKey "asset-image"
              , "sha256" .= Sha256 "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a1"
              , "vault" .= vaultOf "vlt-a0c4e1f8"
              , "pack" .= ("pck-11223344" :: String)
              , "license" .= ("lic-55667788" :: String)
              , "meta" .= object ["width" .= (1 :: Int), "height" .= (1 :: Int), "hasAlpha" .= False]
              ]
      case fromJSON bareIdJson :: Result ManifestAsset of
        Success a -> do
          maPack a `shouldBe` Just (Ref Nothing (idOf "pck-11223344"))
          maLicense a `shouldBe` Just (Ref Nothing (idOf "lic-55667788"))
        Error msg -> expectationFailure ("預期裸 id 被接受為本 vault 參照,卻解析失敗:" <> msg)

  describe "manifest 內部引用圖 vault 化(二輪裁決補述,ManifestPack/ManifestLicense.id 改 Ref)" $ do
    it "asset 的 pack 能以 Ref 相等唯一對應到頂層 packs 的某一筆(不剝前綴比 Id)" $ do
      let found = [p | p <- mPacks sampleManifest, Just (mpId p) == maPack sampleManifestAsset]
      map mpId found `shouldBe` [refOf "vlt-a0c4e1f8:pck-11223344"]

    it "兩個不同 vault 的同號 pack 在同一份 manifest 裡是兩筆可區分的項目" $ do
      let packA = samplePack {mpId = refOf "vlt-aaaaaaaa:pck-11223344"}
          packB = samplePack {mpId = refOf "vlt-bbbbbbbb:pck-11223344"}
          packs = [packA, packB]
      -- 兩筆的 Ref 整體不相等(vault 段不同),即使剝掉前綴後的短 id 相同
      (mpId packA == mpId packB) `shouldBe` False
      -- 各自能被自己的完整 Ref 唯一查到,不會撞名
      [p | p <- packs, mpId p == refOf "vlt-aaaaaaaa:pck-11223344"] `shouldBe` [packA]
      [p | p <- packs, mpId p == refOf "vlt-bbbbbbbb:pck-11223344"] `shouldBe` [packB]
      length packs `shouldBe` 2

  describe "STEP-4 golden files 是合法 JSON 且 schemaVersion = 2" $ do
    it "manifest.golden.json" $ do
      bs <- readGolden "manifest.golden.json"
      case eitherDecodeStrict bs :: Either String Value of
        Right (Object o) -> KM.lookup "schemaVersion" o `shouldBe` Just (Number 2)
        other -> expectationFailure ("預期合法 JSON 物件,得到:" <> show other)

    it "story-manifest.golden.json" $ do
      bs <- readGolden "story-manifest.golden.json"
      case eitherDecodeStrict bs :: Either String Value of
        Right (Object o) -> KM.lookup "schemaVersion" o `shouldBe` Just (Number 2)
        other -> expectationFailure ("預期合法 JSON 物件,得到:" <> show other)

  describe "STEP-5 golden roundtrip" $ do
    it "manifest.golden.json decode -> encode 與原始檔語意相同" $ do
      bs <- readGolden "manifest.golden.json"
      origVal <- either fail pure (eitherDecodeStrict bs :: Either String Value)
      m <- either fail pure (eitherDecodeStrict bs :: Either String Manifest)
      toJSON m `shouldBe` origVal
      (decode (encode m) :: Maybe Manifest) `shouldBe` Just m

    it "story-manifest.golden.json decode -> encode 與原始檔語意相同" $ do
      bs <- readGolden "story-manifest.golden.json"
      origVal <- either fail pure (eitherDecodeStrict bs :: Either String Value)
      sm <- either fail pure (eitherDecodeStrict bs :: Either String StoryManifest)
      toJSON sm `shouldBe` origVal
      (decode (encode sm) :: Maybe StoryManifest) `shouldBe` Just sm

  describe "STEP-6 schemaVersion 錯誤路徑" $ do
    it "Manifest 對 schemaVersion = 1 / 3 回 Left,訊息含「請重新產生」" $ do
      bs <- readGolden "manifest.golden.json"
      origVal <- either fail pure (eitherDecodeStrict bs :: Either String Value)
      mapM_
        ( \n -> case fromJSON (withSchemaVersion n origVal) :: Result Manifest of
            Error msg -> msg `shouldContain` "請重新產生"
            Success _ -> expectationFailure ("schemaVersion = " <> show n <> " 應該被拒絕")
        )
        [1, 3 :: Int]

    it "StoryManifest 對 schemaVersion = 1 / 3 回 Left,訊息含「請重新產生」" $ do
      bs <- readGolden "story-manifest.golden.json"
      origVal <- either fail pure (eitherDecodeStrict bs :: Either String Value)
      mapM_
        ( \n -> case fromJSON (withSchemaVersion n origVal) :: Result StoryManifest of
            Error msg -> msg `shouldContain` "請重新產生"
            Success _ -> expectationFailure ("schemaVersion = " <> show n <> " 應該被拒絕")
        )
        [1, 3 :: Int]

  describe "STEP-7 manifestIndex" $ do
    it "以 AssetKey 建表,查得到已知 key、查不到不存在的 key" $ do
      let idx = manifestIndex sampleManifest
      M.lookup (AssetKey "ui_gui_travel-book-frame_001") idx `shouldBe` Just sampleManifestAsset
      M.lookup (AssetKey "sfx_ui_button-click_001") idx `shouldBe` Just sampleManifestAsset2
      M.lookup (AssetKey "does-not-exist") idx `shouldBe` Nothing

  describe "STEP-8 imageMeta / audioMeta 型別化讀取" $ do
    it "合法 image Value 回 Just 且四欄正確" $
      imageMeta
        (object ["width" .= (512 :: Int), "height" .= (512 :: Int), "hasAlpha" .= True, "colorCount" .= (128 :: Int)])
        `shouldBe` Just (ImageMeta 512 512 True (Just 128))

    it "imColorCount 缺漏時 imageMeta 仍解析成功(Nothing)" $
      imageMeta (object ["width" .= (64 :: Int), "height" .= (64 :: Int), "hasAlpha" .= False])
        `shouldBe` Just (ImageMeta 64 64 False Nothing)

    it "合法 audio Value 回 Just 且三欄正確" $
      audioMeta (object ["durationMs" .= (240 :: Int), "sampleRate" .= (44100 :: Int), "channels" .= (2 :: Int)])
        `shouldBe` Just (AudioMeta 240 44100 2)

    it "image Value 餵給 audioMeta 回 Nothing(反之亦然)" $ do
      audioMeta (object ["width" .= (512 :: Int), "height" .= (512 :: Int), "hasAlpha" .= True])
        `shouldBe` Nothing
      imageMeta (object ["durationMs" .= (240 :: Int), "sampleRate" .= (44100 :: Int), "channels" .= (2 :: Int)])
        `shouldBe` Nothing
