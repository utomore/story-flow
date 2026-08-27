---
id: E001
type: enhance
title: store-internal-module-boundary
description: 把 aapms-store 的內部模組界線從註解收進 cabal,由編譯器守
status: done
created: 2026-08-26
updated: 2026-08-27
depends-on: []
related-adr: []
related-feature: [F006, F008]
---

# E001: 收攏 `aapms-store` 的內部模組界線

## 現況分析

三個模組在自己的 haddock 第一行就宣告自己是內部模組:

| 模組 | 原文 | 位置 |
|---|---|---|
| `Aapms.Store.Edit` | 「內部模組,不對外承諾介面」 | `store/src/Aapms/Store/Edit.hs:1` |
| `Aapms.Store.Node` | 「內部模組」 | `store/src/Aapms/Store/Node.hs:1` |
| `Aapms.Store.Row` | 「內部模組,不對外承諾介面,不經 `Aapms.Store` 門面 re-export」 | `store/src/Aapms/Store/Row.hs:1` |

門面 `store/src/Aapms/Store.hs:25-30` 也再講一次同樣的話,而且確實沒有 re-export 它們。

**但 `store/aapms-store.cabal:25-40` 把 14 個模組全部列進 `exposed-modules`**,所以上面四處宣告
沒有任何一處是編譯器在守的——套件外照樣 import 得到。設計意圖是一致的,缺的只是機制。

已經有人穿過去了:`service/src/Aapms/Service.hs:130` 是
`import Aapms.Store.Edit (Located (..), locate, locateNode)`,在 `:494` 與 `:520` 使用。
build-log D11 記過這件事,處置是「P3 重建 `service` 時改這一行」——修了個案,沒修讓個案發生的原因。
順帶一提,`requireTargetExists`(`Service.hs:488-496`)要的其實是「這個 `Ref` 指得到節點嗎」,
契約 E 的 `lookupNode` 正是這個問題的答案;它穿透內部並沒有拿到門面給不了的能力。

**誰真的依賴這三個模組**(knot 反向可達 depth 1,與 grep 逐條交叉比對,兩者結果完全一致):

| 模組 | 套件內 | 套件外 |
|---|---|---|
| `Node` | `Store.Create:114` | **無** |
| `Row` | `Store.Index:66` / `MultiVault:92` / `Query:89` | **無** |
| `Edit` | `Store.Create:100` / `Write:65` | `Aapms.Service:130`(凍結中) |

所以關掉 `Node` 與 `Row` 在 `aapms-store` 之外零成本;只有 `Edit` 有一個外部消費者,而它是 P3 會
重寫的凍結程式碼。

**第二個洞,性質不同**:`store/src/Aapms/Store/Index.hs:35-37` 的匯出清單裡有

```haskell
    -- * 內部(測試用)
  , vaultMarkdownFiles
  , statOf
```

而 `Aapms.Store.Index` **在門面的 re-export 清單上**,所以這兩個標著「測試用」的符號其實是
`aapms-store` 的公開介面,契約 E 從來沒有登記過它們。`service/src/Aapms/Service.hs:231` 已經在用
`vaultMarkdownFiles`——而且用途很單純:數檔案數填 `IndexReport`。這不是有人亂穿內部,是一個合理的
業務需求撞上了一個沒登記的介面。`statOf` 則連測試都沒有外部使用者,只有 `Index.hs:176` / `:459`
自己在用。

**一件在檢視原始碼時推翻掉的事**:`/arch-audit` 當時把「`WriteResult` 定義在內部模組 `Edit`,
門面永遠得 re-export 一個內部模組的型別」列為結構問題。讀了 `store/src/Aapms/Store/Write.hs:2-3`
之後這條**不成立**——

```haskell
module Aapms.Store.Write
  ( -- * 結果(定義在內部模組 "Aapms.Store.Edit",由本模組帶進門面)
    WriteResult (..)
```

