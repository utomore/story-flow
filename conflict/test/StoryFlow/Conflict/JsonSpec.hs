-- | T6:編碼約定與 round-trip。
--
-- 三件事在這裡守住,後續的 CLI @--json@、REST body 與 MCP 就不可能各自漂移:
-- round-trip 不失真、'HitLayer' 的標籤不洩漏 Haskell 建構子名、
-- @Maybe@ 沒值時整個鍵不出現。
module StoryFlow.Conflict.JsonSpec (spec) where

import Data.Aeson (FromJSON, ToJSON, Value (..), decode, encode, toJSON)
import Data.Aeson.Key (toString)
import qualified Data.Aeson.KeyMap as KM
import Data.List (isInfixOf, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import StoryFlow.Conflict.Fixtures
import StoryFlow.Conflict.Json ()
import StoryFlow.Conflict.Types
import StoryFlow.Core.Id (Ref (..))
import StoryFlow.Core.Link (LinkKind (Contradicts, Custom))
import StoryFlow.Core.Meta (Meta (..), Timeline (..))
import Test.Hspec

spec :: Spec
spec = describe "編碼約定與 round-trip" $ do
  it "七個型別各自 round-trip 不失真" $ do
    roundTrip (Draft "琳達在崩塌後回到埃提亞" [idOf "ent-7f3a"])
    roundTrip (Draft "沒有已知引用的草稿" [])
    roundTrip defaultConflictOpts
    roundTrip
      defaultConflictOpts
        { coTopN = 5
        , coJudgeN = 2
        , coExpandBody = True
        , coTimelineWindow = Just 3
        , coGraphDepth = 1
        }
    roundTrip graphEvidence
    roundTrip (GraphEvidence (idOf "ent-7f3c") (Custom "呼應") (refOf "shared-lore:ent-91cc"))
    roundTrip (ByGraph graphEvidence)
    roundTrip (ByRetrieval 0.82)
    roundTrip (ByJudge 0.91)
    roundTrip (retrievalHit 0.82 "ent-4d10")
    roundTrip (ConflictHit (idOf "ent-91cc") (ByGraph graphEvidence) "已被標註為矛盾" Nothing)
    roundTrip (ContextHit (metaOf "ent-4d10" "崩塌後的埃提亞") "……徵召……" (ByRetrieval 0.7))
    roundTrip (ContextHit (metaOf "ent-4d10" "崩塌後的埃提亞") {metaTimeline = Timeline (Just "崩塌前") (Just 3)} "……" (ByJudge 0.5))
    roundTrip emptyReport
    roundTrip (ConflictReport [retrievalHit 0.82 "ent-4d10", judgeHit 0.91 "ent-5e22"] 20 True [])
    roundTrip (ReportNote "judge_parse_failed" "這一對沒有判斷結果,不是判定為沒有矛盾")
    roundTrip report

  it "HitLayer 編出帶 layer 鍵的物件,值等於 layerTag" $ do
    let tagOf l = KM.lookup "layer" (objOf (toJSON l))
    tagOf (ByGraph graphEvidence) `shouldBe` Just (String "graph")
    tagOf (ByRetrieval 0.82) `shouldBe` Just (String "retrieval")
    tagOf (ByJudge 0.91) `shouldBe` Just (String "judge")

  it "HitLayer 的三種形狀鍵名與 spec 的範例一致" $ do
    sort (keysOf (toJSON (ByGraph graphEvidence))) `shouldBe` sort ["layer", "from", "kind", "to"]
    sort (keysOf (toJSON (ByRetrieval 0.82))) `shouldBe` sort ["layer", "score"]
    sort (keysOf (toJSON (ByJudge 0.91))) `shouldBe` sort ["layer", "confidence"]

  -- aeson 預設的和積編碼會產出 {"ByGraph": {…}};API 契約不該洩漏實作語言的識別字。
  it "編出的 JSON 不含任何 Haskell 建構子名" $ do
    let blob = T.unpack (TE.decodeUtf8 (BL.toStrict (encode report)))
    mapM_ (\c -> (c, c `isInfixOf` blob) `shouldBe` (c, False)) constructorNames

  it "Maybe 沒值時整個鍵不出現,不是 null" $ do
    keysOf (toJSON (ConflictHit (idOf "ent-91cc") (ByGraph graphEvidence) "理由" Nothing))
      `shouldNotContain` ["snippet"]
    keysOf (toJSON defaultConflictOpts) `shouldNotContain` ["timeline_window"]
    keysOf (toJSON defaultConflictOpts {coTimelineWindow = Just 3}) `shouldContain` ["timeline_window"]

  it "Id 與 Ref 編成字串不是物件" $ do
    KM.lookup "from" (objOf (toJSON graphEvidence)) `shouldBe` Just (String "ent-7f3c")
    KM.lookup "to" (objOf (toJSON graphEvidence)) `shouldBe` Just (String "ent-91cc")
    KM.lookup "to" (objOf (toJSON crossVault)) `shouldBe` Just (String "shared-lore:ent-91cc")
    KM.lookup "target" (objOf (toJSON (retrievalHit 0.82 "ent-4d10"))) `shouldBe` Just (String "ent-4d10")

  it "跨 Vault 的 geTo 解回來仍帶 refVault" $ do
    fmap geTo (decode (encode crossVault)) `shouldBe` Just (geTo crossVault)
    fmap (refVault . geTo) (decode (encode crossVault)) `shouldBe` Just (Just "shared-lore")

  -- 客戶端只想調 top_n 時不該被迫把五個欄位都寫齊。
  it "ConflictOpts 缺欄位時退回預設值" $
    decode "{}" `shouldBe` Just defaultConflictOpts

  it "未知的 layer 標籤解析失敗而不是靜默變成別的層" $
    (decode "{\"layer\":\"embedding\",\"score\":0.5}" :: Maybe HitLayer) `shouldBe` Nothing

  -- conflict-detection/F005 T2:judge_n 與 notes 的編解碼。
  it "ReportNote round-trip 且 JSON 鍵是 code / detail" $ do
    let n = ReportNote "judge_parse_failed" "沒有判斷結果"
    roundTrip n
    sort (keysOf (toJSON n)) `shouldBe` sort ["code", "detail"]

  it "ConflictOpts 的 JSON 含 judge_n,缺 judge_n 時解出預設值的那一欄" $ do
    KM.lookup "judge_n" (objOf (toJSON defaultConflictOpts {coJudgeN = 3}))
      `shouldBe` Just (Number 3)
    (coJudgeN <$> (decode "{}" :: Maybe ConflictOpts))
      `shouldBe` Just (coJudgeN defaultConflictOpts)

  it "ConflictReport 的 JSON 含 notes;缺 notes 的舊 payload 解得出來且 crNotes == []" $ do
    keysOf (toJSON report) `shouldContain` ["notes"]
    let oldPayload = "{\"hits\":[],\"scanned\":0,\"llm_used\":false}"
    (crNotes <$> (decode oldPayload :: Maybe ConflictReport)) `shouldBe` Just []

  it "帶 notes 的 report round-trip 不失真" $
    roundTrip
      report
        { crNotes =
            [ ReportNote "judge_disabled" "這份報告只有前兩層"
            , ReportNote "judge_aborted" "尚有 2 對未判斷"
            ]
        }

report :: ConflictReport
report =
  ConflictReport
    [ ConflictHit (idOf "ent-91cc") (ByGraph graphEvidence) "已被標註為矛盾" Nothing
    , retrievalHit 0.82 "ent-4d10"
    , judgeHit 0.91 "ent-5e22"
    ]
    20
    True
    []

crossVault :: GraphEvidence
crossVault = GraphEvidence (idOf "ent-7f3c") Contradicts (refOf "shared-lore:ent-91cc")

constructorNames :: [String]
constructorNames = ["ByGraph", "ByRetrieval", "ByJudge", "GraphEvidence", "ConflictHit", "tag", "contents"]

roundTrip :: (Show a, Eq a, ToJSON a, FromJSON a) => a -> Expectation
roundTrip x = decode (encode x) `shouldBe` Just x

objOf :: Value -> KM.KeyMap Value
objOf = \case
  Object o -> o
  v -> error ("預期是物件,但拿到 " <> show v)

keysOf :: Value -> [String]
keysOf = map toString . KM.keys . objOf
