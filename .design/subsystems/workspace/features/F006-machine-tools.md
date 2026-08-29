---
id: F006
type: feature
title: machine-tools
description: "7-Zip 的三層探測([tools] 覆寫 → PATH → 內建候選清單)與 ToolStatus"
status: open
created: 2026-08-29
updated: 2026-08-29
depends-on: [F001]
related-adr: [ADR-017, ADR-020]
related-feature: []
---

# F006: 7-Zip 的三層探測與 ToolStatus(machine-tools)

## 功能概述

實作 `workspace` **本機環境管線**的 `detectSevenZip` 那一段:`[tools]` 覆寫 → `PATH` →
內建候選清單。負責模組是 design.md「內部模組劃分」的 **Tools**,只寫一個檔案
`workspace/src/Aapms/Workspace/Tools.hs`。

本 feature 是契約 E 的 `ToolOrigin` / `ToolStatus` 兩個型別的**第一個生產者**——這兩個型別已由
F001 一次寫齊在 `Aapms.Workspace.Types`,本 feature **一個字都不改**,也**不新增任何
`WorkspaceError` 建構子**(契約 E 沒有失敗通道,本 feature 一個錯誤建構子都不產生)。

**2026-08-29 W4 閘門裁決(本 spec 的 A1,裁決為選項 a)**:契約 E 增列
`ToolSearchPlan` 與 `detectSevenZipIn`,`detectSevenZip` 的原簽名一個字不動、變成薄包裝。
`ToolSearchPlan` 因此是本 feature **唯一新增的型別**,它住在 `Aapms.Workspace.Tools`
(不進 `Types.hs`——那個檔案在階段二已凍結)。

**驗收標準**(逐字抄自契約卡):

1. `tcSevenZip` 指向一個存在且可執行的檔案時,`tsPath` 等於它且 `tsOrigin == FromToolsConfig`,
   **PATH 與候選清單都不被查**(`tsSearched` 只有那一個) — 觀察點:契約 E 的 `detectSevenZip` /
   `ToolStatus`
2. `tcSevenZip` 指向不存在的檔案時**不中止**,繼續往 PATH 與候選清單找,而該路徑仍出現在
   `tsSearched` — 觀察點:契約 E 的 `tsSearched` / `tsOrigin`
3. 三層都找不到時 `tsPath == Nothing`、`tsOrigin == NotFound`、`tsSearched` 非空,而且函式
   **不回錯誤**(7-Zip 缺席不是失敗) — 觀察點:契約 E 的 `detectSevenZip`
4. `tsPath` 為 `Just` 恰好對應 `tsOrigin /= NotFound`(兩者不可能不一致) — 觀察點:契約 E 的
   `ToolStatus`
5. 不論結果如何都**不執行**找到的檔案(可用一個會寫出標記檔的假執行檔驗證:跑完後標記檔不存在)
   — 觀察點:契約 E 的 `detectSevenZip`

**明確不做**(逐字抄自契約卡):不查版本、不測試解壓能力(那是 `asset-ingest` 真的要用時的事);
不探測 LLM 端點的可達性(那是 `ai`——本子系統只捧著 `[llm]` 那張表);不把工具路徑寫回中樞。

追加三條由「明確不做」推出來的硬界線,全部寫成可機械驗證的條文:

- **不建立、不修改、不刪除任何檔案或目錄**,也不改任何檔案的權限(L11、L15(d))。
- **不啟動任何外部行程**(L11、L15(b))。
- **不讀中樞檔案**:`ToolsConfig` 是參數,由呼叫端(`service`)以 `hubTools` 取出後交進來;
  本模組不碰 `config.toml`、不碰任何 vault(L15(c))。

## 相依性

`depends-on: [F001]`——design.md「功能規劃」階段二表 #6 的「依賴」欄是 `#1`,查證後確實逐條用到
F001 交付的東西:`ToolsConfig` / `ToolOrigin` / `ToolStatus` 三個型別(以及讀 `tcSevenZip` 這個
欄位存取子)。**F002 / F003 / F004 / F005 一個符號都沒用到**——本模組不碰 vault、不碰中樞檔案。

跨子系統:**一個都不用**。本 feature 不 import `aapms-store` 的任何模組,也不 import
`aapms-core`——契約 E 的三個型別完全不涉及 `VaultId` / `Sha256` / `StoreError`。

**不需要新增任何套件依賴**:`aapms-workspace.cabal` 現有的 `base`(`System.Environment`)/
`directory`(`System.Directory`)/ `filepath`(`System.FilePath`)/ `text` 覆蓋本 feature 全部所需。
**特別是不需要 `process` / `typed-process`**——legacy 的 `Sidecar.hs` 需要它是因為它還負責**執行**
7-Zip,而本 feature **只探測不執行**。

## 對應的 Level 2 契約

### 契約 E(本 feature 負責的全部五項)

```haskell
data ToolOrigin = FromToolsConfig | FromPath | FromCandidate | NotFound
data ToolStatus = ToolStatus
  { tsName :: Text, tsPath :: Maybe FilePath, tsOrigin :: ToolOrigin, tsSearched :: [FilePath] }

detectSevenZip :: ToolsConfig -> IO ToolStatus

-- 2026-08-29 W4 閘門裁決(本 spec 的 A1)新增;detectSevenZip 的原簽名一個字不動
data ToolSearchPlan = ToolSearchPlan { tspPathDirs :: [FilePath], tspCandidates :: [FilePath] }
detectSevenZipIn :: ToolSearchPlan -> ToolsConfig -> IO ToolStatus
```

前兩個型別**已由 F001 宣告完畢**(`Types.hs:259-280`),本 feature 一個字都不改;後兩項是 W4
閘門補進契約 E 的,定義住 `Aapms.Workspace.Tools`。契約 E 的欄位值域(design.md 的表)逐條
落成 Laws:

| 欄位 | 契約原文的值域 | 落在哪一條 law |
|---|---|---|
| `tsName` | 固定字串,如 `"7-Zip"` | L13 |
| `tsPath` | 絕對路徑;`Nothing` ⟺ `tsOrigin == NotFound` | L5、L8 |
| `tsOrigin` | 這個路徑**哪裡來的** | L6 |
| `tsSearched` | 依序、去重;`NotFound` 時**必為非空** | L1、L4、L9 |

### 契約 B(本 feature 只使用,無新增)

```haskell
data ToolsConfig = ToolsConfig { tcSevenZip :: Maybe FilePath }
hubTools :: Hub -> ToolsConfig
```

`tcSevenZip` 的值域是「絕對路徑;`Nothing` = **沒有覆寫**(去探測),不是『沒有 7-Zip』」。
本 feature 對 `Nothing` 的處置就是「跳過第一層」;對 `Just p` 一律先探測 `p`,**不論 `p` 是否
真的是絕對路徑**——路徑合不合規是中樞的事(`loadHub` 的 `HubMalformed`),本層不再驗一次
(見 A5)。

**`hubTools` 由呼叫端呼叫,不在本模組**:design.md「模組間公開介面」有 `Tools → Hub:hubTools 取
ToolsConfig` 一列,那描述的是**資料流向**(Tools 讀的是 `ToolsConfig` 這個值),語意成立;但
契約 E 的 `detectSevenZip` 第一參數已經是 `ToolsConfig`,所以本模組**不 import `Hub`,
`ToolsConfig` 由呼叫端傳入**。骨架因此沒有 `import Aapms.Workspace.Hub`;L15(a) 仍**允許**它
出現(只放行 `hubTools` 一個名字),不把這條表列的邊禁掉。**2026-08-29 W4 閘門裁決:design.md
那一列不改**(要改是 `service` 設計時的事)。

## 實作方式

### 相依性查證(2026-08-29 在本機 GHC 9.14.1 / Windows 11 實測)

七點與文字描述不同、必須在實作與寫測試前知道的事實。前四點是本 spec 全部可攜性條文的根據。

1. **`getPermissions` 的 `executable` 在 Windows 上看副檔名,而且對目錄回 `False`。**
   實測(`directory-1.3.10.0`):`.exe` / `.bat` / `.cmd` / `.com` → `True`;`.txt` / 無副檔名 /
   `.ps1` / `.msi` → `False`;一個**名為 `dir.exe` 的目錄** → `executable == False`,而
   `doesFileExist` 對它本來就回 `False`。POSIX 上 `getPermissions` 回的是 `access` 的結果,
   `executable` 就是 x 位元。
   → 「可執行」的跨平台判準因此可以**委給 `directory`**,不必在 workspace 裡寫任何平台分支(A2)。
2. **`getPermissions` 對不存在的路徑會拋 `isDoesNotExistError`**(實測:
   `getPermissions "…/nope.exe"` → `Left … does not exist`)。契約 E **沒有失敗通道**,所以判準
   必須先 `doesFileExist` 再 `getPermissions`,順序不可調換(L7、L12)。
3. **`findExecutable` 在 Windows 上呼叫 Win32 的 `SearchPath`**(haddock 原文:「may search other
   places before checking the directories in the `PATH` environment variable. Where it actually
   searches depends on registry settings, but notably includes the directory containing the current
   executable」)。**它的搜尋範圍測試控制不了**,所以本 spec **不用它**,改自己走 `PATH`
   環境變數(A3)。`findExecutablesInDirectories` 的 haddock 明說它「does not use `SearchPath`」
   且行為等於 `findFileWith` + `exeExtension` + executable 權限測試——本 spec 的第二層就是
   照這個語意手動展開,差別只在**要把每個探測過的路徑記進 `tsSearched`**。
4. **這台開發機上 `C:\Program Files\7-Zip\7z.exe` 實際存在**(實測 `ls` 得到 `7z.exe`),而
   `findExecutable "7z"` 回 `Nothing`(7-Zip 沒進 PATH——正是 legacy `Sidecar.hs` 註解記下的
   那個實機教訓)。
   → **驗收標準第 3 條(三層都找不到)在這台機器上永遠觸發不到**,除非候選清單可以被替換掉。
   這是 A1(注入接縫)存在的唯一理由。
