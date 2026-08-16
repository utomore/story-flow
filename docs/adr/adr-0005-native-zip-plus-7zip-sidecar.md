---
id: adr-0005
type: adr
title: native-zip-plus-7zip-sidecar
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

# ADR-0005: ZIP 用原生 Haskell 處理,RAR/7z 外包給 7-Zip Sidecar 行程

## 狀態(Status)

Accepted。實作於 `archive/src/AssetDB/Archive/{Zip,Sidecar,Types}.hs`。

## 背景(Context)

素材庫壓縮格式以 ZIP 為主(PNG 佔 91%,ZIP 也是),但也有 RAR 與 7z(尤其是 solid 壓縮的
大型效果包)。Haskell 生態沒有成熟的原生 RAR/7z 讀取函式庫,而 solid 壓縮格式的特性是
「單筆項目讀取需要重新解壓整個 solid block」——若對 solid 壓縮檔逐項目呼叫外部行程,
n 個項目會變成 O(n²) 的重複解壓成本。

## 決策(Decision)

- **ZIP**:用純 Haskell 的 `zip` 套件原生處理,列表與單筆項目串流讀取都不需要外部行程。
- **RAR/7z**:外包給 7-Zip CLI(`typed-process` 呼叫 sidecar 行程),**使用者需自行安裝**。
  `archive/Sidecar.hs` 維護一份 Windows/macOS/Linux 的候選安裝路徑清單(含實機教訓:
  裝了但不在 PATH 的情況)。
- **`needsSidecar`**:依副檔名判斷是否需要外部行程,`formatExtensions` 是格式判定的權威
  來源。
- **`prefersBulkExtraction`**:偵測 solid 壓縮特性,對這類壓縮檔改採「一次性批次抽取全部
  項目到暫存目錄」而非逐項目呼叫 sidecar,避免 O(n²) 重複解壓。
- **7-Zip 缺席時的降級行為**:對應資源仍會建索引,只是沒有預覽圖,`doctor` 指令會列出來
  —— 不因為 sidecar 缺席而讓整個掃描失敗。

## 考慮過的替代方案(Alternatives Considered)

- **改用其他語言/生態重寫壓縮處理**:被否決,見 ADR-0001 —— manifest 型別共用的價值
  大於補齊 Haskell 壓縮生態的成本。
- **逐項目呼叫 7-Zip CLI(不做 bulk extraction 特例)**:曾是原始設計,發現 solid 壓縮格式
  下會是 O(n²) 成本後改為 `prefersBulkExtraction` 特例處理。
- **要求使用者統一轉檔成 ZIP**:違反「不重新打包廠商壓縮檔」的原則(見 ADR-0002),
  已放棄。

## 影響(Consequences)

- 系統存在一個**執行期外部相依**(7-Zip 安裝與否),不像其他相依可以在編譯期保證存在。
  `doctor` 指令是這個相依缺口的唯一使用者可見信號,若使用者從未執行 `doctor`,sidecar
  缺席會無聲地表現為「這幾個資源沒有縮圖」,不易被發現。
- solid 壓縮的 bulk extraction 需要暫存磁碟空間,大型 rar/7z 包(如 1,269 個項目的效果包)
  掃描時會有明顯的暫存 I/O,目前未見對暫存空間不足的防禦性處理。
