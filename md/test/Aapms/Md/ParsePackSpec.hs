-- | STEP-9:'toPack' —— pack.md 的檔案層直接解成 'Pack'、每節解成 'Asset',節層
-- @type@ 不繼承且缺漏是錯誤(graph-core/F004,design.md「節層繼承規則」表格)。
module Aapms.Md.ParsePackSpec (spec) where

import qualified Data.Text as T
import Aapms.Core.Asset
import Aapms.Core.Id (Ref (..))
import Aapms.Core.Meta
import Aapms.Core.Pack
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

doc :: Document
doc = docOf packMd

parsed :: (Pack, [Asset])
parsed = packOf doc

pack :: Pack
pack = fst parsed

assets :: [Asset]
assets = snd parsed

assetAt :: Int -> Asset
assetAt = (assets !!)

spec :: Spec
spec = do
  describe "檔案的判別" $
    it "type: asset-pack 判為 PackDoc" $
      docKind doc `shouldBe` PackDoc

  describe "檔案層直接解成 Pack" $ do
    it "Meta 欄位逐一比對" $ do
      let m = pckMeta pack
      metaId m `shouldBe` idOf "pck-4a1e9c02"
      metaVault m `shouldBe` vaultOf "liftgame-assets"
      metaType m `shouldBe` typeOf "asset-pack"
      metaTitle m `shouldBe` "Kenney UI Pack"
      metaStatus m `shouldBe` Canon
      metaTags m `shouldBe` ["商用"]
      metaRevision m `shouldBe` Revision 4

    it "pack 專屬欄位逐一比對" $ do
      pckVendor pack `shouldBe` Just "kenney"
      pckArchive pack `shouldBe` Just "library/packs/kenney/ui-pack/kenney_ui-pack.zip"
      pckSha256 pack `shouldBe` Just (Sha256 "3c1f9a2b")
      pckLicense pack `shouldBe` Just (Ref Nothing (idOf "lic-00000001"))

    it "body 是 preamble 的內容" $
      pckBody pack `shouldSatisfy` T.isInfixOf "掃描時產生的摘要"

  describe "得 2 個 Asset" $
    it "asset 數量正確" $
      length assets `shouldBe` 2

  describe "asset 節 ast-3f9c1d20(panel_book.png)" $ do
    it "type 由節層寫明(不繼承 asset-pack)" $
      metaType (astMeta (assetAt 0)) `shouldBe` typeOf "asset-image"

    it "vault / status 繼承檔案層" $ do
      metaVault (astMeta (assetAt 0)) `shouldBe` vaultOf "liftgame-assets"
      metaStatus (astMeta (assetAt 0)) `shouldBe` Canon

    it "tags 聯集去重(檔案層「商用」+ 節層「gui, book」)" $
      metaTags (astMeta (assetAt 0)) `shouldBe` ["商用", "gui", "book"]

    it "asset 專屬欄位:name / sha256 / entry / kind meta" $ do
      astName (assetAt 0) `shouldBe` Just (LogicalName "ui_gui_travel-book-frame_001")
      astSha256 (assetAt 0) `shouldBe` Sha256 "9f3ac81b"
      astEntry (assetAt 0) `shouldBe` "PNG/panel_book.png"

  describe "asset 節 ast-3f9c1d21(panel_scroll.png,只有必填欄位)" $ do
    it "name 缺漏是 Nothing" $
      astName (assetAt 1) `shouldBe` Nothing

    it "sha256 / entry 仍正確讀出" $ do
      astSha256 (assetAt 1) `shouldBe` Sha256 "9f3ac81c"
      astEntry (assetAt 1) `shouldBe` "PNG/panel_scroll.png"

    it "tags 只有節層自己的(檔案層的「商用」仍聯集進來)" $
      metaTags (astMeta (assetAt 1)) `shouldBe` ["商用", "gui"]

  describe "節缺 type → SectionFieldMissing(不繼承,design.md 表格)" $
    it "asset 節沒寫 type 時回 SectionFieldMissing" $ do
      let bad = T.replace "type: asset-image\nname: ui_gui_travel-book-frame_001\n" "" packMd
      leftKind (toPack (docOf bad))
        `shouldBe` Just (SectionFieldMissing (idOf "ast-3f9c1d20") "type")

  describe "節缺 sha256 / entry → 錯誤" $ do
    it "缺 sha256 時解析失敗" $ do
      let bad = T.replace "sha256: 9f3ac81c\n" "" packMd
      toPack (docOf bad) `shouldSatisfy` \r -> case r of
        Left _ -> True
        Right _ -> False

    it "缺 entry 時解析失敗" $ do
      let bad = T.replace "entry: PNG/panel_scroll.png\n" "" packMd
      toPack (docOf bad) `shouldSatisfy` \r -> case r of
        Left _ -> True
        Right _ -> False

  describe "節 id 前綴必須是 ast" $
    it "節用 {#ent-0001} → IdPrefixMismatch" $ do
      let bad = T.replace "{#ast-3f9c1d21}" "{#ent-00000001}" packMd
      leftKind (toPack (docOf bad))
        `shouldBe` Just (IdPrefixMismatch (idOf "ent-00000001") "ast")
