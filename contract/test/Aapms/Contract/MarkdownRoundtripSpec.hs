-- | 契約 2:Markdown roundtrip 與位元組保留(ADR-002、ADR-010)。
--
-- 檔案是真相。這裡不讀任何內部型別,只看兩件事:
--
-- * 寫進去的內容(含尾端空白、空行、非 ASCII)經「寫回 → 再解析」原樣回來
-- * 改動一節時,該節之前的所有位元組__逐字相同__——未修改區塊不得被重新序列化
module Aapms.Contract.MarkdownRoundtripSpec (spec) where

import Aapms.Contract.Harness
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "Markdown roundtrip 與位元組保留" $ do
  it "正文經寫回再解析不失真(尾端空白、空行、非 ASCII)" $ withVault $ \v -> do
    _ <- aapmsOk v ["entity", "new", "--type", "character-fragment", "--title", "琳達", "--summary", "主角"]
    let body = "第一段有尾端空白   \n\n\n  縮排的第二段\n\n- 清單 · 中文標點「」\n\n結尾沒有換行"
    _ <- aapmsIn v (TE.encodeUtf8 body) ["entity", "set-body", "琳達", "-"]
    shown <- aapmsJson v ["entity", "show", "琳達"]
    got <- jsonText ["data", "entity", "body"] shown
    T.stripEnd got `shouldBe` T.stripEnd body

  it "Meta 欄位(title / summary / tags / aliases)roundtrip" $ withVault $ \v -> do
    _ <-
      aapmsOk
        v
        [ "entity", "new", "--type", "item-fragment"
        , "--title", "織紋刀", "--summary", "「刻著紋路」的刀:含冒號與引號"
        , "--tag", "武器", "--tag", "a/b", "--alias", "紋刀", "--alias", "Weave Blade"
        ]
    shown <- aapmsJson v ["entity", "show", "織紋刀"]
    jsonText ["data", "entity", "title"] shown `shouldReturn` "織紋刀"
    jsonText ["data", "entity", "summary"] shown `shouldReturn` "「刻著紋路」的刀:含冒號與引號"
    show (jsonPath ["data", "entity", "tags"] shown) `shouldContain` "\"a/b\""
    show (jsonPath ["data", "entity", "aliases"] shown) `shouldContain` "Weave Blade"

  it "改動一節時,該節之前的全部位元組逐字相同" $ withVault $ \v -> do
    _ <- aapmsOk v ["entity", "new", "--type", "character-fragment", "--title", "琳達", "--summary", "主角"]
    _ <- aapmsOk v ["entity", "add", "琳達", "--title", "外貌", "--summary", "紅髮"]
    added <- aapmsJson v ["entity", "add", "琳達", "--title", "動機", "--summary", "想回家"]
    motiveId <- jsonText ["data", "anchor"] added
    let file = vaultRoot v </> "characters" </> "琳達.md"
    before <- BS.readFile file
    let marker = TE.encodeUtf8 ("{#" <> motiveId <> "}")
        (prefixBefore, rest) = BS.breakSubstring marker before
    BS.null rest `shouldBe` False
    _ <- aapmsOk v ["entity", "set", T.unpack motiveId, "--summary", "想離開這座城"]
    after <- BS.readFile file
    BS.take (BS.length prefixBefore) after `shouldBe` prefixBefore
    -- 而且改動真的落地了(不是根本沒寫)
    shown <- aapmsJson v ["entity", "show", T.unpack motiveId]
    jsonText ["data", "entity", "summary"] shown `shouldReturn` "想離開這座城"