5. **`exeExtension` 在 Windows 是 `".exe"`、POSIX 是 `""`**;`"7z" <.> exeExtension` 在 Windows
   得到 `"7z.exe"`、在 POSIX 得到 `"7z"`。一條式子兩個平台都對,law 因此寫得出跨平台的版本(L10)。
6. **`normalise` / `makeAbsolute` 在 Windows 會把 `/` 換成 `\`**(實測
   `normalise "C:/Program Files/7-Zip/7z.exe" == "C:\\Program Files\\7-Zip\\7z.exe"`)。而
   system.md「對外介面」第 6 節的中樞範例寫的是 `seven_zip = "C:/Program Files/7-Zip/7z.exe"`
   ——**正斜線**。任何一種正規化都會讓驗收標準第 1 條的「`tsPath` 等於它」變成不成立(A5)。
7. **`loadHub` 已經擋下非絕對的 `seven_zip`**(`workspace/src/Aapms/Workspace/Hub.hs:183-191`):
   `parseToolsSection` 對 `[tools]` 的 `seven_zip` 逐項檢查——不是表回 `HubMalformed`、不是字串回
   `HubMalformed`、**`isAbsolute` 為假回 `HubMalformed fp "鍵 seven_zip 必須是絕對路徑,收到 …"`**。
   → 「`tcSevenZip` 是絕對路徑」這個事實**已經有人守**,本模組不重複驗一次(A5 的前提,已查證)。
8. **本機的 `PATH` 有 45 個目錄**(實測),`PATHEXT` 是
   `.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.CPL`(12 個)。
   → `tsSearched` 的長度直接由第二層的展開方式決定:只試 `exeExtension` 一種是 45 × 2 = **90 條**,
   展開整份 `PATHEXT` 是 45 × 2 × 12 = **1080 條**(A3、A4)。

程式碼知識圖(knot,`codegraph.json` 已是 HEAD `27d2499` 的快照,未重跑 extract)另外確認三件事:

- `knot query find findExecutable` → **0 nodes**:aapms 產品碼裡目前沒有任何一處用 `findExecutable`,
  不用它不會與既有慣例衝突。
- `knot query reachable "Aapms.Workspace.Types.ToolStatus#t" --reverse --depth 2` → 只回
  `Aapms.Workspace.Types` 與三個同套件模組的**包含邊**,**沒有任何消費者**:本 feature 是
  `ToolStatus` 的第一個生產者,改它的產生方式不會波及任何既有呼叫點。
- `knot query find hubTools` → 唯一定義在 `Aapms.Workspace.Types.hubTools`(`Hub` 的欄位存取子),
  由 `Aapms.Workspace.Hub` 轉出。本模組**不需要**它(見上一節)。

### 「存在且可執行」在本 spec 全篇的定義

> **合格(qualifies)= `doesFileExist p` 為 `True` **且** `executable <$> getPermissions p`
> 為 `True`,兩步依此順序。**

平台差異**整條委給 `directory`**:Windows 上這等於「是一個檔案,且副檔名屬 `.exe` / `.bat` /
`.cmd` / `.com`」;POSIX 上等於「是一個檔案(或指向檔案的 symlink),且 `access(X_OK)` 為真」。
本模組**不自己判副檔名、不讀 ACL、不呼叫任何 Win32 API**——那會把平台知識複製一份到 workspace,
而且 Windows 的 ACL 判定需要新增套件依賴(選項見 A2)。

先 `doesFileExist` 的理由是查證事實 2:`getPermissions` 對不存在的路徑會拋例外,而契約 E 沒有
失敗通道。順序不可調換。

### 三層探測的資料流

```text
detectSevenZip cfg
  → dirs = maybe [] splitSearchPath <$> lookupEnv "PATH"    -- 未設 = 空清單,不是失敗
  → detectSevenZipIn (ToolSearchPlan dirs sevenZipCandidates) cfg

detectSevenZipIn plan cfg
  → 組出三層的候選檔案路徑,依序串起來:
      L1 = maybe [] (: []) (tcSevenZip cfg)                             -- 覆寫
      L2 = [ d </> (n <.> exeExtension)                                 -- PATH
           | n <- ["7z", "7zz"], d <- tspPathDirs plan ]                --   名稱外層、目錄內層
      L3 = tspCandidates plan                                           -- 內建候選清單
      probes = 保序去重 (L1 ++ L2 ++ L3)
  → 依序對 probes 的每一項 p 問「合格?」
       第一個合格的 p → tsPath    = Just p
                        tsOrigin  = p 在去重後**最早**出現的那一層(L1→FromToolsConfig /
                                    L2→FromPath / L3→FromCandidate)
                        tsSearched = probes 中從頭到 p(含 p)的那一段前綴
       全部都不合格   → tsPath = Nothing, tsOrigin = NotFound, tsSearched = probes(全部)
  → tsName = "7-Zip"
  -- 全程只呼叫 doesFileExist / getPermissions;不建檔、不改權限、不啟動任何行程
```

三件事值得單獨講清楚:

- **命中即停**是驗收標準第 1 條的全部內容:覆寫合格時 `probes` 的探測在第一項就結束,
  `tsSearched == [那一項]`,第二、三層**連組都不必組**(組不組是實作自由,但**不得被問**——
  L2 用「把 plan 的兩個清單換成任何值,結果逐欄不變」來驗這件事,不依賴任何內部觀察)。
- **保序去重跨層生效**:同一個路徑在多層出現(例如使用者的 `[tools]` 覆寫剛好就是
  `C:\Program Files\7-Zip\7z.exe`)時只探測一次,`tsOrigin` 取**最早**的那一層。這讓
  「`tsSearched` 依序、去重」(契約 E 的值域)與「`tsPath` 是 `tsSearched` 的最後一項」同時成立。
- **`tsSearched` 是前綴,不是全部**。契約 E 只規定「找過哪些地方」與「`NotFound` 時必為非空」;
  把沒問過的路徑也列進去會讓使用者去檢查一個工具根本沒看過的位置,而驗收標準第 1 條
  (「`tsSearched` 只有那一個」)已經把「只列問過的」釘死了。

### 與 legacy `Sidecar.hs` 的三處刻意不同

移植參考是 `legacy/assetdb/archive/src/AssetDB/Archive/Sidecar.hs` 的 `sevenZipCandidates` /
`findSevenZip`。**參考不是契約**,以下三處依 design.md 契約 E 走:

| 項目 | legacy | 本 feature | 依據 |
|---|---|---|---|
| PATH 上的查詢名稱 | `["7z", "7zz", "7za"]` | `["7z", "7zz"]`(**不含 `7za`**) | design.md 契約 E:「PATH 上的 `7z` / `7zz`」 |
| 順序 | **先 PATH 再候選**,沒有設定覆寫這一層 | **覆寫 → PATH → 候選**三層 | design.md 契約 E:「探測順序固定三層」 |
| 候選清單的判準 | 只 `doesFileExist` | `doesFileExist` **且** `executable` | design.md 契約 E:「判準只有『檔案存在且可執行』」 |

候選清單的**內容與順序**逐字沿用 legacy(design.md 契約 E:「沿用 legacy assetdb 的清單」),
見「數據」。

## 使用到的既有串接介面

行號是**建檔當下**的導航線索;一致性檢查一律比對**簽名原文**。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data ToolsConfig = ToolsConfig { tcSevenZip :: Maybe FilePath }` | `workspace/src/Aapms/Workspace/Types.hs:153-157` | F001 | `detectSevenZip` 的參數;第一層的來源 |
| `data ToolOrigin = FromToolsConfig \| FromPath \| FromCandidate \| NotFound` | `workspace/src/Aapms/Workspace/Types.hs:259-268` | F001 | `tsOrigin` 的四個值,本 feature 全部產生得到 |
| `data ToolStatus = ToolStatus { tsName :: Text, tsPath :: Maybe FilePath, tsOrigin :: ToolOrigin, tsSearched :: [FilePath] }` | `workspace/src/Aapms/Workspace/Types.hs:271-280` | F001 | 本 feature 的唯一產出型別 |
| `hubTools :: Hub -> ToolsConfig` | `workspace/src/Aapms/Workspace/Types.hs:99`(定義)、`Hub.hs:22`(轉出) | F001 | **本 feature 不呼叫**;由 `service` 取出後把 `ToolsConfig` 交進來 |
| `doesFileExist :: FilePath -> IO Bool` | `directory` 的 `System.Directory` | - | 判準第一步;對目錄回 `False` |
| `getPermissions :: FilePath -> IO Permissions` | `directory` 的 `System.Directory` | - | 判準第二步;**對不存在的路徑會拋例外**,所以第一步不可省 |
| `executable :: Permissions -> Bool` | `directory` 的 `System.Directory` | - | Windows 看副檔名、POSIX 看 x 位元;平台差異委給它 |
| `splitSearchPath :: String -> [FilePath]` | `filepath` 的 `System.FilePath` | - | 把 `PATH` 切成目錄清單(平台分隔符由它處理) |
| `exeExtension :: String` | `filepath` 的 `System.FilePath` | - | Windows `".exe"` / POSIX `""`;第二層的副檔名 |
| `(<.>) :: FilePath -> String -> FilePath`、`(</>) :: FilePath -> FilePath -> FilePath` | `filepath` 的 `System.FilePath` | - | 拼出 `d </> ("7z" <.> exeExtension)` |
| `lookupEnv :: String -> IO (Maybe String)` | `base` 的 `System.Environment` | - | 讀 `PATH`;**用 `lookupEnv` 不用 `getEnv`**——後者在變數未設時拋例外,而契約 E 沒有失敗通道 |

## 新增的介面

