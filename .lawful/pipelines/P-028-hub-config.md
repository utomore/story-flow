---
id: P-028
description: 中樞 TOML 文字解析成 Hub 值與渲染回去;vault / project 的 upsert 與 remove 保序
status: ready
updated: 2026-09-06
---
# P-028-hub-config:中樞 TOML 文字解析成 Hub 值與渲染回去;vault / project 的 upsert 與 remove 保序

## Brief
把中樞 `config.toml` 的四段變成一份不可變快照,對它做增刪,再以原文為底稿渲染回去(ADR-017 決策二的「可手寫」)。input 是中樞檔案的全文與一個增刪請求;output 是 `Hub`(`[[vaults]]` / `[[projects]]` / `[llm]` / `[tools]` 四段加逐字保留的原始文字)與渲染出來的新全文。流向:TOML 解析與逐段欄位驗證 → 四段結構化內容 → 依 id 覆寫或追加、依 id 刪除 → 以底稿逐段比對後渲染。它是子流:P-004-vault-scope 的中樞讀取、P-005-vault-lifecycle 的中樞寫回、以及 `project new` / `project forget` 都引用它的 stage;讀檔與原子寫檔本身住 shell 的 `Aapms.Workspace.Hub.File`(`loadHub` / `saveHub`),不在本條。中樞存的是快取不是真相——vault 的 `id` / `kind` / `name` / `refs` 屬各 vault 的 marker。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `parseHubText :: FilePath -> Text -> Either WorkspaceError Hub` | 中樞全文解析成四段並逐條驗欄位;原始文字逐字留在快照裡 | `Aapms.Workspace.Hub` | pure |
| 2 | `hubVaults :: Hub -> [VaultEntry]` | `[[vaults]]` 的全部列,保留檔案中的順序 | `Aapms.Workspace.Types` | types |
| 3 | `hubProjects :: Hub -> [ProjectEntry]` | `[[projects]]` 的全部列,保留檔案中的順序 | `Aapms.Workspace.Types` | types |
| 4 | `hubLlm :: Hub -> Maybe LlmSection` | `[llm]` 段的原樣 TOML 表;整段缺席與空表是不同的兩件事 | `Aapms.Workspace.Types` | types |
| 5 | `hubTools :: Hub -> ToolsConfig` | `[tools]` 段;整段缺席時每個欄位都是 `Nothing` | `Aapms.Workspace.Types` | types |
| 6 | `hubSourceText :: Hub -> Text` | 載入當下的原始檔案文字,渲染時當底稿 | `Aapms.Workspace.Types` | types |
| 7 | `mkHub :: [VaultEntry] -> [ProjectEntry] -> Maybe LlmSection -> ToolsConfig -> Text -> Hub` | 快照的唯一建構入口(建構子不匯出) | `Aapms.Workspace.Types` | types |
| 8 | `upsertVault :: VaultEntry -> Hub -> Hub` | 依 `veId` 覆寫既有列;沒有該 id 時追加到末尾 | `Aapms.Workspace.Hub` | pure |
| 9 | `removeVault :: VaultId -> Hub -> Hub` | 依 `veId` 刪整列;沒有該 id 時原樣回傳 | `Aapms.Workspace.Hub` | pure |
| 10 | `upsertProject :: ProjectEntry -> Hub -> Hub` | 依 `peId` 覆寫既有列;沒有該 id 時追加到末尾 | `Aapms.Workspace.Hub` | pure |
| 11 | `removeProject :: Id -> Hub -> Hub` | 依 `peId` 刪整列;沒有該 id 時原樣回傳 | `Aapms.Workspace.Hub` | pure |
| = | `renderHub :: Hub -> Text` | 純的整條:以 `hubSourceText` 為底稿逐段比對,未變動的段落、註解與空白行逐字沿用 | `Aapms.Workspace.Hub` | pure |

## Laws
- LAW-1 [identity] 沒有改過的快照渲染回去,與讀進來的文字逐位元組相同
  - forall fp in FilePath, txt in Text, h in rights [parseHubText fp txt]
  - |- renderHub h == txt
- LAW-2 [roundtrip] 渲染再解析,四段逐欄相等(清單含順序)
  - forall fp in FilePath, h in Hub, h2 in rights [parseHubText fp (renderHub h)]
  - |- hubVaults h2 == hubVaults h and hubProjects h2 == hubProjects h and hubLlm h2 == hubLlm h and hubTools h2 == hubTools h
