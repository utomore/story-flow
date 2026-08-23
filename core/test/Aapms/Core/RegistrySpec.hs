-- | entity-graph-core/F002 T8 的對照測試:型別註冊表的純驗證與 Entity 檢查。
module Aapms.Core.RegistrySpec (spec) where

import Data.Either (isRight)
import Aapms.Core.Entity
import Aapms.Core.Fixtures
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Core.Registry
import Test.Hspec

characterFragment :: EntityTypeSpec
characterFragment =
  EntityTypeSpec
    { etsKey = "character-fragment"
    , etsName = "角色片段"
    , etsFields =
        [ FieldSpec "summary" True "一句話說明這個片段講角色的哪一面"
        , FieldSpec "timeline" False "屬於故事內的哪個時期"
        ]
    , etsAllowedLinks = [PartOf, OccursIn, Contradicts, Supersedes, References]
    , etsStages = ["定位", "外貌與舉止"]
    , etsDir = Just "characters"
    , etsOwnerType = Just "character"
    }

loreFragment :: EntityTypeSpec
loreFragment =
  characterFragment
    { etsKey = "lore-fragment"
    , etsName = "世界觀片段"
    , etsDir = Just "lore"
    , etsOwnerType = Just "lore"
    }

-- | 從合法宣告集建出來的註冊表。
goodRegistry :: TypeRegistry
goodRegistry = case validateRegistry [characterFragment, loreFragment] of
  Right r -> r
  Left es -> error ("這組宣告應該是合法的,卻得到:" <> show es)

-- | 一個合規的角色片段 Entity。
goodEntity :: Entity
goodEntity =
  Entity
    { entMeta =
        (metaOf "ent-7f3a" "外貌")
          { metaType = "character-fragment"
          , metaSummary = "銀灰短髮,左眼下方有織紋刺青"
          , metaLinks = [Link PartOf entLinda Nothing]
          }
    , entBody = "銀灰短髮剪到耳際……"
    }

errsOf :: [EntityTypeSpec] -> [RegistryError]
errsOf = either id (const []) . validateRegistry

