-- | graph-core/F002 STEP-2\/STEP-3(重建 'Aapms.Core.Registry':@family@ 與 'TypeDecl'、
-- 'checkMeta' 對 entity 與 asset 兩族)與 STEP-11(保留鍵、錯誤彙整)的對照測試。
--
-- F001 刪除的舊 @RegistrySpec.hs@(對照舊 @EntityTypeSpec@ \/ @checkEntity@)
-- 整份被本檔取代(DEC-6:舊單元測試隨模組重寫,被取代的舊 Spec 刪掉)。
module Aapms.Core.RegistrySpec (spec) where

import Aapms.Core.AnyNode
import Aapms.Core.Asset
import Aapms.Core.Entity
import Aapms.Core.Fixtures
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Core.Naming
import Aapms.Core.Registry
import qualified Data.Text as T
import Test.Hspec

-- | 'TypeRegistry' 刻意不透明、沒有 'Show' \/ 'Eq' 實例('shouldBe' 用不上),
-- 因此錯誤斷言一律先拆成 @[RegistryError]@ 再比對。
errsOf :: Either [RegistryError] TypeRegistry -> [RegistryError]
errsOf = either id (const [])

segOf :: T.Text -> Segment
segOf t = case mkSegment t of
  Right s -> s
  Left e -> error ("fixture 的 segment 不合法:" <> show e)

-- | entity 族宣告 fixture,對照真實的 @character-fragment.toml@。
characterDecl :: TypeDecl
characterDecl =
  TypeDecl
    { tdKey = typeOf "character-fragment"
    , tdName = "角色片段"
    , tdFamily = FEntity
    , tdDir = Just "characters"
    , tdOwnerType = Just (typeOf "character")
    , tdAllowedLinks = [PartOf, Contradicts]
    , tdStages = ["定位"]
    , tdFields = [FieldDecl "summary" True "一句話說明"]
    , tdNameKinds = []
    }

-- | asset 族宣告 fixture,對照真實的 @asset-image.toml@。
assetImageDecl :: TypeDecl
assetImageDecl =
  TypeDecl
    { tdKey = typeOf "asset-image"
    , tdName = "圖片素材"
    , tdFamily = FAsset
    , tdDir = Nothing
    , tdOwnerType = Nothing
    , tdAllowedLinks = [Depicts]
    , tdStages = []
    , tdFields = [FieldDecl "summary" True "一句話說明"]
    , tdNameKinds = [segOf "spr", segOf "tex", segOf "atlas", segOf "ui"]
    }

-- | asset 族但 @tdNameKinds = []@,對照真實的 @asset-archive.toml@(F002
-- 待確認假設 ASM-3 的驗收對象)。
assetArchiveDecl :: TypeDecl
assetArchiveDecl =
  TypeDecl
    { tdKey = typeOf "asset-archive"
    , tdName = "壓縮檔素材"
    , tdFamily = FAsset
    , tdDir = Nothing
    , tdOwnerType = Nothing
    , tdAllowedLinks = [Depicts]
    , tdStages = []
    , tdFields = []
    , tdNameKinds = []
    }

