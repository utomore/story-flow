---
id: G-B001
type: bugfix
title: cluster-apply-missing-confirm-gate
description: cluster apply 一次寫全庫邏輯名稱卻沒有預覽閘門
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: [ADR-004]
related-feature: [delivery/F001, ingest/F005]
subsystems: [delivery, ingest]
---

# G-B001: `cluster apply` 沒有預覽閘門

## 症狀

```bash
assetdb cluster apply --pack complete-ui-book-styles
```

這一行**直接把數千筆 `logical_name` 寫進資料庫並重建全文索引**,沒有預覽、沒有確認、
沒有 undo。

| | 預期 | 實際 |
|---|---|---|
| 預設行為 | 只預覽,列出會命名幾筆與實際會產生的名字 | **直接寫入** |
| 需要 `--confirm` | 是 | **沒有這個旗標** |
| 寫入後可回退 | —— | 否,`logical_name` 沒有 undo 路徑 |

`logical_name` 是 **ADR-004 定義的對外命名契約**:全域唯一、遊戲專案的 `Assets.hs` 常數
直接由它產生、`manifest.json` 以它為鍵。寫錯之後要復原,只能重新推規則再套一次——而
中間那段時間,任何用這個素材庫建出來的專案都拿到了錯的名字。

**影響範圍**:單一指令即可改動全庫命名。`cluster rule` 有 `--confirm`(預設只預覽),
但那只確認**規則本身**;真正把規則套成名字的 `cluster apply` 反而沒有閘門。使用者調完
規則後打 `apply`,不會看到任何「將要發生什麼」。

## 重現步驟

最小重現(`ingest/test/AssetDB/Ingest/ClusterDbSpec.hs` 的 `withPack` fixture):

1. 對一個叢集存下已確認的命名規則
2. 呼叫 `applyNames st defaultVocab 1`(即 `cluster apply` 的實際動作)
3. 查 `assets.logical_name`

**實際**:名稱已經寫進去了。**預期**:預設情況下一個字都不該寫。

CLI 層:`assetdb cluster apply --help` 列不出任何 `--confirm`,而 `--pack` 是唯一的參數。

## 根因分析

**兩層都缺,而且是契約層先缺的。**

### 1. CLI 沒有旗標(`cli/app/AssetDB/Cli/Options.hs`)

```haskell
command "apply"
  ( info (CmdClusterApply <$> optional packOpt)
         (progDesc "把已確認的規則套用成邏輯名稱") )
```

`Command` 的建構子是 `CmdClusterApply (Maybe Text)` —— 型別裡就沒有確認的位置。
全檔四個 `--confirm` 分別在 `ai apply`、`ai suggest confirm/reject`、`project sync`、
`cluster rule`,**沒有 `cluster apply`**。

### 2. Runner 無條件寫入(`cli/app/AssetDB/Cli/Cluster.hs`)

```haskell
runClusterApply :: FilePath -> Maybe Text -> IO ()
```

簽名裡沒有任何確認參數,函式直接呼叫 `applyNames` 再無條件 `reindexFts`。

### 3. 下游沒有「算但不寫」的能力(`ingest/src/AssetDB/Ingest/ClusterDb.hs`)

```haskell
applyNames :: Store -> NamingVocab -> Int -> IO ApplyNames
```

`applyNames` 內部其實**已經是乾淨的兩段**:先把 `resolved → computed → failures / oks →
collisions → safe` 全部算完,才進交易寫入。但介面上沒有停在第一段的方法,呼叫端只能
「算完並寫入」或什麼都不做。

而且 `ApplyNames` 只帶計數與問題清單(`anNamed` / `anSkipped` / `anFailed` /
`anCollisions`),**不帶實際會產生的名字**——即使能停在第一段,也沒東西可以給人看。

### 4. 契約層:Level 1 與 Level 2 目前不一致

`.design/system.md` 的全域錯誤處理策略第 3 條(2026-08-21 修訂)已把 `cluster apply`
列進「會改動狀態的動作預設只預覽」的適用清單,理由正是「它寫的是 ADR-004 的對外命名
契約且不可逆」。但 `.design/subsystems/delivery/design.md` 的對應清單**還停在舊版**,
只列了 `cluster rule`、`ai suggest confirm/reject`、`ai apply`、`project sync`。