- LAW-3 [total] 工具寫得出來的中樞,工具一定讀得回來
  - forall fp in FilePath, h in Hub
  - given isRight (parseHubText fp (hubSourceText h))
  - given all (not . null) (map veName (hubVaults h))
  - given all (not . null) (map peName (hubProjects h))
  - given nub (map veId (hubVaults h)) == map veId (hubVaults h)
  - given nub (map peId (hubProjects h)) == map peId (hubProjects h)
  - |- isRight (parseHubText fp (renderHub h))
- LAW-4 [total] 解析對任何文字都有值,不拋例外
  - forall fp in FilePath, txt in Text
  - |- total (parseHubText fp txt)
- LAW-5 [relation] id 不在中樞裡時,upsert 追加到末尾,既有列原序不動
  - forall e in VaultEntry, h in Hub
  - given not (veId e in map veId (hubVaults h))
  - |- hubVaults (upsertVault e h) == concat [hubVaults h, [e]]
- LAW-6 [relation] id 已經在中樞裡時,upsert 就地覆寫:列數與 id 順序都不變
  - forall e in VaultEntry, h in Hub
  - given veId e in map veId (hubVaults h)
  - |- map veId (hubVaults (upsertVault e h)) == map veId (hubVaults h) and length (hubVaults (upsertVault e h)) == length (hubVaults h)
- LAW-7 [relation] upsert 之後一定查得到,而且查到的就是給進去的那一列
  - forall e in VaultEntry, h in Hub
  - |- find ((== veId e) . veId) (hubVaults (upsertVault e h)) == Just e
- LAW-8 [identity] upsert 冪等:同一列 upsert 兩次與一次相同
  - forall e in VaultEntry, h in Hub
  - |- upsertVault e (upsertVault e h) == upsertVault e h
- LAW-9 [identity] 新增之後撤除,清單回到原樣
  - forall e in VaultEntry, h in Hub
  - given not (veId e in map veId (hubVaults h))
  - |- hubVaults (removeVault (veId e) (upsertVault e h)) == hubVaults h
- LAW-10 [relation] remove 依 id 保序刪除;id 不存在時整個快照原樣回傳
  - forall v in VaultId, h in Hub
  - |- hubVaults (removeVault v h) == filter ((/= v) . veId) (hubVaults h)
- LAW-11 [invariant] vault 的增刪只動 `[[vaults]]`,其餘三段與底稿一個位元組都不動
  - forall e in VaultEntry, v in VaultId, h in Hub
  - |- hubProjects (upsertVault e h) == hubProjects h and hubLlm (upsertVault e h) == hubLlm h and hubTools (upsertVault e h) == hubTools h and hubSourceText (upsertVault e h) == hubSourceText h and hubProjects (removeVault v h) == hubProjects h and hubLlm (removeVault v h) == hubLlm h and hubTools (removeVault v h) == hubTools h and hubSourceText (removeVault v h) == hubSourceText h
- LAW-12 [relation] `[[projects]]` 成立同一組規則:不存在就追加末尾,新增之後撤除回到原樣
  - forall e in ProjectEntry, h in Hub
  - given not (peId e in map peId (hubProjects h))
  - |- hubProjects (upsertProject e h) == concat [hubProjects h, [e]] and hubProjects (removeProject (peId e) (upsertProject e h)) == hubProjects h
- LAW-13 [relation] project 的 remove 依 id 保序刪除;id 不存在時原樣回傳
  - forall p in Id, h in Hub
  - |- hubProjects (removeProject p h) == filter ((/= p) . peId) (hubProjects h)
- LAW-14 [identity] project 的 upsert 冪等,而且一定查得到
  - forall e in ProjectEntry, h in Hub
  - |- upsertProject e (upsertProject e h) == upsertProject e h and find ((== peId e) . peId) (hubProjects (upsertProject e h)) == Just e
- LAW-15 [invariant] project 的增刪只動 `[[projects]]`,其餘三段與底稿一個位元組都不動
  - forall e in ProjectEntry, p in Id, h in Hub
  - |- hubVaults (upsertProject e h) == hubVaults h and hubLlm (upsertProject e h) == hubLlm h and hubTools (upsertProject e h) == hubTools h and hubSourceText (upsertProject e h) == hubSourceText h and hubVaults (removeProject p h) == hubVaults h and hubLlm (removeProject p h) == hubLlm h and hubTools (removeProject p h) == hubTools h and hubSourceText (removeProject p h) == hubSourceText h
