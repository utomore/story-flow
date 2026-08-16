---
id: func-0003
type: spec
title: markdown-section-format
description: Markdown 分節格式與核心型別的雙向解析與寫回
status: done
created: 2026-08-16
updated: 2026-08-16
depends-on: [func-0002]
related-adr: [adr-0002, adr-0003, adr-0004]
related-spec: [func-0001, func-0002, func-0004]
---

# P1 Markdown 分節格式解析 功能規格

## 功能概述

`storyflow-md` 負責 Markdown 檔與核心型別之間的雙向轉換,純函式、吃 `Text` 吐型別。
Markdown 檔是唯一的真相來源(ADR-0002),所以這個套件的正確性直接等於資料的安全性:
解析漏一個欄位就是設定遺失,寫回破壞排版就是作者的手稿被工具改壞。

本規格同時**確定 Level 場景樹的 Markdown 格式**——architecture.md 只給了 Entity 的分節
格式範例,`levels/教室.md` 長什麼樣是空白的。決定採**標題階層即樹**:Markdown 標題層級
(`##` / `###` / `####`)直接對應 Node 的父子關係,文件順序即 `order`。作者因此不必手寫
`parent` 與 `order` 這兩個最容易寫錯又最容易被工具重算的欄位。

**round-trip 的嚴格度**:採「**未碰過的區塊逐字保留**」。解析後未做任何修改就寫回,
必須與原檔**位元組相等**;修改某一個片段時,只有該片段的 `meta` 區塊被重新序列化,
檔案其餘部分(含作者的空行、YAML 註解、縮排風格)逐字不動。這是本套件所有設計取捨的源頭。

**功能邊界**

做:Entity 檔與 Level 檔的解析、寫回、單節修改、節層繼承規則、帶行號的錯誤回報。

不做:任何檔案 IO(`storyflow-md` 吃 `Text`,讀檔是 func-0004 的事)、SQLite、
關聯的跨檔驗證(目標 Entity 是否存在要查索引,屬 func-0004)、型別註冊表的合規檢查
(`checkEntity` 在 core,由 service 於 P2 呼叫)。

**驗收標準**

- architecture.md 的琳達範例檔解析後得到 1 個主體 Entity + 2 個片段 Entity,欄位全對
- 本規格定義的教室 Level 範例檔解析後,交給 `buildTree` 能建出 ADR-0004 的那棵樹
- round-trip 位元組相等:對 10 份風格各異的測試檔(CRLF/LF、有無註解、縮排不一)
  `render . parse == id`
- 修改單一節的 `summary` 後寫回,`git diff` 只顯示該節 `meta` 區塊的那一行
- 所有解析錯誤都帶檔名與行號

## 相依性

`depends-on: [func-0002]` —— 需要 core 的全部型別(`Meta` / `Entity` / `Level` / `Node` /
`Link` / `Id`)與其 aeson 實例。

**可與 func-0004(store)平行開發**:兩者都只依賴 func-0002,彼此沒有介面往來。
唯一的交會點是 func-0004 的「索引重建」需要呼叫本套件的 `parseDocument`——因此
func-0004 的 T6/T7(rebuild 與等價性)必須等本規格完成,其餘 9 項不受影響。
兩份規格由不同人同時開工是安全的,合流點只有 `parseDocument` 一個函式簽名。

## 實作方式

### 模組劃分

```
storyflow-md
├── StoryFlow.Md.Document   -- Document / Section 資料型別(帶原始片段與行號)
├── StoryFlow.Md.Lexer      -- 逐行切塊:frontmatter / 標題 / meta 區塊 / 正文
├── StoryFlow.Md.Yaml       -- HsYAML → aeson Value → core 的 FromJSON;以及 meta 區塊序列化
├── StoryFlow.Md.Inherit    -- 節層繼承檔案層的合併規則
├── StoryFlow.Md.Parse      -- Document → Entity 檔 或 Level 檔
├── StoryFlow.Md.Render     -- Document → Text(逐字保留)、單節修改
└── StoryFlow.Md.Error      -- MdError 與訊息渲染
```

