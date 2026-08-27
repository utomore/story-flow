---
id: delivery-build
type: build-log
title: delivery-build
description: 委派展開 delivery 階段 14 的專案增量同步
status: done
created: 2026-08-20
updated: 2026-08-21
parent: delivery
---

# Delivery 委派展開紀錄

## 排程

功能規劃 #1–#5(階段 2 / 7 / 8 / 9)在 2026-08-19 的 `.design/` 遷移時已回溯建檔且全部
`done`,不在本次展開範圍。本次只跑階段 14 的 `project-sync`。

依賴 `#5 project-scaffold`(`F005`,`done`)已滿足,無跨子系統或全域依賴,因此單一波次。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段 14 | W1 | project-sync | done(待閘門裁決) |

## 委派決策記錄

批次澄清共四題,開發者全採推薦選項。其中 D1、D2 屬契約類,已回寫
`design.md`(§6、模組間公開介面、定位與範圍、`project-sync` 契約卡),此處不重複內容,
只記錄決策來源;D3、D4 屬執行取向,不進 Level 2,由本表傳給執行者。

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 對帳要算磁碟檔案的 SHA-256,但 `sha256File` 在 `assetdb-ingest`,`project` 不依賴它 | `project` 加 `assetdb-ingest` 依賴,直接用 `AssetDB.Ingest.Hash.sha256File`;不自行實作摘要,不改用其他演算法 | project-sync(已回寫 design.md) |
| D2 | 既有登記素材的素材包後來授權降級時,重寫 manifest 怎麼處理 | 仍列入 manifest 與 `Assets.hs`,但回報逐包警告;授權閘門只擋新增不回溯既有 | project-sync(已回寫 design.md) |
| D3 | 對帳的雜湊成本 | 先比檔案大小:與登記時不同就直接判定「本地已修改」,相同才真的讀檔算雜湊。正確性不變(大小不同必然內容不同),多數情況省掉整批 IO | project-sync 實作 |
| D4 | 測試深度 | 契約卡的 10 條驗收標準各一組 1-to-1 測試;對帳分類用純函數 + 真實 SQLite 暫存庫測到;壓縮檔解壓 IO 路徑沿用 `project` 既有風格不直接測 | project-sync 測試 |

**批次澄清後仍不確定的點**(會變成 subagent 的「待確認假設」):

- 登記的專案目錄存在、但 `assets/` 子目錄被整個刪掉時,四類對帳的結果與訊息措辭
- `--match` / `--pack` 都不給時是否等同「該專案可用的全部素材」(`new-project` 是這個語意)
- 對帳結果的終端機輸出版面(分類標題、是否截斷長清單、截斷幾筆)

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| project-sync | F006 | F006-project-sync.md | 繼承 | 繼承 | impl-done(閘門通過) |

模型選擇理由:`project-sync` 跨 `project` 與 `cli` 兩個套件、要新增套件依賴、四類對帳的
邊界條件多,且是唯一會動使用者既有專案檔案的指令(誤判就是覆蓋或漏判使用者的手動修改)。
契約卡雖然完整,但風險集中在「只增不刪」這條安全性質上,設計與實作都不降級。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F006 A1 | 「既有登記素材的素材包授權降級」的警告要放哪裡:`SyncPlan` 只有 `spBlocked`,而那些素材並沒有被擋 | 經 `soOnEvent` 逐包發出警告,不進 `spBlocked`(放進去會讓「被擋下」的語意變質) | **要改** —— 契約已加 `spWarnedPacks :: [Text]`,涵蓋範圍改為登記全集(併入 B006) |
| F006 A2 | `manifest.json` 的 `maSha256` 對既有素材取哪一個雜湊;0 筆新增時要不要重寫 manifest | 取 `copied_sha256`(磁碟上真正是什麼);`--confirm` 即使 0 新增也重寫 | **接受** —— 與 §6 字面相容 |
| F006 A3 | `--confirm` 下「真的複製成功」的路徑沒有自動化測試 | 遵守 D4,以「新增項讀取失敗」與「0 筆新增」兩條覆蓋 confirm 分支;`copied_sha256` 寫入只能人工驗收 | **接受** —— 已知測試缺口,不阻擋放行;要補時最小成本是 stored ZIP fixture |
| F006 A4 | `project_assets.copied_sha256` 為 NULL 的舊列如何判定 | 退回與 `assets.sha256` 比對;不同就算 `SyncLocallyModified`(保守,永不覆蓋) | **接受** |
| F006 A5 | `AssetDB.Cli.Project` 匯出 `syncExitCode`,**超出契約卡列舉的介面** | 比照 `nonCommercialPacks` 的可測性先例匯出(`runProjectSync` 會 `exitFailure`,測不動) | **接受** —— 已補進 `design.md` 的 `cli` 模組介面與契約卡 |

實作階段追加三條(A6–A8),經 arch-audit 逐條複查,全部「如宣稱」且停在實作自主權內:

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F006 A6 | `project` 測試套件另加 `assetdb-ingest` / `aeson` 等相依 | 純測試相依;測試不用 `discoverTools`,固定資料一律 `.rar` 讓讀取失敗與本機有無 7-Zip 無關 | **接受** —— 純測試相依,library 相依方向未受影響 |
| F006 A7 | `--allow-non-commercial` 是否連既有素材包的降級警告也一併關掉 | 一併關掉(警告與閘門同源) | **接受** —— 維持現狀(§6 只規定閘門預設值,未規定兩者是否解耦) |
| F006 A8 | `Internal` 除文檔列的九項外多一個 `destRelOf` | 純內部輔助,`Create` 維持原樣不改用 | **接受** —— 但落點算法兩份的漂移風險記在 B007,修復時一併收斂 |

