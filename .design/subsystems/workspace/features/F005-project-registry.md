---
id: F005
type: feature
title: project-registry
description: "中樞 [[projects]] 的註冊、移除、selector 查詢與 prj- 配號"
status: done
created: 2026-08-29
updated: 2026-08-29
depends-on: [F001]
related-adr: [ADR-014, ADR-017]
related-feature: []
---

# F005: 專案註冊表的增刪查與 `prj-` 配號(project-registry)

## 功能概述

實作**生命週期管線的同一條路,節點型別換成專案**:前置檢查 → 配號 → `Hub` 追加 → `saveHub`。
負責模組是 design.md「內部模組劃分」的 **Projects**,只寫一個檔案
`workspace/src/Aapms/Workspace/Projects.hs`。

Projects 擁有的唯一事實是**「這台機器上有哪些專案」**——中樞 `[[projects]]` 那個陣列裡有哪幾列、
每一列的 `id` / `name` / `path` 是什麼。專案**不需要 marker**(system.md 對外介面第 5 節:
「專案不需要 marker,由中樞註冊 + 目錄內的 manifest 自述」),所以本模組與 `.aapms/`、
`readMarker`、索引完全無關——它是 workspace 八個模組裡**唯一一個不碰 vault 的**。

本 feature **不寫、不改 `Aapms.Workspace.Types` 一個字**:契約 B 的 `ProjectEntry`、契約 F 的
`ProjectSelectorNotFound` / `ProjectPathMissing` / `InvalidName` 都已由 F001 一次寫齊
(build-log D2);2026-08-29 **W4 閘門新增的兩個建構子**
`ProjectAlreadyRegistered Id FilePath` 與 `ProjectSelectorAmbiguous Text [ProjectEntry]`
由編排者指派給 `Types.hs` 的維護者補上(連同 `renderWorkspaceError` 的兩則訊息),
**本 feature 只是它們的第一個也是唯一的生產者**。

**驗收標準**(逐字抄自契約卡):

1. `registerProject` 產生的 `peId` 前綴恒為 `prj-`,且與中樞既有的 `peId` 都不相同(撞號時以
   salt 遞增重試,不靜默照發) — 觀察點:契約 B 的 `ProjectEntry`、契約 D 的 `registerProject`
2. 同一個路徑註冊兩次得到**兩個不同的 `peId`**,或回一個明確的錯誤——二選一,但行為必須是
   確定的且被斷言 — 觀察點:契約 D 的 `registerProject`、契約 B 的 `hubProjects`
3. `forgetProject` 以名稱或 id 都找得到;都找不到回 `ProjectSelectorNotFound` — 觀察點:契約 D 的
   `forgetProject`、契約 F 的 `ProjectSelectorNotFound`
4. `forgetProject` 執行後專案目錄本身**完全未動**(位元組相同) — 觀察點:契約 D 的 `forgetProject`
5. 註冊時路徑不存在回 `ProjectPathMissing`,訊息含專案名與路徑 — 觀察點:契約 F 的
   `renderWorkspaceError`

第 2 條契約卡刻意沒有替本 spec 選,只要求「行為確定且被斷言」。**2026-08-29 W4 閘門裁決:選
「回一個明確的錯誤」**——契約 F 因此新增 `ProjectAlreadyRegistered Id FilePath`,帶**既有那一列
的 `peId` 與它的路徑**。理由見 design.md 契約 F 的「W4 閘門新增的三個建構子」表:契約 B 對
`pePath` 沒有唯一性要求,所以「靜默發第二個 id」在契約上是合法的——但中樞會出現兩列指同一個
目錄,`projectList` 印兩次而 `forgetProject` 只刪一列;訊息要說出下一步(要改名就先 `forget`
再註冊)。原始的三個選項與代價保留在「待確認假設」A1。

**明確不做**(逐字抄自契約卡):不讀 `assets/manifest.json` 或 `story/manifest.json`(那是
`project` 子系統的真相);不產生、不同步、不驗證專案內容。

追加三條由「明確不做」與 ADR-017 決策五推出來的硬界線,全部寫成可機械驗證的條文:

- **不碰專案目錄**:兩個 IO 函式呼叫前後,專案目錄底下整棵樹逐位元組相同——連 `assets/` /
  `story/` / `.aapms/` 都不建(L14)
- **中樞底下唯一可能改變的檔案是 `config.toml`**,而且只在成功路徑上改變(L15)
- **完全不依賴 `aapms-store`**:落地一律經 `Aapms.Workspace.Hub.saveHub`,本模組不自己原子寫檔、
  不讀任何 marker、不開索引(L18(b))

## 相依性

`depends-on: [F001]`——design.md「功能規劃」階段二表 #5 的「依賴」欄是 `#1`,查證後確實逐條用到
F001 交付的東西:`Hub` / `HubLocation` / `ProjectEntry` / `WorkspaceError` 四個型別,
`hubProjects` / `upsertProject` / `removeProject` / `saveHub` 四個函式。**不依賴 F002 / F003**
(不碰 vault),也**不與 F004 / F006 互相依賴**。

跨子系統:只依賴 `aapms-core` 的 `Aapms.Core.Id`(graph-core F001,`done`),四個符號
(`Id` / `IdPrefix (PPrj)` / `newId` / `renderId`)的簽名逐一開原始碼查證過。
**不依賴 `aapms-store` 的任何符號**——這是本模組與 workspace 其他六個模組最大的不同。

**不需要新增任何套件依賴**:`aapms-workspace.cabal` 現有的 `base` / `containers` / `directory` /
`filepath` / `text` / `time` / `toml-reader` / `aapms-core` / `aapms-store` 覆蓋本 feature 全部所需
(其中 `time` 在 W1–W3 都沒被用到,本 feature 是它的第一個消費者)。

## 對應的 Level 2 契約

### 契約 D(本 feature 負責的三項)

```haskell
registerProject   :: HubLocation -> Hub -> FilePath -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))
allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id   -- 2026-08-29 W4:時間明碼,salt 重試才測得到
forgetProject     :: HubLocation -> Hub -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))
```

三條簽名**逐字照抄,一個字不動**。其中 `allocateProjectId` 是 **2026-08-29 W4 閘門裁決**(本 spec
原提的 A5,選 a)之後才進契約 D 的——原本它只是本 spec 提議的一條模組間介面,現在是對外契約的
一部分。契約 D 的值域表對前兩者的規定:

| 參數 | 規定(design.md 原文) |
|---|---|
| `registerProject` 第三/第四參數 | 路徑必須存在(否則 `ProjectPathMissing`);名稱去空白後長度 ≥ 1 |
| `forgetProject` 第三參數 | 非空;先比 `peId` 再比 `peName` |

「名稱去空白後長度 ≥ 1」在契約 F 只對得上一個建構子:`InvalidName Text`(「收到的原始字串
(去除前後空白後長度為 0)」)。**契約卡的「實作的 Level 2 介面」欄漏列了 `InvalidName`**
——它與 F004 共用同一個建構子,處置見「待確認假設」A4 與「建議編排者做的上層動作」。
W4 閘門對帳確認:本 spec 對「名稱去空白後長度 ≥ 1」的寫法與 F004 對 `initVault` 第五參數的寫法
**一致**,兩個 feature 沒有分岔。

### 契約 B(本 feature 負責的兩項)

```haskell
data ProjectEntry = ProjectEntry
  { peId :: Id, peName :: Text, pePath :: FilePath }

hubProjects :: Hub -> [ProjectEntry]
```

| 欄位 | 值域(design.md 原文) |
|---|---|
| `peId` | `prj-` + 8 位小寫十六進位;中樞內唯一 |
| `peName` | 非空 |
| `pePath` | 絕對路徑,指向含 `assets/` 與 `story/` 的那一層 |

型別**已由 F001 宣告完畢**(`Types.hs:136-144`),本 feature 一個字都不改;`hubProjects` 是讀取端,
本 feature 只讀不改它的定義。**`peName` 的值域沒有寫「唯一」也沒有寫「允許重複」**——這正是
A1 與 A2 要一起處理的那個縫。

### 契約 F(本 feature 負責的五個建構子)

```haskell
ProjectSelectorNotFound  Text                   -- F001 已交付
ProjectPathMissing       Text FilePath          -- F001 已交付
InvalidName              Text                   -- F001 已交付(與 F004 共用)
ProjectSelectorAmbiguous Text [ProjectEntry]    -- 2026-08-29 W4 閘門新增
ProjectAlreadyRegistered Id   FilePath          -- 2026-08-29 W4 閘門新增
```

前三者的**宣告與繁中訊息**都已在 F001 交付(`Types.hs:323-328`、`renderWorkspaceError`
`Types.hs:400-407`);後兩者是 W4 閘門依本 spec 的 A1 / A2 裁決新增的,**宣告與訊息由編排者指派
給 `Types.hs` 的維護者補上,不在本 feature 的寫入白名單**。本 feature 是這五個建構子的
**第一個也是唯一的生產者**,一律不改 `renderWorkspaceError` 一個字。

兩個新建構子帶的值(design.md 契約 F 的 W4 新增表):

| 建構子 | 帶的值 | 訊息要說出的下一步 |
|---|---|---|
| `ProjectSelectorAmbiguous Text [ProjectEntry]` | selector 字串、**全部**撞名的 `ProjectEntry` | 改用完整的 `peId` 指定(與 `VaultSelectorAmbiguous` 同一個模式) |
| `ProjectAlreadyRegistered Id FilePath` | **既有那一列的** `peId`、**它的**路徑 | 要改名就先 `forget` 再註冊 |

另外**原樣轉發**一個:`saveHub` 失敗時回的 `HubWriteFailed FilePath Text`(不重寫訊息)。

### 模組間公開介面

design.md「模組間公開介面」與本 feature 有關的三列(前兩列經 **2026-08-29 W4 補表**):

| 呼叫方向 | 介面(design.md 原文) |
|---|---|
| Projects → Hub | `upsertProject :: ProjectEntry -> Hub -> Hub` / `removeProject :: Id -> Hub -> Hub` + `saveHub` |
| Projects → Hub | `upsertProject` / `removeProject`(見上)+ `hubProjects`(撞號比對與 selector 候選都要讀它)。**2026-08-29 W4 補表** |
| Projects → `aapms-core` | `newId PPrj`(純函式,時間由呼叫端給);唯一性由 Projects 對中樞既有 `peId` 重試保證 |

> **2026-08-29 W4 閘門裁決(本 spec 原提的 A5,選 a)**:本 spec 原本指出 design.md **兩處互相
> 矛盾**——上表最後一列寫著「**時間由呼叫端給**」,但契約 D 的 `registerProject` 簽名**沒有時間
> 參數**,時間只能在函式內部取樣;而藏起來取樣的話,呼叫端就無法預先造出碰撞,**驗收標準 1 的
> 後半「撞號時以 salt 遞增重試,不靜默照發」寫不出任何測試**(graph-core 為逐字相同的理由把時間
> 放到呼叫端,`Aapms.Store.Write.allocateId` 的 Haddock,2026-08-25 G8 裁決)。
>
> 裁決是把「配號」抽成一條純函式並**收進契約 D**(不只是模組間介面),`registerProject` 的簽名
> 一個字不動、自己取 `getCurrentTime` 再傳進去:
>
> ```haskell
> allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id
> ```
>
> 那個矛盾因此消解:「時間由呼叫端給」現在對得上一條真的有時間參數的簽名,而「唯一性由 Projects
> 對中樞既有 `peId` 重試保證」有了一個可以直接斷言的落點(L2 + L4(a))。