三條都在 `workspace/src/Aapms/Workspace/Tools.hs`(本 feature 唯一寫入的 `.hs`),
**三條都在契約 E 內**(後兩條由 2026-08-29 W4 閘門補進契約,見 A1 的裁決欄)。

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `detectSevenZip :: ToolsConfig -> IO ToolStatus` | 契約 E 原文,簽名一個字不動。以真實的 `PATH` 目錄清單與內建候選清單組成 plan,轉呼叫 `detectSevenZipIn` 的**薄包裝** | `workspace/src/Aapms/Workspace/Tools.hs:68` |
| `data ToolSearchPlan = ToolSearchPlan { tspPathDirs :: [FilePath], tspCandidates :: [FilePath] }` | 三層裡「來自環境」的那兩層的來源。W4 閘門納入契約 E | `workspace/src/Aapms/Workspace/Tools.hs:49-57` |
| `detectSevenZipIn :: ToolSearchPlan -> ToolsConfig -> IO ToolStatus` | 把那兩層的來源變成**明碼參數**:給定兩份清單,依序探測。**確定性**——同樣的 plan、同樣的檔案系統就是同樣的結果。W4 閘門納入契約 E | `workspace/src/Aapms/Workspace/Tools.hs:81` |

**這不是測試後門,是「把隱含參數變明碼、原函式變薄包裝」這個既有模式的第三次套用**:
先例是 graph-core 的 `allocateId`(2026-08-25 G8 裁決),同一波的 F005 也依同一個判準把
`allocateProjectId` 提進契約。三者的共同形狀是——原簽名一字不動、新入口只描述**環境事實的
來源**(時間 / 亂數種子 / `PATH` 與候選清單),不洩漏任何內部演算法,而且兩個入口的一致性
由一條 law 釘住(本 feature 是 L14)。

模組匯出清單只有這三個名字;`ToolOrigin` / `ToolStatus` / `ToolsConfig` 一律讓消費端從
`Aapms.Workspace.Types` 取,本模組**不轉出**任何 F001 的型別(與 Discovery / Scope 同一個做法)。

**內建候選清單與 PATH 查詢名稱不匯出**:它們是「數據」段逐字寫死的常數,測試要斷言的是
**spec 寫的那七條**而不是實作剛好放了什麼——把常數匯出讓測試拿去比,會讓「impl 改了清單」
這種漂移變成恆真斷言,測不出來。

## 數據

本 feature **不新增、不修改、不刪除任何 F001 的型別**;新增的 `ToolSearchPlan` 只住在本模組。

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `ToolOrigin` | 沿用(F001 宣告) | 四個建構子 | 「這個路徑哪裡來的」 |
| `ToolStatus` | 沿用(F001 宣告) | 四個欄位 | 「一個外部工具的探測結果」 |
| `ToolsConfig` | 沿用(F001 宣告) | `{ tcSevenZip :: Maybe FilePath }` | 「使用者覆寫了什麼」(擁有者是 Hub,不是 Tools) |
| `ToolSearchPlan` | **新增**(W4 閘門納入契約 E;定義住 `Aapms.Workspace.Tools`,**不進已凍結的 `Types.hs`**) | `{ tspPathDirs :: [FilePath], tspCandidates :: [FilePath] }` | 「這一次探測要掃哪些目錄、要試哪些固定路徑」 |

### `tsName` 的值

**逐字 `"7-Zip"`**,取自 design.md 契約 E 欄位表的 `tsName` 那一列(「固定字串,如 `"7-Zip"`」)。
不論結果如何都是這個字串,`NotFound` 時也一樣(L13)。

### 內建候選清單(`sevenZipCandidates`,私有常數)

逐字沿用 legacy `Sidecar.hs:42-51`,**順序不變、不隨平台過濾**:

```haskell
[ "C:\\Program Files\\7-Zip\\7z.exe"
, "C:\\Program Files (x86)\\7-Zip\\7z.exe"
, "/usr/bin/7z"
, "/usr/local/bin/7z"
, "/opt/homebrew/bin/7z"
, "/usr/bin/7zz"
, "/opt/homebrew/bin/7zz"
]
```

**不分平台**的理由:清單是一份「已知安裝位置」的常數,在 Windows 上探測 `/usr/bin/7z` 只是多
兩次必定失敗的 `doesFileExist`(它不會拋例外),換來的是 `tsSearched` 在兩個平台上**逐項相同**
——law 因此寫得出跨平台的版本,而不是兩套。這也是「沿用 legacy 的清單」的字面意思:legacy 那份
本來就是一份無條件清單。

### PATH 層的查詢名稱與副檔名

- 名稱:`["7z", "7zz"]`,**依此順序**,不含 legacy 的 `"7za"`(契約 E 只列了兩個)。
- 副檔名:**只試 `exeExtension` 一種**(Windows `".exe"`、POSIX `""`),不展開 `PATHEXT`(A3)。
- 展開順序:**名稱外層、目錄內層**——先用 `7z` 掃過 `tspPathDirs` 的每一個目錄,再用 `7zz` 掃一遍
  (沿用 legacy `findSevenZip` 的 `firstJustM findExecutable ["7z", "7zz", "7za"]`)。意思是
  「`7z` 不論在 PATH 的哪一格,都贏過任何位置的 `7zz`」(A4)。

### 測試素材:造得出「合格 / 不合格」檔案的可攜作法

**這一段是本 feature 可攜性的全部依據**,兩個平台各只有一行差別,而**斷言完全相同**。

| 要造的東西 | 可攜作法 | 為什麼在兩個平台都成立 |
|---|---|---|
| **合格**的假 7-Zip(PATH 層) | 在目錄 `d` 下寫出檔案 `d </> ("7z" <.> exeExtension)`,再 `setPermissions p (setOwnerExecutable True perms)` | Windows:`.exe` 副檔名即 `executable == True`,`setPermissions` 對它是無效操作(haddock:Windows 上只改得動 read-only 屬性),不影響結果。POSIX:`exeExtension == ""` 所以檔名就是 `7z`,x 位元由 `setOwnerExecutable` 給 |
| **合格**的假 7-Zip(覆寫層 / 候選層) | 同上,但檔名可以是任何 `name <.> exeExtension` | 同上 |
| **不合格**但**存在**的檔案 | 寫出 `d </> "seven.txt"`,**不**設任何執行權限 | Windows:`.txt` → `executable == False`(實測)。POSIX:新建檔案預設沒有 x 位元 |
| **不存在**的路徑 | `d </> "nope.exe"`(不建立) | `doesFileExist` 回 `False`,判準在第一步就結束,`getPermissions` 不會被呼叫、不會拋例外 |
| 名字像執行檔的**目錄** | `createDirectory (d </> ("bogus" <.> exeExtension))` | `doesFileExist` 對目錄回 `False`(實測);Windows 上 `getPermissions` 對它也回 `executable == False` |
| **會留下痕跡的**假執行檔(驗收標準第 5 條) | 造一個「若被執行就會建立 `d </> "RAN"`」的腳本檔,檔名用 `d </> ("7z" <.> exeExtension)`(Windows 亦可用 `.bat` / `.cmd`,實測兩者的 `executable` 都是 `True`) | 斷言是**否定的**——跑完 `d </> "RAN"` 不存在。這條斷言不要求那個檔案真的跑得起來,只要求它**沒有被跑**,所以兩個平台的 fixture 差異不影響結論 |

**`Hub` 完全不需要**:`detectSevenZip` 吃的是 `ToolsConfig`,測試直接 `ToolsConfig (Just p)` /
`ToolsConfig Nothing` 造得出來,不必經 `mkHub`。

## Laws

以下 `qualifies p` 一律指「實作方式 › 『存在且可執行』」定義的判準;`probes plan cfg` 一律指
「三層探測的資料流」定義的那串保序去重後的候選路徑。

### 三層順序與短路

- **L1(`tsSearched` 是 `probes` 的前綴,命中的那一項在最後)**:對任意 `plan`、任意 `cfg`,
  令 `ps = probes plan cfg`。若 `tsPath == Just p`,則:(a) `p` 是 `ps` 中**第一個**滿足
  `qualifies` 的元素;(b) `tsSearched` 逐項等於 `ps` 從頭到 `p`(含 `p`)的前綴;
  (c) `last tsSearched == p`。
- **L2(覆寫合格時後兩層完全不參與)**:若 `tcSevenZip cfg == Just p` 且 `qualifies p`,則
  `detectSevenZipIn plan cfg` 逐欄等於 `ToolStatus "7-Zip" (Just p) FromToolsConfig [p]`,
  **且與 `plan` 無關**——把 `tspPathDirs` 與 `tspCandidates` 換成任意兩份清單(含空清單、含
  裡面全是合格檔案的清單),結果逐欄不變。
- **L3(覆寫不合格時不中止)**:若 `tcSevenZip cfg == Just p` 而 `not (qualifies p)`,則
  `head tsSearched == p` 且 `tsOrigin /= FromToolsConfig`;而且當 `p` 不等於 `tspPathDirs` /
  `tspCandidates` 展開出來的任何一項時,結果與 `cfg' = ToolsConfig Nothing` 的結果**除了
  `tsSearched` 多了開頭的 `p` 之外逐欄相同**(`tsPath` / `tsOrigin` / `tsName` 三欄一模一樣)。
- **L4(三層都不合格 ⟺ `NotFound`)**:`ps` 中沒有任何一項滿足 `qualifies`,當且僅當
  `tsPath == Nothing` 且 `tsOrigin == NotFound`;此時 `tsSearched` 逐項等於**完整的** `ps`。
  對 `detectSevenZip`(內建候選清單非空,見「數據」)這種情況下 `tsSearched` **必為非空**。
- **L5(`tsPath` 與 `tsOrigin` 不可能不一致)**:對任意 `plan`、`cfg`,
  `tsPath == Nothing` ⟺ `tsOrigin == NotFound`。不存在 `Just _` 配 `NotFound`,也不存在
  `Nothing` 配其他三個建構子中的任何一個。
- **L6(`tsOrigin` 指得出那一項是哪一層來的)**:令 `p` 是 `tsPath` 的內容(`Just` 時)——
  (a) `tsOrigin == FromToolsConfig` ⟺ `tcSevenZip cfg == Just p`;
  (b) `tsOrigin == FromPath` ⟹ 存在 `d ∈ tspPathDirs plan` 與 `n ∈ ["7z", "7zz"]` 使
  `p == d </> (n <.> exeExtension)`,且 `tcSevenZip cfg /= Just p`;
  (c) `tsOrigin == FromCandidate` ⟹ `p ∈ tspCandidates plan`,且 `p` 既不等於
  `tcSevenZip cfg` 的內容、也不等於 (b) 那組展開的任何一項。
  三者互斥,且判定順序恒為 (a) → (b) → (c)。

