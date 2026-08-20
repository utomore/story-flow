-- | T4:表格對齊且欄位齊全。
--
-- 對齊以__顯示寬度__計算而不是字元數。繁中一個字佔兩格,用 'Data.Text.length'
-- 排出來的表格在有中文標題時會整排歪掉——而這個工具的資料幾乎全是中文。
module StoryFlow.Cli.RenderSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (fromGregorian)
import StoryFlow.Cli.Render
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Core.Link (Link (..), LinkKind (Contradicts, PartOf))
import StoryFlow.Core.Meta (Meta (..), Source (Human), Status (Canon, Draft), emptyTimeline)
import StoryFlow.Service (EntityView (..), LinkReport (..), SearchHit (..))
import Test.Hspec

spec :: Spec
spec = describe "人類可讀輸出" $ do
  describe "renderMetaTable" $ do
    it "每一列的欄數都與表頭相同" $ do
      let ls = T.lines (renderMetaTable [linda, tower])
      map (length . T.splitOn "|") ls `shouldBe` replicate 3 5

    it "表頭含 id / type / status / title / summary" $ do
      let hdr = firstOf (T.lines (renderMetaTable [linda]))
      mapM_ (\c -> hdr `shouldSatisfy` T.isInfixOf c) ["id", "type", "status", "title", "summary"]

    it "含中日文標題時仍以顯示寬度對齊" $ do
      let ls = T.lines (renderMetaTable [linda, ascii])
          -- 每一列到第一個 | 為止的顯示寬度都一樣,欄才是直的
          upToBar = map (displayWidth . T.takeWhile (/= '|')) ls
      length (filter (/= firstOf upToBar) upToBar) `shouldBe` 0

    it "空清單有一句話,不是空字串" $
      renderMetaTable [] `shouldSatisfy` (not . T.null)

  describe "displayWidth" $ do
    it "繁中一個字兩格,ASCII 一格" $ do
      displayWidth "琳達" `shouldBe` 4
      displayWidth "linda" `shouldBe` 5
      displayWidth "琳達 linda" `shouldBe` 10

    it "全形標點兩格,半形標點一格" $ do
      displayWidth "崩塌前、之後" `shouldBe` 12
      displayWidth "崩塌前,之後" `shouldBe` 11

  describe "padTo" $ do
    it "補到指定顯示寬度" $ displayWidth (padTo 10 "琳達") `shouldBe` 10
    it "已經超過就至少留兩格" $ displayWidth (padTo 3 "琳達linda") `shouldBe` 11

  describe "renderEntity" $ do
    it "含正文" $ renderEntity view `shouldSatisfy` T.isInfixOf "那年她十四歲"

    it "逐行列出 links" $ do
      let ls = T.lines (renderEntity view)
      ls `shouldSatisfy` any (T.isInfixOf "partOf → ent-7f3a")
      ls `shouldSatisfy` any (T.isInfixOf "contradicts → ent-91cc(對雙親死因不一致)")

    it "含 id / title / summary / status 與檔案路徑" $
      mapM_
        (\c -> renderEntity view `shouldSatisfy` T.isInfixOf c)
        ["ent-7f3c", "與塔主的過節", "canon", "characters/琳達.md#ent-7f3c"]

  describe "renderSearch" $
    it "比 entity list 多一欄 snippet,但人類模式不印 score" $ do
      -- score 有值也不該出現在人類模式的表格裡:這張表本來就很寬,
      -- 相關度只走 --json(conflict-detection/F003 T2)。
      let hdr = firstOf (T.lines (renderSearch [SearchHit linda "……第七織手……" (Just 0.42)]))
      hdr `shouldSatisfy` T.isInfixOf "snippet"
      hdr `shouldSatisfy` (not . T.isInfixOf "score")

  describe "renderLinks" $
    it "正向與反向各成一段" $ do
      let out = renderLinks (LinkReport [Link PartOf (refOf "ent-7f3a") Nothing] [(idOf "ent-9000", Link Contradicts (refOf "ent-7f3c") Nothing)])
      out `shouldSatisfy` T.isInfixOf "正向"
      out `shouldSatisfy` T.isInfixOf "反向"
      out `shouldSatisfy` T.isInfixOf "partOf → ent-7f3a"
      out `shouldSatisfy` T.isInfixOf "ent-9000"

-- 底稿 -------------------------------------------------------------------------

meta :: Text -> Text -> Text -> Text -> Status -> Meta
meta i ty title summary st =
  Meta
    { metaId = idOf i
    , metaVault = "liftgame"
    , metaType = ty
    , metaTitle = title
    , metaSummary = summary
    , metaTags = []
    , metaStatus = st
    , metaTimeline = emptyTimeline
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = 1
    , metaCreated = fromGregorian 2026 8 16
    , metaUpdated = fromGregorian 2026 8 16
    }

linda :: Meta
linda = meta "ent-7f3a" "character" "琳達" "埃提亞的第七織手" Canon

tower :: Meta
tower = meta "ent-8b20" "character" "塔主" "議會的實際掌權者" Draft

ascii :: Meta
ascii = meta "ent-0001" "lore-fragment" "Aetia" "the fallen region" Canon

view :: EntityView
view =
  EntityView
    { evEntity =
        Entity
          { entMeta =
              (meta "ent-7f3c" "character-fragment" "與塔主的過節" "十四歲時因塔主徵召失去雙親" Canon)
                { metaLinks =
                    [ Link PartOf (refOf "ent-7f3a") Nothing
                    , Link Contradicts (refOf "ent-91cc") (Just "對雙親死因不一致")
                    ]
                }
          , entBody = "那年她十四歲……"
          }
    , evPath = "characters/琳達.md"
    , evAnchor = Just "ent-7f3c"
    , evWarnings = []
    }

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error (show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error (show e)

-- | 清單的第一個元素。呼叫處都已經知道它非空,這個小工具只是為了不用 head。
firstOf :: [a] -> a
firstOf (x : _) = x
firstOf [] = error "預期清單至少有一個元素"