## 實作方式

### 相依性查證(2026-08-29 打開 `core/src/`、`store/src/` 與 `workspace/src/` 讀到的實況)

七點與文字描述不同、必須在實作前知道的事實:

1. **`loadHub` 對 `[[projects]]` 的合規判準會反過來約束本 feature 寫進去的形狀**
   (`Hub.hs:150-173` 的 `parseProjectEntry`):`name` 去空白後為空 → `HubMalformed`;
   `path` 不是絕對路徑(`System.FilePath.isAbsolute`)→ `HubMalformed`;`id` 不是 `prj-` 開頭的
   合法 id → `HubMalformed`;同一份中樞裡 `peId` 重複 → `HubMalformed`(`checkUniqueIds`,
   `Hub.hs:146`)。**所以 `pePath` 存相對路徑會讓下一次 `loadHub` 直接失敗**——正規化不是風格
   問題,是往返正確性的前提(見 A3)。
2. **`renderProjectSeg` / `quoteText`(`Hub.hs:425-441`)原本只逸出 `"` 與 `\`,不逸出換行**。
   名稱含 `\n` 會寫出非法的 TOML 基本字串,下一次 `loadHub` 回 `HubUnreadable`——工具寫出一份
   自己讀不回來的中樞。本 spec 交件時把這件事回報給編排者,**2026-08-29 W4 閘門裁決:現在修**,
   由 F001 的 impl 把 `quoteText` 改成逸出 TOML 規格要求的控制字元
   (`\n` / `\t` / `\r` / `\b` / `\f` 與 `\uXXXX`)。**因此 L8 的往返 law 不再限制定義域**
   (原文限制的是「名稱不含換行與其他控制字元」);L8 的條文已註明它是在那次修正之後才成立的,
   紅綠歸因見「紅綠預期」。
3. **`upsertProject` 是「以 `peId` 為鍵覆寫或追加」**(`Hub.hs:494-501` → `replaceOrAppend`
   `Hub.hs:517-520`)。配號保證新 id 不撞既有,所以本 feature 一律走**追加到末尾**那個分支;
   `upsertProject` 的覆寫分支在本 feature 不會被觸發。
4. **`saveHub` 不建立父目錄**(F001 的自裁 S3):中樞目錄不存在時,`atomicWriteText` 的失敗
   原樣包成 `HubWriteFailed`。建目錄是 F004 的 `setupHub`,本 feature 不做(L16)。
5. **`initVaultAt`(`store/src/Aapms/Store/Marker.hs:134-144`)的配號是
   `newId PVlt name now 0`**——內容用**名稱**、時間內部取樣、**沒有重試**(撞號交給呼叫端回
   `VaultIdCollision`)。**`allocateId`(`store/src/Aapms/Store/Write.hs:423-436`)則是 salt 遞增
   重試、時間由呼叫端給**,理由逐字寫在它的 Haddock(`Write.hs:411-416`):「藏在函式內部取樣
   的話,呼叫端就無法預先造出碰撞,salt 重試迴圈也就永遠測不到——而碰撞在正常情況下幾乎不發生,
   那段程式碼可能永遠是錯的而沒人知道。」本 feature 的驗收標準 1 要求的是 `allocateId` 那一種
   (有重試),所以照它的作法把時間提到呼叫端(A5)。
6. **`Id` 的 `Eq` 是 newtype-derived 的字串相等**(`core/src/Aapms/Core/Id.hs:86-88`),撞號比對
   直接用 `==` 即可,不必經過 `renderId`;而 `Id` 的建構子**不外露**,測試造 id 只能經 `newId`
   或 `parseId`。
7. **`renderIdPrefix PPrj == "prj"`、`newId` 一律產生 8 位小寫十六進位**
   (`Id.hs:57-66`、`Id.hs:103-113` 的 `hex8`)。「前綴恒為 `prj-`」因此是 `newId PPrj` 的直接
   後果,而不是本 feature 要自己拼字串的東西——**本模組不得出現 `"prj-"` 字面值**(知識歸屬:
   前綴的唯一真相在 `Aapms.Core.Id`)。

程式碼知識圖(knot)另外查到一件影響架構的事:`newId` 目前的直接消費者只有兩個,
`Aapms.Store.Marker.initVaultAt` 與 `Aapms.Store.Write.allocateId`
(`knot query reachable Aapms.Core.Id.newId --reverse --depth 2`,深度 1 只有這兩個節點)。
本 feature 因此是 `newId` 在 **`aapms-store` 之外的第一個消費者**——這條新的依賴邊已列進
「依賴方向」。

### 「正規化」在本 spec 全篇的定義

> **正規化 = `System.Directory.canonicalizePath`**(沿用 W2 閘門對契約 C 的 `vrPath` 的裁定)。

理由與 W2 相同,再加一條本 feature 特有的:`loadHub` 要求 `pePath` 是絕對路徑(查證 1),
不正規化就會寫出一份自己讀不回來的中樞。被否決的 `makeAbsolute` 見「不可逆決定」與 A3。

### 三個函式的資料流

```text
allocateProjectId existing name t                 -- 純函式
  → 自 salt = 0 起:cand = newId PPrj name t salt
      cand ∈ map peId existing → salt + 1 再來一次
      否則                     → cand
  -- 內容用「去空白後的名稱」(同 initVaultAt);不撞才回,不靜默照發