### 判準

- **L7(合格 = 存在且可執行,依此順序)**:一個路徑 `p` 被算成命中,當且僅當
  `doesFileExist p` 為 `True` **且** `executable <$> getPermissions p` 為 `True`。因此:
  (a) 不存在的路徑不命中;(b) 存在但 `executable` 為假的檔案不命中;(c) **目錄不命中**,
  即使它的名字以 `exeExtension` 結尾;(d) 判定過程對「不存在的路徑」**不得拋例外**——
  `doesFileExist` 為假時 `getPermissions` 不被呼叫。
- **L8(逐字,不做任何正規化)**:`tsPath` 與 `tsSearched` 的每一項都與它的來源**逐字相同**:
  第一層的那一項逐字等於 `tcSevenZip cfg` 的內容;第三層的每一項逐字等於 `tspCandidates` 的
  對應項;第二層的每一項恰好是 `d </> (n <.> exeExtension)` 的結果。特別是**不呼叫**
  `canonicalizePath` / `makeAbsolute` / `normalise`——正斜線不會變反斜線、相對路徑不會被
  絕對化、symlink 不會被解開。
- **L9(依序、去重,且去重跨層)**:`tsSearched` 沒有重複元素;若同一個路徑在多層出現,它只在
  **最早**出現的位置留下一項,`tsOrigin` 依那一次所屬的層決定(L6)。`tsSearched` 的順序恒為
  `probes` 的順序,不重排、不排序。
- **L10(第二層的展開式,兩個平台同一條)**:給定 `tspPathDirs plan == [d1, …, dn]`,`probes` 的
  第二段逐項等於
  `[d1 </> ("7z" <.> exeExtension), …, dn </> ("7z" <.> exeExtension), d1 </> ("7zz" <.> exeExtension), …, dn </> ("7zz" <.> exeExtension)]`
  ——**名稱外層、目錄內層**。名稱只有 `"7z"` 與 `"7zz"` 兩個(**沒有 `"7za"`**);副檔名只有
  `exeExtension` 一種(**不展開 `PATHEXT`**,所以 Windows 上 `PATH` 裡的 `7z.cmd` / `7z.bat`
  不會被這一層找到)。`tspPathDirs` 為空時這一段為空。

### 不執行、不動檔案系統、無失敗通道

- **L11(不執行、不動檔案系統)**:對任意 `plan`、`cfg`,呼叫前後 `tsSearched` 涉及的每一個
  目錄(以及它們的子樹)的檔案清單、檔案內容與檔案權限**逐位元組 / 逐欄相同**。特別是:
  (a) 不建立任何檔案或目錄(連 `PATH` 裡不存在的目錄都不會被建出來);(b) 不刪除、不改寫任何
  檔案;(c) 不呼叫 `setPermissions`;(d) **不啟動任何外部行程**——一個內容會在被執行時建立
  `RAN` 標記檔的假執行檔,在 `detectSevenZipIn` 跑完之後,那個標記檔**不存在**。
- **L12(沒有失敗通道)**:對任意 `plan`、任意 `cfg`、任意檔案系統狀態,`detectSevenZipIn` 都
  回得出一個 `ToolStatus`,**不拋 IO 例外**。特別是:`tcSevenZip` 指向不存在的路徑、指向一個
  不存在的目錄底下的檔案、`tspPathDirs` 含不存在的目錄或空字串、`tspCandidates` 含不存在的
  路徑,全部都只是「這一項不合格」。而 `detectSevenZip` 在 `PATH` 環境變數**未設**時,
  第二層視為空清單(等價於 `tspPathDirs == []`),同樣不失敗。
- **L13(`tsName` 恒為 `"7-Zip"`)**:對任意 `plan`、`cfg`,`tsName == "7-Zip"`,`NotFound` 時
  也一樣。
- **L14(兩個入口一致)**:令 `dirs = maybe [] splitSearchPath` 施用於 `lookupEnv "PATH"` 的結果、
  `cands` 是「數據」段逐字列出的那七條。對任意 `cfg`,`detectSevenZip cfg` 逐欄等於
  `detectSevenZipIn (ToolSearchPlan dirs cands) cfg`。

### 依賴方向與職責界線

- **L15(以 import 行驗證;**比對前先去除行尾 `\r`**)**:專案的 `.gitattributes` 讓 `.hs` 在
  checkout 時轉 CRLF,逐字比對前必須先把行尾的 `\r` 去掉。`Tools.hs` 的 **import 行**滿足:
  - (a) 本套件內**只允許**出現 `import Aapms.Workspace.Types …` 與(可選的)
    `import Aapms.Workspace.Hub …` 兩種;**不得**有任何
    `import Aapms.Workspace.Location` / `Aapms.Workspace.Discovery` / `Aapms.Workspace.Scope` /
    `Aapms.Workspace.Lifecycle` / `Aapms.Workspace.Projects` 的行。若那行
    `import Aapms.Workspace.Hub` 存在,它的匯入清單必須是 `{hubTools}` 的**子集合**——
    Tools 不讀中樞檔案格式,`loadHub` / `saveHub` / `upsertVault` 之類一個都不准進來。
  - (b) **完全不得** import `System.Process`、`System.Process.Typed`、`System.Posix.Process`
    或任何名稱以 `System.Process` 開頭的模組——**不執行找到的檔案**(驗收標準第 5 條)。
  - (c) **完全不得** import 任何 `Aapms.Store.*` 或 `Aapms.Core.*` 模組——本 feature 不碰
    vault、不碰 marker、不碰索引、不寫任何檔案,契約 E 的三個型別也不涉及它們的任何型別。
  - (d) **若**有 `import System.Directory` 的行,它的匯入清單必須是
    `{doesFileExist, executable, getPermissions}` 的**子集合**。這條守的是「**只問不動**」:
    清單一旦長出 `createDirectory` / `createDirectoryIfMissing` / `removeFile` /
    `removeDirectory*` / `renameFile` / `copyFile` / `setPermissions` / `canonicalizePath` /
    `makeAbsolute` / `findExecutable` / `findExecutables*` 任何一個,或被放寬成無清單的
    `import System.Directory`,這條就紅——L8(不正規化)、L11(不動檔案系統)與 A3
    (不用 `SearchPath`)因此守得住,而不是只寫在 Haddock 裡。
  - (e) **若**有 `import System.Environment` 的行,它的匯入清單必須是 `{lookupEnv}` 的
    **子集合**——`getEnv` 在變數未設時拋例外(違反 L12),`setEnv` / `getArgs` /
    `getExecutablePath` 都不屬於本 feature。
  - (f) **若**有 `import System.FilePath` 的行,它的匯入清單必須是
    `{(</>), (<.>), exeExtension, splitSearchPath}` 的**子集合**。

  **判準只看 import 行,不做全檔字串搜尋**:本檔的 Haddock 本來就會提到 `findExecutable` /
  `SearchPath` / `canonicalizePath` / `asset-ingest` 這些名字來說明界線,全檔搜尋會把「文件
  寫得清楚」誤判成「越界」。

> **紅綠預期**(`spec-roles.md`「qa 的交付判準」逐條判定,**不是整批全紅**):
>
> - **預期綠**:**L15 的六條子斷言 (a)–(f) 全部**。它們驗的是骨架原文自身就承載的事實
>   (本檔的 import 行),不經過任何 `undefined`。**從第一天就綠,而且應該綠;不得因為它綠
>   就退回重寫。** 其中 (d)(e)(f) 是條件式:骨架階段本檔只有一行
>   `import Aapms.Workspace.Types (ToolStatus, ToolsConfig)`,三個條件都為假即通過;impl 補上
>   之後,那三行的匯入清單必須落在各自的子集合內才算通過。
> - **預期綠**:凡是只斷言 `ToolSearchPlan` 這個型別**存在、有那兩個欄位**的測試(骨架原文
>   自身承載的事實),例如 `tspPathDirs (ToolSearchPlan ["a"] ["b"]) == ["a"]`。
> - **預期紅**:其餘每一條 law 與每一個 example——`detectSevenZip` 與 `detectSevenZipIn`
>   的本體都是 `undefined`。
>
> 骨架裡**沒有**任何不是 `undefined` 的函數本體。

## Examples

以下 `T` 是一個新建的空暫存目錄;`exe n` 表示「在指定目錄下造出檔名為 `n <.> exeExtension`
的**合格**檔案」(作法見「數據 › 測試素材」);`plan a b` 是 `ToolSearchPlan a b`。