- LAW-16 [roundtrip] 建構入口與五個 selector 互逆
  - forall vs in [VaultEntry], ps in [ProjectEntry], llm in Maybe LlmSection, tools in ToolsConfig, txt in Text
  - |- hubVaults (mkHub vs ps llm tools txt) == vs and hubProjects (mkHub vs ps llm tools txt) == ps and hubLlm (mkHub vs ps llm tools txt) == llm and hubTools (mkHub vs ps llm tools txt) == tools and hubSourceText (mkHub vs ps llm tools txt) == txt
- LAW-17 [invariant] 載入得起來的中樞,每一列的名稱都非空(workspace F001 ASM-3)
  - forall fp in FilePath, txt in Text, h in rights [parseHubText fp txt]
  - |- all (not . null) (map veName (hubVaults h)) and all (not . null) (map peName (hubProjects h))
- LAW-18 [invariant] 鍵是 id,不是名稱也不是路徑:載入得起來的中樞裡 id 唯一,名稱與路徑都可以重複(ADR-017)
  - forall fp in FilePath, txt in Text, h in rights [parseHubText fp txt]
  - |- nub (map veId (hubVaults h)) == map veId (hubVaults h) and nub (map peId (hubProjects h)) == map peId (hubProjects h)
- LAW-19 [relation] 搬動一個 vault 只改路徑,身分不變:同 id 不同 path 的 upsert 不新增列
  - forall e in VaultEntry, h in Hub
  - given veId e in map veId (hubVaults h)
  - |- map vePath (hubVaults (upsertVault e h)) == map vePath (hubVaults (upsertVault e h)) and length (hubVaults (upsertVault e h)) == length (hubVaults h) and find ((== veId e) . veId) (hubVaults (upsertVault e h)) == Just e

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 空字串 `""`;以及只有 `# 空的中樞\n` 一行的檔案 | 兩者都是 `Right`;四段分別是 `[]` / `[]` / `Nothing` / `ToolsConfig Nothing`(「四段都缺席」是合法的空中樞) | LAW-4、LAW-16 |
| EX-2 | `[[vaults` (TOML 語法錯) | `Left (HubUnreadable fp _)`;不拋例外 | LAW-4 |
| EX-3 | 最上層不是 TOML 表的檔案 | `Left (HubMalformed fp "檔案的最上層不是 TOML 表")` | LAW-4 |
| EX-4 | 一列 `[[vaults]]` 只有 `name` / `kind` / `path`,缺 `id` | `Left (HubMalformed fp msg)`,`msg` 含 `id` | LAW-4 |
| EX-5 | 一列 `[[vaults]]` 的 `kind = "media"`;另一份的 `path = "assets/lib"`(相對路徑);另一份的 `id = "prj-91c0aa12"`(前綴錯) | 三者都是 `Left (HubMalformed fp msg)`,`msg` 依序含 `media` / `assets/lib` / `vlt` 與 `prj-91c0aa12` | LAW-4 |
| EX-6 | 一列 `[[vaults]]` 的 `name = "   "`(全空白);另一份的 `[[projects]]` 的 `name = ""` | 兩者都是 `Left (HubMalformed fp msg)`,`msg` 指出名稱不得為空 | LAW-17 |
| EX-7 | 兩列 `[[vaults]]` 用同一個 `id = "vlt-7f3b2a91"` | `Left (HubMalformed fp msg)`,`msg` 含 `vlt-7f3b2a91`;兩列同名不同 id 則照收 | LAW-18 |
| EX-8 | 一份含開頭註解、行內註解、空白行與四段的合法中樞;解析後直接 `renderHub` | 與原文逐位元組相同(含 `kind = "asset"` 後面的行內註解與全部空白行) | LAW-1 |
| EX-9 | EX-8 的文字解析後再 `renderHub` 再解析 | 兩次的 `hubVaults` / `hubProjects` / `hubLlm` / `hubTools` 逐欄相等,清單順序相同 | LAW-2 |
| EX-10 | EX-8 的中樞:`hubVaults` 依序是 `vlt-7f3b2a91`(`alchbees-assets` / `AssetVault`)與 `vlt-a0c4e1f8`(`liftgame` / `StoryVault`);`hubProjects` 一列 `prj-91c0aa12` | 順序與檔案中的一致;`hubTools == ToolsConfig (Just "C:/Program Files/7-Zip/7z.exe")` | LAW-2、LAW-16 |
| EX-11 | 一份 `[llm]` 整段缺席的中樞,與一份有 `[llm]` 但段下沒有任何鍵的中樞 | `hubLlm` 依序是 `Nothing` 與 `Just (LlmSection <空表>)`,兩者不相等 | LAW-16 |
| EX-12 | EX-8 的 `hub` 做 `upsertVault (VaultEntry (VaultId "vlt-11112222") "shared-lore" StoryVault "E:/vaults/shared")` | `hubVaults` 三列,前兩列與 EX-10 相同且順序不變,第三列是新增的;`find` 查得到它 | LAW-5、LAW-7 |
| EX-13 | EX-12 之後再 `renderHub` 再解析 | 原檔的每一行註解與空白行逐字仍在、相對順序不變;`hubVaults` 最後一列是新增的那一列 | LAW-1、LAW-3 |
| EX-14 | EX-8 的 `hub` 對 `vlt-7f3b2a91` 那一列只改 `vePath` 之後 `upsertVault` | 列數仍是 2、id 順序不變,只有該列換成新值 | LAW-6、LAW-19 |
| EX-15 | 同一列連續 `upsertVault` 兩次 | 兩次的結果相等;`hubVaults` 沒有變長 | LAW-8 |
| EX-16 | 空中樞 `mkHub [] [] Nothing (ToolsConfig Nothing) ""` 做 `upsertVault e` 再 `removeVault (veId e)` | `hubVaults` 回到 `[]` | LAW-9 |
| EX-17 | EX-10 的 `hub` 做 `removeVault (VaultId "vlt-a0c4e1f8")` | `hubVaults` 只剩 `vlt-7f3b2a91` 那一列;`hubProjects` / `hubLlm` / `hubTools` / `hubSourceText` 逐欄不變 | LAW-10、LAW-11 |
| EX-18 | `removeVault (VaultId "vlt-deadbeef")`(不存在) | 回傳的 `Hub` 與輸入相等 | LAW-10 |
| EX-19 | 空中樞做 `upsertProject (ProjectEntry prj-91c0aa12 "Circle" "D:/games/Circle")`;再對同一個 id 做 `removeProject` | 先是 `hubProjects == [e]`,再回到 `[]`;`hubVaults` / `hubLlm` / `hubTools` / `hubSourceText` 全程不變 | LAW-12、LAW-15 |
| EX-20 | 中樞已有一列 `e0`,`upsertProject e` | `hubProjects == [e0, e]`——追加在末尾,`e0` 原樣 | LAW-12 |
| EX-21 | 兩列 `[[projects]]` 之一被 `removeProject` 掉;以及對不存在的 `prj-deadbeef` 呼叫 | 前者只少那一列且其餘保序;後者原樣回傳 | LAW-13 |
| EX-22 | 同一個 `ProjectEntry` 連續 `upsertProject` 兩次 | 兩次結果相等;`find` 查得到它 | LAW-14 |
| EX-23 | `mkHub vs ps llm tools txt`,`vs` 兩列、`ps` 一列、`llm` 為 `Just`、`txt` 非空 | 五個 selector 依序取回 `vs` / `ps` / `llm` / `tools` / `txt` | LAW-16 |
| EX-24 | 空中樞 `upsertVault (VaultEntry (VaultId "vlt-7f3b2a91") "line1\nline2\tcol" AssetVault "C:/v")` 再 `renderHub` 再解析 | `Right`(不是 `HubUnreadable`);`veName` 逐字等於 `"line1\nline2\tcol"`;檔案裡該行是逸出後的兩字元序列 | LAW-3 |
| EX-25 | 同 EX-24,名稱改成含 U+0001 的 `"a\SOHb"`,同時放一個這種 `veName` 與一個這種 `peName` | 兩段都讀得回來且逐字相等;檔案裡是 `\u0001`(四位大寫十六進位) | LAW-3 |
| EX-26 | 一份含使用者自訂的未知鍵與未知頂層段的合法中樞,解析後直接 `renderHub` | 未知鍵與未知段落逐字保留,與原文逐位元組相同 | LAW-1 |

