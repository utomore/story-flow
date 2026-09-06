# GAP

## GAP-1(P-028-hub-config#EX-3 / qa)
- 模糊點:EX-3 的輸入「最上層不是 TOML 表的檔案」在 toml-reader 0.3.0.0 產不出來:`TOML.decode` 對任何解得開的文字一律回 `Table`,解不開則是 `TOMLError` 走 `HubUnreadable`,`HubMalformed fp "檔案的最上層不是 TOML 表"` 那條分支不可達
- 卡住的項目:P-028#EX-3 的 example test 寫不出輸入(目前 `pendingWith`)
- 需要回答什麼:EX-3 是刪掉(分支不可達,程式碼留作防禦),還是改寫成別的輸入?
- 狀態:open

## GAP-2(P-028-hub-config#LAW-3 / qa)
- 模糊點:LAW-3 的 given 寫 `all (not . null) (map veName (hubVaults h))`,決定欄寫「名稱去前後空白後為空一律 HubMalformed」;`veName = "   "` 同時滿足 given 又該被拒收。LAW-17 的 `|-` 同樣只寫 `not . null`
- 卡住的項目:沒有卡住(產生器繞開全空白名稱),但 LAW-3 / LAW-17 的定義域比實際值域寬
- 需要回答什麼:LAW-3 的 given 與 LAW-17 的 `|-` 要不要改成「去前後空白後非空」?
- 狀態:open

## GAP-3(P-028-hub-config#LAW-2 / qa)
- 模糊點:`Hub` 的「同一次載入」不變量只寫在 types 層 Haddock,`mkHub` 的簽名不擋;LAW-2 / LAW-16 對 `h in Hub` 沒有前提,而底稿與四段矛盾的快照下 `renderHub` 不會把 `[llm]` / `[tools]` 收斂回四段
- 卡住的項目:沒有卡住(產生器收斂到「一次載入 + 四個純增刪」),但 LAW-2 的定義域字面上含不一致的快照
- 需要回答什麼:LAW-2 的 forall 要不要加前提「h 來自 parseHubText 或空快照,再經 upsert / remove 增刪」?還是 renderHub 必須連 `[llm]` / `[tools]` 都對底稿收斂?
- 狀態:open
