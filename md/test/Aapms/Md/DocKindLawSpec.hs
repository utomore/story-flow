-- | graph-core/F004(重跑)Law LAW-22:'docKind' 只由檔案層 @type@ 決定。
--
-- __委派備註__:同 "Aapms.Md.EditLawsSpec",依賴 @hedgehog@ \/
-- @hspec-hedgehog@,@md\/aapms-md.cabal@ 尚未接線,__未列進__
-- @other-modules@,本次委派無法用 @cabal build@ 實際編譯\/執行。
--
-- 'docKind'\/'Aapms.Md.Parse.resolveDocKind' 本次未改動,預期__綠__。
-- Example 10(五份具體 frontmatter)是純 hspec、已在 "Aapms.Md.DocKindSpec"
-- 覆蓋且__已用 cabal 驗證通過__——本檔是 LAW-22 的全稱量詞版本。
--
-- __spec 對照__:@LAW-22 docKind 只由檔案層 type 決定 -> prop_LAW22@
module Aapms.Md.DocKindLawSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Md
import Aapms.Md.Fixtures (docOf)

-- | 檔案層 @type@ 欄位的六種代表性情形。
data TypeSpec
  = Reserved Text DocKind
  | -- | 非保留字的合法字串(不會被 YAML 解成 Bool/Null/Number 的純字母 + CJK)
    CustomString Text
  | -- | 完全沒有 @type@ 這個鍵
    Missing
  | -- | @type@ 存在,但值不是字串(數字)
    NonString
  deriving stock (Show)

genTypeSpec :: Gen TypeSpec
genTypeSpec =
  Gen.choice
    [ pure (Reserved "level" LevelDoc)
    , pure (Reserved "asset-pack" PackDoc)
    , pure (Reserved "asset-license" LicenseDoc)
    , CustomString <$> genCustomTypeText
    , pure Missing
    , pure NonString
    ]

-- | 純字母 + CJK(不含數字/空白),避開三個保留字與 YAML 會特殊解讀的字面值
-- (@true@\/@false@\/@null@\/@yes@\/@no@)——確保解出來的一定是 'Data.Aeson.String'。
genCustomTypeText :: Gen Text
genCustomTypeText =
  Gen.filter
    (`notElem` ["level", "asset-pack", "asset-license", "true", "false", "null", "yes", "no"])
    (Gen.text (Range.linear 1 8) (Gen.choice [Gen.alpha, Gen.enum '\x4E00' '\x9FFF']))

expectedKind :: TypeSpec -> DocKind
expectedKind (Reserved _ k) = k
expectedKind (CustomString _) = TopicDoc
expectedKind Missing = TopicDoc
expectedKind NonString = TopicDoc

buildFrontmatter :: TypeSpec -> Text
buildFrontmatter ts =
  T.unlines $
    ["---", "id: ent-00000001", "vault: v"]
      ++ typeLine
      ++ ["title: t", "created: 2026-08-16", "updated: 2026-08-16", "---"]
  where
    typeLine = case ts of
      Reserved t _ -> ["type: " <> t]
      CustomString t -> ["type: " <> t]
      Missing -> []
      NonString -> ["type: 42"]

spec :: Spec
spec = describe "graph-core/F004 重跑:docKind Law" $
  it "LAW-22: docKind 只由檔案層 type 決定(三個保留字 / 其餘一律 TopicDoc)" $
    hedgehog $ do
      ts <- forAll genTypeSpec
      docKind (docOf (buildFrontmatter ts)) === expectedKind ts