所以這不只是實作疏忽,是**契約層的遺漏**:Level 2 從來沒有要求過這個閘門,實作自然
不會有。修復必須連契約一起補,否則下次有人讀 `delivery/design.md` 還是會認為現況正確。

## 修復方向

**讓 `applyNames` 能停在「算完但不寫」,並把實際會產生的名字帶出來給人看。**

1. `ApplyNames` 新增 `anNames :: [(Text, Text)]` —— `(entry_path, logical_name)`,
   即通過驗證且不撞名的那些。這份資料 `applyNames` 內部本來就算出來了(`safe`),
   只是沒有交出去。預覽要給人看名字,就必須有它。
2. `applyNames` 新增確認參數:`Store -> NamingVocab -> Int -> Bool -> IO ApplyNames`。
   `False` 時走完全部計算後**不進交易**直接回報。
   **關鍵性質:預覽與實際套用走同一條計算路徑**,不可能漂移——這是 `delivery/B007`
   的教訓(manifest 與 `Assets.hs` 各算各的集合,結果兩邊對不起來)。
3. `CmdClusterApply` 加上確認欄位,`command "apply"` 加 `--confirm` 旗標並改寫 `progDesc`。
4. `runClusterApply` 加確認參數:未確認時印出摘要與抽樣的名稱對應、**不寫入也不重建索引**;
   確認時行為與現況相同。
5. 回填契約:`delivery/design.md` 的適用清單補上 `cluster apply`(同步 Level 1);
   `ingest/design.md` 的 `applyNames` 簽名與 `ApplyNames` 欄位、F005 契約卡同步。

**預覽輸出**:每包一行摘要(將命名 N 筆、跳過 M 筆)加上幾筆 `原檔名 → 邏輯名稱` 的抽樣。
不逐筆全列——一次可能數千筆,列完在終端機裡滾過去沒人會看,而且 PowerShell 接
`Select-Object` 會殺掉上游行程(已知陷阱 6)。

**動到 Level 2 公開契約**:`applyNames` 與 `ApplyNames` 都在 `ingest/design.md` 的對外
契約與模組間公開介面中;`Command` 與 `runClusterApply` 在 `delivery/design.md` 中。
四項都要同步,已與開發者確認。

**替代方案(已放棄)**:讓 CLI 自己用 `loadRules` + `packPaths` + `applyRule`(都是公開
介面)重算一份預覽。不動 ingest 的契約,但等於把命名的業務邏輯複製進 delivery——違反
「delivery 不放業務規則」,而且預覽與實際套用會是兩份各自演進的程式碼,正是 B007 那類
缺陷的翻版。

**本次不做**:不改 `cluster rule` 的既有行為;不為 `logical_name` 做 undo 機制
(那是獨立的 feature,要設計批次與回退語意);不動 `pack apply` / `note import` / `link`
(它們的輸入是版控檔案或單筆操作,`system.md` 第 3 條已寫明不適用)。

## TodoList

- [x] T1: 撰寫重現測試:未確認時不得寫入 `logical_name`(修復前應失敗)  `dep: -`
- [x] T2: `ApplyNames` 加 `anNames`;`applyNames` 加確認參數,未確認時不進交易  `dep: T1`
- [x] T3: `CmdClusterApply` 加確認欄位,`--confirm` 旗標與 `progDesc`  `dep: T1`
- [x] T4: `runClusterApply` 預覽分支:摘要 + 抽樣名稱,不寫入、不重建索引  `dep: T2, T3`
- [x] T5: 回填 `delivery/design.md` 適用清單與 `ingest/design.md` 的介面與契約卡  `dep: T2, T3`

## 驗證方式

重現測試轉綠,`cabal test all` 全綠(基準線 606 examples / 0 failures)。

另需 CLI 層的解析測試:`cluster apply --help` 列得出 `--confirm`;不給旗標時解析結果的
確認欄位為 `False`;`cluster rule` 與其他指令的解析不受影響。

