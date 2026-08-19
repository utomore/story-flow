# 封存文件(歷史快照)

本資料夾是**唯讀的歷史快照**,不再維護。現行設計文檔一律在 `.design/`
(dev-flow 0.7.0 三層結構):`system.md` 是 Level 1 主架構,`subsystems/<slug>/design.md`
是 Level 2 子系統架構,各子系統的 `features/`、`enhancements/`、`bugfixes/` 是 Level 3。

| 檔案 | 內容 | 被誰取代 |
|---|---|---|
| `DESIGN.md` | 最早的整體設計文件 | `.design/system.md` |
| `AI.md` | AI 分類功能的完整操作手冊(troubleshooting、CLI 逐步流程) | 架構部分進 `.design/subsystems/ai-tagging/design.md`;操作手冊仍以本檔為準 |
| `PACKS.md` | 素材包盤點資料(非架構內容) | 機器可讀版本是 `data/packs.toml` |
| `report-2026-08-11-console-encoding-and-db-path.md` | 主控台編碼與資料庫路徑的分析報告 | 結論已落地為 bugfix 文檔 |
| `report-2026-08-12-architecture-review.md` | 全專案架構健檢報告 | 發現已全部展開為 bugfix / enhancement 文檔並完成 |

## 舊編號對照表

2026-08-19 遷移到 `.design/` 時,任務文檔改用「每個子系統自己一組編號」的新規則。
本資料夾內的文件仍使用舊編號,對照如下(引用格式:跨子系統帶 `<子系統>/` 前綴,
全域文檔用 `G-` 前綴):

| 舊 id | 新 id | 標題 |
|---|---|---|
| `bug-0001` | `delivery/B001` | CLI 在錯誤目錄執行時靜默建立空資料庫 |
| `bug-0002` | `delivery/B002` | Server 對不存在的 db 路徑靜默建檔灌 schema |
| `bug-0003` | `delivery/B003` | Server CLI 的 port 參數用 partial read 解析 |
| `bug-0004` | `delivery/B004` | Server 預設綁定所有網路介面且無驗證機制 |
| `bug-0005` | `delivery/B005` | 縮圖端點未驗證 sha 格式且未設定 Cache-Control |
| `bug-0006` | `catalog/B001` | naming_vocab 表是死資料,詞彙實際由硬編碼生效 |
| `enhance-0001` | `ai-tagging/E001` | 修正建議回報值並消除叢集目標的全表掃描 |
| `enhance-0002` | `ingest/E001` | 記錄跨磁碟搬移為非原子操作的評估結論 |
| `enhance-0003` | `delivery/E001` | 修正 Grid 的 effect 依賴,避免每次渲染重跑 |
| `enhance-0004` | `catalog/E001` | 改掉 migration 以字串拼接組 SQL 的脆弱寫法 |
| `enhance-0005` | `ingest/E002` | 強化 Notes 的輸入處理健壯性 |
| `enhance-0006` | `G-E001` | 收斂四處各自為政的分頁常數 |
| `enhance-0007` | `delivery/E002` | 收斂硬編碼於三處的預設埠號 8787 |
| `enhance-0008` | `delivery/E003` | 讓 CLI 能指定專案模板,不再寫死單一模板 |
| `enhance-0009` | `ingest/E003` | 退役已完成搬遷的一次性路徑規則 |
| `enhance-0010` | `ingest/E004` | 散檔掃描改為串流讀取,不再整檔載入記憶體 |
| `enhance-0011` | `ingest/E005` | 為目錄掃描加上符號連結迴圈防護 |
| `enhance-0012` | `G-E002` | 在 core 收斂五處重複的小工具函式 |
| `enhance-0013` | `delivery/E004` | 補齊 cli、server、web 的測試覆蓋缺口 |
| `enhance-0014` | `delivery/E005` | 加上 CI 檢查確保前端型別檔是最新產物 |

ADR 一律 `adr-000N` → `ADR-00N`(全局共用一組編號,位置 `.design/adr/`)。
