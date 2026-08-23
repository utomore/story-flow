module AssetDB.Project.TemplateSpec (spec) where

import AssetDB.Project.Template
import Data.List (isSuffixOf)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "templateDirs" $ do
    it "音效目錄先建好" $ do
      -- 現在是空的,但音效功能上線時不需要有人記得補 —— 而「記得補」不會發生。
      templateDirs `shouldContain` ["assets/audio/sfx"]
      templateDirs `shouldContain` ["assets/audio/bgm"]

    it "含 ADR 目錄" $ templateDirs `shouldContain` ["docs/decisions"]

  describe "templateFiles" $ do
    let files = templateFiles "Circle" "(credits)"

    it "SKILL.md 是給接手的人與 AI agent 讀的第一份文件" $ do
      let skill = contentOf files "SKILL.md"
      skill `shouldSatisfy` T.isInfixOf "cabal build"
      skill `shouldSatisfy` T.isInfixOf "manifest.json"
      skill `shouldSatisfy` T.isInfixOf "Assets.hs"
      -- 建置路徑不可含空格是這個專案踩過的真實坑,樣板要警告。
      skill `shouldSatisfy` T.isInfixOf "不可含空格"

    it "SKILL.md 明確禁止手動複製素材" $
      contentOf files "SKILL.md" `shouldSatisfy` T.isInfixOf "不要手動複製檔案"

    -- delivery/F006 V11:`project sync` 上線之前,樣板教的是「重新產生到新目錄
    -- 再把 assets/ 換過去」。指令存在之後還留著那段話,等於教人繞遠路。
    it "「加入新素材」段落教的是 project sync,不再寫「尚未實作」" $ do
      let skill = contentOf files "SKILL.md"
      skill `shouldSatisfy` T.isInfixOf "assetdb project sync"
      skill `shouldSatisfy` T.isInfixOf "--confirm"
      skill `shouldNotSatisfy` T.isInfixOf "尚未實作"

    it "「加入新素材」段落講明同步不覆蓋既有檔案" $
      contentOf files "SKILL.md" `shouldSatisfy` T.isInfixOf "不刪除、不覆蓋"

    it "gitattributes 把二進位素材交給 LFS" $
      contentOf files ".gitattributes" `shouldSatisfy` T.isInfixOf "filter=lfs"

    it "產生提案書與技術文檔" $ do
      map tfPath files `shouldContain` ["docs/提案書.md"]
      map tfPath files `shouldContain` ["docs/技術文檔.md"]

    it "所有路徑都是相對的" $
      all (not . isSuffixOf "/") (map tfPath files) `shouldBe` True

  describe "creditsSection" $ do
    it "需署名的素材包會被特別標出" $ do
      let c = creditsSection [("Crusenho Pack", Just "Crusenho License", True), ("Kibyra", Just "K", False)]
      c `shouldSatisfy` T.isInfixOf "**是**"
      c `shouldSatisfy` T.isInfixOf "發行時必須出現在致謝畫面"
      c `shouldSatisfy` T.isInfixOf "- Crusenho Pack"

    it "沒有需署名的就不加警告" $
      creditsSection [("K", Just "L", False)] `shouldNotSatisfy` T.isInfixOf "必須出現在致謝畫面"

    it "沒有素材時給明確訊息而不是空表格" $
      creditsSection [] `shouldSatisfy` T.isInfixOf "還沒有使用任何素材"
  where
    contentOf fs p = case [tfContent f | f <- fs, tfPath f == p] of
      (c : _) -> c
      [] -> error ("樣板缺少 " <> p)