registerProject loc hub dir name
  → nm = T.strip name
      T.null nm → Left (InvalidName name)          -- 帶原始字串,不是 nm;不寫任何檔案
  → dir' = canonicalizePath dir
      doesDirectoryExist dir' == False → Left (ProjectPathMissing nm dir')
  → find ((== dir') . pePath) (hubProjects hub)    -- W4 裁決:同路徑不得再註冊一次
      Just e0 → Left (ProjectAlreadyRegistered (peId e0) (pePath e0))
  → now <- getCurrentTime
  → pid = allocateProjectId (hubProjects hub) nm now
  → e   = ProjectEntry pid nm dir'
  → hub' = upsertProject e hub                     -- 配號保證不撞,一律走追加
  → saveHub loc hub'
      Left err → Left err                          -- HubWriteFailed 原樣轉發,不重寫訊息
      Right () → Right (hub', e)

forgetProject loc hub s
  → byId   = [e | e <- hubProjects hub, renderId (peId e) == s]     -- 逐字精確比對
      length == 1 → 往下刪
      length >= 2 → Left (ProjectSelectorAmbiguous s byId)          -- W4 新增;列出全部
      length == 0 → 往下一階段
  → byName = [e | e <- hubProjects hub, peName e == s]
      同上三分支(多列 → Left (ProjectSelectorAmbiguous s byName))
      兩階段都沒命中 → Left (ProjectSelectorNotFound s)
  → hub' = removeProject (peId e) hub
  → saveHub loc hub'
      Left err → Left err
      Right () → Right (hub', e)
  -- 專案目錄一個位元組都不碰(ADR-017 決策五:中樞是註冊表,目錄是真相)
```

**前置檢查為什麼是「先名稱後路徑」**:契約 F 的 `ProjectPathMissing Text FilePath` 第一個值是
**專案名**,而驗收標準 5 要求「訊息含專案名與路徑」。名稱還沒過關就先報路徑錯誤,印出來的會是
一個空名——那則訊息說不出下一步(主架構全域錯誤策略第 2 條)。順序因此是被契約 F 決定的,
不是隨手挑的。

**`forgetProject` 命中兩列以上回 `ProjectSelectorAmbiguous`**(2026-08-29 W4 閘門裁決,本 spec
原提的 A2,選 c):本 spec 交件時契約 F 只有 `ProjectSelectorNotFound`,暫採的是「不刪、回一則
找不到」;閘門裁決改為**新增 `ProjectSelectorAmbiguous Text [ProjectEntry]`**,理由是借用
`ProjectSelectorNotFound` 會說「找不到」,但它其實**找到了兩個**——訊息說了一件假的事;而
vault 側早就有 `VaultSelectorAmbiguous`,專案側缺這一個本來就不對稱。兩組 selector 的行為因此
完全同構:兩階段逐字精確比對(W2 為 `lookupSelector` 裁定的那一套)、撞號/撞名一律**列出全部**、
要求使用者改用完整的 id。**中樞一列都不刪**這件事沒變。

**「同一個路徑」的判準**:`registerProject` 拿**這次正規化後的 `dir'`** 與中樞既有各列的
`pePath` 做**逐字比對**,不對既有列重新正規化。理由與代價見「待確認假設」A6——W4 的裁決給了
`ProjectAlreadyRegistered` 這個建構子,但沒有定義「同一個路徑」怎麼算,而那正是它的觸發條件。

**重複檢查為什麼排在路徑存在性之後**:`ProjectAlreadyRegistered` 的危害論述(design.md:
「中樞會出現兩列指同一個目錄,`projectList` 印兩次而 `forgetProject` 只刪一列」)預設那個目錄
**存在**;目錄已經被刪掉時,使用者真正該知道的是「那一列指的路徑不見了」,而不是「你已經註冊
過它」。所以順序是「名稱 → 路徑存在 → 重複」,三條前置檢查全部不寫任何檔案。

## 使用到的既有串接介面

行號是**建檔當下**的導航線索;一致性檢查一律比對**簽名原文**。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/Aapms/Core/Id.hs:103-109` | graph-core F001(契約 B) | 配號;內容 + 時間 + salt,唯一性不在這一層 |
| `data IdPrefix = … \| PPrj`(`renderIdPrefix PPrj == "prj"`) | `core/src/Aapms/Core/Id.hs:46-66` | graph-core F001 | `prj-` 前綴的**唯一真相**;本模組不寫字面值 |
| `newtype Id`(建構子**不外露**;`Eq` 為 newtype-derived 的字串相等) | `core/src/Aapms/Core/Id.hs:86-88` | graph-core F001 | `peId` 的型別;撞號比對直接用 `==` |
| `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:123-124` | graph-core F001 | `forgetProject` 的 id 階段逐字比對 |
| `parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/Aapms/Core/Id.hs:127-135` | graph-core F001 | **本 feature 不呼叫**;列出是因為測試用它斷言前綴(L1),而 `loadHub` 也用它解析 `[[projects]]` |
| `upsertProject :: ProjectEntry -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:494-501` | F001(W1 閘門為本 feature 補上) | 追加一列(配號保證不撞,覆寫分支不會被觸發) |
| `removeProject :: Id -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:504-511` | F001(同上) | 刪整列;沒有該 id 時原樣回傳 |
| `saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())` | `workspace/src/Aapms/Workspace/Hub.hs:223-230` | F001 | 原子寫回;失敗回 `HubWriteFailed`,**不建立父目錄** |
| `hubProjects :: Hub -> [ProjectEntry]` | `Types.hs:95`(定義)、`Hub.hs:22`(轉出) | F001 | 撞號比對與 selector 的候選清單 |
| `data ProjectEntry = ProjectEntry { peId :: Id, peName :: Text, pePath :: FilePath }` | `workspace/src/Aapms/Workspace/Types.hs:136-144` | F001 | 中樞 `[[projects]]` 的一列 |
| `data Hub`(不透明)、`mkHub`、`hubSourceText` | `workspace/src/Aapms/Workspace/Types.hs:91-117` | F001 | 兩個函式的第二參數;測試造 `Hub` 走 `mkHub` |
| `data HubLocation = HubLocation { hlPath :: FilePath, hlSource :: HubSource }` | `workspace/src/Aapms/Workspace/Types.hs:72-76` | F001 | `saveHub` 的第一參數 |
| `data WorkspaceError`(十七個建構子)、`renderWorkspaceError :: WorkspaceError -> Text` | `workspace/src/Aapms/Workspace/Types.hs:289-411` | F001(+W3) | 本 feature 產生三個、轉發一個 |
| `loadHub :: HubLocation -> IO (Either WorkspaceError Hub)` | `workspace/src/Aapms/Workspace/Hub.hs:79-90` | F001 | **本 feature 不呼叫**;L8 的往返 law 用它驗「寫出去的中樞讀得回來」 |
| `getCurrentTime :: IO UTCTime` | `time` 的 `Data.Time` | - | `registerProject` 取樣一次,傳給 `allocateProjectId` |
| `canonicalizePath :: FilePath -> IO FilePath`、`doesDirectoryExist :: FilePath -> IO Bool` | `directory` 的 `System.Directory` | - | 路徑正規化;專案根是否為既存目錄 |

## 新增的介面

全部三條都在 `workspace/src/Aapms/Workspace/Projects.hs`(本 feature 唯一寫入的 `.hs`)。

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `registerProject :: HubLocation -> Hub -> FilePath -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))` | 前置檢查(先名稱後路徑)→ 配號 → 追加一列 → `saveHub`;回新的 `Hub` 與新加的那一列 | `workspace/src/Aapms/Workspace/Projects.hs:74` |
| `forgetProject :: HubLocation -> Hub -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))` | selector 兩階段(先 id 後 name,逐字精確)→ 刪整列 → `saveHub`;回新的 `Hub` 與被移除的那一列 | `workspace/src/Aapms/Workspace/Projects.hs:102` |
| `allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id` | 純配號:自 `salt = 0` 起 `newId PPrj`,與清單裡任一 `peId` 撞號就 `salt + 1`,回第一個不撞的 | `workspace/src/Aapms/Workspace/Projects.hs:127` |

模組匯出清單只有這三個函式;型別一律讓消費端從 `Aapms.Workspace.Types` 取,本模組**不轉出**任何
型別(W1 / W2 / W3 立下的慣例)。

## 數據

本 feature **不新增、不修改、不刪除任何型別**。

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `ProjectEntry` | 沿用(F001 宣告) | `{ peId :: Id, peName :: Text, pePath :: FilePath }` | 「中樞裡的一個專案是什麼」 |
| `Hub` | 沿用(F001 宣告,不透明) | 四段 + 底稿 | 「中樞記了什麼」(Hub 模組擁有,不是 Projects) |
| `WorkspaceError` | 沿用(F001 宣告) | 十七個建構子,本 feature 產生三個、轉發一個 | 「這個子系統會有哪些失敗」(Types 擁有) |
| `Id` | 沿用(graph-core) | `newtype Id`,建構子不外露 | 「短 id 長什麼樣」(ADR-014,`aapms-core` 擁有) |

**Projects 擁有的唯一事實是「這台機器上有哪些專案」。** 專案裡面裝什麼(`assets/manifest.json`、
`story/manifest.json`)屬 `project` 子系統;短 id 的格式屬 `aapms-core`;中樞的檔案格式屬 Hub 模組。

### 中樞 `[[projects]]` 的檔案格式

`<hlPath>/config.toml`(system.md 對外介面第 6 節;序列化由 F001 的 `renderProjectSeg` 產生):

```toml
[[projects]]
id   = "prj-91c0aa12"
name = "Circle"
path = "D:/games/Circle"
```

`id` 是**鍵**(ADR-017 決策二:「搬動 vault 只改 `path`,身分與關聯不失聯」,專案同理)。

### 測試素材

`Hub` 是不透明型別,測試造它走 `mkHub vs ps llm tools txt`(F001 的唯一建構入口)。本 feature
只讀 `hubProjects`,所以 `vs` / `llm` / `tools` 填什麼都不影響判定(L12 就在驗這件事);但
`txt`(底稿)會影響 `saveHub` 寫出來的檔案長相,要驗往返(L8)時要給一份與 `ps` 一致的底稿,
或給空字串(空底稿時 `saveHub` 會把四段整份產生出來)。

`Id` 的建構子不外露,測試造 id 的兩條路:`newId PPrj "名字" 某個 UTCTime 0`(可預測,撞號測試
用這條)或 `snd <$> parseId "prj-91c0aa12"`。

## Laws

### 配號(`allocateProjectId`)

- **L1(形狀恒為 `prj-` + 8 位小寫十六進位)**:對任意 `existing`、任意 `nm`、任意 `t`,
  令 `i = allocateProjectId existing nm t`,則 `parseId (renderId i) == Right (PPrj, i)`,
  且 `renderId i` 的長度恒為 12(`"prj-"` 4 個字元 + 8 位十六進位),第 5 個字元起全部落在
  `0-9a-f`。**這條由 `newId PPrj` 直接保證,本模組不得自己拼前綴字串。**
- **L2(不撞既有,且撞號時 salt 遞增重試)**:對任意 `existing`、`nm`、`t`,
  `allocateProjectId existing nm t` **不等於** `existing` 裡任何一列的 `peId`;而且它恒等於
  `newId PPrj nm t k`,其中 `k` 是**最小**的、使 `newId PPrj nm t k ∉ map peId existing` 成立的
  非負整數。特別是:`existing` 裡沒有任何一列撞到 `newId PPrj nm t 0` 時,結果就是 `salt = 0`
  的那一個(不會無故跳號)。
- **L3(純函式)**:相同的 `(existing, nm, t)` 恒得到相同的 `Id`;不讀檔案、不看時鐘、不看當前
  目錄。`existing` 裡除了 `peId` 以外的欄位(`peName` / `pePath`)換成任何值,結果不變。

### 註冊(`registerProject`)

- **L4(成功時的四個事實)**:對任意 `loc`(中樞目錄存在且可寫)、`hub`、既存目錄 `dir`
  (其正規化**不等於** `hubProjects hub` 裡任何一列的 `pePath`)、去空白後非空的 `name`,
  `registerProject loc hub dir name` 回 `Right (hub', e)`,且:
  (a) `peId e` 不等於 `hubProjects hub` 裡任何一列的 `peId`,且形狀滿足 L1;
  (b) `peName e == T.strip name`;
  (c) `pePath e == dir` 的正規化(`canonicalizePath`),因此是絕對路徑;
  (d) `hubProjects hub' == hubProjects hub ++ [e]`——**追加到末尾,既有列的相對順序不變**。
- **L5(只動 `[[projects]]`)**:承 L4,`hubVaults hub' == hubVaults hub`、
  `hubLlm hub' == hubLlm hub`、`hubTools hub' == hubTools hub`(逐欄相等)。
- **L6(空名 → `InvalidName`,且什麼都不做)**:對任意 `loc`、`hub`、`dir` 與任意
  `T.strip name == ""` 的 `name`(含 `""`、`"   "`、`"\t\n"`),`registerProject` 回
  `Left (InvalidName name)`——第一個值是**原始字串**,不是去空白後的;而且呼叫前後
  `<hlPath>/config.toml` 與 `dir` 底下整棵樹逐位元組相同。**`dir` 存不存在都不影響這條**
  (名稱檢查先於路徑檢查)。
- **L7(路徑不是既存目錄 → `ProjectPathMissing`,且什麼都不做)**:對任意去空白後非空的 `name`
  與任意「正規化後不是既存目錄」的 `dir`(不存在、或存在但是普通檔案),`registerProject` 回
  `Left (ProjectPathMissing (T.strip name) dir')`,`dir'` 是 `dir` 的正規化;
  `renderWorkspaceError` 對它的輸出**同時含** `T.strip name` 與 `dir'`(驗收標準 5);
  且呼叫前後 `<hlPath>/config.toml` 逐位元組不變。
- **L8(寫出去的中樞讀得回來)**:對任意合法的初始中樞檔案與**任意**去空白後非空的名稱
  (**完整定義域,含帶換行、tab 與其他控制字元的名稱**),`registerProject` 成功後對同一個 `loc`
  呼叫 `loadHub`,結果是 `Right hub''` 而**不是** `HubMalformed` / `HubUnreadable`,且
  `hubProjects hub''` 逐列逐欄等於 `hubProjects hub'`。
  **本條的完整定義域是 2026-08-29 W4 閘門裁決「現在修 `quoteText`」之後才成立的**:交件時的
  `quoteText` 只逸出 `"` 與 `\`,帶換行的名稱會寫出非法 TOML(見「相依性查證」2);修正由 F001
  的 impl 執行,**本 feature 不碰 `Hub.hs`**。控制字元那一段若紅,歸因是 F001 的序列化器,
  不是本模組。
- **L9(同一個路徑不得註冊兩次)**:對同一個 `dir` 連續呼叫兩次 `registerProject`(第二次吃第一次
  回傳的 `hub'`),第一次回 `Right (hub', e1)`,**第二次回
  `Left (ProjectAlreadyRegistered (peId e1) (pePath e1))`**——帶的是**既有那一列**的 id 與路徑,
  不是這次傳進來的;且第二次呼叫前後 `hubProjects` 不變(仍只有 `e1` 那一列)、
  `<hlPath>/config.toml` 逐位元組不變。`renderWorkspaceError` 對它的輸出含
  `renderId (peId e1)` 與 `pePath e1`。
  **判準是「這次正規化後的 `dir'` 逐字等於某一列的 `pePath`」**,不對既有列重新正規化:
  同一個目錄的兩種寫法(`P` 與 `P/a/..`)都會正規化成同一個字串,所以兩者互相擋得住;但中樞裡
  **手寫的、未正規化的**絕對路徑擋不住(它與正規化後的字串不逐字相等),那種情況仍會成功註冊
  成第二列——見「待確認假設」A6。
- **L10(`saveHub` 失敗即失敗)**:若 `saveHub` 回 `Left err`(例如中樞目錄不存在),
  `registerProject` 回 **`Left err` 原件**(同一個建構子、同一個路徑與原因字串,不重寫訊息、
  不包成別的建構子),而且**不回任何 `Hub`**——呼叫端拿不到「已加進去但沒存下來」的快照。

### 撤除(`forgetProject`)

- **L11(兩階段,id 絕對優先)**:對任意 `hub` 與任意 `s`,令
  `byId = filter ((== s) . renderId . peId) (hubProjects hub)`、
  `byName = filter ((== s) . peName) (hubProjects hub)`。`byId` 非空時,`forgetProject` 的結果
  **只由 `byId` 決定**——把 `byName` 那些列的 `peName` 任意換掉(不動 `byId` 那些列),結果不變。