公開的 `Write` 已經原樣 re-export 它,而「型別定義在 `other-modules`、由公開模組 re-export」是
Haskell 的標準做法,型別照樣可用可命名。`Create.hs:6-7` 對 `Aapms.Md.Render` 的 `NewSection`
用的是同一個模式。**所以本次沒有任何型別需要搬家。**

## Scope(涵蓋範圍)

2026-08-26 與開發者定案:

**動**:

1. `Edit` / `Node` / `Row` 從 `exposed-modules` 移到 `other-modules`——由**編譯器**守,不靠人記得
2. `vaultMarkdownFiles` / `statOf` 搬進新的內部模組 `Aapms.Store.Walk`,`Index` 的匯出清單不再有它們
3. test-suite 改成自己編 library 原始碼(見「遷移約束」,兩個動作缺一不可)

**明確不動**:

- **契約 E 一個字不動**。開發者已裁決 `vaultMarkdownFiles` 不收進契約 E:P3 設計 `service` 時
  「`IndexReport` 要的檔案數」該由真正的消費者在 `/subsys-design service` 正式提出需求,不由本次
  替一個還沒設計的子系統猜它要什麼形狀
- **`service/` 一行不改**(凍結中,P3 重寫)。D11 那條穿透 import 留給 P3
- **`WriteResult` 不搬**(理由見現況分析)
- **`Edit` / `Node` / `Row` / `Walk` 的函式本體與簽名一律不改**;本次只動可見度與所在模組

**被排除的「順便改」**(開發者拒絕,不另開文檔,記在此):

- 把契約 E 的結果型別(`CreateResult` / `DeleteResult` / `DeleteMode` / `IndexIssue` / `WriteResult`)
  集中到單一模組。理由:會動到 `Create.hs` 與 `Schema.hs` 兩個目前沒有問題的模組,把回歸面從
  1 個模組擴大到 3 個,而收益只是「以後新增結果型別不用問放哪」

**對外契約**:維持完全相容。`aapms-store` 對外可見的簽名與行為零變動,Level 2 的契約 E 不需回寫。

## 改善目標

1. `aapms-store` 對外承諾的模組清單,唯一真相從「四處 haddock 註解」變成 `aapms-store.cabal`
   一個欄位;套件外 `import Aapms.Store.Edit` 從「可以,只是不該」變成**編譯錯誤**
2. 契約 E 沒登記的符號不再出現在 `aapms-store` 的公開介面上(`vaultMarkdownFiles` / `statOf`)
3. 上述兩點達成的同時,契約 E 的對外簽名與既有 260 條 store 測試的行為**一條都不變**

驗收:L1–L4 全綠(新 law),R1–R6 全綠(回歸 law),`cabal test all` 全綠。

## 數據與介面變動

