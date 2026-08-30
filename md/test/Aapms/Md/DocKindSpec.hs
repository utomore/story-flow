-- | graph-core/F004(重跑):'docKind' 的判別規則(LAW-22)—— Example 10 逐字翻譯。
--
-- 'docKind' \/ 'Aapms.Md.Parse.resolveDocKind' 本次未改動('Aapms.Md.Document.DocKind'
-- 是既有匯出),所以本檔全部應為__綠__。純 hspec,不需要 hedgehog——五種具體
-- frontmatter 是 spec 逐字給定的 Example,不是全稱量詞;LAW-22 的全稱版本另見
-- "Aapms.Md.DocKindLawSpec"(hedgehog,未接線,見回報)。
module Aapms.Md.DocKindSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

-- | 五份 frontmatter 之五:完全沒有 type 欄位。
noTypeMd :: Text
noTypeMd =
  T.unlines
    [ "---"
    , "id: ent-0001"
    , "vault: liftgame"
    , "title: 沒有 type"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "完全沒有寫 type 欄位。"
    ]

spec :: Spec
spec = describe "docKind(graph-core/F004,Example 10)" $ do
  it "type: level -> LevelDoc" $
    docKind (docOf classroomMd) `shouldBe` LevelDoc

  it "type: asset-pack -> PackDoc" $
    docKind (docOf packMd) `shouldBe` PackDoc

  it "type: asset-license -> LicenseDoc" $
    docKind (docOf licensesMd) `shouldBe` LicenseDoc

  it "type: character(非保留字)-> TopicDoc" $
    docKind (docOf lindaMd) `shouldBe` TopicDoc

  it "完全沒有 type 欄位 -> TopicDoc(fallback)" $
    docKind (docOf noTypeMd) `shouldBe` TopicDoc
