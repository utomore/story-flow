# 目標

## O-1:兩種 vault 都能經同一組指令增刪查改與搜尋,結果每筆帶 vault
- 優先:1
- 判準:對 entity vault 與 asset vault 用 aapms CLI / HTTP / MCP 完成 CRUD,search 一次回兩種且每筆帶 vault;--remote 與內嵌輸出相同;--openapi 輸出 OpenAPI 3;任一 vault rm index.db 後重建與原索引等價

| 里程碑 | 做到什麼 | 綁定 |
|---|---|---|
| M-1 | 圖譜核心:短 id、型別註冊表、Level 樹、Markdown 往返與編輯、分詞、manifest 編解碼都有 law 護著 | P-020-core-identity、P-021-registry-build、P-022-logical-name、P-023-manifest-codec、P-024-level-tree、P-025-md-document、P-026-md-edit、P-027-fts-tokenize |
| M-2 | 單 vault 能重建索引、搜尋、寫回節點;rm index.db 後重建等價 | P-001-index-rebuild、P-002-search、P-003-node-write |
| M-3 | 全局中樞認得所有 vault:讀跨全部、寫單一,init / add / forget 與 doctor 可用 | P-028-hub-config、P-029-scope-resolve、P-004-vault-scope、P-005-vault-lifecycle、P-006-workspace-doctor |
| M-4 | 業務契約:圖譜的讀與寫經 service 一份定義,回帶 vault 的 NodeView | P-007-graph-read、P-008-graph-write |
| M-5 | 一份 servant 契約產出 CLI / HTTP / MCP 三個殼,--remote 與內嵌行為一致 | P-009-cli-shell、P-010-http-shell、P-011-mcp-shell |

## O-2:壓縮檔不解壓就成為圖譜節點,搬動與刪除不留幽靈
- 優先:2
- 判準:對真 vault(27 個 pack、6,783 筆資源)asset scan 跑得完且 rm index.db 重建等價;搬動或刪除 pack 後索引沒有 orphan;同內容縮圖只算一次;cluster / reorganize 預設只預覽,--confirm 才寫

| 里程碑 | 做到什麼 | 綁定 |
|---|---|---|
| M-6 | 掃描 library/ 產 pack.md 與索引,縮圖進全局快取 | P-012-asset-scan、P-013-thumb-cache |
| M-7 | 未命名素材經叢集命名,pack 搬遷有計畫、對帳與回退 | P-014-name-cluster、P-015-pack-reorganize |

## O-3:新劇情草稿能被指出與既有設定的矛盾,素材標註與工作坊共用一個地端 LLM
- 優先:3
- 判準:conflict check 的報告指到片段且候選集含 asset;ai classify 的建議進暫存表、confirm 才寫入圖譜;ai classify 與 workshop 讀同一份中樞 [llm] 設定

| 里程碑 | 做到什麼 | 綁定 |
|---|---|---|
| M-8 | 新劇情草稿的衝突報告指到片段 | P-016-conflict-check |
| M-9 | 地端 LLM 的素材標註與階段式工作坊共用一個端點 | P-017-ai-classify、P-018-workshop |

## O-4:挑一個 Level 就能帶出它牽涉的 Entity 與素材,過授權閘門後產出專案檔
- 優先:3
- 判準:project new 選 Level 後自動帶出 involves 的 Entity 與 uses / depicts 的 Asset,授權不過的被擋下,落成 assets/manifest.json、Assets.hs 與 story/manifest.json

| 里程碑 | 做到什麼 | 綁定 |
|---|---|---|
| M-10 | Level → Entity → Asset 連動,過授權閘門落成專案檔 | P-019-project-export |
