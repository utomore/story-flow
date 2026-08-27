-- | 測試共用的範例檔。
--
-- 'lindaMd' 逐字取自 system.md 的「Markdown 分節格式」節,
-- 'classroomMd' 逐字取自 entity-graph-core/F003 的「Level 檔的解析:標題階層即樹」節,
-- 'packMd' 取自 system.md「pack Markdown」節的 Kenney UI Pack 範例(改成可解析的
-- 合法值:@license@ 換成 'Ref' 格式、補齊必填欄位),'licensesMd' 是
-- graph-core/F004 依 design.md「授權節點」段落新增的範例(system.md 沒有逐字
-- 範例可抄)。
module Aapms.Md.Fixtures
  ( -- * 範例檔
    lindaMd
  , classroomMd
  , packMd
  , licensesMd
  , synthPackMd

    -- * 建構輔助
  , idOf
  , refOf
  , vaultOf
  , typeOf
  , day0
  , crlf
  , dropFinalNL
  , docOf
  , firstSection
  , topicOf
  , levelOf
  , packOf
  , licensesOf
  , leftKind
  , leftLine
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian)
import Numeric (showHex)
import Aapms.Core.Asset (Asset)
import Aapms.Core.Entity (Entity)
import Aapms.Core.Id (Id, Ref, VaultId (..), parseId, parseRef)
import Aapms.Core.Level (Level, Node)
import Aapms.Core.License (License)
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Pack (Pack)
import Aapms.Md

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

-- | system.md「pack Markdown」節的 Kenney UI Pack 範例,改成可解析的合法值:
-- @license@ 從示意的 @cc0@ 換成 'Ref' 格式(@lic-00000001@)、frontmatter 補上
-- @created@;檔案層加 @tags@ 供節層 tags 聯集去重測試用。第二個節不寫
-- @vault@ / @status@,測試檔案層繼承。
packMd :: Text
packMd =
  T.unlines
    [ "---"
    , "id: pck-4a1e9c02"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: Kenney UI Pack"
    , "vendor: kenney"
    , "archive: library/packs/kenney/ui-pack/kenney_ui-pack.zip"
    , "sha256: 3c1f9a2b"
    , "license: lic-00000001"
    , "status: canon"
    , "tags: [商用]"
    , "source: scan"
    , "revision: 4"
    , "created: 2026-08-10"
    , "updated: 2026-08-23"
    , "---"
    , ""
    , "# Kenney UI Pack"
    , ""
    , "掃描時產生的摘要;作者可以在這裡寫筆記。"
    , ""
    , "## panel_book.png {#ast-3f9c1d20}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "name: ui_gui_travel-book-frame_001"
    , "entry: PNG/panel_book.png"
    , "sha256: 9f3ac81b"
    , "tags: [gui, book]"
    , "summary: 書本風格的面板框"
    , "meta: {width: 256, height: 192}"
    , "links:"
    , "  - {kind: depicts, target: ent-7f3a}"
    , "```"
    , ""
    , "## panel_scroll.png {#ast-3f9c1d21}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: PNG/panel_scroll.png"
    , "sha256: 9f3ac81c"
    , "tags: [gui]"
    , "```"
    ]

-- | graph-core/F004 新增:授權節點檔,依 design.md「授權節點」段落與
-- 「節層繼承規則」表格(licenses.md 併入主題檔 / Level 檔那一欄,@type@ 繼承)
-- 編寫。兩節分別示範「全部八維度都寫」與「只寫兩個必填維度」。
licensesMd :: Text
licensesMd =
  T.unlines
    [ "---"
    , "id: lic-00000001"
    , "vault: liftgame-assets"
    , "type: asset-license"
    , "title: 授權登記"
    , "status: canon"
    , "source: human"
    , "created: 2026-08-10"
    , "updated: 2026-08-10"
    , "---"
    , ""
    , "本檔登記本 vault 用到的全部授權條款。"
    , ""
    , "## CC0 {#lic-0000000a}"
    , ""
    , "```meta"
    , "commercial: true"
    , "attribution_required: false"
    , "```"
    , ""
    , "## CC-BY 4.0 {#lic-0000000b}"
    , ""
    , "```meta"
    , "commercial: true"
    , "attribution_required: true"
    , "credit_text: 需標註原作者"
    , "modification_allowed: true"
    , "redistribution_allowed: true"
    , "resale_allowed: false"
    , "nft_allowed: false"
    , "source_url: https://creativecommons.org/licenses/by/4.0/"
    , "```"
    ]