### 兩階段解析

解析刻意分成兩階段,而不是一步到位。第一階段(`Lexer` → `Document`)是**無損的結構切分**,
它只認得「哪幾行是 frontmatter、哪一行是節標題、哪一段是 `meta` 區塊」,並把每一塊的
**原始文字原封不動保留**;第二階段(`Parse`)才把原始文字解讀成核心型別。

這個分法是「未碰過的區塊逐字保留」的實作基礎:`Document` 同時持有原始位元組與解讀結果,
寫回時預設吐原始文字,只有被明確修改的區塊才重新序列化。

```haskell
data LineEnding = LF | CRLF

data Document = Document
  { docPath       :: FilePath        -- 僅用於錯誤訊息
  , docFrontRaw   :: Text            -- frontmatter 原始內容(不含 --- 界線)
  , docPreamble   :: Text            -- frontmatter 之後、第一個節標題之前的原始文字
  , docSections   :: [Section]
  , docEnding     :: LineEnding      -- 全檔行尾風格,寫回時沿用
  , docFinalNL    :: Bool            -- 原檔是否以換行結尾
  }

data Section = Section
  { secLevel      :: Int             -- 標題層級,## = 2
  , secHeadingRaw :: Text            -- 原始標題行,含 {#id}
  , secTitle      :: Text            -- 去掉 {#id} 與 # 後的標題文字
  , secId         :: Id
  , secMetaRaw    :: Maybe Text      -- 原始 ```meta 區塊,含前後 fence 行
  , secBodyRaw    :: Text            -- meta 區塊之後到下一個節標題之前的原始文字
  , secLine       :: Int             -- 標題行在原檔的行號,錯誤訊息用
  }
```

`Section` 只存原始文字,不存解析後的 `Meta`。解析是 `Parse` 模組的函式,可重複呼叫,
`Document` 因此永遠是原檔的忠實表示。

**混合行尾**(檔案裡 LF 與 CRLF 並存,常見於跨平台編輯)的處理:`docEnding` 取全檔多數,
但 `secHeadingRaw` / `secBodyRaw` / `secMetaRaw` 保留的是**含原始行尾的切片**,因此
逐字寫回時混合行尾也不會被正規化。`docEnding` 只在**新產生**的行(重新序列化的 meta 區塊)
上使用。

### Entity 檔的解析

檔案層 frontmatter 描述主體 Entity,`docPreamble` 是它的 `body`;每個節是一個片段 Entity。

```haskell
data EntityFile = EntityFile
  { efMain      :: Entity      -- 檔案層主體
  , efFragments :: [Entity]    -- 各節
  }

parseDocument :: FilePath -> Text -> Either [MdError] Document
parseEntityFile :: Document -> Either [MdError] EntityFile
```

`meta` 區塊的內容是 **`MetaOverride`**:每個欄位都是 `Maybe`,未寫的欄位交給繼承規則填補。

```haskell
data MetaOverride = MetaOverride
  { moType     :: Maybe Text
  , moVault    :: Maybe Text
  , moSummary  :: Maybe Text
  , moTags     :: Maybe [Text]
  , moStatus   :: Maybe Status
  , moTimeline :: Maybe Timeline
  , moAliases  :: Maybe [Text]
  , moLinks    :: Maybe [Link]
  , moSource   :: Maybe Source
  , moRevision :: Maybe Int
  , moCreated  :: Maybe Day
  , moUpdated  :: Maybe Day
  }