| # | 輸入 | 預期 | 覆蓋的 law |
|---|---|---|---|
| X1 | `E1 = T` 下的合格檔 `seven <.> exeExtension`;`D` 下有合格的 `7z <.> exeExtension`;`C` 是合格的候選檔。`detectSevenZipIn (plan [D] [C]) (ToolsConfig (Just E1))` | `ToolStatus "7-Zip" (Just E1) FromToolsConfig [E1]` | L1, L2, L5, L6(a), L13 |
| X2 | 同 X1,但 plan 換成 `plan [] []` | 與 X1 **逐欄相同** | L2 |
| X3 | `P = T </> "nope.exe"`(**不建立**);`D` 下有合格的 `7z <.> exeExtension`(記為 `S`)。`detectSevenZipIn (plan [D] []) (ToolsConfig (Just P))` | `ToolStatus "7-Zip" (Just S) FromPath [P, S]`——覆寫不合格不中止,`P` 仍在 `tsSearched` | L1, L3, L6(b), L7(a) |
| X4 | `D1` 空、`D2` 下有合格的 `7z <.> exeExtension`(記為 `S2`)。`detectSevenZipIn (plan [D1, D2] []) (ToolsConfig Nothing)` | `tsPath == Just S2`、`tsOrigin == FromPath`、`tsSearched == [D1 </> "7z…", D2 </> "7z…"]` | L1, L6(b), L10 |
| X5 | `D1` 下有合格的 `7zz <.> exeExtension`、`D2` 下有合格的 `7z <.> exeExtension`。`detectSevenZipIn (plan [D1, D2] []) (ToolsConfig Nothing)` | 命中的是 **`D2` 的 `7z`**(名稱外層):`tsSearched == [D1 </> "7z…", D2 </> "7z…"]`,`D1` 的 `7zz` **沒有**進 `tsSearched` | L1, L10 |
| X6 | `D` 下沒有任何合格檔;候選清單 `[C1, C2]`,`C1` 不存在、`C2` 是合格檔。`detectSevenZipIn (plan [D] [C1, C2]) (ToolsConfig Nothing)` | `tsOrigin == FromCandidate`、`tsPath == Just C2`、`tsSearched == [D </> "7z…", D </> "7zz…", C1, C2]` | L1, L6(c), L10 |
| X7 | `D` 下沒有任何合格檔;候選清單 `[C1]`,`C1` 不存在。`detectSevenZipIn (plan [D] [C1]) (ToolsConfig Nothing)` | `ToolStatus "7-Zip" Nothing NotFound [D </> "7z…", D </> "7zz…", C1]`——**非空**,而且**沒有拋例外** | L4, L5, L12, L13 |
| X8 | `B = T </> ("bogus" <.> exeExtension)` 是一個**目錄**;`detectSevenZipIn (plan [] [B]) (ToolsConfig (Just B))` | `tsPath == Nothing`、`tsOrigin == NotFound`、`tsSearched == [B]`(去重後只有一項) | L7(c), L9 |
| X9 | `N = T </> "seven.txt"`(存在,未設執行權限);`detectSevenZipIn (plan [] [N]) (ToolsConfig (Just N))` | `tsPath == Nothing`、`tsOrigin == NotFound`、`tsSearched == [N]` | L7(b), L9 |
| X10 | `C1` 不存在;`detectSevenZipIn (plan [] [C1, C1]) (ToolsConfig (Just C1))` | `tsSearched == [C1]`——三層都提到同一個路徑,只留一項 | L9 |
| X11 | `X = T </> "gone"`(不存在的目錄);`detectSevenZipIn (plan [X] [T </> "also-gone.exe"]) (ToolsConfig Nothing)` | 回 `ToolStatus`,不拋例外;`tsSearched == [X </> "7z…", X </> "7zz…", T </> "also-gone.exe"]`;呼叫後 `X` **仍然不存在** | L11(a), L12 |
| X12 | `R = D </> ("7z" <.> exeExtension)` 是一個「被執行就會建立 `D </> "RAN"`」的合格檔;`detectSevenZipIn (plan [D] []) (ToolsConfig Nothing)` | `tsOrigin == FromPath`、`tsPath == Just R`,而 `D </> "RAN"` **不存在**;呼叫前後對 `T` 遞迴列出的檔案清單與內容完全相同 | L11 |
| X13 | `detectSevenZipIn (plan [] ["relative/7z.exe"]) (ToolsConfig (Just "sub dir/7z.exe"))` | `tsSearched == ["sub dir/7z.exe", "relative/7z.exe"]`——**逐字**,正斜線沒有變成反斜線、沒有被絕對化 | L8 |
| X14 | `detectSevenZipIn (plan [] ["C:\\Program Files\\7-Zip\\7z.exe"]) (ToolsConfig Nothing)` | `tsSearched` 的那一項逐字等於 `"C:\\Program Files\\7-Zip\\7z.exe"`,**不論平台** | L8 |
| X15 | `cfg = ToolsConfig Nothing`;取 `dirs = maybe [] splitSearchPath` 對 `lookupEnv "PATH"` 的結果、`cands` = 「數據」段的七條;比較 `detectSevenZip cfg` 與 `detectSevenZipIn (ToolSearchPlan dirs cands) cfg` | 兩者**逐欄相同**(不需要改動任何環境變數) | L14 |
| X16 | `E = T` 下的合格檔;`detectSevenZip (ToolsConfig (Just E))` | `ToolStatus "7-Zip" (Just E) FromToolsConfig [E]`——真實入口在覆寫合格時同樣不看 `PATH` 與候選清單 | L2, L14 |
| X17 | 讀 `workspace/src/Aapms/Workspace/Tools.hs` 的 import 行(**先去除行尾 `\r`**) | 滿足 L15 的 (a)–(f) 六條 | L15 |

## 依賴方向

- **依賴誰**:`Aapms.Workspace.Types`(`ToolsConfig` / `ToolOrigin` / `ToolStatus`)、
  `directory`(`System.Directory`)、`filepath`(`System.FilePath`)、`base`
  (`System.Environment`)、`text`(`tsName` 的 `Text` 字面值,由 `OverloadedStrings` 供給)。
  **不依賴 `aapms-store`、不依賴 `aapms-core`、不依賴本套件的其他六個模組。**
- **誰會依賴它**:`service`(組 `doctor` 報告)、以及日後真的要用 7-Zip 的 `asset-ingest`。
  兩者都尚未存在;knot 反向可達確認 `ToolStatus` 目前**沒有任何消費者**。
- **新增的依賴邊**(一條都不能漏):
  - `Aapms.Workspace.Tools → Aapms.Workspace.Types`(新)
  - `Aapms.Workspace.Tools → System.Directory` / `System.FilePath` / `System.Environment`
    (新;impl 填本體時出現)
  - **不新增** `Aapms.Workspace.Tools → Aapms.Workspace.Hub`:**本模組不 import `Hub`,
    `ToolsConfig` 由呼叫端傳入**。design.md「模組間公開介面」的 `Tools → Hub:hubTools 取
    ToolsConfig` 那一列描述的是**資料流向**(Tools 讀的是 `ToolsConfig` 這個值),語意成立;
    履行它的是呼叫端(`service`),不是本模組的 import 行。**2026-08-29 W4 閘門裁決:該列
    不改**(要改是 `service` 設計時的事;現在動會讓 W4 的三份 spec 對不上同一張表)。
    L15(a) 仍放行這條邊,只是骨架不建立它。
  - **套件層級不新增任何依賴邊**:`.cabal` 的 `build-depends` 一行不用動
    (`base` / `directory` / `filepath` / `text` 都已列在裡面)。
- **可否與其他進行中任務平行開發**:可以與 F004(vault-lifecycle)、F005(project-registry)
  平行——三者的寫入白名單各是一個不同的 `.hs`,共同讀的 `Types.hs` 只讀不寫。本 feature 甚至
  沒有讀 `Hub.hs` / `Discovery.hs`,耦合面比另外兩個更小。

## 不可逆決定

| 決定 | 被否決的替代方案與否決理由 |
|---|---|
**(2026-08-29 W4 閘門裁決)** `detectSevenZipIn` / `ToolSearchPlan` **納入契約 E**,`detectSevenZip` 的原簽名一字不動、變成薄包裝。與 graph-core `allocateId`(2026-08-25 G8)、同一波 F005 的 `allocateProjectId` 同一個模式:把隱含的環境參數變明碼,原函式留成薄包裝 | **(a) 只實作 `detectSevenZip`**:零新增介面,契約面最小。否決理由是驗收標準第 3 條(三層都找不到)在**任何裝了 7-Zip 的機器上都觸發不到**——本機 `C:\Program Files\7-Zip\7z.exe` 實際存在(2026-08-29 實測),而候選清單是寫死的常數;那條驗收標準會變成一條寫在文件裡、永遠沒有人驗的話。**(b) 讓測試改動 `PATH` 環境變數**:不新增介面。否決理由是它只治得了第二層——第三層的候選清單不看環境變數,`NotFound` 還是測不出來;而且 `setEnv` 是行程全域的副作用,同一個 hspec 行程裡的其他 suite 會被波及。**(c) 連判準也注入(`FilePath -> IO Bool` 當參數)**:接縫最大、最好測。否決理由是那樣測到的就不是「存在且可執行」這條真正的規則了,而它正是 A2 要釘住的東西 |
| 「可執行」的判準整條委給 `directory` 的 `getPermissions` / `executable`,不在 workspace 寫任何平台分支 | **自己判副檔名(Windows)+ 自己讀 x 位元(POSIX)**:行為完全自己掌握。否決理由是那把平台知識複製了一份到 workspace,而 `directory` 已經有一份;兩份遲早會漂移,而且漂移的症狀是「doctor 說找到了但 asset-ingest 跑不起來」。**呼叫 Win32 API 讀 ACL**:最精確。否決理由是要新增 `Win32` 套件依賴(委派決策記錄:新增依賴一律寫進阻塞項),而且會讓本模組長出一段只在 Windows 編譯得過的程式碼 |
| PATH 層只試 `exeExtension` 一種副檔名,不展開 `PATHEXT` | **展開整份 `PATHEXT`**:涵蓋 `.cmd` / `.bat` 形式的 shim。否決理由是 `tsSearched` 會從 90 條變成 1080 條(本機實測 45 個 PATH 目錄 × 2 個名稱 × 12 個副檔名),而 `tsSearched` 的用途正是「印給人看,告訴他下一步」;付出的代價是可讀性歸零,換來的是一個可以用 `[tools]` 覆寫一行解決的情境。而且 `PATHEXT` 是 Windows 才有的環境變數,展開它等於在 law 裡引入平台分支 |
| `tsPath` / `tsSearched` 逐字捧著,一律不正規化 | **一律 `canonicalizePath`**(F002 對 `vrPath` 的做法)。否決理由是驗收標準第 1 條寫的是「`tsPath` **等於它**」——`canonicalizePath` 會解 symlink(POSIX 上 `/usr/bin/7z` 常是指向 `7zz` 的 symlink)、會還原 Windows 8.3 短檔名,`tsPath` 因此會與使用者在 `[tools]` 裡寫的那一行不同,而 `doctor` 印出來的東西要能讓使用者對回自己的設定。**一律 `makeAbsolute`**:相對路徑會被絕對化。否決理由是它在 Windows 上會順手 `normalise`,把 system.md 中樞範例裡的 `C:/Program Files/7-Zip/7z.exe` 變成 `C:\Program Files\7-Zip\7z.exe`(實測),同樣讓「等於它」不成立 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `workspace/src/Aapms/Workspace/Tools.hs` | 模組宣告與匯出清單(`detectSevenZip` / `ToolSearchPlan (..)` / `detectSevenZipIn`)、`ToolSearchPlan` 的完整型別定義、兩條完整簽名與各自的 Haddock;兩個函數本體一律 `undefined` |