另有一項編排者選配、未動的:`design.md` 的「內部模組劃分」是否為 `project` 補一列
`AssetDB.Project.Internal`(`Create` 與 `Sync` 共用的私有輔助,`other-modules` 不 exposed)。
arch-audit 認為它是**模組**層級的劃分而非私有函數命名,補上不違反抽象邊界規範,建議補。

## 階段結果

### 階段 14

**完成的 features**:`F006` project-sync(TodoList 10/10,設計與實作都未降級模型)。

**測試**:592 examples / 0 failures,9 個 test suite 全 PASS(基準線 558 → +34)。
`assetdb-project-test` 24 → 47、`assetdb-cli-test` 37 → 48,其餘七個 suite 數字未變且全綠
(`CreateSpec` / `TemplateSpec` / `AssetsSpec` 綠燈 = T1 的跨模組搬移無回歸)。
編排者獨立重跑驗證,非採信回報。

**三條硬規則的獨立查證**(編排者 grep + arch-audit 靜態閱讀,兩邊各自確認):

1. 不得刪 `project_assets` —— `Sync.hs` 只有 `INSERT OR IGNORE` 與 `UPDATE projects.updated_at`;
   `DELETE FROM project_assets` 全庫只在 `Create.hs:128`,且 `registerProject` 不在 `Create`
   的匯出清單裡,語言層面就到不了
2. 不覆蓋既有檔案 —— `project/` 與 `cli/` 全域無 `removeFile` / `renameFile` / `copyFile`;
   `copyAssets` 的輸入只有 `SyncNew` 類
3. `new-project` 行為不受影響 —— 四處落點算法逐字相同,唯一輸出變動是契約要求的 V11
   (SKILL.md 樣板改寫)

**arch-audit 發現**:嚴重 0、中等 3、輕微 10。中等三條見下方裁決事項;輕微多為文檔落差
(P6 段落順序、契約卡負責模組漏列、`system.md` 未登記 `project` 指令群)。

**閘門結論**:**通過放行**(2026-08-21)。開發者裁決四項:

1. `syncExitCode` 納入契約 —— 已補進 `design.md` 的 `cli` 模組間公開介面與 `project-sync` 契約卡
2. 警告改為結構化 —— `SyncPlan` 加 `spWarnedPacks :: [Text]`,**契約已變動**,由 B006 實作
3. M1 與 M3 兩個缺陷現在就修 —— 開 `B006`、`B007`
4. 文檔落差全部補齊 —— P6 段落順序、`Internal` 模組列、契約卡負責模組、`system.md` 的
   `project` 指令群與階段 14、README 的「尚未實作」與新增的使用章節

編排者另發現 M3 的雙集合寫法在 `Create.hs:82/92` 早已存在,是從 `F005` 繼承的既有缺陷
而非本次委派寫壞,因此 B007 涵蓋 `new-project` 與 `project sync` 兩條路徑。

**契約在過程中被修訂**:是。§6 加了「警告涵蓋登記全集」與「兩個產物同一集合」兩條、
`SyncPlan` 加 `spWarnedPacks`、`cli` 介面加 `syncExitCode`、P6 兩處段落順序修正。

### 閘門後的缺陷修復(2026-08-21)

閘門裁決「現在就修」的兩條,依 `/bugfix` 流程先寫會紅的重現測試再修:

| id | 缺陷 | 修法 | 結果 |
|---|---|---|---|
| `B006` | 授權降級警告只涵蓋本次候選,不在篩選條件內的既有素材包被靜默寫進 manifest | 新增 `registeredPackSlugs`(查 `project_assets`,與 `rewriteGenerated` 同範圍)取代原本從候選反推;`SyncPlan` 填入 `spWarnedPacks`,CLI 加摘要輸出 | done,+5 條測試 |
| `B007` | `manifest.json` 與 `Assets.hs` 用兩個不同集合,驗證失敗的列會出現在 `Assets.hs` 卻不在 manifest | `Internal` 新增 `excludeUnusable`,回傳 `[(a, b)]` 讓兩個產物**天然拿到同一個集合**,被排除的列一律經事件回呼出聲;`Create` 與 `Sync` 兩條路徑都改;落點算法從四份收斂成一份 `destRelOf` | done,+7 條測試 |

`B007` 的缺陷在 `Create.hs:82/92` 早已存在(繼承自 `F005`),不是本次委派寫壞的;
兩條路徑一起修,`new-project` 因此也拿到了「被排除的列會出聲」這個新行為。

**測試**:592 → **604 examples / 0 failures**(9 個 test suite 全綠),編排者獨立重跑驗證。
重現測試都確認過「先紅後綠」——`B007` 的 `Create` 路徑另以「把 `Create.hs` 暫時改回缺陷
形狀」的方式驗證新測試抓得到(2 failures),還原後轉綠。

修復階段追加兩條假設:

| 來源 | 假設 | 採取的判斷 | 裁決 |
|---|---|---|---|
| B006 A1 | 警告要「只從 `spWarnedPacks` 出」還是「事件 + 摘要」雙輸出 | 保留 `soOnEvent` 的逐包事件(涵蓋範圍已改成全集),另在 CLI 加摘要,與 `spBlocked` 現有模式對稱 | **接受** —— 與既有輸出模式一致,且不必改寫 F006 的 V8 測試 |
| B007 A2 | 素材包 / 授權中繼資料要不要跟著產物集合縮減 | **不縮減**:被排除的檔案仍在專案裡,致謝與授權義務跟著檔案走而不是跟著 manifest 條目走 | **接受** —— 授權義務的判斷應取寬不取窄 |