- **L12(命中集合 → 結果,兩階段同一套規則)**:令 `E` 是實際生效的那個命中集合(`byId` 非空時
  是它,否則是 `byName`)——
  (a) `length E == 1` → `Right (hub', e)`,`e` 是 `E` 的那一列,
      `hubProjects hub'` 等於 `hubProjects hub` **去掉 `e` 那一列**(其餘保序不變),
      且 `hubVaults` / `hubLlm` / `hubTools` 逐欄不變;
  (b) `length E >= 2` → `Left (ProjectSelectorAmbiguous s E)`,第二個欄位**逐列等於 `E`**
      (含全部撞到的列、順序同 `hubProjects`),**中樞一列都沒少**,
      `<hlPath>/config.toml` 逐位元組不變;
  (c) 兩個集合都空 → `Left (ProjectSelectorNotFound s)`,同樣什麼都不動。
- **L13(逐字精確比對)**:`forgetProject` 不去前後空白、不忽略大小寫、不做前綴或子字串比對。
  對任意 `e` 與任意 `s`,若 `s` 既不逐字等於 `renderId (peId e)`、也不逐字等於 `peName e`,
  則 `e` 不會被移除。
- **L14(只看 `[[projects]]`)**:對任意 `hub`、`s`,`forgetProject` 回傳的 `Either` 的**內容**
  只由 `hubProjects hub` 與 `s` 決定——用 `mkHub` 把 `hubVaults` / `hubLlm` / `hubTools` 換成
  任何其他值,`Left` 的建構子與參數、或 `Right` 的 `ProjectEntry` 逐欄不變。

### 不碰的東西

- **L15(專案目錄完全未動)**:`registerProject` 與 `forgetProject` 在**任何**路徑上(成功、
  `InvalidName`、`ProjectPathMissing`、`ProjectSelectorNotFound`、`HubWriteFailed`),呼叫前後
  `dir` / `pePath` 底下整棵目錄樹的檔案清單與內容**逐位元組相同**——特別是**不建立**
  `assets/` / `story/` / `.aapms/`,**不寫入** `manifest.json`,**不刪除**任何東西
  (驗收標準 4;ADR-017 決策五)。
- **L16(中樞底下只可能動 `config.toml`)**:兩個函式呼叫前後,`<hlPath>` 底下除
  `config.toml` 以外的所有檔案(含 `cache/thumbs/` 整棵樹)逐位元組相同;而 `config.toml`
  **只在成功路徑上**改變,三條失敗路徑(L6 / L7 / L12(b)(c))下它逐位元組不變。
  本模組**不建立任何目錄**:中樞目錄不存在時,失敗以 `HubWriteFailed` 原樣捧出(L10),
  不自己 `createDirectoryIfMissing`(建目錄是 F004 的 `setupHub`)。

### 依賴方向與職責界線

- **L17(以 import 行驗證;**比對前先去除行尾 `\r`**)**:專案的 `.gitattributes` 讓 `.hs` 在
  checkout 時轉 CRLF,逐字比對前必須先把行尾的 `\r` 去掉(W1 的 L17(d) 就是漏了這條,在乾淨
  checkout 上紅了一輪)。`Projects.hs` 的 **import 行**滿足:
  - (a) 沒有任何 `import Aapms.Workspace.Location` / `Aapms.Workspace.Discovery` /
    `Aapms.Workspace.Scope` / `Aapms.Workspace.Lifecycle` / `Aapms.Workspace.Tools` 的行——
    design.md「模組間公開介面」只給了 Projects 兩條出邊(→ Hub、→ `aapms-core`),
    Lifecycle / Tools 是**平行的兄弟模組**,Discovery / Scope 是 vault 那條線。
    本套件內允許的 import 只有 `Aapms.Workspace.Types` 與 `Aapms.Workspace.Hub`。
  - (b) **完全不得**出現任何 `import Aapms.Store` 開頭的行(含門面 `Aapms.Store` 與
    `Aapms.Store.Atomic` / `Marker` / `Schema` / `Index` / `Write` / `Create` / `Query` /
    `MultiVault` 等任何子模組)。**這條守的是三件事**:專案沒有 marker(不讀 `readMarker`)、
    不開索引、落地一律經 `Aapms.Workspace.Hub.saveHub`(不自己 `atomicWriteText`)。
    Projects 是 workspace 八個模組裡**唯一一個不依賴 `aapms-store` 的**。
  - (c) **若**有 `import Aapms.Core.Id` 的行,它的匯入清單**只能由 `Id`、`IdPrefix (PPrj)`、
    `newId`、`renderId` 這四項組成**(可以少、不可以多,順序不限,不得寫成 `IdPrefix (..)`
    或 `Aapms.Core.Id` 的無清單 import)。特別是 `parseId` / `parseIdPrefix` / `renderIdPrefix` /
    `idPrefix` / `fnv1a64` / `Ref` / `VaultId` / `localRef` / `parseRef` / `renderRef`
    一個都不得出現——**這條守的是「配號只走 `newId PPrj`」**:自己拼 `"prj-"` 字面值、
    自己算雜湊、或去碰 vault 的身分型別,編譯得過但這條會紅。
    (寫成條件式是因為骨架階段只用得到 `Id` 一項;impl 填本體時才會補上另外三項。)
  - (d) **完全不得** import `System.Process`——不執行任何外部程式(那是 F006)。
  - (e) 除 `Aapms.Core.Id` 外**不得**有任何 `import Aapms.Core.` 開頭的行,也**不得** import
    `Data.Aeson`(或其任何子模組)——`assets/manifest.json` 與 `story/manifest.json` 是
    `project` 子系統的真相,本模組不讀、不產生、不驗證。

  **判準只看 import 行,不做全檔字串搜尋**:本檔的 Haddock 本來就會提到 `manifest.json` /
  `readMarker` / `allocateId` / `setupHub` 這些名字來說明界線,全檔搜尋會把「文件寫得清楚」
  誤判成「越界」。

> **紅綠預期**(`spec-roles.md`「qa 的交付判準」逐條判定,**不是整批全紅**):
>
> - **預期綠**:**L17 的五條子斷言 (a)–(e) 全部**。它們驗的是骨架原文自身就承載的事實
>   (本檔的 import 行),不經過任何 `undefined`。**從第一天就綠,而且應該綠;不得因為它綠就
>   退回重寫。** 其中 (c) 是條件式,**兩個階段都預期綠**:骨架階段的那一行是
>   `import Aapms.Core.Id (Id)`(`{Id}` 是允許集合的子集),impl 補上 `newId` /
>   `IdPrefix (PPrj)` / `renderId` 之後仍在集合內;多出任何一項或放寬成 `IdPrefix (..)` 就紅。
> - **預期紅**:其餘每一條 law 與每一個 example——三個函式的本體全是 `undefined`。
>
> 骨架裡**沒有**任何不是 `undefined` 的本體(與 F001 的 `mkHub = Hub` 不同)。
>
> **兩個先決條件(2026-08-29 W4 閘門裁決的連帶,兩者都不在本 feature 的寫入白名單)**:
>
> 1. `Types.hs` 必須先長出 `ProjectAlreadyRegistered Id FilePath` 與
>    `ProjectSelectorAmbiguous Text [ProjectEntry]` 兩個建構子與對應訊息,**否則 qa 的測試檔
>    連編譯都過不了**(L9 / L12(b) / X17 / X21 / X30 直接指名它們)。這是**編譯期**的相依,
>    不是紅綠問題
> 2. L8 的完整定義域依賴 F001 的 impl 修好 `quoteText`。**在那之前,L8 帶控制字元的那一段會紅,
>    歸因是 `Aapms.Workspace.Hub` 的序列化器,不是本模組**——依「仲裁協議」不得改本 feature 的
>    測試或實作來讓它變綠

## Examples

`P` 表示一個既存的暫存目錄(充當專案根),`P'` 是它的正規化;`H` 表示一個中樞目錄
(已存在且可寫),`loc = HubLocation H FromEnv`;`t0` 是一個固定的 `UTCTime`。