## 修復紀錄

依「修復方向」完成,**無偏差**。

`applyNames` 的計算段(`resolved → computed → failures / oks → collisions → safe`)本來就
已經在寫入之前全部做完,所以確認參數只是決定**要不要進最後那個交易**——預覽與套用共用
同一條路徑,兩者的 `anNamed` 與 `anNames` 逐筆相同,不存在漂移的可能。這一點有測試直接
釘住(「確認後才真的寫入,且結果與預覽完全一致」比對的是 `anNames` 而不只是數字)。

CLI 側預覽輸出每包一行摘要加上頭中尾抽樣的 `原檔名 → 邏輯名稱`,並在結尾提示
「這是預覽,沒有寫入任何東西」。預覽不呼叫 `reindexFts`——沒有改動任何東西,索引自然
不必重建。

### 一處超出字面要求的改動

`sampleOf` 原本是 `runClusterRule` 的 `where` 綁定,預覽輸出需要同樣的「頭中尾各取」
取樣。**把它提升為多型的頂層 helper 而不是複製一份**——複製出來的第二份取樣邏輯正是
本次修復要避免的那類問題(兩份各自演進)。純搬移,`cluster rule` 的行為未變。

### 重現測試

`ingest/test/AssetDB/Ingest/ClusterDbSpec.hs` 的「預覽閘門(G-B001)」三條:

| 測試 | 釘住的性質 |
|---|---|
| 未確認時算得出會命名幾筆,但一個字都不寫進資料庫 | 閘門本身 |
| 預覽帶得出實際會產生的名字,不只是數字 | 規則對不對只有看名字才判斷得出來 |
| 確認後才真的寫入,且結果與預覽完全一致 | 預覽與套用不可漂移 |

`cli/test/AssetDB/Cli/ParserSpec.hs` 的「cluster apply」四條:`--help` 列得出 `--confirm`、
預設 `confirm = False`、`--confirm` 與 `--pack` 一起收得到、`cluster rule` 與 `list` 的
解析不受影響。

**修復前執行結果**(第一條):

```text
1) 預覽閘門(G-B001) 未確認時算得出會命名幾筆,但一個字都不寫進資料庫
     expected: []
      but got: ["ui_gui_travel-book-alert_01a","ui_gui_wizard-book-alert_01a"]
```

那兩個名字**已經寫進資料庫了**——而使用者從來沒有機會看它們一眼。

### 驗證結果

```text
cabal build all     # 零 error、零 warning
cabal test all      # 613 examples, 0 failures(9 個 test suite 全 PASS)
cabal run assetdb -- cluster apply --help   # 列出 --pack 與 --confirm
```

基準線 606 → 613(+7),既有測試無一變紅。既有的 `applyNames` 呼叫點(四條測試)改為
明確傳 `True`,語意不變。

### 契約回填

- `delivery/design.md`:「會改動狀態的動作預設只預覽」補上 `cluster apply`,並寫明它
  **最容易被漏掉**的理由(看起來只是「套用已確認的規則」,實際寫的是不可逆的對外命名契約,
  而 `cluster rule` 的 `--confirm` 只確認規則本身,不能替代);`Command` 的建構子同步
- `ingest/design.md`:`applyNames` 簽名與 `ApplyNames` 的 `anNames`、管線 C 的分支圖、
  F005 契約卡的驗收標準
- `README.md`:日常操作 2 的步驟 ③ 改為兩行(預覽 / `--confirm`),並解釋兩道 `--confirm`
  確認的不是同一件事

這條 Level 1 與 Level 2 的不一致(`system.md` 已列入、`delivery/design.md` 未列入)
至此消除。

### 過程中發現、未在本次處理的

`ingest/test/AssetDB/Ingest/ClusterDbSpec.hs:55` 對 `anCollisions` 用了 `head`,
在該檔重新編譯時會產生 `-Wx-partial` 警告。屬既有測試碼、與本缺陷無關,依最小修復原則
未動;值得日後順手改成 pattern match。