## 決定
- **中樞 `[[vaults]]` / `[[projects]]` 以 id 為鍵,名稱與路徑都不是身分。** 否決:以路徑為鍵。理由:搬動一個 vault 或專案目錄就等於換一個身分,而目錄本來就會被搬;改名一個專案也不該讓它失聯。證據:ADR-017-unified-marker-id-registry-read-across-write-single
- **`renderHub` 以 `hubSourceText` 為底稿逐段比對,未變動的段落、註解與空白行逐字沿用;序列化自己寫,不用泛型 encoder。** 否決:整份重新序列化。理由:中樞是 ADR-017 決策二明訂「可手寫」的檔案,泛型 encoder 會把使用者寫的註解與排版順手整理掉
- **四個純增刪只動結構化的四段,不動 `hubSourceText`;底稿與「現在應該長什麼樣」的差異由 `renderHub` 一次收斂。** 否決:每次增刪順手改寫底稿。理由:那樣每一次增刪都要重做一次保留邏輯,而保留邏輯只要有兩份就會分歧
- **`Hub` 是不透明型別,建構走 `mkHub`、讀取走五個 selector。** 否決:匯出全部欄位。理由:`hubSourceText` 與四段之間有「同一次載入」的不變量,允許逐欄拼裝就是允許拼出「文字說有三個 vault、清單只有一個」的快照,而 `saveHub` 會照著這種快照把使用者的檔案寫壞——那是一條沉默的資料損毀路徑
- **未知的鍵與未知的頂層段一律容忍且原樣保留,不是 `HubMalformed`。** 否決:嚴格拒收。理由:對使用者自己加的註記、以及未來版本新增的段落嚴格拒收,會讓一個新版寫出的檔案被舊版判成壞檔
- **名稱去前後空白後為空一律 `HubMalformed`。** 否決:照收,由選擇器自然比不到。理由:讀寫兩端對同一個欄位要用同一套值域,否則會出現「工具自己寫不出來的檔案,工具讀得進來」這種不對稱
- **同一個 id 在中樞裡出現一次以上是 `HubMalformed`,不靜默去重。** 否決:去重帶過。理由:身分不確定時,任何以 id 為鍵的操作都是不確定的;沿用 vault marker 對重複 id 的同一個立場
- **端到端的 law 掛在「文字 ↔ `Hub` 值」的純函式上,不掛 `loadHub` / `saveHub`。** 否決:直接對 `loadHub` / `saveHub` 立 law。理由:那兩個是 IO,而位元組恆等與往返本來就是純性質,綁在檔案系統上等於讓每一條 law 都要先造一個暫存目錄;`loadHub` / `saveHub` 因此退成讀檔、寫檔加一次呼叫
- **`Aapms.Workspace.Hub` 整個模組是 pure 的:它只做「文字 ↔ `Hub` 值」與對 `Hub` 值的增刪,碰檔案的 `loadHub` / `saveHub` 住 shell 的 `Aapms.Workspace.Hub.File`。** 否決:解析、序列化與讀寫檔案住同一個模組。理由:`=` 列是純的整條,而端到端的位元組恆等與往返只有在純函式上才驗得到;IO 那一半留在同一個模組會把整個模組拉進 shell 層,每一條 law 都得先造一個暫存目錄
- **`saveHub` 寫出的 TOML 基本字串做完整逸出(`\b` / `\t` / `\n` / `\f` / `\r` / `\"` / `\\`,其餘 U+0000–U+001F 與 U+007F 用 `\uXXXX`)。** 否決:只逸出雙引號與反斜線。理由:控制字元不逸出就是非法 TOML,等於工具寫出一份自己讀不回來的中樞;LAW-3 的定義域因此是完整的「去空白後非空」而不是「不含控制字元」
- **中樞存的是快取不是真相:vault 的 `id` / `kind` / `name` / `refs` 屬各 vault 的 marker,每次探測重讀。** 否決:以中樞為準。理由:marker 才跟著目錄走,中樞只是索引;兩者不一致時要看得出漂移,而不是讓中樞蓋掉事實。證據:ADR-017-unified-marker-id-registry-read-across-write-single

## 修訂記錄
無