| # | 輸入 | 預期 | 覆蓋的 law |
|---|---|---|---|
| X1 | `allocateProjectId [] "Circle" t0` | `newId PPrj "Circle" t0 0`(逐欄相等) | L1, L2 |
| X2 | `existing = [ProjectEntry (newId PPrj "Circle" t0 0) "x" "C:/x"]`;`allocateProjectId existing "Circle" t0` | `newId PPrj "Circle" t0 1`——撞號跳 salt,**不是**照發 salt 0 的那個 | L2 |
| X3 | `existing` 同時含 salt 0 與 salt 1 的兩個候選;`allocateProjectId existing "Circle" t0` | `newId PPrj "Circle" t0 2` | L2 |
| X4 | X2 的 `existing`,但把該列的 `peName` / `pePath` 換成完全不同的值;同樣呼叫 | 與 X2 逐欄相同 | L3 |
| X5 | `renderId (allocateProjectId [] "任意名字" t0)` | 以 `"prj-"` 開頭、總長 12、第 5 字元起全為 `0-9a-f`;`parseId` 回 `Right (PPrj, _)` | L1 |
| X6 | 空中樞 `mkHub [] [] Nothing (ToolsConfig Nothing) ""`;`registerProject loc hub P "Circle"` | `Right (hub', e)`;`peName e == "Circle"`、`pePath e == P'`、`hubProjects hub' == [e]` | L4, L5 |
| X7 | 中樞已有一列 `e0`(其 `pePath` **不是** `P'`);`registerProject loc hub P "Circle"` | `hubProjects hub' == [e0, e]`——**追加在末尾**,`e0` 原樣 | L4(d) |
| X8 | `registerProject loc hub P "  Circle  "` | `Right (hub', e)`,`peName e == "Circle"`(存進去的是去空白後的) | L4(b) |
| X9 | `registerProject loc hub P "   "`(全空白) | `Left (InvalidName "   ")`——帶**原始字串**;`config.toml` 與 `P` 底下逐位元組不變 | L6, L15, L16 |
| X10 | `registerProject loc hub P ""` | `Left (InvalidName "")` | L6 |
| X11 | `registerProject loc hub (H </> "no-such-dir") "Circle"`(路徑不存在) | `Left (ProjectPathMissing "Circle" (正規化後的路徑))`;`renderWorkspaceError` 的輸出**同時含** `"Circle"` 與該路徑 | L7 |
| X12 | `dir` 是一個普通**檔案**(不是目錄);`registerProject loc hub dir "Circle"` | `Left (ProjectPathMissing "Circle" dir')`——`pePath` 的值域是「指向含 `assets/` 與 `story/` 的那一層」,那是目錄 | L7 |
| X13 | 名稱為空**且**路徑不存在;`registerProject loc hub (H </> "nope") "  "` | `Left (InvalidName "  ")`——名稱檢查先於路徑檢查,恒不回 `ProjectPathMissing` | L6 |
| X14 | `registerProject loc hub (P </> "a" </> ".." </> ".") "Circle"` | `Right (hub', e)`,`pePath e == P'`——正規化解掉 `.` / `..`,存進去的是絕對路徑 | L4(c) |
| X15 | X6 之後對同一個 `loc` 呼叫 `loadHub` | `Right hub''`(**不是** `HubMalformed`),`hubProjects hub''` 逐欄等於 `hubProjects hub'` | L8 |
| X16 | 中樞底稿含使用者寫的註解與 `[[vaults]]` 段;X6 之後讀回 `config.toml` 原文 | 註解與 `[[vaults]]` 段**逐字保留**,只多出一段 `[[projects]]` | L5, L8 |
| X17 | 對同一個 `P` 連續註冊兩次(第二次吃第一次的 `hub'`,名稱換成 `"Circle2"`) | 第一次 `Right (hub', e1)`;第二次 `Left (ProjectAlreadyRegistered (peId e1) (pePath e1))`;`hubProjects hub'` 仍只有 `e1` 一列,`config.toml` 逐位元組不變 | L9, L16 |
| X18 | `loc` 指向一個**不存在**的中樞目錄;`registerProject loc hub P "Circle"` | `Left (HubWriteFailed fp _)` 原件(與直接呼叫 `saveHub` 得到的**逐欄相同**);沒有任何目錄被建立 | L10, L16 |
| X19 | `hubProjects` 有 e1(`peId` render 後是 `prj-91c0aa12`、`peName = "Circle"`)與 e2(`peName = "prj-91c0aa12"`);`forgetProject loc hub "prj-91c0aa12"` | `Right (hub', e1)`——id 先於 name | L11, L12(a) |
| X20 | 承 X19 成功後 | `hubProjects hub' == [e2]`;`hubVaults` / `hubLlm` / `hubTools` 逐欄不變;`P` 底下逐位元組不變(**專案目錄完全未動**) | L12(a), L15 |
| X21 | 兩列同名 `"Circle"`(id 不同)`e3` / `e4`;`forgetProject loc hub "Circle"` | `Left (ProjectSelectorAmbiguous "Circle" [e3, e4])`——清單**兩列都在**且順序同 `hubProjects`;**兩列都還在**、`config.toml` 逐位元組不變 | L12(b), L16 |
| X22 | `forgetProject loc hub "nope"` | `Left (ProjectSelectorNotFound "nope")`;`config.toml` 逐位元組不變 | L12(c) |
| X23 | `forgetProject loc hub "CIRCLE"`(大小寫不同) | `Left (ProjectSelectorNotFound "CIRCLE")` | L13 |
| X24 | `forgetProject loc hub " Circle "`(前後有空白) | `Left (ProjectSelectorNotFound " Circle ")` | L13 |
| X25 | 同一組 projects,但 `mkHub` 的 vaults / llm / tools 換成完全不同的值;`forgetProject loc hub "Circle"` | 回傳的 `ProjectEntry` 與換之前逐欄相同 | L14 |
| X26 | X19 成功後對同一個 `loc` 呼叫 `loadHub` | `Right hub''`,`hubProjects hub''` 只剩 e2;檔案裡 e1 的那一段整段消失,其餘逐字保留 | L12(a), L8 |
| X27 | `forgetProject` 在 `loc` 指向不存在的中樞目錄時 | `Left (HubWriteFailed fp _)` 原件;`hubProjects` 的移除**沒有落地** | L10 |
| X28 | X17 成功註冊 `P` 之後,改用**另一種寫法**指同一個目錄:`registerProject loc hub' (P </> "a" </> "..") "Circle2"` | `Left (ProjectAlreadyRegistered (peId e1) (pePath e1))`——兩種寫法正規化成同一個字串,擋得住 | L9 |
| X29 | 中樞是**手寫**的,含一列 `path = "D:/games/../games/Circle"`(絕對但未正規化,`loadHub` 判它合法);對 `D:/games/Circle` 呼叫 `registerProject` | `Right`——**擋不住**,中樞出現第二列。本 spec 的判準是逐字比對,不對既有列重新正規化(A6 的已知代價,必須被斷言) | L9 |
| X30 | `renderWorkspaceError (ProjectAlreadyRegistered (peId e1) (pePath e1))` | 非空的繁中訊息,**同時含** `renderId (peId e1)` 與 `pePath e1` | L9 |
| X31 | 以 `mkHub` 造出兩列 `peId` 相同的中樞(`loadHub` 擋得掉,但 `mkHub` 造得出來);`forgetProject loc hub "prj-91c0aa12"` | `Left (ProjectSelectorAmbiguous "prj-91c0aa12" [兩列])`——**id 階段與 name 階段同一套規則**,不取第一列 | L12(b) |

## 依賴方向

- **依賴誰**:`Aapms.Workspace.Types`(`Hub` / `HubLocation` / `ProjectEntry` / `WorkspaceError`)、
  `Aapms.Workspace.Hub`(`hubProjects` / `upsertProject` / `removeProject` / `saveHub`)、
  `Aapms.Core.Id`(`Id` / `IdPrefix (PPrj)` / `newId` / `renderId`)、`time`、`directory`、`text`。
- **誰會依賴它**:`service`(`project new` / `project forget` 兩道指令)。**本套件內無人**——
  Lifecycle / Tools 是平行的兄弟模組,Discovery / Scope 走 vault 那條線,都不呼叫 Projects。
- **新增的依賴邊**(一條都不能漏):
  - `Aapms.Workspace.Projects → Aapms.Workspace.Types`(新;骨架就有)
  - `Aapms.Workspace.Projects → Aapms.Workspace.Hub`(新;impl 填本體時出現)
  - `Aapms.Workspace.Projects → Aapms.Core.Id`(新;骨架就有 `Id`,impl 再補三項)。
    **`newId` 在 `aapms-store` 之外的第一個消費者**——knot 反向可達確認目前只有
    `Aapms.Store.Marker.initVaultAt` 與 `Aapms.Store.Write.allocateId` 用它
  - **不新增** `Projects → aapms-store` 的任何邊(L17(b) 守著);**套件層級不新增任何依賴邊**:
    `aapms-workspace → aapms-core` 在 F001 就已存在,`.cabal` 的 `build-depends` 一行不用動
    (`time` 已經在清單裡,只是 W1–W3 沒用到)
- **可否與其他進行中任務平行開發**:可以與 F004(vault-lifecycle)、F006(machine-tools)平行
  ——三者的寫入白名單各是一個不同的 `.hs`,共同讀的 `Types.hs` / `Hub.hs` 都只讀不寫。
  **與 F004 的唯一交集是契約 F 的 `InvalidName` 與契約 D 的「名稱去空白後長度 ≥ 1」值域**:
  A4 的裁決應同時套用到 F004 的 `initVault` 第五參數,否則 vault 與 project 的名稱處置會分岔
  (兩個 feature 互相看不見,不會自己對齊)。

## 不可逆決定

| 決定 | 被否決的替代方案與否決理由 |
|---|---|
| 中樞 `[[projects]]` 以 `peId` 為鍵,`peName` / `pePath` 都不是身分 | **以路徑為鍵**:註冊表最直觀,天然去重。否決理由是 ADR-017 決策二已經為 vault 付過這個學費——搬動一個專案目錄就等於換一個身分,而專案目錄本來就會被搬(`D:\games\Circle` → `E:\games\Circle`)。**以名稱為鍵**:人最好讀。否決理由同 ADR-017「註冊表維持名稱為鍵」那一條:改名一個專案不該讓它失聯 |
| 配號抽成純函式 `allocateProjectId`,時間由 `registerProject` 取樣後傳進去(2026-08-29 W4 閘門裁決後**已收進契約 D**) | **(a) 整段藏在 `registerProject` 裡**:匯出清單最小、契約卡沒要求多這一條。否決理由逐字寫在 graph-core `allocateId` 的 Haddock(2026-08-25 G8 裁決):藏起來取樣,呼叫端就造不出碰撞,salt 重試迴圈永遠測不到——而驗收標準 1 的後半正是在要求那段迴圈。**(b) 在 `registerProject` 的簽名加一個 `UTCTime` 參數**:最直接,與 `allocateId` 完全同構。否決理由是那會改到**契約 D 的對外簽名**(`service` 直接消費),而抽成純函式在契約 D 一個字不動的前提下拿到同樣的可測性 |
| 註冊時同路徑回 `ProjectAlreadyRegistered`(2026-08-29 W4 閘門裁決,A1 選 b) | **靜默發第二個 id**:契約上合法(契約 B 對 `pePath` 沒有唯一性要求)、零成本。否決理由是中樞會出現兩列指同一個目錄,`projectList` 印兩次而 `forgetProject` 只刪一列,使用者要靠 `peId` 才分得出來。**冪等回既有那一列**:不新增也不報錯。否決理由是 `registerProject` 會變成「有時新增、有時什麼都不做」,而契約 D 沒有給它 `setupHub` 那種 `spHubCreated` 欄位,呼叫端分不出兩者。三個選項的完整代價見 A1 |
| 撞名 / 撞號回 `ProjectSelectorAmbiguous` 並列出全部(2026-08-29 W4 閘門裁決,A2 選 c) | **靜默刪第一列**:零成本。否決理由是方向不可逆——使用者一旦習慣「打名字就會刪掉某一個」,再收緊成拒絕就是破壞性變更;而 ADR-017 對「身分不確定」的一貫立場是不靜默帶過。**借用 `ProjectSelectorNotFound`**(本 spec 交件時的暫採):不必動 `Types.hs`。否決理由是訊息會說「找不到」,但它其實**找到了兩個**——說了一件假的事,與 W3 新增 `WriteTargetIdDrift` 是同一個判準 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `workspace/src/Aapms/Workspace/Projects.hs` | 模組宣告與匯出清單(三個函式)、三條完整簽名與各自的 Haddock;本體一律 `undefined` |

**編譯狀態**:`Aapms.Workspace.Projects` **已列進 `aapms-workspace.cabal`**(library 的
`exposed-modules` 與 test-suite 的 `other-modules`,連同 `Aapms.Workspace.ProjectsSpec`,
由**編排者**單線維護——D2:`.cabal` 不屬任何 feature 的寫入白名單)。

`cabal build aapms-workspace:lib:aapms-workspace` → **exit 0、零警告**
(2026-08-29 於 GHC 9.14.1 / Windows 實跑;八個模組全部編過,`Aapms.Workspace.Projects` 是
`[3 of 8]`)。

**2026-08-29 W4 閘門的三條裁決不動骨架一個字**:`registerProject` / `forgetProject` /
`allocateProjectId` 三條簽名原封不動(裁決 C 只是把第三條從「本 spec 提議」升格成契約 D 的一員),
而新增的兩個 `WorkspaceError` 建構子只出現在**函式本體**裡,骨架階段的本體全是 `undefined`,
連 import 都不必動(`WorkspaceError` 本來就是裸型別 import)。

## TodoList

- [ ] T1: `allocateProjectId`:自 `salt = 0` 起 `newId PPrj nm t salt`,與 `map peId existing`
  比對,撞號就 `salt + 1`,回第一個不撞的。純函式,不取時間、不讀檔 `dep: -`
- [ ] T2: `registerProject` 的**三條**前置檢查,順序固定「名稱 → 路徑存在 → 重複」:
  `T.strip name` 為空 → `InvalidName` 原字串;`canonicalizePath dir` 後 `doesDirectoryExist`
  為否 → `ProjectPathMissing (T.strip name) dir'`;`dir'` 逐字等於某一列的 `pePath` →
  `ProjectAlreadyRegistered (peId e0) (pePath e0)`(帶**既有那一列**的值)。三條路徑都不寫
  任何檔案 `dep: -`
