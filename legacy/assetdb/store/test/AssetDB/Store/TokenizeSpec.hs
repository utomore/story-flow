module AssetDB.Store.TokenizeSpec (spec) where

import AssetDB.Store.Tokenize
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "cjkBigrams" $ do
    let cases :: [(Text, Text)]
        cases =
          [ ("金門建築", "金門 門建 建築")
          , ("金門", "金門")
          , -- 單字序列不產生 bigram,由 unigram 欄位負責
            ("金", "")
          , ("", "")
          , -- 非中日韓的部分丟棄,那些由 trigram 索引負責
            ("hello world", "")
          , ("1990 年代文化風格", "年代 代文 文化 化風 風格")
          , -- 各段獨立展開,不會跨段產生假 bigram
            ("台灣 日本", "台灣 日本")
          , ("福岡廟宇", "福岡 岡廟 廟宇")
          , ("ひらがな", "ひら らが がな")
          ]
    mapM_
      (\(i, o) -> it (T.unpack ("展開 " <> tshow i)) $ cjkBigrams i `shouldBe` o)
      cases

    it "不跨越非中日韓字元" $
      -- 「灣日」橫跨了空白,語意上不存在,不該被索引
      cjkBigrams "台灣 日本" `shouldNotSatisfy` T.isInfixOf "灣日"

    it "n 個字產生 n-1 個 bigram" $
      let n = 6
       in length (T.words (cjkBigrams (T.replicate n "中"))) `shouldBe` (n - 1)

  describe "cjkUnigrams" $ do
    it "取出所有中日韓字元" $
      cjkUnigrams "1990 年代金門" `shouldBe` "年 代 金 門"

    it "純 ASCII 回空字串" $
      cjkUnigrams "ui_gui_frame" `shouldBe` ""

  describe "cjkIndex" $
    it "兩欄一起產生" $
      cjkIndex "金門建築" `shouldBe` CjkIndex "金 門 建 築" "金門 門建 建築"

  describe "cjkMatchExpr" $ do
    it "單字走 unigram 欄" $
      cjkMatchExpr "金" `shouldBe` Just "uni : \"金\""

    it "雙字走 bigram 欄" $
      cjkMatchExpr "金門" `shouldBe` Just "bi : \"金門\""

    it "長詞是 bigram 片語" $
      cjkMatchExpr "金門建築" `shouldBe` Just "bi : \"金門 門建 建築\""

    it "多段中日韓以 AND 連接,段內才用片語" $
      -- 用片語會要求「灣」與「建」相鄰,那不是使用者的意思
      cjkMatchExpr "台灣 建築" `shouldBe` Just "bi : \"台灣\" AND bi : \"建築\""

    it "純 ASCII 回 Nothing —— 那種查詢該走 trigram 索引" $
      cjkMatchExpr "blue-potion" `shouldBe` Nothing

    it "中英混合只取中日韓部分" $
      cjkMatchExpr "Fukuoka 福岡" `shouldBe` Just "bi : \"福岡\""

  describe "hasCJK" $ do
    it "認得中文" $ hasCJK "金門建築" `shouldBe` True
    it "認得中英混合" $ hasCJK "Fukuoka 福岡" `shouldBe` True
    it "純 ASCII 回 False" $ hasCJK "ui_gui_travel-book-frame" `shouldBe` False

  describe "ftsQuoted" $ do
    -- FTS5 的 MATCH 語法會把減號當成 NOT、星號當成前綴萬用字元。
    -- 使用者搜 "blue-potion" 時那個減號必須失去意義。
    it "包起來讓運算子失效" $
      ftsQuoted "blue-potion" `shouldBe` "\"blue-potion\""

    it "內部雙引號以重複跳脫" $
      ftsQuoted "say \"hi\"" `shouldBe` "\"say \"\"hi\"\"\""

    it "星號不再是萬用字元" $
      ftsQuoted "icon*" `shouldBe` "\"icon*\""

  describe "ftsPhrase" $
    it "正規化空白" $
      ftsPhrase "  金門   門建  " `shouldBe` "\"金門 門建\""

tshow :: Show a => a -> Text
tshow = T.pack . show