| 項目 | 動作 | 簽名 / 定義 | 語意(做什麼) | 受影響呼叫端 | 骨架位置 |
|---|---|---|---|---|---|
| `Aapms.Store.Edit` | 改可見度 | 整個模組:`exposed-modules` → `other-modules` | 不再是 `aapms-store` 的對外承諾;套件外 import 即編譯失敗 | 套件內 `Create.hs:100`、`Write.hs:65` 不受影響(同套件);套件外只有凍結的 `Service.hs:130`,本次不動 | `store/aapms-store.cabal:25-40` |
| `Aapms.Store.Node` | 改可見度 | 同上 | 同上 | 套件內 `Create.hs:114`;套件外無 | `store/aapms-store.cabal:25-40` |
| `Aapms.Store.Row` | 改可見度 | 同上 | 同上 | 套件內 `Index.hs:66`、`MultiVault.hs:92`、`Query.hs:89`;套件外無 | `store/aapms-store.cabal:25-40` |
| `Aapms.Store.Walk` | 新增(內部模組) | `vaultMarkdownFiles :: FilePath -> IO [FilePath]` | 回傳 vault 底下全部 Markdown 檔的相對路徑,已排序;略過 `.` 開頭目錄與非 `.md` 檔 | 新:`Index.hs` 改為 import 本模組;`IndexSpec.hs` 的 T3 改指本模組 | `store/src/Aapms/Store/Walk.hs:40` |
| `Aapms.Store.Walk` | 新增(內部模組) | `statOf :: FilePath -> IO (Either StoreError (Int64, Int64))` | 回傳過時偵測的兩個依據,順序是 **`(mtime, size)`**——第一個分量是修改時間(奈秒),第二個是位元組數;讀不到檔案回 `StoreError`,不拋例外 | 新:`Index.hs:127`、`Index.hs:410` 改呼叫本模組 | `store/src/Aapms/Store/Walk.hs:69` |
| `Aapms.Store.Index` 匯出清單 | 移除兩項 | 拿掉 `vaultMarkdownFiles`、`statOf` 與「內部(測試用)」那一段 | `Index` 不再對外暴露檔案走訪與 stat(`Index` 本身仍是公開模組,所以這一步是 L4 而不是 L1 在守) | `IndexSpec.hs:14` 的開放式 `import Aapms.Store.Index` | `store/src/Aapms/Store/Index.hs:35-37` |
| `WriteResult` | **不動** | `data WriteResult` 仍定義在 `Edit.hs:96` | 由公開的 `Write.hs:3` 原樣 re-export,門面路徑與今天完全相同 | 無 | `store/src/Aapms/Store/Edit.hs:96`(不動) |

## Laws(行為性質)

**回歸 law(改完必須一模一樣的現有行為)**

- R1: 只 `import Aapms.Store`(不 import 任何 `Aapms.Store.*` 子模組)就取得到契約 E 的每一個公開
  符號——vault 把手組、索引維護組、單一 vault 查詢組、跨 vault 讀組、寫入組、錯誤組。這條由
  「能不能編譯」證明:少 re-export 任何一項,測試模組就編不過
- R2: `WriteResult` 經 `Aapms.Store` 取得的,與經 `Aapms.Store.Write` 取得的是**同一個型別**,
  四個欄位 `wrId` / `wrPath` / `wrRevision` / `wrIssues` 都存取得到
- R3: 對任意 vault 目錄,`vaultMarkdownFiles` 回傳的清單與搬模組前**逐項相同且順序相同**
  (仍然略過 `.` 開頭目錄與非 `.md` 檔,仍然回相對路徑,仍然已排序)
- R4: 對任意路徑,`statOf` 的結果與搬模組前相同;檔案不存在時仍回 `Left`,不拋例外。
  **回傳的 tuple 是 `(mtime, size)`**:對任意位元組內容 `bs`,把 `bs` 寫進一個檔再 `statOf` 它,
  **第二個**分量等於 `bs` 的長度;第一個分量是奈秒級的修改時間,不等於長度(除非長度碰巧相同,
  斷言請只釘第二分量)。同一個未變動的檔案連續 `statOf` 兩次,兩次結果完全相同
- R5: `aapms-store` 既有的 260 條測試維持全綠——本次不得產生任何可觀察的行為差異
- R6: 索引重建等價不變:`rm index.db` → `rebuildIndex` 後的查詢結果與重建前相同(ADR-013)

**新 law(這次優化才成立的性質)**

- L1: `aapms-store.cabal` 的 library `exposed-modules` **不含** `Aapms.Store.Edit`、
  `Aapms.Store.Node`、`Aapms.Store.Row`、`Aapms.Store.Walk`
- L2: 上述四個模組**都出現在** library 的 `other-modules`
- L3: `aapms-store-test` 的 `build-depends` **不含** `aapms-store`,且它的 `hs-source-dirs`
  同時含 `src` 與 `test`(兩者只做一半會編出兩份模組實體,型別不合一——見「遷移約束」)