**編譯狀態**:`Aapms.Workspace.Tools` **已列進 `aapms-workspace.cabal`**(library 的
`exposed-modules` 與 test-suite 的 `other-modules`,連同 `Aapms.Workspace.ToolsSpec`,都由
**編排者**單線維護,本 feature 不得修改)。

2026-08-29 交件當下的兩道驗證:

1. `cabal build aapms-workspace:lib:aapms-workspace` 的批次中
   `[2 of 8] Compiling Aapms.Workspace.Tools` **通過**(該次整體建置最後停在**另一個平行 feature
   在途的 `Projects.hs`** 的 `Not in scope: allocateProjectId`,與本模組無關)。
2. 為了與平行 feature 的在途狀態隔離,另以**唯讀**方式做單檔型別檢查——在 `workspace/` 下跑
   `cabal exec -- ghc -fno-code -Wall -Wcompat -XGHC2021 -XDerivingStrategies -XLambdaCase
   -XOverloadedStrings -XRecordWildCards -XStrictData -package aapms-core -package aapms-store
   -package containers -package directory -package filepath -package toml-reader
   -hide-package text-2.1.3 -isrc -outputdir <暫存> src/Aapms/Workspace/Tools.hs`
   → `[1 of 2] Aapms.Workspace.Types` / `[2 of 2] Aapms.Workspace.Tools`,**exit 0、零警告**。
   這道指令不寫任何檔案到專案樹,也沒有動 `.cabal`。

## TodoList

- [ ] T1: 私有判準 `qualifies :: FilePath -> IO Bool` = `doesFileExist` 為真時再問
  `executable <$> getPermissions`,否則直接 `False`(不呼叫 `getPermissions`,避免它對不存在的
  路徑拋例外) `dep: -`
- [ ] T2: 私有常數:內建候選清單(七條,逐字)與 PATH 查詢名稱 `["7z", "7zz"]`;兩者都**不匯出**
  `dep: -`
- [ ] T3: 三層候選路徑的組出與**保序去重**:`L1 ++ L2 ++ L3`,`L2` 名稱外層、目錄內層、副檔名
  只用 `exeExtension` `dep: T2`
- [ ] T4: `detectSevenZipIn`:依序問 `qualifies`,命中即停;算出 `tsPath` / `tsOrigin`(依命中項
  所屬的層)/ `tsSearched`(前綴)/ `tsName`;全不中回 `NotFound` + 完整清單 `dep: T1, T3`
- [ ] T5: `detectSevenZip`:`lookupEnv "PATH"` → `maybe [] splitSearchPath` → 組 `ToolSearchPlan`
  → 轉呼叫 `detectSevenZipIn`;`PATH` 未設時是空清單而不是失敗 `dep: T4`

## 1-to-1 測試對照表

| Todo | Law / Example | 測試 |
|------|---------------|------|
| T1 | L7 / X8, X9 | `test_qualifies_rejects_directory`、`test_qualifies_rejects_non_executable_file`、`test_qualifies_missing_path_does_not_throw` |
| T2 | L10(名稱與副檔名的部分)/ X14 | `test_candidate_list_is_verbatim_and_platform_independent`(斷言「數據」段那七條逐字進 `tsSearched`) |
| T3 | L9, L10 / X5, X6, X10, X13 | `test_probe_order_names_outer_dirs_inner`、`test_probe_order_layers`、`test_searched_is_deduped_across_layers`、`test_paths_are_verbatim` |
| T4 | L1, L2, L3, L4, L5, L6, L8, L11, L12, L13 / X1–X4, X7, X11, X12 | `test_config_hit_short_circuits`、`test_config_hit_ignores_plan`、`test_config_miss_continues`、`test_path_layer_hit`、`test_not_found_is_not_a_failure`、`test_missing_dirs_do_not_throw`、`test_never_executes_the_tool`、`test_path_and_origin_are_consistent` |
| T5 | L14 / X15, X16 | `test_real_entry_matches_injected_plan`、`test_real_entry_config_override` |
| (全部) | L15 (a)–(f) | `test_tools_no_sibling_module_imports`(a)、`test_tools_never_imports_process`(b)、`test_tools_never_imports_store_or_core`(c)、`test_tools_directory_import_is_read_only`(d)、`test_tools_environment_import_is_lookup_only`(e)、`test_tools_filepath_import_is_whitelisted`(f)。**六條都只掃 import 行,比對前先去除行尾 `\r`** |

## 待確認假設

> **2026-08-29 W4 閘門:五條全部裁完。** A1 裁決為選項 a(納入契約 E);A2–A5 由編排者**降級**
> ——不上閘門、暫採即定案。每條的「裁決」欄記在該條末尾,**選項與代價的原文一律保留**,供事後
> 抽查與日後重議時對照。

- A1: 在契約 E 的 `detectSevenZip` **之外**新增一個注入接縫
  (`ToolSearchPlan` 型別 + `detectSevenZipIn :: ToolSearchPlan -> ToolsConfig -> IO ToolStatus`),
  `detectSevenZip` 變成「拿真實的兩份清單去呼叫它」。契約卡沒有答案,是因為它只規定了行為,
  沒有處理「三層裡有兩層是測試控制不了的環境事實」這件事——而本機 `C:\Program Files\7-Zip\7z.exe`
  實際存在(2026-08-29 實測),使驗收標準第 3 條在這台機器上恒觸發不到。
  - 契約錨點:design.md 契約 E 的 `detectSevenZip`(簽名不動)與「探測順序固定三層」那一段;
    design.md「內部模組劃分」的 Tools 那一列(擁有的事實:「外部工具在哪、怎麼找的」);
    新增符號 `ToolSearchPlan` / `tspPathDirs` / `tspCandidates` / `detectSevenZipIn`
  - 層級自答:出現在邊界上?**會**(它們是 `Aapms.Workspace.Tools` 的匯出清單,`service` 與
    測試都看得到);改錯驚動其他模組?**要**(`service` 的 `doctor` 若改用 `detectSevenZipIn`
    自帶候選清單,「候選清單住哪個模組」這個事實就搬家了)
  - 選項:
    a) **新增 `ToolSearchPlan` + `detectSevenZipIn`(本 spec 採用)**——當下成本:模組匯出多兩個
       名字、一個只住在本模組的小型別;design.md 的契約 E 要補一句「另有一個可注入版本」。
       三個月後代價:多一個公開入口要維護,而且它容易被誤用成「繞過內建候選清單」的後門
       (`service` 若直接呼叫 `detectSevenZipIn` 自帶清單,清單的唯一真相就分岔了)——L14 把
       兩個入口的一致性釘成 law,但擋不住第三方自己組 plan
    b) **只實作 `detectSevenZip`,不加任何東西**——當下成本:零,契約面最小;
       三個月後代價:驗收標準第 3 條(`NotFound`)與第 6 個 `ToolOrigin` 值 `FromCandidate` 的
       行為在裝了 7-Zip 的機器上**測不出來**,而**這套系統的開發機就是這樣一台**;等到某天
       候選清單被改壞,發現的方式會是使用者回報「doctor 說沒裝但我明明裝了」
    c) **不加介面,改由測試操作 `PATH` 環境變數**——當下成本:低(qa 用 `setEnv`);
       三個月後代價:只治得了第二層,第三層的候選清單不看環境變數,`NotFound` 仍測不出來;
       而且 `setEnv` 是行程全域副作用,同一個 hspec 行程裡的其他 suite(尤其 F001 的
       `AAPMS_HOME` 測試)會互相干擾,變成偶發紅燈
  - 傾向:a。理由是驗收標準第 3 條是契約卡**逐字寫出來要驗的**,而 b / c 都做不到;a 付出的
    是「多兩個匯出名字」,而且新增的兩個名字都只描述**環境事實的來源**,沒有洩漏任何內部演算法。
    依賴的前提:`service` 會呼叫 `detectSevenZip` 而不是 `detectSevenZipIn`——這個前提由
    design.md「本機環境管線」的那條 `hubTools → detectSevenZip` 佐證,但**它是慣例不是型別**,
    真的要擋住只能靠 arch-audit。可逆性:**有條件可逆**——把 `detectSevenZipIn` 從匯出清單拿掉
    是純減法(`detectSevenZip` 的簽名與行為完全不變),代價是連帶刪掉靠它的那幾條測試;
    此刻只有骨架,代價最小,**等 `service` 開始呼叫它就變成難逆**
  - 暫採:a(`detectSevenZip` 契約原簽名 + `ToolSearchPlan (..)` + `detectSevenZipIn`)→ 影響:
    若裁決成 b,骨架刪掉 `ToolSearchPlan` 與 `detectSevenZipIn`(匯出清單只剩一個),L1–L12 的
    主詞全部從 `detectSevenZipIn plan cfg` 改寫成 `detectSevenZip cfg`、L14 整條刪掉,
    X1–X14 全部要改成「以真實環境呼叫」的形式,而 X7(`NotFound`)與 X6(`FromCandidate`)
    **必須整條刪掉並在 spec 明寫「驗收標準第 3 條無法機械驗證」**;若裁決成 c,再加一條
    「測試必須序列執行且復原 `PATH`」的限制,X7 仍然要刪
  - **裁決(2026-08-29 W4 閘門):選 a,注入接縫進契約。** `design.md` 契約 E 已增列
    `ToolSearchPlan` 與 `detectSevenZipIn`,`detectSevenZip` 的原簽名一個字不動、變成薄包裝。
    採納理由即本條的傾向:這台機器上 `C:\Program Files\7-Zip\7z.exe` 實際存在、候選清單又是
    寫死常數,驗收標準第 3 條(`NotFound`)與 `FromCandidate` 這個 `ToolOrigin` 值**永遠觸發
    不到**——那條驗收標準會變成沒人驗得了的話。
    **這不是測試後門**:它與 graph-core `allocateId` 的 2026-08-25 **G8 裁決**是同一個模式
    (把隱含參數變明碼、原函式變薄包裝),同一波的 **F005 也依同一個判準把 `allocateProjectId`
    提進契約**。三者的共同形狀是:原簽名一字不動、新入口只描述**環境事實的來源**、兩個入口的
    一致性由一條 law 釘住(本 feature 是 L14)。
    → spec 與骨架**不必改動任何簽名**:暫採的形狀即裁決的形狀。本條原記的「若裁決成 b / c」
    那兩串影響**不再適用**,保留只為存檔。

