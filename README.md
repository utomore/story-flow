# aapms

故事設定的**片段圖譜**與**場景樹**管理工具,以 Haskell 撰寫,API 優先。

核心主張:**能被關聯的最小單位是「片段」,不是「文件」**。
「世界觀:歷史」不是一個 Entity;歷史裡「描述埃提亞這個地區在崩塌前的樣貌」那一段才是。
片段夠細,關聯才有意義,「這段新劇情和過去的故事有沒有衝突」才可能精準回答。

**目前版本 `v0.1.0.0`** —— story-flow 時期的四個子系統 19 個 feature 全數完成,12 個測試套件 1462 條全綠。

> **2026-08-23 起本 repo 進入 aapms 重構**(把素材庫 assetdb 深度整合進來,見 [`.design/system.md`](./.design/system.md)):
> P0 已完成——全樹改名 `aapms-*` / `Aapms.*`、assetdb 以保留歷史的方式併入 `legacy/assetdb/`、
> 契約層測試 `contract/` 立起。下面的指令說明仍是 story-flow 的功能面,P1–P6 逐期改寫,README 於 P7 重寫。

---

## 安裝

### 下載發佈包(Windows x64,不需要 Haskell 環境)

到 [Releases](https://github.com/utomore/aapms/releases) 下載 `aapms-<版本>-windows-x64.zip`,解開就能跑。

裡面有三個執行檔加一個 `registry/` 資料夾:

| 檔案 | 用途 |
|---|---|
| `aapms` | 主要的命令列工具。建 Vault、寫片段、查關聯、偵測衝突、工作坊 |
| `aapms-serve` | REST API 伺服器。只有要用 MCP、或從別台機器操作時才需要 |
| `aapms-mcp` | MCP stdio adapter,讓 claude code / codex 直接操作圖譜 |
| `registry/` | 型別註冊表(五份 TOML)。**必須跟執行檔放在同一個資料夾** |

**解開後第一件事**:

```
aapms doctor
```

### 從原始碼安裝

需求:GHC 9.14.1、cabal 3.16.x(不使用 stack)。

```
git clone https://github.com/utomore/aapms && cd aapms
cabal install exe:aapms exe:aapms-serve exe:aapms-mcp
```

型別註冊表會隨 cabal 的 `data-files` 一起裝好,零設定。

### 型別註冊表怎麼被找到

執行檔啟動時依序找三個地方,取第一個存在的:

1. 環境變數 `STORYFLOW_REGISTRY` 指到的目錄
2. **執行檔旁邊的 `registry/`** ← 發佈包用這個
3. cabal `data-files` 目錄 ← `cabal install` 用這個

只有要自訂型別時才需要第 1 項:複製 `registry/` 出去改,再把變數指過去。
從 `dist-newstyle/` 直接跑開發版執行檔時也需要它(那份沒經過安裝步驟)。

---

## 五分鐘上手

```bash
aapms vault init ./my-world --name myworld   # 把資料夾變成 Vault
cd my-world

aapms type list                              # 有哪些片段型別、各自要填什麼

aapms entity new --type character-fragment \
  --title 琳達 --summary "織紋刀的持有者" \
  --body "琳達在埃提亞崩塌後失去雙親。"           # 建一份主題檔

aapms entity add 琳達 --title 動機 \
  --summary "她想找出崩塌的真相" \
  --body "..." --link partOf:ent-xxxx             # 往同一個角色加一節

aapms search 織紋刀                           # FTS5 中文全文檢索

echo "琳達那年就帶著織紋刀上路了。" > draft.txt
aapms conflict check --draft draft.txt       # 這段草稿跟既有設定矛盾嗎
```

---

## 概念

| 概念 | 是什麼 |
|---|---|
| **Vault** | 一個世界/作品 = 一個資料夾 = 一個 git repo。`.storyflow/` 標記它,像 `.git` |
| **Entity** | 內容的最小單位。世界觀片段、角色片段、道具、對話、劇情片段 |
| **主題檔 / 片段** | 一份 Markdown = 一個主題檔,檔內每個 `##` 分節是一個片段。`entity new` 建檔,`entity add` 加節 |
| **Link** | 有方向性的關聯。八個核心關聯驅動推論,其餘自由字串只做標註 |
| **Level / Node** | 場景的結構。Node 樹狀無限展開,承載順序、分支、鏡頭;內容一律關聯到 Entity |
| **統一 Meta** | Entity / Level / Node 共用同一組 metadata(id、summary、tags、status、timeline、aliases、links、revision……) |

**儲存**:Markdown 檔是**唯一真相來源**(可 `git diff`、可用編輯器直接改、AI Agent 可直接讀);
SQLite 只是**可重建的索引**(關聯查詢與 FTS5 中文全文檢索)。刪掉 `.storyflow/index.db`
跑 `aapms index rebuild` 就回得來。

**八個核心關聯**:`contradicts`(矛盾)、`supersedes`(取代)、`derivedFrom`(衍生自)、
`partOf`(屬於)、`involves`(牽涉)、`occursIn`(發生於)、`references`(引用)、
`convergesTo`(收斂到)。其他字串(「師承於」「宿敵」)照存、可查、AI 讀得到,但不驅動推論。

**五個內建型別**:`character-fragment`、`lore-fragment`、`item-fragment`、`plot-fragment`、
`dialogue`。加一份 `.toml` 到 `registry/` 就是新增一個型別,**不用改程式**——欄位提示、
必填檢查、工作坊的階段清單全部跟著走。

**三種 status**:`draft`(草稿)、`canon`(定案)、`deprecated`(已廢棄)。
**只有 `canon` 參與衝突偵測的比對基準**——草稿不該被當成「過去的設定」,否則每個未定案的
想法都會製造假衝突。

---

## 指令全覽

```
aapms [--vault <名稱>|--remote <網址>] [--json] <名詞> <動詞> [選項]
```

### 全域旗標

| 旗標 | 說明 |
|---|---|
| `--vault <名稱>` | 指定 Vault。不給時從目前目錄向上搜尋 `.storyflow/`(與 git 同一個心智模型) |
| `--json` | 輸出統一信封 `{"ok":true,"data":…}` / `{"ok":false,"error":{"code","message"}}`。**給 AI Agent 用的就是這個** |
| `--remote <網址>` | 改走遠端伺服器,如 `http://127.0.0.1:8787`。**不能與 `--vault` 併用** |
| `--version` | 印出版本後結束 |
| `--help` | 任何層級都可用,如 `aapms entity add --help` |

**退出碼**:`0` 成功、`1` 業務或傳輸失敗、`2` 引數用法錯誤。

### `doctor` —— 本機診斷

```
aapms doctor
```

五項讀不連的檢查,**不開索引、不打網路**,沒有 Vault 也跑得起來:

```
[ok] 版本:aapms 0.1.0.0
[ok] 型別註冊表:5 個型別,來自執行檔旁 C:\tools\aapms\registry
[!!] Vault:從目前目錄向上找不到 .storyflow/;請在 Vault 根目錄執行 aapms vault init
[ok] 全域註冊表:C:\Users\me\AppData\Roaming\aapms\vaults.toml,登記了 3 個 Vault
[--] [llm]:無法檢查(沒有 Vault)
```

`[ok]` 沒問題、`[!!]` 有問題、`[--]` 前置項失敗查不了。
**退出碼只看型別註冊表那一項**——沒有註冊表什麼都不能做;其餘四項是資訊。

### `vault` —— Vault 的建立與資訊

| 指令 | 說明 |
|---|---|
| `vault init [目錄] --name <名稱>` | 把資料夾變成 Vault 並登記進全域註冊表。目錄預設為 `.` |
| `vault list` | 列出全域註冊表裡的全部 Vault |
| `vault info` | 目前 Vault 的名稱、路徑與 Entity 數 |

`--name` 是 `--vault` 用來定址的名字,可以是中文。全域註冊表在
`%APPDATA%\aapms\vaults.toml`(Windows)/ `~/.config/story-flow/vaults.toml`(POSIX),
可用 `STORYFLOW_VAULTS` 覆寫。

`vault init` 會建出:

```
my-world/
├── .gitignore                  # 自動加了 .storyflow/index.db
├── .storyflow/
│   ├── config.toml             # name、references、[llm] 設定
│   ├── .gitignore              # index.db、workshops/
│   ├── index.db                # SQLite + FTS5,可重建
│   └── workshops/              # 工作坊 session 快照
└── characters/ lore/ items/ …  # 依型別註冊表的 dir 欄
```

### `type` —— 型別註冊表

```
aapms type list          # 列出全部型別:鍵、名稱、目錄、允許的關聯、欄位提示、工作坊階段
```

`--json` 的輸出就是給 AI Agent 的提示來源:每個型別的 `fields` 帶 `required` 與 `hint`,
`stages` 是工作坊的階段清單。

### `entity` —— 片段的增刪查改

| 指令 | 說明 |
|---|---|
| `entity new` | 建一份新的主題檔 |
| `entity add <主體>` | 往既有主題檔加一個片段(節) |
| `entity show <實體>` | 印出欄位與正文 |
| `entity list` | 列出 Entity |
| `entity set <實體>` | 改 Meta 欄位 |
| `entity set-body <實體>` | 換掉正文 |
| `entity rm <實體>` | 刪除 |

`<實體>` / `<主體>` 可以給 **id**(`ent-7f3a2b10`)或**標題**;標題多筆命中時會列出候選。

**`entity new` 的選項**

| 選項 | 說明 |
|---|---|
| `--type <型別>` | **必填**。`type list` 查得到的鍵 |
| `--title <標題>` | **必填**。人類可讀的標題 |
| `--summary <一句話>` | **必填**。衝突偵測與 AI 撈 context 時優先用它 |
| `--body <正文>` / `--body-file <檔案>` | 正文。都不給就是空正文 |
| `--tag <標籤>` | 可重複 |
| `--alias <別名>` | 可重複。**不寫的話全文檢索撈不到用別名提及的段落** |
| `--status <狀態>` | `draft`(預設)/ `canon` / `deprecated` |
| `--timeline <時間點>` | 故事內時間點,可模糊如「崩塌前」 |
| `--order <n>` | 供排序的整數 |
| `--link <關聯>:<目標>[:<說明>]` | 可重複。只切前兩個冒號,其餘算進說明 |
| `--source <來源>` | `human`(預設)/ `agent:<名稱>` / `workshop:<型別>` |

**`entity add`** 的選項相同,但 `--type` 選填(不給就繼承主體),另外多一個位置引數指定主體。

**`entity list` 的篩選**:`--type` / `--status` / `--tag` / `--limit <n>`。

**`entity set`**:`--title` / `--summary` / `--tag` / `--status` / `--timeline` / `--order` /
`--alias` / `--source`,只改有給值的欄位。**`--tag` 與 `--alias` 給了就整組取代**,不是追加。

**樂觀鎖**:`set` / `set-body` / `rm` / `link add` / `link rm` / `node add` / `node rm` 都吃
`--revision <n>`;不給時 CLI 會先讀一次取當前值。並發修改會被 `stale_revision` 擋下。

**`entity rm`** 的 `--force`:被別的實體指向時仍強制刪除(會回報打斷了哪些關聯)。

**正文從 stdin**:`entity set-body <實體> -`。

### `search` —— 全文檢索

```
aapms search <關鍵詞> [--type|--status|--tag|--limit]
```

FTS5 trigram tokenizer,中文可用。兩字以下的詞由落地層自動改走 `LIKE`。
回傳帶 `[關鍵詞]` 標記的 snippet 與相關度分數。

### `link` —— 關聯

| 指令 | 說明 |
|---|---|
| `link add <來源> --kind <關聯> --target <目標> [--note <說明>]` | 加一筆 |
| `link rm <來源> --kind <關聯> --target <目標>` | 刪一筆 |
| `link list <實體>` | **正向與反向一次列完**(「這個片段跟什麼有關」在作者心裡是一個問題) |

目標必須已經存在,否則回 `dangling_link_target`。用非核心關聯時 CLI 會提示最接近的核心關聯。

### `level` / `node` —— 場景樹

| 指令 | 說明 |
|---|---|
| `level new --title <標題> --root-title <標題> --root-kind <kind>` | 建一份 Level 連同根 Node |
| `level show <Level>` | 印出場景樹 |
| `level list` | 列出 Level |
| `level rm <Level>` | 刪除整份 Level |
| `node add <父節點> --title <標題> --kind <kind>` | 在父節點底下新增子節點 |
| `node rm <節點>` | 刪掉節點與它**整棵子樹** |

`<kind>` 六選一:`scene`(場景)、`cast`(出場人物)、`camera`(鏡頭)、
`interaction`(人物互動)、`dialogue`(對話)、`branch`(分支)。

`node add` 也吃 `--summary` / `--body` / `--link`。內容一律用 `--link` 關聯到 Entity,
**不要把場景描述直接寫在 Node 上**。

### `context` —— 撈相關片段(不判斷矛盾)

```
aapms context --for <檔案|-> [--ref <id>]… [選項]
```

給一段草稿,回傳相關的既有 `canon` 片段**連內容一起**。只跑前兩層(圖遍歷 + FTS5 候選),
**不做矛盾判斷**——這是給 AI Agent 「先看看有什麼相關設定」用的,比 `conflict check` 快且不需要 LLM。

| 選項 | 預設 | 說明 |
|---|---|---|
| `--for <檔案\|->` | **必填** | 草稿來源;寫 `-` 從 stdin 讀 |
| `--ref <id>` | — | 草稿已引用的片段 id,可重複。第 1 層由它起步 |
| `--top-n <n>` | 20 | 第 2 層的候選上限 |
| `--graph-depth <n>` | 2 | 第 1 層順 `supersedes` 反向遍歷的深度 |
| `--timeline-window <n>` | 不過濾 | 只保留 timeline order 與草稿引用片段相距 n 以內的候選 |

### `conflict check` —— 三層衝突報告

```
aapms conflict check --draft <檔案|-> [--ref <id>]… [選項]
```

| 層 | 做什麼 | 確定性 | 成本 |
|---|---|---|---|
| 1 | 順著已引用片段的 `contradicts` / `supersedes` 遍歷 | 完全確定性 | 零 |
| 2 | 關鍵詞 + `aliases` 用 FTS5 撈候選,`canon` / `timeline` 過濾、一跳擴充 | 確定性 | 每個關鍵詞一次 SQL |
| 3 | 草稿 × 候選逐對送 LLM 問「是否矛盾、矛盾在哪」 | 非確定性 | 每對一次呼叫 |

`context` 的選項全部適用,另外多:

| 選項 | 預設 | 說明 |
|---|---|---|
| `--judge-n <n>` | 5 | 第 3 層的候選預算 |
| `--expand-body` | off | 第 3 層展開 `body` 而非只送 `summary` |
| `--no-llm` | off | 這一次不跑第 3 層,報告退化成兩層 |

**沒設定 `[llm]` 時不會失敗**,報告的 `llm_used` 是 `false`,`notes` 會說明原因
(`judge_not_configured` / `judge_unreachable`)並告訴你下一步。

### `workshop` —— 階段式引導工作坊

需要地端 LLM 端點(見下)。階段清單與必填欄位**完全來自型別註冊表**,新增型別不改程式。

| 指令 | 說明 |
|---|---|
| `workshop start --type <型別> [--constraint <id>]…` | 開一個工作坊,印出 session id |
| `workshop step <session-id> --input <文字>` | 把這一輪的輸入送進目前階段 |
| `workshop commit <session-id>` | 把目前階段的草稿定案,寫進圖譜 |

- `--constraint <id>` 可重複:勾選為硬約束的既有片段,以 `summary` 進 prompt
- `--input <文字>` / `--input-file <檔案>` / `-`(stdin)三選一
- **中途對話不進圖譜**,只有 `commit` 的片段才寫出去
- session 快照在 `.storyflow/workshops/<id>.json`,**跨行程接得回去**——`start` 之後關掉終端機,
  隔天用同一個 id `step` 照樣繼續。CLI 與 REST 共用同一份快照
- 一次工作坊 = **一份主題檔**:首次 `commit` 建主體,之後每階段加節,片段以 `partOf` 指向主體,
  `source` 標成 `workshop:<型別>`,`status` 一律 `draft`

用 `ls .storyflow/workshops/` 看有哪些 session(目前沒有 `workshop list`)。

### `index` —— 索引維護

| 指令 | 說明 |
|---|---|
| `index refresh` | 只補過時的檔案。**用編輯器改完 `.md` 之後跑這個** |
| `index rebuild` | 全量重建。刪掉 `index.db` 也回得來 |

平常不必手動跑——每次開 Vault 都會自動補過時的檔案。

---

## `aapms-serve` —— REST API

```
aapms-serve [--port <n>] [--bind <位址>] [--vault <名稱>] [--openapi] [--version]
```

- `--port` 預設 `8787`,`--bind` 預設 `127.0.0.1`
- **綁非 loopback 位址時必須設 `STORYFLOW_TOKEN`,否則拒絕啟動**(整個 Vault 暴露在區域網路上
  不是可以靠使用者留意來緩解的後果)。loopback 模式下 token 是選配
- `--openapi` 不啟動伺服器,把 OpenAPI 3 文件印到 stdout:
  `aapms-serve --openapi > openapi.json` 是給 Agent 的一步驟交付

28 個 operation 覆蓋 `service` 的全部業務操作加 conflict 與 workshop 的出口。
錯誤 body 一律 `{"error":{"code":…,"message":…}}`,`code` 與 CLI 的 `--json` 完全相同。

CLI 的 `--remote <網址>` 走同一份契約(servant 的 API 型別同時產生 server 與 client,
兩條路徑不可能悄悄長歪)。

---

## 接 claude code / codex

### 方式 A:直接跑 CLI(最簡單,不用起 server)

Claude Code 在 Bash 裡跑 `aapms --json …` 就好。內嵌模式直接讀寫檔案,不需要 daemon。

先跑 `aapms --json type list` 拿到每個型別的 `stages` 與 `fields`(含 `required` 與 `hint`),
Claude Code 就能照著階段跟你談,每階段 `entity add` 一節,`--source agent:claude-code`。

### 方式 B:MCP

```
aapms-serve --port 8080
claude mcp add aapms -- aapms-mcp --url http://127.0.0.1:8080
```

`aapms-mcp` 把 REST 的**全部** operation 暴露成 MCP tool,tool 名字由 OpenAPI 的
`operationId` 機械推導、參數形狀來自同一份 API 型別 —— 新增 REST 路由會自動長出對應的 tool。

| 設定 | 說明 |
|---|---|
| `--url <網址>` 或 `STORYFLOW_URL` | 伺服器位址(旗標優先) |
| `STORYFLOW_TOKEN` | 伺服器有設 token 時要帶 |

**它不會自己拉背景 server** —— 連不上就在 `initialize` 回錯誤並告訴你先跑 `aapms-serve`。

---

## 地端 LLM 設定

衝突偵測第 3 層與工作坊需要一個 OpenAI 相容端點(llama.cpp、Ollama、或雲端)。
在 Vault 的 `.storyflow/config.toml` 加:

```toml
[llm]
base_url   = "http://127.0.0.1:8080/v1"  # 必填。指到 /v1 那一層
model      = "..."                       # 必填
api_key    = "..."                       # 選填。地端通常不用
timeout_ms = 60000                       # 選填,預設 60000
retries    = 1                           # 選填,預設 1。只重試「連不上服務」
```

**沒有 `[llm]` 段時回錯誤而不是猜預設值**——給一組地端預設值看似方便,但連不上時你看到的會是
「連線失敗」而不是「你還沒設定」,那是兩個完全不同的下一步。

錯誤分五類,各自的下一步不同:`llm_unavailable`(服務沒起來,**只有這類會重試**)、
`llm_http_status`(看狀態碼:401 是金鑰、404 是路徑)、`llm_bad_response`(換端點或換模型)、
`llm_config_missing`(去加 `[llm]` 段)、`llm_config_invalid`(照訊息改那一個鍵)。

用 `aapms doctor` 的第五項確認設定解不解得開(**不會連線**)。

---

## 給 AI Agent 的契約

- **全指令 `--json`**,成功 `{"ok":true,"data":…}`、失敗 `{"ok":false,"error":{"code","message"}}`
- **`code` 是 snake_case 的穩定識別碼**,三種介面(CLI / REST / MCP)完全相同
- **`message` 是繁體中文,每一則都說出下一步該做什麼**
- `--json` 的輸出**一律是 UTF-8**(不受終端機 code page 影響);繁中不逃逸成 `\uXXXX`
- **`type list` 是型別的自我描述**:欄位提示、必填、允許的關聯、工作坊階段全在裡面,
  Agent 不必內建任何型別知識

---

## 架構

```
       ┌─ aapms CLI ─┐   預設內嵌,--remote 走 HTTP
Agent ─┼─ MCP adapter ────┼─→ REST API ─→ service ─→ storage
       └─ 直接打 API ─────┘
```

業務邏輯**只存在於 `service`**,三種介面行為由型別保證一致。12 個套件,依賴單向向下、無環:

```
core → {types, md} → store → service → {llm, conflict, workshop} → {api} → {cli, server, mcp}
```

`service` 只認識它下面四層,不認識任何上游 —— 這條由 `CabalSpec` 的逐字相依斷言釘住,不是靠自律。

---

## 開發

```
cabal build all
cabal test all --test-show-details=direct
```

一鍵版本(建置 + 測試,exit 0 表示全綠):`./scripts/check.ps1`(Windows)/ `./scripts/check.sh`。
本專案**不使用 CI**,`scripts/check` 就是它的替代品。

打包發佈:`./scripts/release.ps1` / `./scripts/release.sh` —— 產出
`dist-release/aapms-<版本>-<平台>/` 與同名 zip。

> `cabal test` **不會重新 link 執行檔**。改完程式要實跑驗證時,先 `cabal build exe:aapms`。

`direct-sqlite` 在 `cabal.project` 開啟 `+fulltextsearch`,以取得中文搜尋所需的 FTS5
trigram tokenizer;`aapms-store` 的測試會直接驗證這個 flag 有生效。

### 設計文檔

- [`.design/system.md`](./.design/system.md) —— 專案燈塔:需求、對外契約、子系統劃分、通訊拓撲、開發階段
- [`.design/subsystems/`](./.design/subsystems) —— 重構後的子系統架構(目前只有 [graph-core](./.design/subsystems/graph-core/design.md),0/9);
  合併前的四份子系統文檔在 [`.design/legacy/`](./.design/legacy)
- [`.design/adr/`](./.design/adr) —— 22 份架構決策紀錄(ADR-019~022 由 assetdb 搬入)
- [`contract/`](./contract) —— 契約層測試(ADR-018):只跑執行檔與讀 `.cabal`,不依賴任何內部型別,重建期間的安全網
- [`types/registry/`](./types/registry) —— 宣告式型別註冊表

---

## 已知限制

- **跨 Vault 引用尚未實作**:`config.toml` 的 `references` 欄位存在,但實際操作回
  `cross_vault_unsupported`
- **工作坊沒有 `list` / `rm`**:用 `ls .storyflow/workshops/` 看,手動刪檔清理
- **只提供 Windows x64 的發佈包**:其他平台用 `scripts/release.sh` 自行產出
- **工作坊尚未對真實的地端模型跑過端到端**:測試打的是本機 stub 端點
- **embedding 語意檢索未實作**(ADR-007 推遲):第 2 層目前是 FTS5 trigram,
  對「改寫過的同義描述」抓不到。策略接縫已經留好

---

## 與其他工具的關係

aapms 屬於 [alchbees-dev](https://github.com/utomore) 工作室工具集:

- **`assetdb`** —— 管「已經存在的素材」。與 aapms 平行,無程式化相依
- **`design-studio`** —— aapms 的前身概念(Python 的 AI 引導式設計工作坊)。並存不動,
  不做資料遷移