- [ ] T3: `registerProject` 的主線:`getCurrentTime` → `allocateProjectId` → 組 `ProjectEntry`
  (`T.strip` 後的名稱 + 正規化後的路徑)→ `upsertProject` → `saveHub`;`saveHub` 失敗原樣
  回 `Left` `dep: T1, T2`
- [ ] T4: `forgetProject` 的 selector:兩階段命中集合(先 `renderId . peId` 後 `peName`,逐字
  精確比對)→ 1 / 多 / 0 三分支;**多 → `ProjectSelectorAmbiguous s E`(列出全部,兩階段同一套
  規則)、0 → `ProjectSelectorNotFound s`**,兩者都不動任何東西 `dep: -`
- [ ] T5: `forgetProject` 的主線:`removeProject (peId e)` → `saveHub`,回新的 `Hub` 與**被移除
  的那一列**;失敗原樣回 `Left` `dep: T4`

## 1-to-1 測試對照表

| Todo | Law / Example | 測試 |
|------|---------------|------|
| T1 | L1, L2, L3 / X1–X5 | `test_allocate_project_id_no_collision_uses_salt_zero`、`test_allocate_project_id_retries_on_collision`、`test_allocate_project_id_retries_twice`、`test_allocate_project_id_ignores_other_fields`、`test_allocate_project_id_shape_is_prj_plus_8_hex` |
| T2 | L6, L7, L9, L15, L16 / X9–X13, X17, X28–X30 | `test_register_project_blank_name_is_invalid_name`、`test_register_project_empty_name_is_invalid_name`、`test_register_project_missing_path`、`test_register_project_file_path_is_missing`、`test_register_project_name_checked_before_path`、`test_register_project_failure_writes_nothing`、`test_register_project_same_path_twice_is_already_registered`、`test_register_project_already_registered_detects_other_spelling`、`test_register_project_does_not_renormalize_existing_rows`、`test_render_already_registered_has_id_and_path` |
| T3 | L4, L5, L8, L10 / X6–X8, X14–X16, X18 | `test_register_project_success_fields`、`test_register_project_appends_at_end`、`test_register_project_stores_trimmed_name`、`test_register_project_normalizes_path`、`test_register_project_roundtrips_through_load_hub`、`test_register_project_preserves_comments_and_vaults`、`test_register_project_save_failure_is_forwarded` |
| T4 | L11, L12(b)(c), L13, L14 / X19, X21–X25, X31 | `test_forget_project_id_beats_name`、`test_forget_project_ambiguous_name_lists_all`、`test_forget_project_ambiguous_id_lists_all`、`test_forget_project_ambiguous_removes_nothing`、`test_forget_project_not_found`、`test_forget_project_is_case_sensitive`、`test_forget_project_does_not_trim`、`test_forget_project_ignores_other_sections` |
| T5 | L12(a), L15, L16 / X20, X26, X27 | `test_forget_project_removes_only_that_row`、`test_forget_project_leaves_project_dir_untouched`、`test_forget_project_roundtrips_through_load_hub`、`test_forget_project_save_failure_is_forwarded` |
| (全部) | L17 (a)–(e) | `test_projects_no_sibling_or_vault_imports`(a)、`test_projects_never_imports_store`(b)、`test_projects_core_id_import_is_allocation_only`(c,條件式:匯入清單必須是 `{Id, IdPrefix (PPrj), newId, renderId}` 的子集,`IdPrefix (..)`、`parseId`、`fnv1a64` 都要紅)、`test_projects_no_process_import`(d)、`test_projects_never_reads_manifests`(e)。**五條都只掃 import 行,比對前先去除行尾 `\r`** |

## 待確認假設

- A1: **同一個路徑註冊兩次的行為**(**已由 W4 裁決,見下第一個欄位;以下是交件時的原文**)
  ——本 spec 交件時暫採「得到兩列、兩個不同的 `peId`」,`registerProject`
  **不做路徑去重**。契約卡驗收標準 2 刻意寫成「二選一,但行為必須是確定的且被斷言」,把選擇留給
  這裡;而契約 B 的 `pePath` 值域也沒有寫「唯一」。
  - **2026-08-29 W4 閘門裁決:選 b**——契約 F 新增 `ProjectAlreadyRegistered Id FilePath`,
    帶既有那一列的 `peId` 與它的路徑。裁決理由:契約 B 對 `pePath` 沒有唯一性要求,所以暫採的 a
    在契約上合法——但中樞會出現兩列指同一個目錄,`projectList` 印兩次而 `forgetProject` 只刪一列;
    訊息要說出下一步(要改名就先 `forget` 再註冊)。`Types.hs` 的解凍由編排者指派,不在本
    feature 的白名單。**回寫位置**:功能概述的驗收標準 2 段、契約 F 段、資料流的 `registerProject`
    第三步、L4 的前提、L9 全文、X17 / X28 / X29 / X30、不可逆決定表第三列、T2、1-to-1 對照表
  - 契約錨點:design.md 契約 D 的 `registerProject`;契約 B 的 `ProjectEntry.pePath` 值域與
    `hubProjects`;契約 F(選項 b 需要一個**新的**建構子)
  - 層級自答:出現在邊界上?**會**(它是 `registerProject` 對 `service` 的可觀測行為,
    `project new` 打兩次會拿到什麼由它決定);改錯驚動其他模組?**要**(`service` 的
    `errorCode` 對照表、`shell` 的訊息、以及既有中樞檔案裡已經存在的重複列)
  - 選項:
    a) **兩列、兩個不同 id(本 spec 採用)**——當下成本:零,配號本來就保證不撞;三個月後代價:
       中樞可能出現兩列同路徑,`project list` 看起來像重複資料,而使用者要靠 `peId` 才分得出來
       ——但「這兩列其實是同一個專案」本來就不是註冊表擁有的事實(專案的真相在它自己的
       `manifest.json`,那是 `project` 子系統的),註冊表只記「我知道這些專案」
    b) **回一個明確的錯誤(例如 `ProjectAlreadyRegistered Id FilePath`)**——當下成本:**要在
       契約 F 新增一個建構子,也就是解凍 `Types.hs`**,而 W4 三個 feature 正在平行寫入同一個
       套件,D2 的併發前提正是「W2 之後沒人再碰 `Types.hs`」;沒有任何現有建構子表達得了這件事
       (`ProjectPathMissing` 說的是路徑不存在,`InvalidName` 說的是名稱)。三個月後代價:最小
       ——中樞永遠不會有兩列同路徑,語意最乾淨
    c) **冪等:同路徑已註冊時原樣回既有那一列,不新增也不報錯**——當下成本:要定義「同路徑」
       的判準(正規化後逐字相等?),而且要決定「路徑相同但名稱不同」時要不要改名;三個月後
       代價:`registerProject` 變成「有時新增、有時什麼都不做」,回傳的 `Hub` 與傳入的可能相同,
       呼叫端分不出「剛註冊好」與「早就註冊過」(這正是 `setupHub` 用 `spHubCreated` 解決的
       那個問題,而契約 D 沒給 `registerProject` 對應的欄位)
  - 傾向:a。理由是它是唯一**不需要動已凍結的 `Types.hs`**、也不需要新增回傳欄位的選項,而
    它的代價(可能出現兩列同路徑)落在一個註冊表本來就不擁有的事實上。依賴的前提:`service`
    的 `project new` 不會把「已註冊」當成必須攔截的錯誤——這一點由契約卡的「明確不做」佐證
    (「不產生、不同步、不驗證專案內容」:註冊表不對專案內容做判斷)。b 客觀上語意最乾淨,
    若編排者願意像 W3 那樣再解凍一次 `Types.hs`(當時為 `WriteTargetIdDrift`),b 值得選。
    可逆性:**有條件可逆**——從 a 改成 b 要加建構子 + 加一條 law + 改 L9 / X17;但**中樞檔案
    裡已經寫下的重複列不會自己消失**,改成 b 之後那些檔案仍然合法(`loadHub` 只查 `peId` 唯一),
    所以是「新行為對新註冊生效」,不是資料遷移
  - 暫採:a(兩列、兩個不同 id)→ 影響:若裁決成 b,`Types.hs` 加一個建構子與一則
    `renderWorkspaceError` 訊息(F001 的檔案,需編排者指派)、L9 整條改寫成「第二次回
    `Left`」、X17 的預期改掉、TodoList 的 T2 多一步前置檢查;若裁決成 c,L9 改寫成「第二次回
    `Right` 但 `hubProjects` 不變且 `peId` 相同」,並要在 spec 明寫「路徑相同名稱不同」怎麼辦

