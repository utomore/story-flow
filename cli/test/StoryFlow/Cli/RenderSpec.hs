-- | T4:表格對齊且欄位齊全。
--
-- 對齊以__顯示寬度__計算而不是字元數。繁中一個字佔兩格,用 'Data.Text.length'
-- 排出來的表格在有中文標題時會整排歪掉——而這個工具的資料幾乎全是中文。
module StoryFlow.Cli.RenderSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (fromGregorian)
import StoryFlow.Cli.Render
import StoryFlow.Conflict.Types
  ( ConflictHit (..)
  , ConflictReport (..)
  , GraphEvidence (..)
  , HitLayer (..)
  , ReportNote (..)
  )
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Core.Link (Link (..), LinkKind (Contradicts, PartOf))
import StoryFlow.Core.Meta (Meta (..), Source (Human), Status (Canon, Draft), emptyTimeline)
import StoryFlow.Api (WorkshopCommitResp (..))
import StoryFlow.Service (EntityView (..), LinkReport (..), SearchHit (..))
import StoryFlow.Workshop (Session (..))
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

  describe "renderReport(conflict-detection/F006)" $ do
    it "via 欄逐字等於 renderVia 的輸出" $ do
      let out = renderReport threeLayerReport
          ls = T.lines out
      mapM_
        (\h -> ls `shouldSatisfy` any (T.isInfixOf (renderVia (chLayer h))))
        (crHits threeLayerReport)

    it "chSnippet == Nothing 印 (無)" $
      renderReport threeLayerReport `shouldSatisfy` T.isInfixOf "(無)"

    it "crHits 為空印 (沒有發現衝突),摘要行照印" $ do
      let out = renderReport emptyHitsReport
      out `shouldSatisfy` T.isInfixOf "(沒有發現衝突)"
      out `shouldSatisfy` T.isInfixOf "掃過"

    it "摘要行含 crScanned 的數字與「有跑 / 沒有跑」" $ do
      renderReport threeLayerReport `shouldSatisfy` T.isInfixOf "掃過 12 個候選;語意判斷:有跑"
      renderReport emptyHitsReport `shouldSatisfy` T.isInfixOf "語意判斷:沒有跑"

    it "crNotes 為空時不印注意段;非空時每則一行且含 rnCode" $ do
      renderReport emptyHitsReport `shouldSatisfy` (not . T.isInfixOf "注意:")
      let out = renderReport threeLayerReport
      out `shouldSatisfy` T.isInfixOf "注意:"
      out `shouldSatisfy` T.isInfixOf "(judge_budget)"
      out `shouldSatisfy` T.isInfixOf "(link_suggested)"

    it "snippet 裡的換行被壓成空白(表格不歪)" $ do
      let out = renderReport reportWithMultilineSnippet
      out `shouldSatisfy` T.isInfixOf "第一行 第二行 第三行"
      -- 換行沒有讓那筆命中在表格裡多長出一列
      length (filter (T.isInfixOf "ent-c41d") (T.lines out)) `shouldBe` 1

  describe "renderWorkshopStarted(llm-workshop-mcp/F004)" $
    it "含 session id、型別與第幾階段" $ do
      let out = renderWorkshopStarted sampleWorkshopSession
      out `shouldSatisfy` T.isInfixOf "wksp-00000001"
      out `shouldSatisfy` T.isInfixOf "character-fragment"
      out `shouldSatisfy` T.isInfixOf "第 2/4 階段"

  describe "renderWorkshopCommit(llm-workshop-mcp/F004)" $ do
    it "尚未走完全部階段時印進入第 N 階段" $ do
      let r = WorkshopCommitResp sampleWorkshopSession {wsCurrent = 1} [view]
      renderWorkshopCommit r `shouldSatisfy` T.isInfixOf "已定案 1 個片段"
      renderWorkshopCommit r `shouldSatisfy` T.isInfixOf "進入第 2 階段"

    it "wsCurrent 達到 stages 長度時印工作坊已完成全部階段" $ do
      let r = WorkshopCommitResp sampleWorkshopSession {wsCurrent = 4} []
      renderWorkshopCommit r `shouldSatisfy` T.isInfixOf "已定案 0 個片段"
      renderWorkshopCommit r `shouldSatisfy` T.isInfixOf "工作坊已完成全部階段"

-- 底稿:工作坊(llm-workshop-mcp/F004) ---------------------------------------------

sampleWorkshopSession :: Session
sampleWorkshopSession =
  Session
    { wsId = "wksp-00000001"
    , wsType = "character-fragment"
    , wsConstraints = []
    , wsStages = ["定位", "外貌與舉止", "動機與過往", "關係網"]
    , wsCurrent = 1
    , wsHistory = []
    , wsOwner = Nothing
    , wsPending = []
    , wsCommitted = []
    }

-- 底稿:conflict check ------------------------------------------------------------

graphHitR, retrievalHitR, judgeHitR :: ConflictHit
graphHitR =
  ConflictHit
    { chTarget = idOf "ent-91cc"
    , chLayer = ByGraph (GraphEvidence (idOf "ent-7f3c") Contradicts (refOf "ent-91cc"))
    , chReason = "你引用的 ent-7f3c 與 ent-91cc 已標記矛盾"
    , chSnippet = Nothing
    }
retrievalHitR =
  ConflictHit
    { chTarget = idOf "ent-c41d"
    , chLayer = ByRetrieval 0.82
    , chReason = "草稿與 ent-c41d 共同出現「琳達」"
    , chSnippet = Just "……琳達……"
    }
judgeHitR =
  ConflictHit
    { chTarget = idOf "ent-8b20"
    , chLayer = ByJudge 0.91
    , chReason = "兩段對雙親死因的敘述不一致"
    , chSnippet = Just "……徵召……"
    }

threeLayerReport :: ConflictReport
threeLayerReport =
  ConflictReport
    { crHits = [graphHitR, retrievalHitR, judgeHitR]
    , crScanned = 12
    , crLlmUsed = True
    , crNotes =
        [ ReportNote "judge_budget" "候選 12 個,只有前 5 個送了語意判斷;其餘 7 個沒有第 3 層的結論"
        , ReportNote "link_suggested" "第 3 層判定 ent-8b20 與草稿矛盾;確認成立後替草稿對應的片段建立 contradicts 關聯"
        ]
    }

emptyHitsReport :: ConflictReport
emptyHitsReport = ConflictReport {crHits = [], crScanned = 0, crLlmUsed = False, crNotes = []}

reportWithMultilineSnippet :: ConflictReport
reportWithMultilineSnippet =
  ConflictReport
    { crHits = [retrievalHitR {chSnippet = Just "第一行\n第二行\n第三行"}]
    , crScanned = 1
    , crLlmUsed = False
    , crNotes = []
    }

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