- L4: `store/src/Aapms/Store/Index.hs` 的模組匯出清單**不含** `vaultMarkdownFiles` 與 `statOf`
  ——`Index` 仍是公開模組,所以光靠 L1 / L2 擋不住它;這兩個符號必須從它的匯出清單消失,
  才算真的離開 `aapms-store` 的公開介面。與 L1 / L2 同樣以原始檔文字斷言

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| E1 | 讀 `aapms-store.cabal` 的 library stanza | `exposed-modules` 含 `Aapms.Store` / `.Atomic` / `.Create` / `.Error` / `.Index` / `.Marker` / `.MultiVault` / `.Query` / `.Schema` / `.Tokenize` / `.Write` 共 11 項;`other-modules` 含 `.Edit` / `.Node` / `.Row` / `.Walk` 共 4 項 | L1 / L2 的具體形狀;11 + 4 = 15,對帳用 |
| E2 | 一個測試模組只寫 `import Aapms.Store (...)`,列出契約 E 的全部符號並各引用一次 | 編譯通過 | R1(門面完整性) |
| E3 | vault 目錄含 `.aapms/config.toml`、`.git/HEAD`、`foo.txt`、`bar.md` | `vaultMarkdownFiles` 回 `["bar.md"]` **= 現況**(即今天 `IndexSpec.hs:22-31` T3 的斷言) | R3:`.` 開頭目錄與非 `.md` 都要略過 |
| E4 | 完全空的 vault 目錄 | `vaultMarkdownFiles` 回 `[]` **= 現況** | R3 退化邊界 |
| E5 | 不存在的檔案路徑 | `statOf` 回 `Left` 的 `StoreError`,不拋例外 **= 現況** | R4 錯誤路徑 |
| E6 | 寫一個內容恰為 5 個位元組的檔,對它 `statOf` | 回 `Right (m, 5)`——**第二個**分量是 `5`;第一個分量 `m` 是奈秒時間戳,遠大於 5 **= 現況** | R4 的 tuple 順序(G20 的回歸點:順序寫反時這條會紅,而簽名比對抓不到) |

## 遷移約束

- **契約 E 的簽名與行為一個字不變。** 本次不得出現任何對外可見的行為差異;任何「順便修正一下」
  的念頭都屬於別的文檔
- **test-suite 的兩個動作缺一不可**:`hs-source-dirs` 加 `src` **且**從 `build-depends` **移除**
  `aapms-store`。只做前者會讓同一批模組被編兩份(一份來自套件、一份來自 `src`),GHC 會報
  「同名型別不是同一個型別」;只做後者則根本找不到模組。移除套件相依之後,test-suite 要自己補上
  library 的相依面——目前它已有 `aeson` / `bytestring` / `containers` / `directory` / `filepath` /
  `sqlite-simple` / `aapms-core` / `aapms-md` / `text` / `time` / `toml-reader`,**還缺 `direct-sqlite`**
- **`service/` 凍結中,一行不改。** `Service.hs:130` 的穿透 import 與 `:231` 的
  `vaultMarkdownFiles` 都留給 P3 重建 `service` 時處理;本次不為了讓它編得過而放寬任何界線
- **`Walk` 的兩個函式是原樣搬移**,不是重寫:搬過去之後行為必須與 `Index.hs:85` / `Index.hs:104`
  的現有實作完全相同(R3 / R4 在釘這件事)

## 邊界與知識歸屬

- **擁有的知識**:
  - 「哪些模組是 `aapms-store` 的對外承諾」——本次從**四處 haddock 註解**(靠人記得)收攏到
    `aapms-store.cabal` 的 `exposed-modules` **一處**(靠編譯器)。三份模組註解可以保留為說明,
    但它們不再是唯一真相
  - 「哪些檔案算這個 vault 的 Markdown」「怎麼取 size / mtime」——本次從 `Aapms.Store.Index`
    分出來,由 `Aapms.Store.Walk` 唯一持有;`Index` 改成向它拿,不自己走訪