- A2: **`forgetProject` 的 selector 比對規則,以及命中兩列以上的處置**(**已由 W4 裁決,見下
  第一個欄位;以下是交件時的原文**)——本 spec 沿用 W2 對
  `lookupSelector` 的裁定(兩階段、逐字精確比對、不 trim、不忽略大小寫),但**命中兩列以上時
  回 `ProjectSelectorNotFound` 並不刪任何一列**,因為契約 F **沒有** project 版的 `Ambiguous`
  建構子。契約卡只寫了「以名稱或 id 都找得到;都找不到回 `ProjectSelectorNotFound`」,沒說撞名。
  - **2026-08-29 W4 閘門裁決:選 c**——契約 F 新增 `ProjectSelectorAmbiguous Text [ProjectEntry]`,
    帶 selector 字串與**全部**撞到的列。裁決採納了本條傾向裡自己點出的那句話(既然為 A1 要解凍
    `Types.hs`,這一條的邊際成本接近零),決定性理由是暫採的 a 會讓訊息說「找不到」,但它其實
    **找到了兩個**;而 vault 側早就有 `VaultSelectorAmbiguous`,專案側缺這一個本來就不對稱。
    selector 的比對規則**沿用 W2 為 `lookupSelector` 裁定的那一套**(兩階段逐字精確、不 trim、
    不忽略大小寫),與暫採相同。**回寫位置**:契約 F 段、資料流的 `forgetProject`、
    「命中兩列以上」那段散文、L12(b)、X21 / X31、不可逆決定表第四列、T4、1-to-1 對照表
  - 契約錨點:design.md 契約 D 的 `forgetProject` 第三參數值域(「非空;先比 `peId` 再比
    `peName`」);契約 C 的「`lookupSelector` 的比對規則」段(W2 裁決);契約 F 的
    `ProjectSelectorNotFound`,以及**不存在的** project 版 `VaultSelectorAmbiguous` 對應物;
    契約 B 的 `peName` 值域(只寫「非空」,沒寫唯不唯一)
  - 層級自答:出現在邊界上?**會**(它決定 `project forget X` 這個使用者輸入被接受還是被拒,
    那是 system.md 的對外 CLI 契約);改錯驚動其他模組?**要**(`service` 的 `errorCode` 對照表
    要不要多一個 code、`shell` 的訊息;而且 A1 選 a 之後**撞名是常態**,不是邊角情況)
  - 選項:
    a) **逐字精確比對 + 撞名時回 `ProjectSelectorNotFound` 且不刪(本 spec 採用)**——當下成本:
       零,不需要新建構子;三個月後代價:訊息會說「找不到符合『Circle』的專案」,而使用者眼前
       明明有兩個叫 Circle 的——訊息與事實不符,使用者要自己看 `project list` 才想得通。
       (既有訊息的後半「請確認 id 或名稱是否正確,或先執行 project list 查看可用的專案」
       剛好把他導向唯一能解決撞名的動作,所以誤導是有限的)
    b) **撞名時取第一列刪掉**——當下成本:零;三個月後代價:`project forget Circle` 會**靜默**
       刪掉兩個同名專案裡的其中一個,而 ADR-017 對「身分不確定」的一貫立場是不靜默帶過
       (`VaultIdCollision`、`loadHub` 的 `HubMalformed`、`lookupSelector` 的
       `VaultSelectorAmbiguous` 全都是這個立場)。這裡開一個例外,以後查起來會很難;而且
       「刪錯的那一列」使用者要重新註冊才救得回來(專案目錄沒事,但 id 換了)
    c) **在契約 F 新增 `ProjectSelectorAmbiguous Text [ProjectEntry]`,與 vault 那一組對稱**——
       當下成本:**要解凍 `Types.hs`**(同 A1 選項 b 的成本),外加一則 `renderWorkspaceError`
       訊息;三個月後代價:最小,而且 vault 與 project 兩組 selector 的行為完全同構,只要記
       一套規則
  - 傾向:a,但這是三個選項裡**最將就**的一個,若編排者本來就要為 A1 解凍 `Types.hs`,c 應該
    一起做(兩者共用同一次解凍,邊際成本接近零)。理由:b 違反系統一貫立場且有資料損失的方向性,
    直接排除;a 與 c 的差別只在訊息品質,而 a 不需要動凍結的檔案。依賴的前提:`project forget`
    的 selector 來自 `shell` 原樣傳入、不做正規化(ADR-015 第三條「`shell` 零業務邏輯」,由
    design.md 對外契約段的「`shell` 不直接 import 本套件」佐證)。可逆性:**可逆**——從 a 改成
    c 只是把一個 `Left` 換成另一個 `Left`,不會讓任何既有中樞檔變成非法,也不會讓原本成功的
    指令失敗
  - 暫採:a(逐字精確比對;撞名回 `ProjectSelectorNotFound` 且不刪)→ 影響:若裁決成 c,
    `Types.hs` 加一個建構子與訊息、L12(b) 的預期從 `ProjectSelectorNotFound` 改成
    `ProjectSelectorAmbiguous s E`(且要求列出**全部**命中列)、X21 的預期跟著改、
    1-to-1 對照表的 `test_forget_project_ambiguous_name_removes_nothing` 改斷言;
    若裁決成 b,L12(b) 整條改寫成「刪第一列」,X21 的預期從 `Left` 改成 `Right`

- A3: **`pePath` 的正規化方式與路徑存在性的判準**——本 spec 全篇把「正規化」釘死成
  `System.Directory.canonicalizePath`(沿用 W2 對 `vrPath` 的裁定),而「路徑必須存在」的判準是
  `doesDirectoryExist`(不是 `doesPathExist`)。契約 D 只寫「路徑必須存在(否則
  `ProjectPathMissing`)」,沒說怎麼算絕對化、也沒說普通檔案算不算存在。
  - **2026-08-29 W4 閘門:編排者降級,不上議程**——沿用 W2 為契約 C 的 `vrPath` 釘死的
    `canonicalizePath`,同一個子系統的兩個路徑欄位不得用兩種絕對化規則。暫採 a 維持不變,
    spec 一個字不必改;下列選項與代價原文保留備查
  - 契約錨點:design.md 契約 B 的 `ProjectEntry.pePath` 值域(「絕對路徑,指向含 `assets/` 與
    `story/` 的那一層」);契約 D 的 `registerProject` 第三參數值域;契約 C 的 `vrPath` 值域
    (W2 已為 vault 那一組釘死 `canonicalizePath`);契約 A 的「`loadHub` 的合規判準」
  - 層級自答:出現在邊界上?**會**(`pePath` 的值會被寫進中樞檔案、被 `hubProjects` 捧出來給
    `service`,而 `ProjectPathMissing` 帶的也是這個形式的路徑);改錯驚動其他模組?**要**
    (`loadHub` 會把非絕對路徑判成 `HubMalformed`;`project` 子系統之後要拿 `pePath` 去開
    `manifest.json`)
  - 選項:
    a) **`canonicalizePath` + `doesDirectoryExist`(本 spec 採用)**——當下成本:零(`directory`
       已在依賴清單);三個月後代價:symlink 會被解掉,使用者用 symlink 路徑註冊、之後在
       `project list` 看到的是實體路徑;Windows 上 8.3 短檔名被還原成長檔名。兩者都是「顯示的
       不是我打的那個字串」,但都是**工具真正去看的那個位置**
    b) **`makeAbsolute` + `doesDirectoryExist`**——當下成本:零,而且與 graph-core 的
       `initVaultAt`(`Marker.hs:136` 用 `makeAbsolute`)一致;三個月後代價:`D:\games\..\games\Circle`
       與 `D:\games\Circle` 是兩個不同的字串,A1 選 a 之後這兩列會並存且看起來毫無關係;
       測試裡 `canonicalizePath` 過的 fixture 路徑與回傳值逐字不等,會出現看起來莫名其妙的紅燈
       (W2 已經為 vault 那一組付過這個學費)
    c) **`canonicalizePath` + `doesPathExist`**(普通檔案也算「存在」)——當下成本:零;
       三個月後代價:一個檔案被註冊成專案根,錯誤要等到 `project` 子系統去開
       `assets/manifest.json` 才爆,而那時的訊息與「你註冊錯了」相距很遠
  - 傾向:a。理由是 W2 已經為同一個子系統的路徑欄位釘死 `canonicalizePath`,兩個路徑欄位用兩種
    絕對化規則是「同一個系統兩種行為」;而 `doesDirectoryExist` 直接對應契約 B 的值域(「指向含
    `assets/` 與 `story/` 的那一層」= 目錄)。依賴的前提:`canonicalizePath` 對不存在的路徑不拋
    例外(W2 在本機 GHC 9.14.1 / Windows 實測確認過),所以「先正規化再判存在」是安全的順序
    ——這一點在 F002 的「正規化」段有實測紀錄。可逆性:**有條件可逆**——改成 b 只要換一個函式,
    但**已經寫進中樞檔案的路徑不會自己變回去**,那些列會保持解過 symlink 的形式
  - 暫採:a → 影響:若裁決成 b,L4(c) / L7 / X14 的「正規化」全部改指 `makeAbsolute`,並要在
    spec 明寫「兩種寫法的同一個目錄會產生兩列」;若裁決成 c,L7 與 X12 改寫(普通檔案改成
    成功註冊),並要說明錯誤延後到 `project` 子系統爆的後果

- A4: **名稱的處置**——(i) `T.strip name` 為空時回 `InvalidName`(帶**原始字串**),且這個檢查
  **先於**路徑檢查;(ii) 存進中樞的 `peName` 是**去空白後**的字串,不是原字串。契約 D 的值域表
  只寫「名稱去空白後長度 ≥ 1」,沒說存哪一個形式;契約卡的「實作的 Level 2 介面」欄**漏列了
  `InvalidName`**。
  - **2026-08-29 W4 閘門:編排者降級,不上議程**——決定性理由不在本 spec 的分析裡:
    **W2 已裁定 `lookupSelector`(以及沿用它的 `forgetProject`)是逐字精確比對,存未 trim 的
    名稱會讓它永遠選不到**。也就是說 trim 是被前一條裁決**逼出來**的,不是一個新選擇。暫採 a
    維持不變,spec 一個字不必改;下列選項與代價原文保留備查。跨 feature 對帳:本 spec 與 F004
    對 `initVault` 第五參數的寫法一致,兩者沒有分岔
  - 契約錨點:design.md 契約 D 的 `registerProject` 第四參數值域(**與 `initVault` 第五參數
    共用同一句話**,所以這條同時波及 F004);契約 F 的 `InvalidName Text`(「收到的原始字串」)
    與 `ProjectPathMissing Text FilePath`(第一個值是專案名);契約 B 的 `peName` 值域(「非空」);
    契約卡 `project-registry` 的「實作的 Level 2 介面」欄
  - 層級自答:出現在邊界上?**會**(`peName` 的值會被寫進中樞檔案,而 `forgetProject` 又拿它做
    逐字比對——存原字串就代表使用者要打出前後空白才刪得掉);改錯驚動其他模組?**要**
    (F004 的 `initVault` 共用同一句值域規定,而 vault 的名稱還會被寫進 marker;兩個 feature
    互相看不見,不對齊就會分岔)
  - 選項:
    a) **存 `T.strip` 後的字串,空名回 `InvalidName` 原字串,名稱檢查先於路徑檢查(本 spec
       採用)**——當下成本:零;三個月後代價:使用者打 `project new " Circle "` 之後,中樞裡
       是 `Circle`,他下次要 `project forget Circle`——一致;但「工具改了我輸入的字串」這件事
       沒有任何地方告訴他
    b) **原樣存 `name`(不 trim),只用 `T.strip` 判空**——當下成本:零,而且與 `loadHub` 對
       手寫檔案的處置一致(`parseProjectEntry` 只檢查 `T.strip` 後非空,存的是原字串,
       `Hub.hs:166-169`);三個月後代價:`" Circle "` 存進去之後,`forgetProject "Circle"`
       **找不到**(L13 是逐字比對),使用者必須連空白一起打;而中樞是可手寫的檔案,他也看不出
       名字前後有空白
    c) **完全不 trim,空白字串也接受**——當下成本:零(連 `InvalidName` 都不用產生);
       三個月後代價:契約 B 的 `peName` 值域「非空」被打破,而 `loadHub` 會把這份自己寫出來的
       中樞判成 `HubMalformed`——工具寫出一份自己讀不回來的檔案
  - 傾向:a。理由是 c 直接違反契約(自己寫出讀不回來的中樞),而 b 讓「註冊時打的名字」與
    「撤除時要打的名字」不是同一個字串——那正是 selector 逐字比對(A2 選 a)的直接代價。
    `loadHub` 對**手寫**檔案原樣保留是另一回事:那是「不改使用者親手寫下的字」,而
    `registerProject` 是工具自己在寫這一列。依賴的前提:`ProjectPathMissing` 帶的名稱應該是
    使用者認得的那一個(去空白後的),這由驗收標準 5「訊息含專案名」佐證。可逆性:**可逆**
    ——改成 b 只影響新註冊的列,既有中樞檔案兩種形式都合法
  - 暫採:a → 影響:若裁決成 b,L4(b) / X8 的預期改成「`peName e == name` 原字串」,並要在
    spec 明寫「前後有空白的名稱要連空白一起打才刪得掉」;若裁決成 c,L6 / X9 / X10 整組刪掉,
    並要同時修契約 B 的 `peName` 值域與 `loadHub` 的合規判準(那會動到 F001 已交付的
    `Hub.hs`)。**無論裁哪一個,都應同時套用到 F004 的 `initVault` 第五參數**