spec :: Spec
spec = do
  describe "STEP-2 test_family_and_typedecl" $ do
    it "renderFamily / parseFamily 互為反函式" $ do
      renderFamily FEntity `shouldBe` "entity"
      renderFamily FAsset `shouldBe` "asset"
      parseFamily "entity" `shouldBe` Just FEntity
      parseFamily "asset" `shouldBe` Just FAsset

    it "parseFamily 對未知字串回 Nothing" $
      parseFamily "weird" `shouldBe` Nothing

    it "reservedTypeKeys 含 level / asset-pack / asset-license 三項" $
      reservedTypeKeys `shouldBe` [typeOf "level", typeOf "asset-pack", typeOf "asset-license"]

    it "buildRegistry 對合法宣告成功,lookupType / listTypes 查得回來" $
      case buildRegistry [characterDecl, assetImageDecl] of
        Right reg -> do
          lookupType reg (typeOf "character-fragment") `shouldBe` Just characterDecl
          lookupType reg (typeOf "asset-image") `shouldBe` Just assetImageDecl
          map tdKey (listTypes reg) `shouldBe` [typeOf "asset-image", typeOf "character-fragment"]
        Left es -> expectationFailure (show es)

    it "buildRegistry 對重複鍵回 DuplicateTypeKey" $
      errsOf (buildRegistry [characterDecl, characterDecl])
        `shouldBe` [DuplicateTypeKey (typeOf "character-fragment")]

    it "buildRegistry 對空鍵回 EmptyTypeKey" $
      errsOf (buildRegistry [characterDecl {tdKey = typeOf ""}])
        `shouldBe` [EmptyTypeKey]

    it "buildRegistry 對三個保留鍵各回 ReservedTypeKey" $ do
      errsOf (buildRegistry [characterDecl {tdKey = typeOf "level"}])
        `shouldBe` [ReservedTypeKey (typeOf "level")]
      errsOf (buildRegistry [characterDecl {tdKey = typeOf "asset-pack"}])
        `shouldBe` [ReservedTypeKey (typeOf "asset-pack")]
      errsOf (buildRegistry [characterDecl {tdKey = typeOf "asset-license"}])
        `shouldBe` [ReservedTypeKey (typeOf "asset-license")]

    it "buildRegistry 對不存在的 Meta 欄位名回 UnknownMetaField" $
      errsOf (buildRegistry [characterDecl {tdFields = [FieldDecl "no-such-field" True "?"]}])
        `shouldBe` [UnknownMetaField (typeOf "character-fragment") "no-such-field"]

    it "buildRegistry 對同一個 owner_type 兩種 dir 回 ConflictingOwnerDir" $
      errsOf
        ( buildRegistry
            [ characterDecl {tdKey = typeOf "character-a", tdOwnerType = Just (typeOf "character"), tdDir = Just "a"}
            , characterDecl {tdKey = typeOf "character-b", tdOwnerType = Just (typeOf "character"), tdDir = Just "b"}
            ]
        )
        `shouldBe` [ConflictingOwnerDir (typeOf "character")]

    it "buildRegistry 一次回報全部問題,不是只回第一個" $
      length (errsOf (buildRegistry [characterDecl {tdKey = typeOf "level"}, characterDecl {tdKey = typeOf ""}]))
        `shouldBe` 2

    it "lookupDir 對主體型別鍵走 owner_type 那一半" $
      case buildRegistry [characterDecl] of
        Right reg -> lookupDir reg (typeOf "character") `shouldBe` Just "characters"
        Left es -> expectationFailure (show es)

    it "renderRegistryError 對 RegistryErrors 逐行攤平" $
      renderRegistryError (RegistryErrors [EmptyTypeKey, ReservedTypeKey (typeOf "level")])
        `shouldBe` T.intercalate "\n" [renderRegistryError EmptyTypeKey, renderRegistryError (ReservedTypeKey (typeOf "level"))]

  describe "STEP-3 test_checkmeta_entity_and_asset" $ do
    it "型別不在註冊表內回 UnknownNodeType" $
      case buildRegistry [] of
        Right reg -> checkMeta reg (NEntity sampleEntity) `shouldBe` [UnknownNodeType (typeOf "character-fragment")]
        Left es -> expectationFailure (show es)

    it "entity:缺必填欄位回 MissingRequiredField" $
      case buildRegistry [characterDecl] of
        Right reg -> do
          let ent =
                sampleEntity
                  { entMeta = (entMeta sampleEntity) {metaType = typeOf "character-fragment", metaSummary = ""}
                  }
          checkMeta reg (NEntity ent)
            `shouldSatisfy` (MissingRequiredField (typeOf "character-fragment") "summary" `elem`)
        Left es -> expectationFailure (show es)

    it "entity:必填欄位有值時不產生 MissingRequiredField" $
      case buildRegistry [characterDecl] of
        Right reg -> do
          let ent = sampleEntity {entMeta = (entMeta sampleEntity) {metaType = typeOf "character-fragment"}}
          [() | MissingRequiredField _ _ <- checkMeta reg (NEntity ent)] `shouldBe` []
        Left es -> expectationFailure (show es)

    it "entity:關聯不在 allowed_links 內回 LinkNotAllowed" $
      case buildRegistry [characterDecl] of
        Right reg -> do
          let ent =
                sampleEntity
                  { entMeta =
                      (entMeta sampleEntity)
                        { metaType = typeOf "character-fragment"
                        , metaLinks = [Link OccursIn (refOf "ent-8b20") Nothing]
                        }
                  }
          checkMeta reg (NEntity ent)
            `shouldSatisfy` (LinkNotAllowed (typeOf "character-fragment") "occursIn" `elem`)
        Left es -> expectationFailure (show es)

    it "entity:allowed_links 空清單視為未宣告限制,不產生 LinkNotAllowed" $
      case buildRegistry [characterDecl {tdAllowedLinks = []}] of
        Right reg -> do
          let ent =
                sampleEntity
                  { entMeta =
                      (entMeta sampleEntity)
                        { metaType = typeOf "character-fragment"
                        , metaLinks = [Link OccursIn (refOf "ent-8b20") Nothing]
                        }
                  }
          [() | LinkNotAllowed _ _ <- checkMeta reg (NEntity ent)] `shouldBe` []
        Left es -> expectationFailure (show es)

    it "asset:name_kinds 內的 LogicalName 不產生 NameKindNotAllowed" $
      case buildRegistry [assetImageDecl] of
        Right reg -> [() | NameKindNotAllowed _ _ <- checkMeta reg (NAsset sampleAsset)] `shouldBe` []
        Left es -> expectationFailure (show es)

    it "asset:name_kinds 外的 LogicalName 產生 NameKindNotAllowed" $
      case buildRegistry [assetImageDecl] of
        Right reg -> do
          let bad = sampleAsset {astName = Just (LogicalName "fnt_rune_runic-codex_100")}
          checkMeta reg (NAsset bad)
            `shouldSatisfy` (NameKindNotAllowed (typeOf "asset-image") "fnt" `elem`)
        Left es -> expectationFailure (show es)

    it "asset:astName = Nothing 不產生 NameKindNotAllowed" $
      case buildRegistry [assetImageDecl] of
        Right reg -> do
          let noName = sampleAsset {astName = Nothing}
          [() | NameKindNotAllowed _ _ <- checkMeta reg (NAsset noName)] `shouldBe` []
        Left es -> expectationFailure (show es)

    it "asset:tdNameKinds 空清單視為未宣告限制(asset-archive,待確認假設 ASM-3)" $
      case buildRegistry [assetArchiveDecl] of
        Right reg -> do
          let arc =
                sampleAsset
                  { astMeta = (astMeta sampleAsset) {metaType = typeOf "asset-archive"}
                  , astName = Just (LogicalName "src_tool_random-thing_01a")
                  }
          [() | NameKindNotAllowed _ _ <- checkMeta reg (NAsset arc)] `shouldBe` []
        Left es -> expectationFailure (show es)