```

### 節層繼承規則(`StoryFlow.Md.Inherit`)

architecture.md 只寫了「節層未寫的欄位繼承檔案層(`vault`/`type`/`timeline`/`status` 等)」。
「等」需要被定義清楚,否則兩個實作者會做出兩種行為:

| 欄位 | 規則 | 理由 |
|---|---|---|
| `id` | **不繼承**,來自節標題的 `{#id}`;缺少即錯誤 | 每個片段必須有自己的身分 |
| `title` | **不繼承**,來自節標題文字 | 同上 |
| `vault` / `type` / `status` / `timeline` / `source` | 繼承 | 同一份檔案裡的片段幾乎總是同一個 vault/型別/狀態 |
| `created` / `updated` | 繼承 | 作者不會想每節寫一次日期 |
| `tags` | **聯集去重**(檔案層 + 節層) | 檔案層放共通標籤、節層放專屬標籤是最自然的用法;純覆寫會逼作者重寫共通標籤 |
| `summary` | **不繼承**,節層未寫即空字串並產生警告 | 片段的一句話總結是衝突偵測撈 context 的主要輸入,繼承主體的總結等於製造假資訊 |
| `aliases` | **不繼承** | 別名屬於主體(角色本人),不屬於「他的外貌」這個片段 |
| `links` | **不繼承** | 關聯是片段自己的;繼承會讓每個片段都莫名帶上主體的全部關聯 |
| `revision` | **不繼承**,未寫時視為 `1` | 繼承會讓多個片段共用同一個 revision 值,樂觀鎖(func-0004)就失去意義 |

```haskell
inheritMeta :: Meta -> Id -> Text -> MetaOverride -> (Meta, [MdWarning])
--             ^檔案層  ^節 id ^節標題              ^節層覆寫
```

`summary` 缺漏回 `MdWarning` 而非 `MdError`:作者手寫時漏寫一句總結不該讓整個檔案無法讀取,
但工具要講出來。警告與錯誤分離的原則貫穿本套件——**任何無法還原資料的情況是錯誤,
任何品質問題是警告**。

### Level 檔的解析:標題階層即樹

檔案層 frontmatter 的 `type: level` 是判別依據——`type` 為 `level` 時走 Level 解析,
否則走 Entity 解析。`level` 因此是保留型別鍵,不可用於 `types/registry/`(由 func-0002 的
`validateRegistry` 檢查)。

格式:

````markdown
---
id: lvl-3a01
vault: liftgame
type: level
title: 教室
summary: 崩塌後的午後教室,琳達與塔主的第一次對峙
status: canon
source: human
revision: 1
created: 2026-08-16
updated: 2026-08-16
---

場景整體的說明寫在這裡(對應 Level 的 body,不進 Node)。

## 午後的教室 {#nod-0001}

```meta
kind: scene
summary: 午後的教室,窗外是崩塌後的天際線
links:
  - {kind: involves, target: ent-c41d}
```

### 出場人物 {#nod-0002}

```meta
kind: cast
links:
  - {kind: involves, target: ent-7f3a}
  - {kind: involves, target: ent-8b20}
```

#### 琳達走向講台 {#nod-0004}

```meta
kind: interaction
```

##### A-to-B 對話 {#nod-0005}

```meta
kind: dialogue
links:
  - {kind: references, target: ent-d902}
```

###### 琳達選擇動手 {#nod-0007}

```meta
kind: branch
```

### 鏡頭 {#nod-0003}

```meta
kind: camera
summary: 自窗外緩推至講台,焦段 35mm
```
````

規則:

- **最淺的標題層級是根**。全檔第一個節的層級定為根層級(上例是 `##`),其 `parent = Nothing`
- **層級 +1 即子節點**,父節點是它前面最近的、層級小 1 的節
- **`order` 由文件順序決定**:同一父節點下的第 n 個子節點,`order = n`(從 1 起算)
- **`kind` 必填**,寫在 `meta` 區塊。缺少即錯誤(不像 Entity 的 `type` 可繼承——Node 的 kind
  是結構語意,繼承毫無意義)
- **`entities` 由 `involves` / `references` 關聯推導**,不另設欄位。ADR-0003 說 Node 指向
  Entity,而 `Link` 已經能表達方向與語意;再開一個 `entities` 欄位等於同一件事有兩種寫法
- **跳級是錯誤**(`##` 之後直接出現 `####`):`HeadingSkip`。跳級的父子關係有歧義,
  與其猜不如報錯
- **超過根層級的標題**(根是 `##` 卻出現 `#`):`HeadingAboveRoot`
- `convergesTo` 只是 `meta` 裡的一筆 `links`,**不影響結構**(ADR-0004)

```haskell
data LevelFile = LevelFile
  { lfLevel :: Level
  , lfNodes :: [Node]     -- parent / order 已由標題階層填好
  }

parseLevelFile :: Document -> Either [MdError] LevelFile
```

`parseLevelFile` 產出的 `[Node]` 直接餵給 core 的 `buildTree` 就能得到 `NodeTree`。
本套件**不呼叫** `buildTree`——結構合法性是 core 的職責,這裡只負責把文字變成 Node 清單。
(實務上標題階層天然保證了單一父、無環、無孤兒;`buildTree` 仍會再驗一次,因為 Node 也可能
來自 API 而非檔案。)

`lvlRoot` 的處理:frontmatter 若寫了 `root`,與實際第一個節的 id 不符時回 `RootMismatch`;
未寫則以第一個節的 id 填入。作者不必手寫。

### 寫回(`StoryFlow.Md.Render`)

```haskell
-- | 逐字重組。未經修改的 Document 保證 renderDocument (parseDocument p t) == t
renderDocument :: Document -> Text

-- | 修改單一節的 Meta:只有該節的 meta 區塊被重新序列化,其餘逐字不動。
--   節不存在回 Left。
updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document

-- | 在指定節之後插入新節(P2 的 CLI 建立片段時用)
insertSection :: Maybe Id -> Section -> Document -> Either MdError Document

-- | 刪除節(連同其 meta 區塊與正文)
removeSection :: Id -> Document -> Either MdError Document
```

`renderDocument` 就是把 `docFrontRaw`、`docPreamble`、每個 `Section` 的
`secHeadingRaw` / `secMetaRaw` / `secBodyRaw` 依序接起來,前後補上 `---` 界線與
`docFinalNL`。因為每一塊都是原始切片,位元組相等是結構上保證的,不是靠測試碰運氣。

`updateSection` 的實作:對目標 `Section` 重新序列化 `secMetaRaw`,其他 `Section` 的欄位
一個字都不碰。序列化採**固定欄位順序**(`type` → `summary` → `tags` → `status` →
`timeline` → `aliases` → `source` → `revision` → `links`),與 architecture.md 的範例一致;
值為 `Nothing` 的欄位不輸出。固定順序讓同一份資料每次寫出都一樣,`git diff` 才乾淨。

**meta 區塊的序列化自己寫,不用 YAML 編碼器**。理由:只有被修改的節需要重寫,格式完全由
我們決定(欄位順序固定、`links` 用 `- {kind: ..., target: ...}` 的流式風格、字串只在
必要時加引號);引入 YAML 編碼器反而要對抗它的排版偏好。解析方向則用
**`HsYAML` + `HsYAML-aeson`**——純 Haskell 無 C 相依,把 YAML 轉成 aeson `Value` 後套用
func-0002 在 `StoryFlow.Core.Json` 定義的 `FromJSON` 實例,編碼規則因此全系統只有一份。

### 錯誤處理

```haskell
data MdError = MdError
  { errPath :: FilePath
  , errLine :: Int
  , errKind :: MdErrorKind
  }

data MdErrorKind
  = NoFrontmatter
  | UnterminatedFrontmatter
  | FrontmatterYaml Text            -- HsYAML 的訊息
  | SectionYaml Id Text
  | HeadingWithoutId Text           -- 標題文字
  | DuplicateSectionId Id
  | IdPrefixMismatch Id Text        -- 實際 id, 期望的前綴
  | HeadingSkip Int Int             -- 前一個層級, 這一個層級
  | HeadingAboveRoot Int Int
  | UnterminatedMetaBlock
  | MissingNodeKind Id
  | RootMismatch Id Id
  | RequiredFieldMissing Text       -- 檔案層缺必填欄位

data MdWarning
  = MissingSummary Id
  | CustomLinkKind Id Text          -- 用了自訂關聯,附上 suggestCoreKind 的建議
  | EmptyBody Id
```

**所有錯誤帶行號**,而且解析**盡量往下走完再一次回報全部錯誤**——作者手改一份檔案常一次
壞好幾節,一次列完比修一個跑一次快得多。只有 frontmatter 層級的錯誤(`NoFrontmatter` /
`UnterminatedFrontmatter`)會中止解析,因為後面的內容失去了繼承來源,再解析下去只會產生
一連串誤導的次生錯誤。

`renderMdError :: MdError -> Text` 輸出 `檔案:行號: 訊息` 格式,與編譯器/linter 的慣例一致,
編輯器可直接跳轉。

## 使用到的既有串接介面

func-0002 的核心型別與函式:

| 介面 | 用途 |
|---|---|
| `data Meta`, `data Status`, `data Source`, `data Timeline` | 解析目標 |
| `data Entity`, `data Level`, `data Node`, `data NodeKind` | 解析目標 |
| `data Link`, `data LinkKind`, `parseLinkKind :: Text -> LinkKind` | `links` 欄位解析,未知字串成 `Custom` |
| `renderLinkKind :: LinkKind -> Text` | meta 區塊序列化 |
| `suggestCoreKind :: Text -> Maybe LinkKind` | 產生 `CustomLinkKind` 警告的建議內容 |
| `newtype Id`, `data Ref`, `parseId`, `renderId`, `parseRef`, `renderRef` | `{#id}` 與 `links` 的 `target` 解析 |
| `parseNodeKind :: Text -> Either e NodeKind`, `renderNodeKind` | Level 檔的 `kind` 欄位 |
| `StoryFlow.Core.Json` 的 `FromJSON` 實例 | YAML → aeson `Value` → 核心型別 |

func-0001 的建置骨架:`storyflow-md` 套件與其 test-suite、UTF-8 測試進入點。

外部套件介面:

| 介面 | 來源 | 用途 |
|---|---|---|
| `Data.YAML.decode1 :: FromYAML a => ByteString -> Either (Pos, String) a` | `HsYAML` | YAML 解析與位置資訊 |
| `Data.YAML.Aeson.decode1 :: ByteString -> Either (Pos, String) Value` | `HsYAML-aeson` | YAML → aeson `Value` |
| `Data.Aeson.fromJSON :: FromJSON a => Value -> Result a` | `aeson` | `Value` → 核心型別 |
| `Data.Text` (`splitOn`, `stripPrefix`, `breakOn`, `lines`) | `text` | 逐行切塊 |

## 新增的介面

| 模組 | 介面 |
|---|---|
| `StoryFlow.Md.Document` | `data Document`, `data Section`, `data LineEnding`, `sectionById :: Id -> Document -> Maybe Section` |
| `StoryFlow.Md.Parse` | `parseDocument :: FilePath -> Text -> Either [MdError] Document`, `documentKind :: Document -> Either [MdError] DocKind`, `parseEntityFile :: Document -> Either [MdError] (EntityFile, [MdWarning])`, `parseLevelFile :: Document -> Either [MdError] (LevelFile, [MdWarning])`, `data EntityFile`, `data LevelFile`, `data DocKind` |
| `StoryFlow.Md.Inherit` | `data MetaOverride`, `emptyOverride :: MetaOverride`, `inheritMeta :: Meta -> Id -> Text -> MetaOverride -> (Meta, [MdWarning])` |
| `StoryFlow.Md.Render` | `renderDocument :: Document -> Text`, `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document`, `insertSection :: Maybe Id -> Section -> Document -> Either MdError Document`, `removeSection :: Id -> Document -> Either MdError Document`, `renderMetaBlock :: MetaOverride -> LineEnding -> Text` |
| `StoryFlow.Md.Error` | `data MdError`, `data MdErrorKind`, `data MdWarning`, `renderMdError :: MdError -> Text`, `renderMdWarning :: MdWarning -> Text` |
| `StoryFlow.Md.Yaml` | `decodeMeta :: Text -> Either Text MetaOverride`, `decodeFrontmatter :: Text -> Either Text Meta` |

**格式契約**(本規格新確立、需回寫 architecture.md):Level 檔的 Markdown 格式為
「標題階層即樹、文件順序即 `order`、`kind` 寫在 `meta` 區塊、`entities` 由
`involves`/`references` 關聯推導」。

## TodoList

- [x] T1: `StoryFlow.Md.Document` —— `Document` / `Section` / `LineEnding` 型別與 `sectionById`
- [x] T2: `StoryFlow.Md.Lexer` —— 逐行切塊:frontmatter 界線、節標題行、` ```meta ` 區塊、正文,全部保留原始切片與行號
- [x] T3: 節標題 `{#id}` 屬性語法解析 —— 標題文字與 id 分離、缺 id / 重複 id / 前綴不符的錯誤
- [x] T4: `StoryFlow.Md.Yaml` —— HsYAML → aeson `Value` → core `FromJSON`,frontmatter 與 `meta` 區塊兩個入口
- [x] T5: `StoryFlow.Md.Inherit` —— 依上表的欄位規則合併,`tags` 聯集、`summary` 缺漏產生警告
- [x] T6: `parseEntityFile` —— 檔案層主體 Entity + 各節片段 Entity
- [x] T7: `parseLevelFile` —— 標題階層 → `parent` / `order`,`kind` 必填,`entities` 由關聯推導,跳級與越級的錯誤
- [x] T8: `renderDocument` —— 逐字重組,未修改時位元組相等
- [x] T9: `updateSection` / `insertSection` / `removeSection` 與 `renderMetaBlock` 的固定欄位順序序列化
- [x] T10: `StoryFlow.Md.Error` —— 錯誤與警告型別、`檔案:行號: 訊息` 渲染、多錯誤一次回報的收集機制

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.Md.DocumentSpec` | `Document` / `Section` 欄位齊全可建構;`sectionById` 命中與未命中;`LineEnding` 對 LF、CRLF、混合行尾檔案的判定取多數 |
| T2 | `StoryFlow.Md.LexerSpec` | 琳達範例檔切出 1 段 frontmatter + 1 段 preamble + 2 個 Section,各自的 `secLine` 行號正確;無 frontmatter → `NoFrontmatter`;frontmatter 只有開頭 `---` → `UnterminatedFrontmatter`;` ```meta ` 未關閉 → `UnterminatedMetaBlock`;正文中出現的 ` ``` ` 程式碼區塊**不**被誤判為 meta 區塊 |
| T3 | `StoryFlow.Md.HeadingSpec` | `## 外貌 {#ent-7f3b}` 得 title `外貌` 與 id `ent-7f3b`;無 `{#id}` → `HeadingWithoutId`;同檔兩節同 id → `DuplicateSectionId`;Entity 檔用 `{#nod-0001}` → `IdPrefixMismatch`;標題文字含 `#` 字元時不誤切 |
| T4 | `StoryFlow.Md.YamlSpec` | 琳達的 `meta` 區塊解出 `type` / `summary` / `tags` / `timeline` / 三筆 `links`(含 `contradicts` 帶 `note`);YAML 語法錯誤回 `SectionYaml` 帶該節 id 與 HsYAML 訊息;未知欄位被忽略不報錯;`links` 的 `target` 為 `shared-lore:ent-1234` 時解析為跨 Vault `Ref` |
| T5 | `StoryFlow.Md.InheritSpec` | 節層未寫 `vault`/`type`/`status`/`timeline`/`source`/`created`/`updated` 時全部繼承檔案層;節層寫了則覆寫;`tags` 為檔案層與節層的聯集去重;`summary` **不**繼承且缺漏時回 `MissingSummary` 警告;`links` / `aliases` 不繼承(節層未寫即空);`revision` 未寫為 `1` 而非繼承檔案層的值 |
| T6 | `StoryFlow.Md.ParseEntitySpec` | architecture.md 的琳達範例檔解析得 1 個主體(`ent-7f3a`,body 為 preamble)+ 2 個片段(`ent-7f3b` / `ent-7f3c`),逐欄比對預期值;`ent-7f3c` 的三筆 links 與 `timeline` 正確 |
| T7 | `StoryFlow.Md.ParseLevelSpec` | 本規格的教室範例檔解析得 1 個 Level + 6 個 Node(範例檔共六個標題,原本寫 7 是筆誤,見實作備註 8);`nod-0002` 與 `nod-0003` 的 `parent` 皆為 `nod-0001` 且 `order` 分別為 1、2;`nod-0007` 的 parent 為 `nod-0005`;`entities` 由 `involves`/`references` 推導出琳達與塔主;缺 `kind` → `MissingNodeKind`;`##` 後接 `####` → `HeadingSkip`;frontmatter 的 `root` 與第一個節不符 → `RootMismatch`;產出的 `[Node]` 餵給 core 的 `buildTree` 成功建樹 |
| T8 | `StoryFlow.Md.RenderSpec`(逐字) | 對 10 份風格各異的測試檔(LF、CRLF、混合行尾、YAML 含註解、縮排 2/4 空白、檔尾有無換行、preamble 為空、僅 frontmatter 無節)驗證 `renderDocument . parseDocument == id` 位元組相等 |
| T9 | `StoryFlow.Md.EditSpec` | `updateSection` 改 `ent-7f3b` 的 `summary` 後,寫回結果與原檔逐行比對**只有該節 meta 區塊的 summary 那一行不同**;`renderMetaBlock` 的欄位順序固定且 `Nothing` 欄位不輸出;同一份資料連續序列化兩次結果相同;`insertSection` 插入後可再被 `parseDocument` 解析;`removeSection` 移除節連同其 meta 與正文;操作不存在的 id 回 `Left` |
| T10 | `StoryFlow.Md.ErrorSpec` | `renderMdError` 輸出 `characters/琳達.md:12: ...` 格式;一份含三個獨立節錯誤的檔案**一次回報三筆**且行號各自正確;frontmatter 層級錯誤中止解析且只回一筆(不產生次生錯誤);`CustomLinkKind` 警告帶 `suggestCoreKind` 的建議 |

## 實作備註

實作於 2026-08-16 完成,`cabal build all` / `cabal test all` 綠燈(md 160 examples、
core 157、types 21、store 4,`scripts/check.ps1` exit 0)。模組劃分、兩階段解析、
繼承規則表、錯誤/警告的分界都照本規格實作,以下九點是規格沒寫死、實作時補齊或
偏離的地方(1–4 已與開發者確認)。

1. **`MetaOverride` 補了 `moKind :: Maybe NodeKind`**。規格的欄位表沒有 `kind`,
   但 Level 檔的節一定有 `kind`;少了這一欄,`updateSection` 重新序列化時會把
   `kind:` 整行刪掉,等於編輯一次就毀掉樹的語意。序列化順序因此改為
   `kind` → `type` → `vault` → `summary` → `tags` → `status` → `timeline` →
   `aliases` → `source` → `revision` → `created` → `updated` → `links`——規格給的
   九個欄位順序原樣是它的子序列,補進來的四個(`kind`/`vault`/`created`/`updated`)
   是為了「作者寫了什麼就留什麼」,不能在重寫時靜靜蒸發。

2. **`timeline` 接受純字串簡寫**。architecture.md 的琳達範例寫
   `timeline: 埃提亞崩塌前`,而 core 的 `FromJSON Timeline` 吃的是
   `{label, order}` 物件——照規格「一律套 core 的實例」會讓文件自己的範例檔
   變成非法輸入。作法:`StoryFlow.Md.Yaml` 在 aeson `Value` 層把字串補成
   `{label: ...}` 再交給 core,編碼規則仍然只有一份,只是多接受一種表層寫法;
   寫回時 `order` 為空就寫回字串簡寫,`git diff` 才不會因為工具的偏好而改寫。

3. **`secMetaRaw` 的界線含前導空行**。規格說它是「原始 ` ```meta ` 區塊,含前後
   fence 行」,但標題行與 fence 之間的空行(範例檔都有一行)必須有地方放,否則
   位元組相等會破掉。定義改為「標題行之後到結尾 fence 行(含)的原始切片」,
   重新序列化時保留前導空行、只換掉 fence 之間的內容。

4. **切片含界線行的行尾字元**。`docFrontRaw` 由開頭 `---` 的行尾字元起算,
   `docPreamble` 由結尾 `---` 的行尾字元起算,`renderDocument` 只重生 `---` 三個
   字元本身。這樣連「frontmatter 界線用 LF、正文用 CRLF」的混合檔,位元組相等
   也是結構保證而不是靠 `docEnding` 猜。代價是 frontmatter 界線行只接受剛好
   `---`(不接受尾隨空白)。`docFinalNL` 因此在寫回時用不到(行尾已在切片裡),
   保留是給 `insertSection` 在檔尾補節時判斷要不要先補一個換行。

5. **`MdErrorKind` 補了 `UnknownSectionId Id`**。規格要求三個編輯函式在節不存在時
   回 `Left`,卻沒有給對應的錯誤種類。

6. **分節界線:第一個帶 `{#id}` 的標題才開始分節**。琳達範例的 `# 琳達` 因此留在
   `docPreamble`(規格 T2 要的「1 段 preamble + 2 個 Section」);第一個節之後的
   標題一律必須帶 `{#id}`,否則是 `HeadingWithoutId`(規格 T3 要的)。兩條驗收
   標準只有這個讀法能同時滿足。副作用:片段正文裡不能再用 Markdown 子標題——
   對「節即片段」的格式來說這是想要的行為。`{#id}` 存在但不是合法 ID(如
   `{#zzz-0001}`)也回 `HeadingWithoutId`,因為 `IdPrefixMismatch` 需要一個
   建構得出來的 `Id`。

7. **`parseEntityFile` / `parseLevelFile` 採「新增的介面」表的簽名**,即
   `Either [MdError] (EntityFile, [MdWarning])`;「實作方式」節裡不帶警告的那個
   簽名是省略版。判別檔案身分的 `documentKind` 也照介面表實作。

8. **教室範例檔是 6 個 Node 不是 7 個**:規格的範例檔只有六個標題
   (`nod-0001`/`0002`/`0004`/`0005`/`0007`/`0003`),1-to-1 表原本寫 7 是筆誤,
   已一併更正。T7 的其餘斷言(parent、order、`buildTree` 建樹)全部照原文驗證。

9. **`EmptyBody` 警告只對 Entity 片段發**。Level 的 Node 承載的是結構與演出,
   正文本來就常常是空的,對每個 Node 發一次警告只會讓真正的警告被淹沒。
   `MissingSummary` 與 `CustomLinkKind` 則 Entity / Node 一視同仁。

**回寫 architecture.md**:Level 檔的格式契約在 bcd20cc 已經寫進 architecture.md
的「Level 場景樹」節,本次只補上實作備註 2 與 6 兩條格式規則(`timeline` 的字串
簡寫、`# 標題` 留在 preamble),其餘與燈塔一致,無衝突。
