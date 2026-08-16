-- | func-0002 T8 的對照測試:型別註冊表的純驗證與 Entity 檢查。
module StoryFlow.Core.RegistrySpec (spec) where

import Data.Either (isRight)
import StoryFlow.Core.Entity
import StoryFlow.Core.Fixtures
import StoryFlow.Core.Link
import StoryFlow.Core.Meta
import StoryFlow.Core.Registry
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
    }

loreFragment :: EntityTypeSpec
loreFragment =
  characterFragment {etsKey = "lore-fragment", etsName = "世界觀片段"}

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

  describe "checkEntity —— 警告而非錯誤(ADR-0005 引導而非阻擋)" $ do
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