- A5: **配號抽成一條匯出的純函式 `allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id`**,
  `registerProject` 自己取 `getCurrentTime` 再傳進去。契約卡沒有答案,是因為這不是卡片漏寫,而是
  design.md **兩處互相矛盾**:「模組間公開介面」的 `Projects → aapms-core` 那一列寫著「時間由
  呼叫端給」,但契約 D 的 `registerProject` 簽名**沒有時間參數**——時間只能在函式內部取樣,
  而那樣一來驗收標準 1 的後半(「撞號時以 salt 遞增重試,不靜默照發」)**寫不出任何測試**。
  - **2026-08-29 W4 閘門裁決:選 a**,而且**升格**——`allocateProjectId` 不只進「模組間公開
    介面」表,直接收進**契約 D**(design.md 契約 D 的程式碼區塊已補上這一行,註記「時間明碼,
    salt 重試才測得到」)。裁決理由與 graph-core `allocateId` 的 2026-08-25 G8 裁決逐字相同;
    `registerProject` 的簽名一個字不動,本 spec 指出的 design.md 內部矛盾因此消解。
    **回寫位置**:契約 D 段(兩項 → 三項)、模組間公開介面段的引言塊、新增的介面表、
    不可逆決定表第二列、骨架段
  - 契約錨點:design.md「模組間公開介面」表的 `Projects → aapms-core` 那一列(`newId PPrj`,
    「時間由呼叫端給;唯一性由 Projects 對中樞既有 `peId` 重試保證」);契約 D 的
    `registerProject` 簽名;新增符號 `allocateProjectId`;graph-core 契約 E 的
    `allocateId :: VaultHandle -> IdPrefix -> Text -> UTCTime -> IO (Either StoreError Id)`
    (同一個問題在 graph-core 的既有裁決)
  - 層級自答:出現在邊界上?**會**(它是 `Aapms.Workspace.Projects` 的匯出清單多出來的一條,
    design.md 的模組間公開介面表要多一列);改錯驚動其他模組?**要**(它是驗收標準 1 的唯一
    可測落點,拿掉之後 qa 只能斷言「回傳的 id 不在既有集合裡」,重試迴圈本身無法觀測——
    這正是 graph-core 2026-08-25 G8 裁決逐字反對的情況)
  - 選項:
    a) **抽成匯出的純函式(本 spec 採用)**——當下成本:模組匯出清單多一條、design.md 的模組間
       公開介面表要多一列;三個月後代價:多一個對外可見的符號要維護,而它的唯一消費者是
       `registerProject` 與測試——若日後 `registerProject` 的配號規則改變,這條也要跟著改
       (兩者的一致性由 L2 + L4(a) 兩條 law 釘住)
    b) **整段藏在 `registerProject` 裡,不匯出**——當下成本:零,匯出清單最小;三個月後代價:
       salt 重試迴圈**永遠測不到**——碰撞在正常情況下幾乎不發生,那段程式碼可能永遠是錯的而
       沒人知道(graph-core `allocateId` 的 Haddock 逐字寫著這個理由)。驗收標準 1 的後半會
       變成一條寫不出斷言的條文,也就是一條必然發生的 spec-gap
    c) **在 `registerProject` 的簽名加一個 `UTCTime` 參數**,與 `allocateId` 完全同構——當下
       成本:**要改契約 D 的對外簽名**,而 `service` 是它的直接消費者;三個月後代價:最小,
       整個系統的配號一律「時間由呼叫端給」,只有一種心智模型;但改對外契約是本 feature 唯一
       一處會動到 `service` 介面的地方
  - 傾向:a。理由是它在**契約 D 一個字不動**的前提下拿到與 c 相同的可測性,而 b 的代價是一條
    驗收標準直接失去斷言。依賴的前提:把配號從 `registerProject` 抽出來之後,「唯一性由 Projects
    對中樞既有 `peId` 重試保證」這句話仍然成立——成立,因為 `registerProject` 傳給它的正是
    `hubProjects hub`,而 L4(a) 把這件事釘成 law。**這不是測試後門**:配號是 Projects 擁有的
    事實(design.md「內部模組劃分」的 Projects 職責就寫著「`prj-` 配號」),把它做成一個具名的
    純函式是知識歸屬的正常結果,不是為了測試而開的洞。可逆性:**可逆**——把它改回私有只要從
    匯出清單拿掉,`registerProject` 的簽名與行為完全不變(代價是那幾條測試要一起刪)
  - 暫採:a(匯出 `allocateProjectId`,`registerProject` 內部取 `getCurrentTime`)→ 影響:
    若裁決成 b,骨架刪掉第三條簽名、L1 / L2 / L3 改寫成只能間接觀測的形式(只剩「不撞既有」與
    「前綴恒為 `prj-`」)、X1–X5 整組刪掉,並要在 spec 明寫「salt 重試迴圈無法被測試覆蓋」;
    若裁決成 c,契約 D 的 `registerProject` 加一個 `UTCTime` 參數(design.md + `service` 的
    呼叫端都要改),`allocateProjectId` 可以保留也可以併回去

- A6: **「同一個路徑」的判準**——本 spec 以「這次正規化後的 `dir'` **逐字等於**中樞某一列的
  `pePath`」為 `ProjectAlreadyRegistered` 的觸發條件,**不對既有列重新正規化**。這是 W4 裁決
  (A1 選 b)**新造出來**的一個縫:裁決給了建構子與訊息,但沒有定義「同一個路徑」怎麼算,而那
  正是它唯一的觸發條件——不定義就是把一條 spec-gap 留到仲裁那一輪。
  - 契約錨點:契約 F 的 `ProjectAlreadyRegistered Id FilePath`(W4 新增)的**觸發條件**;
    契約 B 的 `ProjectEntry.pePath` 值域(「絕對路徑」——**沒有**說「正規化後的絕對路徑」);
    契約 A 的「`loadHub` 的合規判準」(只驗 `isAbsolute`,不驗正規化);契約 D 的 `registerProject`
  - 層級自答:出現在邊界上?**會**(它決定 `registerProject` 什麼時候回 `Right`、什麼時候回
    `ProjectAlreadyRegistered`,那是 W4 裁決剛剛新增的對外行為);改錯驚動其他模組?**要**
    (`loadHub` 對 `pePath` 只驗 `isAbsolute`,選項 c 會反過來要求它多驗一件事,而 `Hub.hs` 是
    F001 的檔案)
  - 選項:
    a) **逐字比對正規化後的新路徑 vs 既有列的 `pePath` 原文(本 spec 採用)**——當下成本:零,
       純字串比對、不多做任何 IO;三個月後代價:中樞裡**手寫的、未正規化**的絕對路徑
       (`D:/games/../games/Circle`)擋不住,那個目錄仍能被註冊成第二列——而重複列正是 W4 裁決
       要消滅的東西,所以這個洞是裁決意圖的一個缺口(已由 X29 明文斷言,不是靜默的行為)
    b) **對既有每一列的 `pePath` 也跑一次 `canonicalizePath` 再比**——當下成本:每次註冊多 N 次
       檔案系統 IO;三個月後代價:`canonicalizePath` 對**不存在**的路徑雖然不拋例外(W2 實測),
       但它對已刪除目錄的輸出是「字串層面解 `.` / `..`」而非真實解析,同一列在目錄存在與不存在
       時可能得到不同結果——於是「這次擋不擋得住」會取決於**別的專案目錄還在不在**,那是一條
       很難解釋的行為;而且純函式的部分被拖進 IO
    c) **把「`pePath` 必須是正規化後的路徑」升進契約 B 的值域,由 `loadHub` 驗**——當下成本:
       要改 F001 的 `Hub.hs`(`parseProjectEntry` 多驗一條)與契約 B 的值域欄;三個月後代價:
       最小,判準恒成立,a 的缺口消失。但它會讓**手寫**的中樞更難寫(使用者要自己寫出正規化
       後的路徑,寫錯就是 `HubMalformed`),而 ADR-017 決策二把「可手寫」列為中樞的性質
  - 傾向:a。理由是缺口只出現在「使用者手寫了一個未正規化的絕對路徑」這條路徑上,而由
    `registerProject` 寫出去的列**永遠是正規化後的**(L4(c)),所以工具自己產生的資料一定擋得住;
    b 引入的「行為取決於別的目錄還在不在」比它要解決的問題更難解釋;c 客觀上最乾淨,但它拿
    「可手寫」去換,而那是 ADR-017 明文的性質。依賴的前提:`loadHub` 不會把未正規化的絕對路徑
    判成不合規——成立,`parseProjectEntry` 只呼叫 `isAbsolute`(相依性查證 1)。
    可逆性:**可逆**——改成 b 或 c 只會讓原本成功的第二次註冊變成 `Left`,不會讓任何既有中樞檔
    變成非法(c 除外:c 會讓既有的手寫未正規化列變成 `HubMalformed`,那是**破壞性**的,要配
    遷移說明)
  - 暫採:a → 影響:若裁決成 b,L9 的判準句改寫成「對既有列也正規化後再比」、X29 的預期從
    `Right` 改成 `Left (ProjectAlreadyRegistered ...)`;若裁決成 c,除上述之外還要改 F001 的
    `Hub.hs` 與契約 B 的 `pePath` 值域,並補一條「既有手寫中樞可能因此變成 `HubMalformed`」的
    遷移說明

## 實作備註

### 2026-08-29 W4 閘門裁決的回寫

三條裁決影響本 feature,已逐處回寫(對照見上面 A1 / A2 / A5 各自的「W4 閘門裁決」欄):

| 裁決 | 對應的假設 | 結果 |
|---|---|---|
| A | A1 | 選 **b**:同路徑重複註冊回 `ProjectAlreadyRegistered Id FilePath`(契約 F 新增) |
| B | A2 | 選 **c**:撞名 / 撞號回 `ProjectSelectorAmbiguous Text [ProjectEntry]`(契約 F 新增);比對規則沿用 W2 的 `lookupSelector` |
| C | A5 | 選 **a** 並**升格進契約 D**:`allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id` |

另外三件事:

- **A3 / A4 由編排者在閘門降級**,不上議程。A4 的決定性理由不在本 spec 原本的分析裡:
  W2 已裁 `lookupSelector` 逐字精確比對,**存未 trim 的名稱會讓它永遠選不到**——trim 是被前一條
  裁決逼出來的,不是新選擇。兩條的暫採都維持,選項與代價原文保留備查
- **`quoteText` 的缺陷裁決「現在修」**(由 F001 的 impl 執行),因此 **L8 的往返 law 拿掉了
  「名稱不含換行與其他控制字元」的定義域限制**,回到完整定義域;條文與「紅綠預期」都註明了
  它是在那次修正之後才成立的,以及紅了要歸因給誰
- **A6 是本次回寫新增的假設**:W4 的裁決給了 `ProjectAlreadyRegistered`,但沒有定義「同一個
  路徑」怎麼算,而那是它唯一的觸發條件。不定義就會變成一條必然發生的 spec-gap

**骨架與三條簽名一個字未動**;新增的兩個 `WorkspaceError` 建構子只出現在函式本體裡,
它們的宣告與訊息由編排者指派給 `Types.hs` 的維護者。