spec :: Spec
spec = do
  describe "validateRegistry" $ do
    it "合法宣告集通過" $
      isRight (validateRegistry [characterFragment, loreFragment])
        `shouldBe` True

    it "空清單得到空註冊表,不是錯誤" $
      fmap listTypes (validateRegistry []) `shouldBe` Right []

    it "重複的 key 回 DuplicateTypeKey" $
      errsOf [characterFragment, characterFragment]
        `shouldBe` [DuplicateTypeKey "character-fragment"]

    it "欄位名打錯(summry)回 UnknownMetaField,並指出是哪個型別" $
      errsOf
        [ characterFragment
            { etsFields = [FieldSpec "summry" True "打錯字的欄位"]
            }
        ]
        `shouldBe` [UnknownMetaField "character-fragment" "summry"]

    it "空的 key 回 EmptyTypeKey" $
      errsOf [characterFragment {etsKey = "  "}]
        `shouldContain` [EmptyTypeKey]

    it "佔用保留鍵 level 回 ReservedTypeKey" $
      errsOf [characterFragment {etsKey = "level"}]
        `shouldContain` [ReservedTypeKey "level"]

    it "allowed_links 含自訂關聯不產生錯誤 —— 自訂關聯本來就合法" $
      isRight
        ( validateRegistry
            [ characterFragment
                { etsAllowedLinks = [PartOf, Custom "師承於"]
                }
            ]
        )
        `shouldBe` True

    it "一次回報全部錯誤而非第一個" $
      let bad =
            [ characterFragment {etsFields = [FieldSpec "summry" True ""]}
            , loreFragment {etsFields = [FieldSpec "titel" True ""]}
            ]
       in length (errsOf bad) `shouldBe` 2

  describe "lookupType / listTypes" $ do
    it "查得到已宣告的型別" $
      fmap etsName (lookupType "character-fragment" goodRegistry)
        `shouldBe` Just "角色片段"

    it "查不到未宣告的型別" $
      fmap etsName (lookupType "npc" goodRegistry) `shouldBe` Nothing

    it "listTypes 依 key 排序,輸出穩定" $
      map etsKey (listTypes goodRegistry)
        `shouldBe` ["character-fragment", "lore-fragment"]

  -- entity-graph-core/F005 T4:lookupDir 以 key 或 owner_type 命中,衝突宣告被擋下
  describe "lookupDir" $ do
    it "以 key 精確命中" $
      lookupDir "character-fragment" goodRegistry `shouldBe` Just "characters"

    it "以 owner_type 命中 —— 檔案層主體的 type 不在註冊表裡" $
      lookupDir "character" goodRegistry `shouldBe` Just "characters"

    it "兩個鍵指向同一筆宣告,目錄一致" $
      lookupDir "character" goodRegistry
        `shouldBe` lookupDir "character-fragment" goodRegistry

    it "沒宣告 dir 的型別回 Nothing,由呼叫端決定丟哪裡" $
      let reg = case validateRegistry [characterFragment {etsDir = Nothing}] of
            Right r -> r
            Left es -> error (show es)
       in lookupDir "character-fragment" reg `shouldBe` Nothing

    it "查不到的型別回 Nothing" $
      lookupDir "npc" goodRegistry `shouldBe` Nothing

    it "同一個 owner_type 被兩份宣告以不同 dir 認領時回 ConflictingOwnerDir" $
      errsOf
        [ characterFragment
        , loreFragment {etsOwnerType = Just "character", etsDir = Just "lore"}
        ]
        `shouldBe` [ConflictingOwnerDir "character"]

    it "同一個 owner_type 但 dir 相同不算衝突" $
      isRight
        ( validateRegistry
            [ characterFragment
            , loreFragment {etsOwnerType = Just "character", etsDir = Just "characters"}
            ]
        )
        `shouldBe` True

    it "兩份宣告共用同一個 dir 但 owner_type 不同不算衝突(lore/ 放兩種片段)" $
      isRight
        ( validateRegistry
            [ characterFragment {etsDir = Just "lore", etsOwnerType = Just "lore"}
            , loreFragment {etsOwnerType = Just "plot"}
            ]
        )
        `shouldBe` True

    it "缺 dir 與 owner_type 的舊格式宣告仍然通過驗證" $
      isRight
        ( validateRegistry
            [characterFragment {etsDir = Nothing, etsOwnerType = Nothing}]
        )
        `shouldBe` True

  describe "checkEntity —— 警告而非錯誤(ADR-005 引導而非阻擋)" $ do
    it "合規的 Entity 回空清單" $
      checkEntity goodRegistry goodEntity `shouldBe` []

    it "缺少必填的 summary 回警告" $
      let e = goodEntity {entMeta = (entMeta goodEntity) {metaSummary = ""}}
       in checkEntity goodRegistry e
            `shouldBe` [MissingRequiredField "character-fragment" "summary"]

    it "只有空白的 summary 也算沒填" $
      let e = goodEntity {entMeta = (entMeta goodEntity) {metaSummary = "   "}}
       in checkEntity goodRegistry e
            `shouldBe` [MissingRequiredField "character-fragment" "summary"]

    it "非必填欄位沒填不產生警告" $
      let e =
            goodEntity
              { entMeta = (entMeta goodEntity) {metaTimeline = emptyTimeline}
              }
       in checkEntity goodRegistry e `shouldBe` []

    it "使用未列於 allowed_links 的關聯回警告" $
      let e =
            goodEntity
              { entMeta =
                  (entMeta goodEntity)
                    { metaLinks = [Link Involves entLinda Nothing]
                    }
              }
       in checkEntity goodRegistry e
            `shouldBe` [LinkNotAllowed "character-fragment" "involves"]

    it "自訂關聯不在 allowed_links 內時同樣回警告(可查詢但不推論)" $
      let e =
            goodEntity
              { entMeta =
                  (entMeta goodEntity)
                    { metaLinks = [Link (Custom "師承於") entLinda Nothing]
                    }
              }
       in checkEntity goodRegistry e
            `shouldBe` [LinkNotAllowed "character-fragment" "師承於"]

    it "型別不在註冊表內回 UnknownEntityType" $
      let e = goodEntity {entMeta = (entMeta goodEntity) {metaType = "npc"}}
       in checkEntity goodRegistry e `shouldBe` [UnknownEntityType "npc"]

    it "allowed_links 為空視為未宣告限制,不產生關聯警告" $
      let reg = case validateRegistry [characterFragment {etsAllowedLinks = []}] of
            Right r -> r
            Left es -> error (show es)
          e =
            goodEntity
              { entMeta =
                  (entMeta goodEntity)
                    { metaLinks = [Link Involves entLinda Nothing]
                    }
              }
       in checkEntity reg e `shouldBe` []

    it "同時缺欄位又用了不允許的關聯時,兩種警告都回" $
      let e =
            goodEntity
              { entMeta =
                  (entMeta goodEntity)
                    { metaSummary = ""
                    , metaLinks = [Link Involves entLinda Nothing]
                    }
              }
       in checkEntity goodRegistry e
            `shouldBe` [ MissingRequiredField "character-fragment" "summary"
                       , LinkNotAllowed "character-fragment" "involves"
                       ]