- **依賴方向**:
  - **套件之間零變動**。`aapms-store` 的 `build-depends` 不動,四條硬規則的判定結果不變
  - 套件內**新增兩條邊**:`Aapms.Store.Index → Aapms.Store.Walk`、`Aapms.Store.Walk → Aapms.Store.Error`(`statOf` 的錯誤型別)
  - **移除的邊**:無
  - test-suite 的相依面變動見「遷移約束」(移除 `aapms-store`、補 `direct-sqlite`)——依
    `boundary-rules.md`「測試不在依賴圖裡」,這不影響 production 的依賴方向斷言
- **不可逆決定**:**無**。可見度是 `.cabal` 的一個欄位,要改回去是一行的事。若 P3 發現 `service`
  真的需要某個現在被關起來的符號,正確做法是**把那個符號加進契約 E**(經 `/subsys-design`),
  而不是把模組重新打開——後者會讓契約 E 再一次失去「登記過的才算數」這個性質

## 相依性

`depends-on: []`——不依賴任何未完成的文檔。`F006`(`Index` / `Row` 的擁有者)與 `F008`
(`Edit` / `Node` / `Write` / `Create` 的擁有者)都已 `done`,本次只動它們交付物的可見度與所在模組,
不動任何一條它們的 law。

可與其他任務平行:可以。本次只碰 `store/`,與 P2 的一次性匯出器、P3 的 `workspace` / `service`
設計都不重疊。唯一的排序要求是**要在 P3 重建 `service` 之前完成**——否則新寫的 `service` 會再一次
從還開著的門穿進去,那時要改的就是新程式碼而不是這份會被丟掉的舊碼。

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `vaultMarkdownFiles :: FilePath -> IO [FilePath]` | `store/src/Aapms/Store/Index.hs:85` | graph-core/F006 | 原樣搬進 `Walk`,簽名與行為不變 |
| `statOf :: FilePath -> IO (Either StoreError (Int64, Int64))` | `store/src/Aapms/Store/Index.hs:104` | graph-core/F006 | 原樣搬進 `Walk`,簽名與行為不變 |
| `data WriteResult = WriteResult { wrId :: Id, wrPath :: FilePath, wrRevision :: Revision, wrIssues :: [IndexIssue] }` | `store/src/Aapms/Store/Edit.hs:96-104` | graph-core/F008 契約 E | 不動;確認它仍經 `Write.hs:3` re-export 到門面(R2) |
| `data StoreError` | `store/src/Aapms/Store/Error.hs:29` | graph-core/F005 契約 G | `Walk.statOf` 的錯誤型別,沿用 |

## 骨架

本次屬「行為不變、對外簽名不動」,所以**既有程式碼一行未改**——`Edit` / `Node` / `Row` 的可見度、
`Index` 的匯出清單、test-suite 的 stanza 全部維持現狀,由 impl 動。骨架只新增一個檔,讓 qa 有
`Aapms.Store.Walk` 可以 import(否則 R3 / R4 寫不出來):

| 檔案 | 變動 |
|---|---|
| `store/src/Aapms/Store/Walk.hs` | **新檔**:兩個函式的簽名完整,本體 `undefined` |
| `store/aapms-store.cabal` | `Aapms.Store.Walk` 暫時加進 `exposed-modules`,讓現行 test-suite(仍依賴 `aapms-store` 套件)import 得到;**impl 要把它與另外三個一起移進 `other-modules`**(L1 / L2 就是在釘這一步) |

編譯檢查:`cabal build aapms-store` 通過,無警告(`[12 of 15] Compiling Aapms.Store.Walk`)。

**2026-08-27 更新(G20 裁決後)**:上表描述的是**第一版骨架**的狀態,已由 `/spec-build` 的
第一輪執行完畢——`Walk.hs` 兩個本體已填、四個模組已進 `other-modules`、test-suite stanza 已改、
`Index.hs` 匯出清單已清。本次 spec 修訂**不動任何簽名與行為**,只改兩處寫錯的文字:
`Walk.hs` 的 `statOf` haddock(補上 tuple 順序與奈秒理由)與上面「數據與介面變動」表的語意欄。