-- | 合成 n 節的 pack.md(D4:'appendSection' 對 1,693 節文件的驗收用測試內
-- 產生器合成,不需要真實大檔)。每節 id 各自不同、欄位齊全,整份文件本身
-- 合法可解析。每節之後隔__兩個__空行(而不是一個)——讓最後一節的
-- @secBodyRaw@ 已經是 @"\\n\\n"@,'Aapms.Md.Render.appendSection' 的
-- @blankTail@ 補齊分隔空行時剛好是 no-op,「前面節位元組不變」才能斷言到
-- 逐位元組相等,不必靠「插入點本來就會變」的但書。
synthPackMd :: Int -> Text
synthPackMd n =
  T.unlines $
    [ "---"
    , "id: pck-00000001"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: 合成 Pack"
    , "created: 2026-08-10"
    , "updated: 2026-08-10"
    , "---"
    , ""
    , "合成測試用。"
    , ""
    ]
      ++ concatMap section [1 .. n]
  where
    section :: Int -> [Text]
    section i =
      [ "## asset " <> T.pack (show i) <> " {#" <> idFor i <> "}"
      , ""
      , "```meta"
      , "type: asset-image"
      , "entry: img/" <> T.pack (show i) <> ".png"
      -- 加引號:sha256 值可能全是十進位數字(如 hex8 1 = "00000001"),不加
      -- 引號會被 YAML 誤判成數字純量,decode Sha256(FromJSON 期待字串)失敗
      , "sha256: \"" <> hashFor i <> "\""
      , "```"
      , ""
      , ""
      ]

    idFor :: Int -> Text
    idFor i = "ast-" <> hex8 i

    hashFor :: Int -> Text
    hashFor i = hex8 i <> "00000000"

    hex8 :: Int -> Text
    hex8 i = T.justifyRight 8 '0' (T.pack (showHex i ""))

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("fixture 的 ref 不合法:" <> show e)

-- | 由字面值直接取得 'VaultId'(不像 'idOf' 要求 @vlt-\<hex\>@ 格式——md 的
-- fixture 沿用既有範例的任意 vault 名稱,如 @liftgame@)。
vaultOf :: Text -> VaultId
vaultOf = VaultId

typeOf :: Text -> TypeKey
typeOf = TypeKey

day0 :: Day
day0 = fromGregorian 2026 8 16

-- | 把 LF 檔轉成 CRLF 檔。
crlf :: Text -> Text
crlf = T.replace "\n" "\r\n"

-- | 去掉檔尾換行。
dropFinalNL :: Text -> Text
dropFinalNL = T.dropWhileEnd (`elem` ['\r', '\n'])

-- | 解析成 'Document',失敗就讓測試直接爆掉(附上錯誤訊息)。
docOf :: Text -> Document
docOf src = case parseDocument src of
  Right d -> d
  Left e -> error (T.unpack (renderMdError e))

-- | 第一個節;沒有節就讓測試爆掉。
firstSection :: Document -> Section
firstSection d = case docSections d of
  (s : _) -> s
  [] -> error "這份文件應該至少有一個節"

topicOf :: Document -> (Entity, [Entity])
topicOf d = case toTopic d of
  Right r -> r
  Left e -> error (T.unpack (renderMdError e))

levelOf :: Document -> (Level, [Node])
levelOf d = case toLevel d of
  Right r -> r
  Left e -> error (T.unpack (renderMdError e))

packOf :: Document -> (Pack, [Asset])
packOf d = case toPack d of
  Right r -> r
  Left e -> error (T.unpack (renderMdError e))

licensesOf :: Document -> [License]
licensesOf d = case toLicenses d of
  Right r -> r
  Left e -> error (T.unpack (renderMdError e))

-- | 取出 'Left' 的 'errKind';'Right' 時是 'Nothing'。斷言「這個呼叫應該以
-- 某種 'MdErrorKind' 失敗」時比對 @Just <kind>@ 用,失敗訊息比硬掰型別更好讀。
leftKind :: Either MdError a -> Maybe MdErrorKind
leftKind = either (Just . errKind) (const Nothing)

-- | 同 'leftKind',取 'errLine'。
leftLine :: Either MdError a -> Maybe Int
leftLine = either (Just . errLine) (const Nothing)
