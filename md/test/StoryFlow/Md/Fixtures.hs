-- | 測試共用的範例檔。
--
-- 'lindaMd' 逐字取自 system.md 的「Markdown 分節格式」節,
-- 'classroomMd' 逐字取自 entity-graph-core/F003 的「Level 檔的解析:標題階層即樹」節。
-- 測試對照的因此是文件裡真的寫出來的那兩份檔案,不是另外編的樣本。
module StoryFlow.Md.Fixtures
  ( -- * 範例檔
    lindaMd
  , classroomMd

    -- * 建構輔助
  , idOf
  , refOf
  , day0
  , crlf
  , dropFinalNL
  , docOf
  , firstSection
  , entityFileOf
  , levelFileOf
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian)
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Md

-- | system.md 的琳達範例檔(LF、檔尾有換行)。
lindaMd :: Text
lindaMd =
  T.unlines
    [ "---"
    , "id: ent-7f3a"
    , "vault: liftgame"
    , "type: character"
    , "title: 琳達"
    , "summary: 埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
    , "status: canon"
    , "aliases: [小琳, 第七織手]"
    , "source: human"
    , "revision: 3"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 琳達"
    , ""
    , "角色主體的概述寫在這裡。"
    , ""
    , "## 外貌 {#ent-7f3b}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: 銀灰短髮,左眼下方有織紋刺青"
    , "tags: [外觀]"
    , "links:"
    , "  - {kind: partOf, target: ent-7f3a}"
    , "```"
    , ""
    , "銀灰短髮剪到耳際……"
    , ""
    , "## 與塔主的過節 {#ent-7f3c}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: 十四歲時因塔主徵召失去雙親,自此對議會抱持敵意"
    , "tags: [動機, 仇恨]"
    , "timeline: 埃提亞崩塌前"
    , "links:"
    , "  - {kind: partOf, target: ent-7f3a}"
    , "  - {kind: occursIn, target: ent-c41d}"
    , "  - {kind: contradicts, target: ent-91cc, note: 對雙親死因的敘述不一致}"
    , "```"
    , ""
    , "那年她十四歲……"
    ]

-- | entity-graph-core/F003 的教室 Level 範例檔。
classroomMd :: Text
classroomMd =
  T.unlines
    [ "---"
    , "id: lvl-3a01"
    , "vault: liftgame"
    , "type: level"
    , "title: 教室"
    , "summary: 崩塌後的午後教室,琳達與塔主的第一次對峙"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "場景整體的說明寫在這裡(對應 Level 的 body,不進 Node)。"
    , ""
    , "## 午後的教室 {#nod-0001}"
    , ""
    , "```meta"
    , "kind: scene"
    , "summary: 午後的教室,窗外是崩塌後的天際線"
    , "links:"
    , "  - {kind: involves, target: ent-c41d}"
    , "```"
    , ""
    , "### 出場人物 {#nod-0002}"
    , ""
    , "```meta"
    , "kind: cast"
    , "links:"
    , "  - {kind: involves, target: ent-7f3a}"
    , "  - {kind: involves, target: ent-8b20}"
    , "```"
    , ""
    , "#### 琳達走向講台 {#nod-0004}"
    , ""
    , "```meta"
    , "kind: interaction"
    , "```"
    , ""
    , "##### A-to-B 對話 {#nod-0005}"
    , ""
    , "```meta"
    , "kind: dialogue"
    , "links:"
    , "  - {kind: references, target: ent-d902}"
    , "```"
    , ""
    , "###### 琳達選擇動手 {#nod-0007}"
    , ""
    , "```meta"
    , "kind: branch"
    , "```"
    , ""
    , "### 鏡頭 {#nod-0003}"
    , ""
    , "```meta"
    , "kind: camera"
    , "summary: 自窗外緩推至講台,焦段 35mm"
    , "```"
    ]

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("fixture 的 ref 不合法:" <> show e)

day0 :: Day
day0 = fromGregorian 2026 8 16

-- | 把 LF 檔轉成 CRLF 檔。
crlf :: Text -> Text
crlf = T.replace "\n" "\r\n"

-- | 去掉檔尾換行。
dropFinalNL :: Text -> Text
dropFinalNL = T.dropWhileEnd (`elem` ['\r', '\n'])

-- | 解析成 'Document',失敗就讓測試直接爆掉(附上錯誤訊息)。
docOf :: FilePath -> Text -> Document
docOf path src = case parseDocument path src of
  Right d -> d
  Left es -> error (T.unpack (T.intercalate "\n" (map renderMdError es)))

-- | 第一個節;沒有節就讓測試爆掉。
firstSection :: Document -> Section
firstSection d = case docSections d of
  (s : _) -> s
  [] -> error "這份文件應該至少有一個節"

entityFileOf :: Document -> (EntityFile, [MdWarning])
entityFileOf d = case parseEntityFile d of
  Right r -> r
  Left es -> error (T.unpack (T.intercalate "\n" (map renderMdError es)))

levelFileOf :: Document -> (LevelFile, [MdWarning])
levelFileOf d = case parseLevelFile d of
  Right r -> r
  Left es -> error (T.unpack (T.intercalate "\n" (map renderMdError es)))