**給 qa 的紅綠預期(2026-08-27 修訂版,取代上一版)**:

- R1、R2、R5、R6:**全綠**(捕捉現況)
- R3、E3、E4、E5:**全綠**——`Walk.hs` 的本體已經填好了,不再是 `undefined`
- **R4 與新增的 E6:目前紅,修完就綠。** 紅的原因是上一版 spec 把 tuple 順序寫反,qa 據此
  斷言了第一個分量等於位元組數。正確順序是 **`(mtime, size)`**:請只對**第二個**分量斷言長度,
  第一個分量是奈秒時間戳。**這是本次修訂唯一要動的測試**,其餘斷言一律不得更動
- L1–L4:**全綠**(第一輪已完成那些 cabal 與匯出清單的變動)
- `IndexSpec.hs` 的 T3 已由第一輪的 qa 遷移到 `Aapms.Store.Walk`,無須再動

## 實作備註

**2026-08-27 spec 修訂(G20)—— `statOf` 的 tuple 順序寫反**

第一版 spec 的「數據與介面變動」語意欄與骨架 `Walk.hs` 的 `statOf` haddock 都寫
「回傳檔案的 **(size, mtime)**」,但實際順序是 **`(mtime, size)`**
(`pure (floor (utcTimeToPOSIXSeconds t * 1e9), fromIntegral s)`)。這讓 spec 自己前後矛盾:
語意欄說 `(size, mtime)`,R4 卻要求「與搬移前相同」而搬移前就是 `(mtime, size)`。
qa 照語意欄寫斷言 → 紅;impl 照 R4 逐字搬移 → 正確。兩邊都沒錯,錯的是 spec。

**裁決(2026-08-27,開發者)**:**改 spec 的文字,不動實作。** 實作、`Index.hs:129` 的
`Right (mtime, size)`、`:412` 的 `m/m'`、`s/s'` 比對、R4 四者本來就一致;過時偵測比的是兩個分量
的相等性,順序對它沒有語意差別。改實作等於為一句寫錯的文件去動一個正確運作的函式,
還會撞破 E001「行為不變」的 scope。

**這次改了什麼**:

| 位置 | 改動 |
|---|---|
| 「數據與介面變動」`statOf` 那一列的語意欄 | `(size, mtime)` → **`(mtime, size)`**,並寫明哪個分量是什麼;呼叫端行號同步更新為搬移後的 `Index.hs:127` / `:410` |
| R4 | 補上 tuple 順序的機械可判定子句(只對**第二**分量斷言長度) |
| Examples | 新增 **E6**,把順序釘成一個具體例子 |
| `Walk.hs` 的 `statOf` haddock | 補上順序、補回「mtime 取奈秒」的理由、並寫明「為什麼要把順序寫出來」 |

**為什麼一致性檢查沒攔下來(值得記住的教訓)**:`/enhance-design` 的一致性檢查比對的是
**簽名原文**,而 `(Int64, Int64)` 兩個分量同型別——順序寫反,型別檢查、簽名比對、呼叫端編譯
全部照過,只有一條真的去斷言「哪個分量是什麼」的測試抓得到。**同型別的 tuple 分量,順序必須
在語意欄與 law 裡寫成機械可判定的句子**,不能只寫一個 `(a, b)` 讓人自己對。

**另一件順帶修復的事**:搬移時 `statOf` 原本的 haddock
「過時偵測的兩個依據。mtime 取**奈秒**:同一秒內改兩次是測試與人手都做得到的事,秒級解析度會漏掉」
被第一版骨架的 haddock 取代掉了,那句理由一度只存在於 git history。已補回。
附帶一提,原本那句 haddock **從頭到尾沒有寫出順序**(只說「兩個依據」)——這正是第一版 spec
會寫反的原因:順序只存在於函式本體那一行,文件層從來沒有講過。現在講了。