- A2: 「存在且可執行」的判準定成
  `doesFileExist p` **且** `executable <$> getPermissions p`,平台差異**整條委給 `directory`**
  (Windows 上等於「副檔名屬 `.exe` / `.bat` / `.cmd` / `.com`」,POSIX 上等於 x 位元)。
  契約卡只寫了「判準只有『檔案存在且可執行』」,而「可執行」在兩個平台**不是同一件事**,
  契約沒有指定用哪一種語意。
  - 契約錨點:design.md 契約 E 的「判準只有『檔案存在且可執行』,**不執行它、不查版本**」
    那一段;契約 E 欄位表的 `tsPath`(「找到的執行檔」);`detectSevenZip` 的可觀察行為
  - 層級自答:出現在邊界上?**會**(它直接決定 `tsPath` / `tsOrigin` 的值,是 `doctor` 印給
    使用者看的結果);改錯驚動其他模組?**要**(`asset-ingest` 拿 `tsPath` 去執行——判準太鬆
    會讓「doctor 說找到了」與「真的跑得起來」分家,而那個失敗會出現在別的子系統裡)
  - 選項:
    a) **`doesFileExist` + `getPermissions.executable`(本 spec 採用)**——當下成本:兩行,零
       平台分支;測試素材在兩個平台各差一行(Windows 靠副檔名、POSIX 靠 `setOwnerExecutable`),
       斷言完全相同。三個月後代價:Windows 上這條判準**只看副檔名**,一個名為 `7z.exe` 的
       零位元組空檔會被判成「找到了」,真正的失敗延後到 `asset-ingest` 執行它的時候;要收緊
       只能去讀檔頭或真的執行它,而後者被契約 E 明文禁止
    b) **只用 `doesFileExist`(照 legacy `Sidecar.hs` 對候選清單的做法)**——當下成本:零,
       而且 Windows 上與 (a) 幾乎等價;三個月後代價:契約 E 寫的是「存在**且可執行**」,
       (b) 直接違反字面;POSIX 上一個沒有 x 位元的 `/usr/bin/7z` 會被回報成找到,`doctor`
       的結論與現實相反
    c) **自己判平台:Windows 比對 `PATHEXT` 的副檔名集合、POSIX 讀 x 位元(或呼叫 Win32 讀
       ACL)**——當下成本:一段 CPP 或 `System.Info.os` 分支;讀 ACL 還要新增 `Win32` 套件
       依賴(委派決策記錄:新增依賴一律寫進阻塞項)。三個月後代價:workspace 裡多一份平台
       知識,而 `directory` 已經有一份;兩份遲早漂移,而且 law 會被迫寫成平台分支的版本
       (本波明文禁止)
  - 傾向:a。理由是它讓「可執行」在整個專案只有**一個**定義,而那個定義住在 `directory` 而不是
    我們的程式碼裡;(a) 的缺口(Windows 上的空 `7z.exe`)在契約 E 的「不執行它、不查版本」之下
    **本來就無解**,不是這個選項造成的。依賴的前提:`directory` 的 `getPermissions` 在
    Windows 上對目錄回 `executable == False`——2026-08-29 實測確認(`dir.exe` 這個目錄回 `False`),
    所以「目錄不會被誤判成執行檔」不需要額外的一次 `doesDirectoryExist`。可逆性:**可逆**
    ——判準是私有函式,收緊或放寬都不動任何簽名;只會讓某些既有的探測結果改變
  - 暫採:a → 影響:若裁決成 b,L7 的 (b)(c) 兩款刪掉、X8 / X9 的預期從「不命中」改成「命中」;
    若裁決成 c,L7 要改寫成兩段平台條文(違反本波「不要寫出只在某一個平台成立的 law」),
    而且 `Win32` 依賴要先過阻塞項
  - **裁決(2026-08-29 W4 閘門):編排者降級,不上閘門,暫採 a 即定案。** 理由記在 `build-log.md`:
    本條的結論是由**實測結果**決定的(`getPermissions` 在 Windows 上看副檔名、對目錄回
    `executable == False`,在 POSIX 上是 `access` 的 x 位元),b 直接違反契約 E 的字面
    (「存在**且可執行**」),c 要新增 `Win32` 依賴且會逼出平台分支的 law——**寫不出真實的第二方案**。
    → spec、laws、examples **一字不改**。

- A3: `PATH` 那一層**自己走 `PATH` 環境變數**(`lookupEnv "PATH"` → `splitSearchPath` →
  `d </> (n <.> exeExtension)`),**不用 `System.Directory.findExecutable`**;連帶決定 Windows 上
  **只試 `exeExtension` 一種副檔名,不展開 `PATHEXT`**。design.md「使用的技術」那一段**原本**點名
  `findExecutable`,但契約 E 同時要求 `tsSearched` 說出「找過哪些地方」,而 `findExecutable`
  在 Windows 上走的是 Win32 的 `SearchPath`——它搜過哪裡是**不可觀察也不可控制**的。
  (**2026-08-29 W4 閘門已依本條的理由改掉 design.md 那一行**,現在寫的是「路徑正規化
  (`canonicalizePath`)、`getPermissions` 的可執行判準。**不用 `findExecutable`**」,衝突消失。)
  - 契約錨點:design.md 契約 E 的 `tsSearched` 欄位(「依序、去重;`NotFound` 時必為非空;
    找過哪些地方」)與探測順序那一段(「PATH 上的 `7z` / `7zz`」);design.md「使用的技術」
    的「`directory` / `filepath`:向上探測、路徑正規化、**`findExecutable`**」那一行
  - 層級自答:出現在邊界上?**會**(它決定 `tsSearched` 有哪些項、以及 `PATH` 上的 `7z.cmd`
    到底找不找得到);改錯驚動其他模組?**要**(`doctor` 的訊息內容、以及 `asset-ingest`
    在什麼情況下拿得到 7-Zip)
  - 選項:
    a) **自走 `PATH` + 只試 `exeExtension`(本 spec 採用)**——當下成本:四行;`tsSearched` 在
       本機是 45 × 2 = 90 條(實測 `PATH` 有 45 個目錄)。三個月後代價:Windows 上以
       `.cmd` / `.bat` shim 安裝的 7-Zip(部分套件管理器的做法)在第二層找不到——但第三層的
       候選清單涵蓋標準安裝位置,而且 `[tools]` 覆寫一行就解決,錯誤訊息也列得出找過哪裡
    b) **用 `findExecutable`(照 design.md「使用的技術」的字面)**——當下成本:一行,而且
       Windows 上連 `PATHEXT` 都被 `SearchPath` 處理掉;三個月後代價:`tsSearched` 在這一層
       **寫不出任何路徑**(只能塞查詢名 `"7z"` / `"7zz"`,那不是「地方」);而且 `SearchPath`
       會搜「目前執行檔所在目錄」等註冊表決定的位置,**測試控制不了**,`NotFound` 與
       `FromPath` 兩種結果都會變成依機器而定的偶發紅燈
    c) **自走 `PATH` + 在 Windows 上展開整份 `PATHEXT`**——當下成本:多讀一個環境變數、多一層
       迴圈;三個月後代價:`tsSearched` 從 90 條變成 1080 條(45 × 2 × 12,實測 `PATHEXT`
       有 12 個),而 `tsSearched` 存在的唯一理由是印給人看;另外 `PATHEXT` 是 Windows 專有,
       law 會被迫寫成平台分支
  - 傾向:a。理由是契約 E 對 `tsSearched` 的要求(「依序、去重、說得出找過哪些地方」)與
    `findExecutable` 的不可觀察性**直接衝突**,而 design.md「使用的技術」那一行是整個子系統
    共用的技術清單、不是契約 E 的條文——`findExecutable` 在那一行旁邊還列著「向上探測、路徑
    正規化」,那兩項屬 F002。依賴的前提:`splitSearchPath` 處理得了兩個平台的分隔符與 Windows
    的引號寫法(`filepath` 的文件如此聲明,本 spec 不再自己切字串)。可逆性:**可逆**——
    第二層是私有實作;改成 (b) 只會讓 `tsSearched` 少掉一段、`tsOrigin == FromPath` 的判定
    改用 `findExecutable` 的回傳值,不動任何簽名
  - 暫採:a → 影響:若裁決成 b,L10 整條改寫(第二層不再有展開式,`tsSearched` 在這一層要嘛
    空、要嘛只有兩個查詢名)、L6(b) 改成「`tsPath` 等於 `findExecutable` 對 `"7z"` 或 `"7zz"`
    的回傳」、X4 / X5 / X15 全部要改成不可控環境的版本或刪掉;若裁決成 c,L10 的展開式多一層
    副檔名迴圈,X4 / X5 / X6 的 `tsSearched` 期望值跟著變長
  - **裁決(2026-08-29 W4 閘門):編排者降級,不上閘門,暫採 a 即定案。** 理由記在 `build-log.md`:
    本條的結論由**實測結果**決定(`findExecutable` 在 Windows 上走 Win32 `SearchPath`,搜哪裡由
    登錄檔決定、含「目前執行檔所在目錄」,**測試控制不了**),b 與契約 E 的 `tsSearched` 要求
    直接衝突、c 的 1080 條清單讓 `tsSearched` 唯一的用途(印給人看)歸零——**寫不出真實的第二
    方案**。連帶:**design.md「使用的技術」那一行已依本條的理由改掉**(見本條開頭的括號)。
    → spec、laws、examples **一字不改**。

