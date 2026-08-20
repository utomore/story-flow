# assetdb — 給 AI agent 的入口

工作室素材庫的索引、檢索與遊戲專案素材配置系統。Haskell 後端(9 個 cabal 套件)+
Vite/React 前端 + SQLite。**壓縮檔是唯一真相,其餘皆為衍生物**:資料庫索引壓縮檔的內容
而不解壓,專案需要素材時才單筆取出並改名。

## 先讀什麼

| 要做的事 | 讀 |
|---|---|
| 了解怎麼用:安裝、日常操作、已知陷阱 | `README.md`(給人的使用手冊) |
| 系統邊界、子系統劃分、通訊拓撲、全域錯誤處理策略 | `.design/system.md` |
| 某個子系統的契約、模組、資料流、feature 路線圖與契約卡 | `.design/subsystems/<catalog\|ingest\|ai-tagging\|delivery>/design.md` |
| 為什麼這樣設計 | `.design/adr/` |
| 任務文檔(F 功能 / E 優化 / B 缺陷) | `.design/subsystems/<slug>/{features,enhancements,bugfixes}/`;跨子系統的在 `.design/{enhancements,bugfixes}/` |
| 整體進度與健康度 | `/arch-audit status`(只跑腳本,不讀全文) |

`docs/_archive/` 是唯讀歷史快照,不在那裡新增或修改任何檔案。

## 建置與測試

- GHC 9.14.1 + cabal 3.16(由 ghcup 安裝),**不用 stack**。建置路徑不可含空格
  (Windows 上 GHC 的 `llvm-ar` 會在空格處截斷路徑)。
- `cabal build all`、`cabal test all`(9 個 hspec suite,改完必須全綠)。
- 執行 CLI 一律 `cabal run assetdb -- <子指令>`。PATH 上的 `assetdb` 是 `cabal install` 的
  舊副本,schema 改版後會丟 `DatabaseNewerThanCode`,不要拿它驗證行為。
- 改了 `server` 的 DTO 或 `ToJSON`:`cabal run assetdb-server -- --emit-types web/src/api/types.ts`
  重新產生。`types.ts` 是產生物,禁止手改,漂移測試會擋下來。
- 前端:`cd web && npm install && npm run dev`(5173,`/api` 與 `/thumb` proxy 到 8787);
  正式建置 `npm run build`。
- 真實素材庫在 `C:\Users\User\Documents\alchbees-assets`(資料庫在其 `.assetdb/assetdb.sqlite`,
  不在 repo 內)。對它執行會改狀態的指令前,先用預設的預覽模式看結果。

## 架構硬規則

- 套件依賴嚴格單向:`core` + `store`(catalog)← `archive` + `ingest` + `reorg`(ingest)←
  `ai`(ai-tagging)← `cli` + `server` + `web` + `project`(delivery)。**`server` 只准依賴
  `core` + `store`**;`cli` 是唯一的組合根,跨子系統的協作在那裡組裝。
- 子系統邊界回 `Either` / `Maybe`,例外不穿越邊界;給使用者看的訊息用繁體中文。
- 會改狀態的指令預設只預覽,`--confirm` 才寫入;不可逆操作另需獨立旗標。
  查詢類指令找不到資料庫時拒絕自動建檔。
- 批次作業分「單筆失敗(記錄後續跑)」與「整批中止(外部服務掛了,佇列保留原狀)」兩層,
  不可把服務中斷誤判成逐筆失敗。
- 長時間外部呼叫(LLM、7-Zip)絕不在資料庫交易內持有寫鎖(ADR-007)。
- Schema 只做正向 migration,沒有 down(ADR-006)。新增一種素材格式只改
  `ingest/src/AssetDB/Ingest/Handler.hs` 的 `handlers`,kind 專屬資料進 `meta_json`,不開新表。
- 列舉以穩定小寫文字存進 DB 與 JSON(ADR-008);邏輯名稱文法
  `<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]` 是對外契約(ADR-004)。
- 文字檔 I/O 一律 `BS.readFile` / `BS.writeFile` 配 `decodeUtf8` / `encodeUtf8`,不用
  `Data.Text.IO`(它吃 locale 編碼);每個執行檔的 `main` 先 `hSetEncoding stdout utf8`。
- PowerShell 裡有副作用的指令不要接 `Select-Object -First N`,它會在寫入前殺掉上游行程;
  重導向到檔案再讀。

## 工作流程(dev-flow)

- 新功能:先確認它在所屬 `design.md` 的「功能規劃」與「Feature 契約卡」裡(沒有就先走
  `/subsys-design` 更新模式補上),再 `/feature-design` → `/feature-impl`;缺陷走 `/bugfix`;
  優化走 `/enhance-design` → `/enhance-impl`。
- Level 1 / Level 2 文檔只寫邊界契約與資料流,不寫私有函數、helper 名稱或內部資料結構;
  實作細節只存在於 Level 3 文檔與程式碼。
- 文檔檔名英文 kebab-case、內文繁體中文、frontmatter 的清單欄位用行內陣列(`[]`)。
- 程式碼註解與使用者訊息用繁體中文;commit 與 PR 標題英文、內文繁中;
  分支命名 `<type>/<YYYY-MM-DD>-<slug>`(如 `enhance/2026-08-18-symlink-pathtext-tsdrift`)。
