{-# OPTIONS_GHC -Wno-orphans #-}

-- | 衝突偵測全部型別的 aeson 編解碼,__集中在這一個模組__。
--
-- 孤兒實例是刻意的,理由與 "Aapms.Core.Json" / @Aapms.Service.Json@
-- 完全相同:CLI 的 @--json@、REST 的 body、未來 MCP 用的是同一套編碼規則,
-- 規則只該有一份;把實例散在型別模組會讓「規則有一份」變成靠自律維持。
--
-- 編碼約定沿用 "Aapms.Core.Json" 的三條:
--
-- * 欄位名去掉 Haskell 的前綴,多字用 snake_case
-- * @Maybe@ 沒值時__整個鍵不出現__,不是 @null@
-- * 'Aapms.Core.Id.Id' 與 'Aapms.Core.Id.Ref' 是__字串__,不是物件
--
-- 'HitLayer' 是和積型別,編成__帶 @layer@ 標籤的物件__:
--
-- > {"layer": "graph",     "from": "ent-7f3c", "kind": "contradicts", "to": "ent-91cc"}
-- > {"layer": "retrieval", "score": 0.82}
-- > {"layer": "judge",     "confidence": 0.91}
--
-- 用 @layer@ 當標籤而不是 aeson 預設的和積編碼:預設會產出 @{"ByGraph": {…}}@
-- 這種帶 Haskell 建構子名的形狀,而 API 契約不該洩漏實作語言的識別字。
-- 標籤值與 'Aapms.Conflict.Types.layerTag' 共用同一份,不各自寫一次。
module Aapms.Conflict.Json () where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Aapms.Conflict.Types
import Aapms.Core.Json ()

instance ToJSON Draft where
  toJSON Draft {..} = object ["text" .= drText, "refs" .= drRefs]

instance FromJSON Draft where
  parseJSON = withObject "Draft" $ \o ->
    Draft <$> o .: "text" <*> o .:? "refs" .!= []

instance ToJSON ConflictOpts where
  toJSON ConflictOpts {..} =
    object $
      [ "top_n" .= coTopN
      , "judge_n" .= coJudgeN
      , "expand_body" .= coExpandBody
      , "graph_depth" .= coGraphDepth
      ]
        ++ ["timeline_window" .= v | Just v <- [coTimelineWindow]]

-- | 缺欄位時退回 'defaultConflictOpts' 的那一欄:客戶端只想調 @top_n@ 時,
-- 不該被迫把五個欄位都寫齊。
instance FromJSON ConflictOpts where
  parseJSON = withObject "ConflictOpts" $ \o ->
    ConflictOpts
      <$> o .:? "top_n" .!= coTopN defaultConflictOpts
      <*> o .:? "judge_n" .!= coJudgeN defaultConflictOpts
      <*> o .:? "expand_body" .!= coExpandBody defaultConflictOpts
      <*> o .:? "timeline_window"
      <*> o .:? "graph_depth" .!= coGraphDepth defaultConflictOpts

instance ToJSON GraphEvidence where
  toJSON GraphEvidence {..} =
    object ["from" .= geFrom, "kind" .= geKind, "to" .= geTo]

instance FromJSON GraphEvidence where
  parseJSON = withObject "GraphEvidence" $ \o ->
    GraphEvidence <$> o .: "from" <*> o .: "kind" <*> o .: "to"

instance ToJSON HitLayer where
  toJSON l = object (("layer" .= layerTag l) : payload l)
    where
      payload = \case
        -- 證據攤平進同一層而不是塞進巢狀的 "evidence":讀 JSON 的人看到的
        -- 就是 layer/from/kind/to 四個鍵,與 spec 的範例逐字一致。
        ByGraph GraphEvidence {..} ->
          ["from" .= geFrom, "kind" .= geKind, "to" .= geTo]
        ByRetrieval s -> ["score" .= s]
        ByJudge c -> ["confidence" .= c]

instance FromJSON HitLayer where
  parseJSON = withObject "HitLayer" $ \o -> do
    tag <- o .: "layer" :: Parser String
    case tag of
      "graph" -> ByGraph <$> (GraphEvidence <$> o .: "from" <*> o .: "kind" <*> o .: "to")
      "retrieval" -> ByRetrieval <$> o .: "score"
      "judge" -> ByJudge <$> o .: "confidence"
      _ -> fail ("未知的命中層級:" ++ tag)

instance ToJSON ConflictHit where
  toJSON ConflictHit {..} =
    object $
      ["target" .= chTarget, "layer" .= chLayer, "reason" .= chReason]
        ++ ["snippet" .= v | Just v <- [chSnippet]]

instance FromJSON ConflictHit where
  parseJSON = withObject "ConflictHit" $ \o ->
    ConflictHit <$> o .: "target" <*> o .: "layer" <*> o .:? "reason" .!= "" <*> o .:? "snippet"

instance ToJSON ContextHit where
  toJSON ContextHit {..} =
    object ["meta" .= xhMeta, "snippet" .= xhSnippet, "via" .= xhVia]

instance FromJSON ContextHit where
  parseJSON = withObject "ContextHit" $ \o ->
    ContextHit <$> o .: "meta" <*> o .:? "snippet" .!= "" <*> o .: "via"

instance ToJSON ConflictReport where
  toJSON ConflictReport {..} =
    object
      [ "hits" .= crHits
      , "scanned" .= crScanned
      , "llm_used" .= crLlmUsed
      , "notes" .= crNotes
      ]

-- | @notes@ 缺席退 @[]@:舊客戶端的 payload(F005 之前產生的)不會壞。
instance FromJSON ConflictReport where
  parseJSON = withObject "ConflictReport" $ \o ->
    ConflictReport
      <$> o .:? "hits" .!= []
      <*> o .:? "scanned" .!= 0
      <*> o .:? "llm_used" .!= False
      <*> o .:? "notes" .!= []

-- {"code": "judge_parse_failed", "detail": "…"}
instance ToJSON ReportNote where
  toJSON ReportNote {..} = object ["code" .= rnCode, "detail" .= rnDetail]

instance FromJSON ReportNote where
  parseJSON = withObject "ReportNote" $ \o ->
    ReportNote <$> o .: "code" <*> o .: "detail"
