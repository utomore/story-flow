-- | Manifest 是工具與**遊戲本體**之間的合約,所以這裡測的重點是
-- 「格式不會無聲改變」與「未知欄位不會炸掉舊版遊戲」。
module AssetDB.ManifestSpec (spec) where

import AssetDB.Id (parseULID)
import AssetDB.Manifest
import AssetDB.Naming (validateLogicalName)
import AssetDB.Types (AssetKind (..))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import Test.Hspec

spec :: Spec
spec = do
  describe "JSON 來回一致" $ do
    it "完整 manifest" $
      eitherDecode (encode sample) `shouldBe` Right sample

    it "欄位名稱是穩定的字面字串" $ do
      -- 這些 key 被遊戲端讀取。如果有人改了 Haskell 欄位名而 JSON 跟著變,
      -- 這條測試會擋下來。
      KM.keys (asObject sample)
        `shouldMatchList` ["schemaVersion", "project", "generatedAt", "assets", "packs", "licenses"]
      KM.keys (asObject sampleAsset)
        `shouldMatchList` ["id", "key", "path", "kind", "sha256", "pack", "license", "meta"]

  describe "schemaVersion 把關" $ do
    it "版本不符時拒絕載入,而不是留下一堆 Nothing" $ do
      let bumped = Object (KM.insert "schemaVersion" (Number 99) (asObject sample))
      (eitherDecode (encode bumped) :: Either String Manifest) `shouldSatisfy` isLeft

    it "錯誤訊息說得出該怎麼修" $
      case eitherDecode (encode (Object (KM.insert "schemaVersion" (Number 99) (asObject sample)))) of
        Right (_ :: Manifest) -> expectationFailure "應該要失敗"
        Left err -> err `shouldContain` "assetdb sync"

  describe "向前相容" $ do
    it "多出來的未知欄位會被忽略" $ do
      -- 之後版本加欄位時,舊版遊戲仍應該讀得動。
      let extended = Object (KM.insert "futureField" (String "whatever") (asObject sample))
      eitherDecode (encode extended) `shouldBe` Right sample

    it "packs 與 licenses 缺席時視為空清單" $ do
      let minimal =
            Object $
              KM.fromList
                [ ("schemaVersion", Number 1)
                , ("project", String "Circle")
                , ("generatedAt", toJSON sampleTime)
                , ("assets", Array mempty)
                ]
      case eitherDecode (encode minimal) of
        Right m -> (mPacks m, mLicenses m) `shouldBe` ([], [])
        Left err -> expectationFailure err

  describe "kind 專屬 metadata" $ do
    -- 這是「加音效不需重構」的實證:同一個 ManifestAsset 型別,
    -- meta 換一種形狀就是另一種資源,沒有任何核心型別要改。
    it "圖片 metadata 取得出來" $
      imageMeta sampleAsset `shouldBe` Just (ImageMeta 48 48 True (Just 27))

    it "同一筆資料用錯的取用函式會拿到 Nothing,不會爆炸" $
      audioMeta sampleAsset `shouldBe` Nothing

    it "音效素材走完全相同的路徑" $ do
      let sfx =
            sampleAsset
              { maKind = KAudio
              , maPath = "assets/audio/sfx/sfx_ui_click_01.wav"
              , maMeta = toJSON (AudioMeta 320 44100 2)
              }
      audioMeta sfx `shouldBe` Just (AudioMeta 320 44100 2)
      imageMeta sfx `shouldBe` Nothing
      eitherDecode (encode sfx) `shouldBe` Right sfx

    it "meta 缺席時不影響其他欄位" $ do
      let bare = sampleAsset {maMeta = Null}
      imageMeta bare `shouldBe` Nothing
      eitherDecode (encode bare) `shouldBe` Right bare

  describe "查表" $ do
    it "以邏輯名稱為 key" $
      Map.keys (manifestIndex sample) `shouldBe` ["ui_gui_travel-book-frame_01a"]

    it "lookupAsset 找得到" $ do
      let k = either (error . show) id (validateLogicalName "ui_gui_travel-book-frame_01a")
      fmap maSha256 (lookupAsset k sample) `shouldBe` Just "e3b0c44298fc1c14"

  describe "授權欄位" $ do
    it "commercial 是必填,沒有預設值" $ do
      -- 建專案的授權閘門依賴這個欄位。漏填時寧可解析失敗,
      -- 也不要預設成 True 而放行 Non-Commercial 素材。
      let noCommercial = Object (KM.fromList [("name", String "unknown")])
      (eitherDecode (encode noCommercial) :: Either String ManifestLicense) `shouldSatisfy` isLeft

--------------------------------------------------------------------------------

asObject :: ToJSON a => a -> Object
asObject x = case toJSON x of
  Object o -> o
  other -> error ("預期是 JSON 物件,收到 " <> show other)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 8 9) (secondsToDiffTime 43200)

sampleAsset :: ManifestAsset
sampleAsset =
  ManifestAsset
    { maId = either (error . T.unpack) id (parseULID "01JZ0000000000000000000000")
    , maKey = either (error . show) id (validateLogicalName "ui_gui_travel-book-frame_01a")
    , maPath = "assets/sprites/gui/ui_gui_travel-book-frame_01a.png"
    , maKind = KImage
    , maSha256 = "e3b0c44298fc1c14"
    , maPack = Just "Crusenho Complete GUI"
    , maLicense = Just "itch.io Commercial"
    , maMeta = toJSON (ImageMeta 48 48 True (Just 27))
    }

sample :: Manifest
sample =
  Manifest
    { mSchemaVersion = currentSchemaVersion
    , mProject = "Circle"
    , mGeneratedAt = sampleTime
    , mAssets = [sampleAsset]
    , mPacks =
        [ ManifestPack
            { mpName = "Crusenho Complete GUI"
            , mpVendor = Just "Crusenho"
            , mpSourceUrl = Just "https://crusenho.itch.io/complete-gui-essential-pack"
            , mpVersion = Nothing
            , mpLicense = Just "itch.io Commercial"
            }
        ]
    , mLicenses =
        [ ManifestLicense
            { mlName = "itch.io Commercial"
            , mlCommercial = True
            , mlAttributionRequired = False
            , mlNotes = Nothing
            }
        ]
    }
