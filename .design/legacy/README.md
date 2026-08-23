# legacy:合併前(story-flow 單體)的設計文檔

2026-08-23 主架構重構為 aapms(見 `../system.md`)後,這裡存放**合併前**的四個子系統文檔與兩份
全域優化文檔。它們描述的是舊邊界,**不再是權威**,`/arch-audit status` 不掃描這個資料夾。

| 舊文檔 | 用途 |
|---|---|
| `subsystems/entity-graph-core/` | `graph-core` 的移植參考(F002–F005 對應新 #1 / #4 / #6 / #8) |
| `subsystems/service-and-interfaces/` | `service` 與 `shell` 的移植參考 |
| `subsystems/conflict-detection/` | `conflict` 的移植參考 |
| `subsystems/llm-workshop-mcp/` | `ai` 與 `shell`(MCP)的移植參考 |
| `enhancements/G-E001` | 已結案(superseded by ADR-015) |
| `enhancements/G-E002` | 已完成,發佈腳本與 `doctor` 隨 P3 的 `shell` / `workspace` 重做 |

對應的新子系統以 `/subsys-design` 重建完成後,這裡的參考文檔即可刪除。
