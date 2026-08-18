-- | T15:純 CLI 從零建出琳達與教室。
--
-- 這是 func-0007 的驗收標準 1,也是 architecture.md 裡 P2 的完成標準:
-- __能純用 CLI 把「教室」場景與琳達的片段從零建起來__。整條路只用 'runCli',
-- 沒有任何一步繞到 service 或 store 去補。
module StoryFlow.Cli.EndToEndSpec (spec) where

import Data.Aeson (Value (..))
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Cli.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "端到端" $
  it "vault init 開始,建出琳達的片段與教室的六個 Node" $ withCliVault $ \_ -> do
    -- 1. 主體:琳達
    linda <-
      idFromJson
        <$> sfJson
          [ "entity"
          , "new"
          , "--type"
          , "character"
          , "--title"
          , "琳達"
          , "--summary"
          , "埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
          , "--status"
          , "canon"
          , "--alias"
          , "小琳"
          , "--alias"
          , "第七織手"
          ]

    -- 2. 兩個片段,各自 partOf 主體
    _ <-
      sfOk
        [ "entity"
        , "add"
        , "琳達"
        , "--title"
        , "外貌"
        , "--type"
        , "character-fragment"
        , "--summary"
        , "銀灰短髮,左眼下方有織紋刺青"
        , "--tag"
        , "外觀"
        , "--link"
        , "partOf:" <> linda
        , "--body"
        , "銀灰短髮剪到耳際……"
        ]
    _ <-
      sfOk
        [ "entity"
        , "add"
        , "琳達"
        , "--title"
        , "與塔主的過節"
        , "--type"
        , "character-fragment"
        , "--summary"
        , "十四歲時因塔主徵召失去雙親,自此對議會抱持敵意"
        , "--tag"
        , "動機"
        , "--timeline"
        , "埃提亞崩塌前"
        , "--link"
        , "partOf:" <> linda
        , "--body"
        , "那年她十四歲……"
        ]

    -- 3. 片段之間的關聯
    grudge <- idOfTitle "與塔主的過節"
    _ <- sfOk ["link", "add", "外貌", "--kind", "references", "--target", grudge, "--note", "刺青是那件事之後刺的"]

    -- 4. 教室 Level 與它的六個 Node
    _ <-
      sfOk
        [ "level"
        , "new"
        , "--title"
        , "教室"
        , "--summary"
        , "崩塌後的午後教室,琳達與塔主的第一次對峙"
        , "--root-title"
        , "午後的教室"
        , "--root-kind"
        , "scene"
        , "--status"
        , "canon"
        ]
    _ <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast", "--link", "involves:" <> linda]
    _ <- sfOk ["node", "add", "出場人物", "--title", "琳達走向講台", "--kind", "interaction"]
    _ <- sfOk ["node", "add", "琳達走向講台", "--title", "A-to-B 對話", "--kind", "dialogue"]
    _ <- sfOk ["node", "add", "A-to-B 對話", "--title", "琳達選擇動手", "--kind", "branch"]
    _ <-
      sfOk
        ["node", "add", "午後的教室", "--title", "鏡頭", "--kind", "camera", "--summary", "自窗外緩推至講台,焦段 35mm"]

    -- 驗收 1:場景樹的形狀與 architecture.md 的圖一致
    out <- sfOk ["level", "show", "教室"]
    let ls = T.lines (T.strip out)
    length ls `shouldBe` 7
    firstLine ls `shouldContainT` "教室"
    map shape (drop 1 ls) `shouldBe` expectedShape

    -- 驗收 2:三個 Entity 都在,而且關聯正反向都查得到
    listed <- sfOk ["entity", "list"]
    mapM_ (shouldContainT listed) ["琳達", "外貌", "與塔主的過節"]
    fromFrag <- sfOk ["link", "list", "外貌"]
    fromFrag `shouldContainT` "partOf → "
    fromFrag `shouldContainT` "references → "
    toMain <- sfOk ["link", "list", "琳達"]
    toMain `shouldContainT` "反向"
    toMain `shouldContainT` T.pack grudge

    -- 驗收 3:全文檢索找得到片段,而不只是主體
    hits <- sfOk ["search", "織紋刺青"]
    hits `shouldContainT` "外貌"

    -- 驗收 4:刪掉索引也回得來(資料流 C)
    env <- sfJson ["index", "rebuild"]
    jsonPath ["data", "files"] env `shouldBe` Just (Number 2)
    rebuilt <- sfOk ["level", "show", "教室"]
    rebuilt `shouldBe` out

-- | 樹的形狀:(分支字元, kind, 摘要或標題)。
--
-- id 是內容雜湊出來的,每次跑都不同,所以比對的是形狀而不是逐字——欄位對齊的
-- 逐字比對由 T5 用固定的 id 負責。
expectedShape :: [(Text, Text, Text)]
expectedShape =
  [ ("└─ ", "scene", "午後的教室")
  , ("   ├─ ", "cast", "出場人物")
  , ("   │  └─ ", "interaction", "琳達走向講台")
  , ("   │     └─ ", "dialogue", "A-to-B 對話")
  , ("   │        └─ ", "branch", "琳達選擇動手")
  , ("   └─ ", "camera", "自窗外緩推至講台,焦段 35mm")
  ]

shape :: Text -> (Text, Text, Text)
shape l = (prefix, kind, T.unwords rest)
  where
    (prefix, body) = T.span (`elem` ("└├─│ " :: String)) l
    (kind, rest) = case T.words body of
      (_id : k : xs) -> (k, xs)
      other -> ("?", other)

-- | 用標題查 id。定址本身測過了,這裡只是要拿 id 去當 @--target@。
idOfTitle :: String -> IO String
idOfTitle t = do
  env <- sfJson ["entity", "show", t]
  case jsonPath ["data", "entity", "id"] env of
    Just (String i) -> pure (T.unpack i)
    other -> fail ("data.entity.id 取不到:" <> show other)

-- | 輸出的第一行。呼叫處已經斷言過行數,這個小工具只是為了不用 head。
firstLine :: [Text] -> Text
firstLine (x : _) = x
firstLine [] = error "預期輸出至少有一行"