- A4: `tsSearched` 記錄的**粒度**是「每一個**被判準問過的完整檔案路徑**」(而不是 `PATH` 的
  目錄、也不是查詢名),**順序**是「覆寫 → PATH(名稱外層、目錄內層)→ 候選清單」,而且
  `tsSearched` 只含**問過的那一段前綴**(命中之後的不列)。契約卡只說 `tsSearched` 是
  「依序、去重」的 `[FilePath]` 且「`NotFound` 時必為非空」,沒有說一項代表什麼、也沒有說
  兩個名稱之間誰先誰後。
  - 契約錨點:design.md 契約 E 欄位表的 `tsSearched` 那一列;契約卡驗收標準第 1 條
    (「`tsSearched` 只有那一個」)與第 2 條(「該路徑仍出現在 `tsSearched`」)
  - 層級自答:出現在邊界上?**會**(`tsSearched` 是契約 E 的欄位,`shell` 會把它印成訊息);
    改錯驚動其他模組?**要**(`service` / `shell` 的 `doctor` 輸出格式直接建立在它的粒度上——
    「找過 90 個檔案路徑」與「找過 45 個目錄」要印成完全不同的東西)
  - 選項:
    a) **每個被問過的完整檔案路徑,前綴語意(本 spec 採用)**——當下成本:零;`tsSearched`
       在最壞情況(`NotFound`)是 97 條(90 + 7)。好處是「`tsPath` 是 `tsSearched` 的最後
       一項」「`tsSearched` 的每一項都真的被問過」兩條都成立,驗收標準第 1、2 條逐字對得上。
       三個月後代價:`doctor` 要自己決定怎麼摺疊這 97 行(那是 `shell` 的呈現問題,但它是被
       這個決定逼出來的)
    b) **PATH 那一層只記目錄**——當下成本:零;`tsSearched` 縮到 45 + 1 + 7 = 53 條,而且讀起來
       像「我去這些目錄找過」。三個月後代價:`tsSearched` 的元素變成**兩種東西**(目錄與檔案
       路徑)混在同一個清單裡,`tsPath ∈ tsSearched` 不再成立,驗收標準第 1 條的「只有那一個」
       與第 2 條的「該路徑仍出現在」也要各自解釋一次
    c) **PATH 那一層只記查詢名(`"7z"` / `"7zz"`)**——當下成本:零;`tsSearched` 只有 10 條,
       最好讀。三個月後代價:`"7z"` 不是一個「地方」,使用者拿它沒辦法去 `ls` 任何東西;
       而且型別是 `[FilePath]`,塞一個相對的裸檔名進去,消費端無從分辨它是路徑還是名稱
  - 傾向:a。理由是它讓 `tsSearched` 的每一項有**同一種**意義(「一個被 `doesFileExist` /
    `getPermissions` 問過的檔案路徑」),兩條驗收標準因此不需要任何額外解釋就對得上;
    冗長是呈現問題,而 ADR-015 第三條讓 `shell` 本來就負責呈現。依賴的前提:`shell` 印
    `doctor` 時可以只印前 N 條加一句「另有 M 條」——這個前提尚未被任何已交付的程式碼佐證
    (`shell` 還不存在),是本條最弱的一環。可逆性:**可逆**——粒度是純輸出,改哪一種都不動
    簽名,也不會讓任何既有中樞檔或指令失效
  - 暫採:a → 影響:若裁決成 b,L1(b)(c)、L6(b)、L9 要改寫(`tsPath` 不再是 `tsSearched` 的
    最後一項),X3–X7、X11、X12 的 `tsSearched` 期望值全部改成目錄形式;若裁決成 c,再加上
    L8 對第二層那一款整條刪除(裸檔名沒有「逐字對應來源」可言)
  - **裁決(2026-08-29 W4 閘門):編排者降級,不上閘門,暫採 a 即定案。** 理由記在 `build-log.md`:
    粒度由 A3 的**實測結果**連帶決定(既然第二層是自己展開 `PATH`,被問過的就是完整檔案路徑),
    而 b / c 都會讓契約卡驗收標準第 1、2 條(「`tsSearched` 只有那一個」「該路徑仍出現在
    `tsSearched`」)需要額外解釋才對得上——**寫不出真實的第二方案**。
    → spec、laws、examples **一字不改**。

- A5: `tsPath` 與 `tsSearched` 的每一項一律**逐字**捧著,**不做任何正規化**
  (不 `canonicalizePath`、不 `makeAbsolute`、不 `normalise`),而且**不驗證 `tcSevenZip` 是不是
  絕對路徑**。契約 E 的欄位表說 `tsPath` 是「絕對路徑」,而驗收標準第 1 條說 `tsPath`「等於它」
  ——兩者在「使用者寫了相對路徑」或「路徑用正斜線寫」時無法同時成立,契約卡沒有處理這個衝突。
  - 契約錨點:design.md 契約 E 欄位表的 `tsPath`(「絕對路徑」)與 `tsSearched`;契約 B
    `ToolsConfig.tcSevenZip` 的值域(「絕對路徑;`Nothing` = 沒有覆寫」);契約卡驗收標準
    第 1 條(「`tsPath` 等於它」);對照組是 F002 對 `vrPath` 釘死的 `canonicalizePath`
  - 層級自答:出現在邊界上?**會**(`tsPath` 是契約 E 的欄位,而且會被 `asset-ingest` 拿去
    當執行檔路徑用);改錯驚動其他模組?**要**(相對的 `tsPath` 交給 `asset-ingest`,它會相對
    於**那時的**工作目錄解析,而本子系統的 cwd 與它的 cwd 未必相同)
  - 選項:
    a) **一律逐字,不正規化(本 spec 採用)**——當下成本:零;驗收標準第 1 條逐字成立,
       `doctor` 印出來的路徑與使用者在 `config.toml` 裡寫的那一行**一模一樣**,對得回去。
       三個月後代價:`PATH` 裡若有相對目錄(合法但罕見)、或呼叫端不經 `loadHub` 自己組出一個
       帶相對路徑的 `ToolsConfig`,`tsPath` 會是相對路徑,違反契約 E 欄位表的「絕對路徑」;
       下游若在別的 cwd 執行它會失敗,而失敗點離設定很遠(經 `loadHub` 的那條路已由
       `Hub.hs:188-189` 的 `isAbsolute` 擋住)
    b) **一律 `makeAbsolute`**——當下成本:一行;相對路徑問題根治。三個月後代價:Windows 上
       `makeAbsolute` 會順手 `normalise`,把 system.md 中樞範例的 `C:/Program Files/7-Zip/7z.exe`
       變成 `C:\Program Files\7-Zip\7z.exe`(2026-08-29 實測),驗收標準第 1 條的「等於它」
       不再逐字成立,而且 `doctor` 印的東西與使用者寫的不同形
    c) **一律 `canonicalizePath`(與 F002 的 `vrPath` 一致)**——當下成本:一行,而且與同一個
       子系統的另一條路徑處理保持一致。三個月後代價:它會解 symlink(POSIX 上 `/usr/bin/7z`
       常是指向 `7zz` 的 symlink,`tsPath` 會變成使用者沒見過的 `/usr/bin/7zz`)、會還原
       Windows 8.3 短檔名;比 (b) 更偏離「等於它」
  - 傾向:a。理由是這個欄位的用途與 `vrPath` 不同:`vrPath` 要拿來**比對兩個路徑是不是同一個
    vault**(所以必須歸一),`tsPath` 只要拿來**對回使用者的設定**與**交給下游執行**(所以要
    保原形)。相對路徑的缺口由中樞那一層守——契約 B 已經規定 `tcSevenZip` 的值域是絕對路徑,
    重複驗一次會讓「路徑合不合規」這個事實住在兩個地方。依賴的前提:`loadHub` 真的會擋下
    非絕對的 `tcSevenZip`——**已查證成立**:`Hub.hs:183-191` 的 `parseToolsSection` 對
    `seven_zip` 做 `isAbsolute` 檢查,不通過即 `HubMalformed`(見「相依性查證」事實 7)。
    殘留的缺口只剩「`PATH` 裡的相對目錄」,那不是中樞管得到的東西。可逆性:**可逆**——
    加上正規化是純增量,不會讓任何既有設定失效,只會改變 `doctor` 印出來的字
  - 暫採:a → 影響:若裁決成 b 或 c,L8 整條改寫成「`tsPath` 是 `<該正規化函式>` 施用於來源
    路徑的結果」,X13 / X14 的預期改成正規化後的形式,X1 / X3 / X16 的斷言從「等於 fixture 路徑」
    改成「等於 fixture 路徑的正規化」;另外要在本 spec 明寫「驗收標準第 1 條的『等於它』理解為
    『等於它的正規化』」。若編排者同時想補上 `loadHub` 對 `[tools]` 路徑的合規檢查,那是 F001
    的修訂,不在本 feature
  - **裁決(2026-08-29 W4 閘門):編排者降級,不上閘門,暫採 a 即定案。** 理由記在 `build-log.md`:
    本條**沿用 W1 的 `loadHub` 合規判準**——`[tools].seven_zip` 已被要求必須是絕對路徑
    (`Hub.hs:183-191` 的 `isAbsolute`,見「相依性查證」事實 7),所以「使用者給相對路徑」
    根本進不來,契約 E 的「絕對路徑」與驗收標準第 1 條的「等於它」**衝突不存在**,b / c 要解決
    的問題本身不成立。→ spec、laws、examples **一字不改**。
    (殘留的「`PATH` 裡有相對目錄」不在中樞管得到的範圍,由 L8 如實記錄,不另設檢查。)
