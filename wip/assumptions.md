# 待確認假設(ASM)盤點與 spec-gaps 未結案清單

> 掃描範圍:`.design/subsystems/{graph-core,service,workspace}/features/F00x-*.md`(status 為 `done` 者)
> 與三份 `spec-gaps.md`。**未讀 `.design/legacy/`**。
> 判定方式:逐條看 ASM 條目本文的狀態標記,並回頭查同一份文檔的
> `## 修訂記錄` / `## 決定` / `## 實作備註` / `## 已裁決紀錄` 是否已在別處結掉。
> 引用一律逐字,不改寫。

## 一、對帳

| 子系統 / 文檔 | ASM 總數 | 已結案 | **未結案** |
|---|---|---|---|
| graph-core/F001-core-unified-meta | 3 | 0 | **3** |
| graph-core/F002-registry-family-and-naming | 6 | 1 | **5** |
| graph-core/F003-manifest-schema-v2 | 4 | 4 | 0 |
| graph-core/F004-md-unified-sections | 12 | 5 | **7** |
| graph-core/F005-store-vault-handle | 6 | 0 | **6** |
| graph-core/F006-store-unified-index | 10 | 1 | **9** |
| graph-core/F007-store-fts-dual-index | 5 | 1 | **4** |
| graph-core/F008-store-write-operations | 6 | 6 | 0 |
| graph-core/F009-store-multi-vault-read | 6 | 6 | 0 |
| service/F001-service-env-and-scope | 3 | 3 | 0 |
| service/F002-workspace-facade | 4 | 4 | 0 |
| workspace/F001-hub-registry | 3 | 0 | **3** |
| workspace/F002-vault-discovery | 2 | 0 | **2** |
| workspace/F003-scope-resolution | 1 | 1 | 0 |
| workspace/F004-vault-lifecycle | 8 | 8 | 0 |
| workspace/F005-project-registry | 6 | 5 | **1** |
| workspace/F006-machine-tools | 5 | 5 | 0 |
| **合計** | **90** | **50** | **40** |

`service/F003`–`F008` 六份是 `status: planned` 的骨架(僅 `## 契約` 一節),沒有 `## 待確認假設`,不計入。

**與遷移帳本「45 條還在檔上」的差異**:帳本(`wip/migrate-ledger.md:147`)的 45 是機械掃描數,
本次逐條人判得到 **40 條未結案**。差額來自帳本的掃描沒有讀條目內文的裁決標記,例如:
`graph-core/F002` 的 ASM-1(條目標題就寫「**已裁決**,2026-08-23 階段一閘門」)、
`graph-core/F006` 的 ASM-1(「已由開發者裁決並落地,不再是待確認項」)、
`graph-core/F007` 的 ASM-3(「2026-08-24 依開發者裁決改寫」)、
`graph-core/F004` 段末那行「**ASM-11 / ASM-12 已於 2026-08-25 裁決**」以及
`workspace/F005` 五條條目內嵌的「2026-08-29 WAVE-4 閘門裁決」欄——這些條目仍留在
`## 待確認假設` 標題底下(留作決策紀錄),機械掃描會把它們算成「還在檔上」。
另有一類邊界案:`workspace/F004`(5 條)、`workspace/F006`(4 條)、`workspace/F005`(2 條)
的處置是「**編排者降級,不上閘門,暫採即定案**」——本報告視為已結案(有明確處置),
若把「降級」也算成未決,未結案會變成 51 條。無論怎麼算,都湊不出剛好 45;
**建議以本報告的逐條清單取代那個數字**。

---

## 二、未結案假設(40 條)

### `.design/subsystems/graph-core/features/F001-core-unified-meta.md`

整份 `## 待確認假設` 三條都沒有任何裁決標記;`## 實作備註` 只記實作偏差,未回答其中任何一條。

#### ASM-1

**涉及**:`MetaWarning` 的建構子清單 / `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]`(`Meta.hs`)

**要裁決什麼**:`MetaWarning` 的四個建構子就是最終清單,還是要為「型別未宣告 `dir`」之類再加建構子?(是/否)

```
- ASM-1: `MetaWarning` 的確切建構子清單(`MissingRequiredField` / `LinkNotAllowed` / `UnknownNodeType` /
  `NameKindNotAllowed`)是依 F002 契約卡驗收標準文字(「`checkMeta` 對 asset 檢查 `name` 第一段在該
  型別的 `name_kinds` 內、關聯在 `allowed_links` 內」)反推的最小合理形狀,`checkMeta` 本身**不**在
  本 feature 實作 → 採取:先把型別骨架放進 `Meta.hs` 供後續 import,`checkMeta` 的呼叫邏輯與
  `TypeRegistry` 相依留給 #2 → 影響:若 #2 需要更多警告種類(例如型別未宣告 `dir`),`MetaWarning`
  要加建構子,不影響 F001 已完成的其餘型別
```

#### ASM-2

**涉及**:`Aapms.Core.Graph` 的 `buildGraph` / `follow` / `supersededSet` / `contradictionPairs`;`LinkGraph` 型別別名(併入 `Link.hs`)

**要裁決什麼**:這四個純函式確認永久不進 `aapms-core` 契約 B(留給日後 `conflict` 子系統)嗎?(是/否)

> **注意**:`graph-core/F002` 的 `## 實作備註` 有一句「只有 `Graph`(F001 的待確認假設 ASM-2,確認不沿用)永久不該出現」,
> 已把 `CabalSpec.hs` 的斷言照 ASM-2 的採取寫死。這是實作端的確認,**不是閘門裁決**,ASM-2 條目本身未動——
> 可視為「幾乎可直接結案」的一條。

```
- ASM-2: `Aapms.Core.Graph` 的 `buildGraph` / `follow` / `supersededSet` / `contradictionPairs` 四個
  純函式判定為**不在**本次 Level 2 契約範圍(design.md 契約 B 與「內部模組劃分」都沒有列出),
  只留 `LinkGraph` 型別別名 → 採取:刪除四個函式與 `GraphSpec.hs`,`LinkGraph` 併入 `Link.hs` →
  影響:若編排者認為這四個函式仍是「三條管線共用的型別層」該提供的能力(例如衝突偵測子系統設計
  時想直接沿用),需要回頭修 `design.md` 契約 B 補上這幾個函式簽名,再開一個小 feature 或併入
  日後的 `conflict` 子系統設計時原樣移植
```

#### ASM-3

**涉及**:`core/test/Aapms/Core/CabalSpec.hs` 的禁用套件清單(非函式,是測試守門的判準)

**要裁決什麼**:禁用套件維持「逐字 8 個名字」的白/黑名單,不做分類判斷,接受漏網風險?(是/否)

```
- ASM-3: `aapms-core.cabal` 的 `CabalSpec.hs` 禁用清單固定抄 design.md「使用的技術」一節逐字列出的
  8 個套件名,不做「凡出現 IO / SQLite / 壓縮 / 影像類套件就擋」的模糊分類判斷(那需要套件分類
  知識庫,超出本 feature 範圍)→ 採取:逐字清單,新出現的違規套件名不會被這條測試攔下 → 影響:
  若日後 `aapms-core` 意外多相依一個沒列在清單裡的重量級套件,這條測試不會變紅,需要人工發現後
  補清單
```

---

### `.design/subsystems/graph-core/features/F002-registry-family-and-naming.md`

ASM-1 已於 2026-08-23 階段一閘門裁決(條目標題自帶「**已裁決**」)。ASM-2–ASM-6 五條無裁決標記,`## 實作備註` 未回答任何一條。

#### ASM-2

**涉及**:`validateLogicalName`(是否吃 `TypeKey`)、`checkMeta`、`NamingVocab.nvKinds :: [Segment]`

**要裁決什麼**:`validateLogicalName` 確定只做語法 + `nvKinds` 全域成員檢查、型別專屬的 `name_kinds` 一律只由 `checkMeta` 出警告嗎?(是/否;答「否」要重塑 `NamingVocab`,屬契約 C 變動)

```
- ASM-2:`validateLogicalName` 的 `TypeKey` 參數,在契約卡「`checkMeta` 對 asset 檢查 name 第一段在
  該型別的 `name_kinds` 內……**只回警告**」與「明確不做:不決定警告要不要擋」兩句之間,若
  `validateLogicalName`(回傳硬錯誤 `Either NameError ()`)也做同一件事的型別專屬檢查,會與
  「只警告」的立場矛盾。→ 採取:`validateLogicalName` 只做語法 + `nvKinds` 全域成員檢查,不吃
  `TypeKey` 做型別專屬過濾,型別專屬的 `name_kinds` 檢查完全交給 `checkMeta` → 影響:若編排者
  認為 `validateLogicalName` 確實該依 `TypeKey` 做硬性型別過濾(例如未來某處需要在寫入前**拒絕**
  而非僅警告一個名稱），需要重新設計 `NamingVocab` 的形狀(讓它能依 `TypeKey` 查到專屬
  `name_kinds`,目前的 `nvKinds :: [Segment]` 是扁平清單做不到),屬於契約 C 的變動
```

#### ASM-3

**涉及**:`tdNameKinds` 空清單的語意、`checkMeta` 的 `NameKindNotAllowed` 分支、型別 `asset-archive`

**要裁決什麼**:`tdNameKinds == []` 沿用 `allowed_links` 的「未宣告限制」語意(不產生警告)嗎?(是/否)

```
- ASM-3:`tdNameKinds` 為空清單時的語意,契約卡與驗收標準都沒有明講(只講「非空時檢查成員」)。
  `asset-archive` 依 DEC-5 的對照表算出來剛好是空清單(legacy `KindPrefix` 沒有任何值對應
  `KArchive`)。→ 採取:比照既有 `allowed_links` 空清單 = 「未宣告限制」的慣例(舊
  `checkEntity`/`badLinks` 明寫「`etsAllowedLinks` 為空視為未宣告限制」),`tdNameKinds` 空清單
  時 `checkMeta` 不對該型別的 asset 產生 `NameKindNotAllowed` → 影響:若編排者認為
  `asset-archive` 應該完全不允許被命名(任何 `name` 都是警告),需要把「空清單」的語意反過來,
  且要另外決定 `asset-archive` 的 `name_kinds` 該填什麼非空值(目前的來源資料——legacy
  `KindPrefix`——就是沒有這個值)
```

#### ASM-4

**涉及**:`parseLogicalName` 的拆解演算法步驟②(legacy `peel` 的「不剝到清空」guard)

**要裁決什麼**:`spr_char_up` 這種「subject 撞上 `nvStates` 詞彙」的輸入要解析成功(保留 guard)還是回錯誤?(保留 guard = 是/否)

```
- ASM-4(新增,ASM-1 推翻後浮現的演算法完整性問題):design.md「命名文法的拆解規則」字面上四步驟沒有
  提到 legacy `peel` 函式的「不剝到清空」guard。若照字面實作,單獨一段的 subject 剛好撞見
  `nvStates` 的詞(如 `spr_char_up`,`domain`後只有一段 `up` 且沒有任何 variant/state/index),
  步驟②會把它誤剝成 `npState`,剝完 `remaining` 淨空,步驟③「剩下的一段」不存在,結構上會被判成
  `TooFewSegments`——但這其實是一個完全合法的名稱(`subject = "up"`,沒有 modifier)。
  → 採取:比照 legacy `peel` 的 guard,②的剝除只在「剝掉後 `remaining` 還留得下至少一段」時才
  發生,否則整段留給 subject(見「實作方式」演算法步驟 3b、待驗證的 STEP-9 邊界案例)→ 影響:這是純
  演算法層級的補強,不改變任何契約簽名或 `naming-cases.txt` 既有案例的結果;若編排者認為「subject
  不該與 state 詞彙撞名,撞了就該是使用者的錯」,則這個 guard 要拿掉,`spr_char_up` 這類輸入改成
  回錯誤而非解析成功——這是行為選擇,不是正確性問題,兩種都自洽
```

#### ASM-5

**涉及**:`mkLogicalName` / `renderParts` / `parseLogicalName` 的往返性質(`renderParts . parseLogicalName == id`)

**要裁決什麼**:接受「呼叫端把 state 詞放進 `npVariant` 會發生語意標籤漂移」而不在 `mkLogicalName` 加檢查嗎?(是/否)

```
- ASM-5(新增):`mkLogicalName` 允許呼叫端手工建構 `NameParts`(不是每次都經過 `parseLogicalName`)。
  若呼叫端把一個剛好在 `nvStates` 內的詞放進 `npVariant`(而非 `npState`),`mkLogicalName` 目前
  **不會**拒絕它(`npVariant` 開放、不查表是刻意設計)——但 `renderParts` 產生的字串經
  `parseLogicalName` 重新拆解時,那段文字會依規則②被歸類成 `npState`,與原始 `NameParts` 的欄位
  標籤不一致(值不變,語意標籤變了)。→ 採取:不視為錯誤——契約與 STEP-9 承諾的是
  `renderParts . parseLogicalName == id`(parse 之後 render 拿回原字串),不是「render 之後 parse
  拿回原始語意標籤」;`npVariant` 的文件字串已經明講「開放,不查詞彙表」,呼叫端若把 state 詞放
  進 `npVariant` 是自找的語意漂移,不是本 feature 的契約義務 → 影響:若編排者認為這個漂移
  不可接受(例如某處依賴「我建構時標的是 variant,讀回來也該是 variant」的不變量),需要在
  `mkLogicalName` 加一條檢查:`npVariant` 不可為 `nvStates` 成員,回一個新錯誤建構子
```

#### ASM-6

**涉及**:`checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` 的簽名、`badNameKind` 取 kind 的方式

**要裁決什麼**:`checkMeta` 的契約簽名確定不加 `NamingVocab` 參數、`badNameKind` 就用「切第一個 `_` 之前」的字串取 kind 嗎?(是/否)

```
- ASM-6(新增):`checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` 的契約簽名沒有 `NamingVocab`
  參數,但 ASM-1 裁決後 `parseLogicalName` 需要它,`badNameKind` 因此不能再呼叫完整
  `parseLogicalName` 取得 `npKind`。→ 採取:`badNameKind` 改成直接切 `LogicalName` 文字第一個
  `_` 之前的片段當 kind 文字用,不重新驗證合法性(`astName :: LogicalName` 的唯一建構路徑是
  `mkLogicalName`,已經保證第一段是 `nvKinds` 成員,見「實作方式」的 `checkMeta` 小節)→ 影響:
  若編排者認為 `checkMeta` 未來需要更完整的命名文法資訊(例如也要對 `npState`/`npVariant` 做型別
  專屬檢查),`checkMeta` 的契約簽名要加一個 `NamingVocab` 參數,屬於契約 B 的變動
```

---

### `.design/subsystems/graph-core/features/F004-md-unified-sections.md`

ASM-8 / ASM-9 / ASM-10 / ASM-11 / ASM-12 已於 2026-08-25 spec 閘門裁決(見同檔 `## 已裁決紀錄(2026-08-25 spec 閘門)`)。
ASM-1–ASM-7 七條**沒有**裁決欄,`## 實作備註` 是「(撰寫時留空;開發過程中與設計的偏差記錄於此)」——什麼都沒寫。

#### ASM-1

**涉及**:`MetaExtras` / `extrasOf` / `extrasAt` / `mergeExtras` / `updateSectionExtras` / `payloadOverride` / `payloadExtras`;`renderMetaBlock` 與 `mkSection` 的新簽名(吃兩半)

**要裁決什麼**:這七個契約 D 逐字清單之外的公開介面要補進 design.md 契約 D(全部保持公開),還是把其中五個降成內部函式?(補進契約 = 是/否)

```
- **ASM-1**:新增七個契約 D 逐字清單之外的公開介面(`MetaExtras` / `extrasOf` / `extrasAt` /
  `mergeExtras` / `updateSectionExtras` / `payloadOverride` / `payloadExtras`),並把
  `renderMetaBlock` / `mkSection` 的簽名改成吃兩半。→ 採取:照做,並請編排者把它們補進 design.md
  契約 D。依據:(a) 只要 `renderMetaBlock` 還存在一個「只吃 `MetaOverride`」的公開版本,GAP-2 就只是
  被繞過而不是被消滅——型別上必須寫不出來;(b) 契約 E 的 `writeAssetFields` / `upsertLicense` 要改的
  正是型別專屬那一半,而 `(MetaOverride -> MetaOverride)` 表達不了,不補這條路 F008 會再撞一次牆。
  → 影響:若編排者判定 md 的公開面必須嚴格等於契約 D 逐字清單,`extrasAt` / `mergeExtras` /
  `updateSectionExtras` / `payloadOverride` / `payloadExtras` 可改成非 export 的內部函式,但
  `MetaExtras` 與 `renderMetaBlock` 的新簽名不能退回——那是缺陷修復本身。屆時 F008 需要另一條寫入
  型別專屬欄位的管道,要回 `/subsys-design` 更新契約 D。
```

#### ASM-2

**涉及**:`renderMetaBlock` 的欄位排序、`updateSection`、LAW-8(冪等)

**要裁決什麼**:接受「第一次 `updateSection` 會重排既有檔案 meta 區塊行序」嗎?(是/否)

```
- **ASM-2**:型別專屬條目一律排在 `Meta` 欄位之後,因此**第一次** `updateSection` 會重排既有檔案 meta
  區塊的行序(資料不變,排版變)。→ 採取:接受,並以 LAW-8(冪等)保證只重排一次。依據:見「不可逆
  決定」第 3 條。→ 影響:若判斷錯誤(要求既有檔案的行序原樣不動),`MetaExtras` 要改成帶「原本
  夾在哪兩個 `Meta` 欄位之間」的位置資訊,`renderMetaBlock` 的合併規則跟著改;`appendSection` 產生
  的新節仍需要一套預設順序,兩條路徑會分岔。
```

#### ASM-3

**涉及**:`payloadOverride`、`NSNode.nnKind` vs `MetaOverride.moKind`、LAW-16

**要裁決什麼**:`nnKind` 是 `kind` 的唯一真相來源、一律覆蓋 `moKind` 嗎?(是/否)

```
- **ASM-3**:`NSNode` 的 `nnKind` 是 `kind` 的唯一真相來源,`payloadOverride` 一律以它覆蓋 `moKind`。
  → 採取:照做(LAW-16)。依據:契約 D 的 `NSNode` 同時帶 `MetaOverride` 與 `NewNode`,兩者都能表達
  `kind`,不指定優先權就是兩個真相來源。→ 影響:若判斷錯誤(要求 `moKind` 優先或兩者必須一致),
  是 `payloadOverride` 一個函式的改動,不影響任何簽名。
```

#### ASM-4

**涉及**:`MetaExtras` 的表示法(`[Text]` 原始行 vs `[(Text, Text)]`)、`extrasOf` / `mergeExtras` 簽名

**要裁決什麼**:`MetaExtras` 維持 `[Text]` 原始行(換得「作者手寫格式原樣保留」、失去逐欄改值)嗎?(是/否)

```
- **ASM-4**:`MetaExtras` 是 `[Text]`(原始行)而不是結構化的鍵值對。→ 採取:照做。依據:見「不可逆
  決定」第 2 條。→ 影響:呼叫端(F008)要改某一欄時,必須靠 `payloadExtras` 產生新條目再
  `mergeExtras`,不能直接改一個欄位的值;若判斷錯誤,`MetaExtras` 要改成 `[(Text, Text)]` 之類的
  結構,`extrasOf` 與 `mergeExtras` 的簽名跟著改,且會失去「作者手寫格式原樣保留」這條性質。
```

#### ASM-5

**涉及**:私有函式 `metaFieldLines :: MetaOverride -> Text -> [Text]`、LAW-10

**要裁決什麼**:允許 spec 角色在骨架裡留一個非 `undefined` 的本體(保留上一輪已交付的序列化規則)嗎?(是/否)

```
- **ASM-5**:`renderMetaBlock` 中 `metaFieldOrder` 每一欄怎麼寫成一行,抽成私有的
  `metaFieldLines :: MetaOverride -> Text -> [Text]`,並**保留上一輪已交付的本體**(不是 `undefined`)。
  → 採取:照做。依據:那是已上線、已被 EditSpec 逐行斷言過的序列化規則(引號、流式風格、newtype
  解包),本次的變更是「多接一半」而不是「重寫排版」;讓 impl 從零重推有回歸風險,LAW-10 也正是為了
  釘住它。→ 影響:若編排者認定 spec 角色不得留下任何非 `undefined` 的本體,把它改成 `undefined`
  即可,LAW-10 會抓到任何排版漂移。
```

#### ASM-6

**涉及**:`NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` / `MetaExtras` 的模組歸屬(`Aapms.Md.Render` vs 新開 `Aapms.Md.Section`)

**要裁決什麼**:接受這六個型別與兩個 `FromJSON` 實例住在 `Aapms.Md.Render`(不動 `md/aapms-md.cabal`)嗎?(是/否)

```
- **ASM-6**:`NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` / `MetaExtras`
  全部定義在 `Aapms.Md.Render`,而不是新開一個 `Aapms.Md.Section` 模組。→ 採取:照做。依據:委派
  指示要求 `md/aapms-md.cabal` 不得改動,新模組加不進 `exposed-modules` 就編不過;`NewSection` 上一
  輪本來就住在 `Aapms.Md.Render`。→ 影響:代價是 `Aapms.Md.Render` 裡出現了兩個 `FromJSON` 實例
  (解碼職責通常在 `Aapms.Md.Yaml` / `Aapms.Md.Parse` 那一側)。若編排者願意動 cabal,把這六個型別
  與兩個實例搬到 `Aapms.Md.Section` 是純機械搬移,`Aapms.Md.Parse` → `Aapms.Md.Render` 那條新的
  模組內相依也會一併消失。
```

#### ASM-7

**涉及**:`Aapms.Store.Create`(`store/src/Aapms/Store/Create.hs:137-216`)與 `aapms-md` 同名同形的 DTO 家族

**要裁決什麼**:誰在什麼時候刪掉 store 那份重複定義、改成 re-export?(編排者要點名一個 feature)

> 註:`graph-core/F008` 的「已裁決的假設」表 ASM-4 一列已寫「F004 GAP-2 重跑已把它們放進 `Aapms.Md.Render`,store 改成 re-export」,
> 收斂方向已定;本條剩下的是**誰執行**,尚未點名。

```
- **ASM-7**:`aapms-store` 的 `Aapms.Store.Create`(`store/src/Aapms/Store/Create.hs:137-216`)已經有一組
  同名同形的 `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode`。→ 採取:
  **不碰 store**(委派指示明令),在 `aapms-md` 定義正本時**逐欄採用與 store 完全相同的欄位名**
  (`naName` / `naSha256` / …、`nlcCommercial` / …、`nnKind`),讓收斂成本降到「刪掉 store 那段、
  改成 re-export」。依據:契約 D 說這組 DTO 屬於 `aapms-md`;兩份定義同時存在時,store 一旦
  `import Aapms.Md` 就會產生名稱衝突。→ 影響:編排者需要在 F007 / F008 收斂時裁決由誰刪除;在那之前
  `aapms-store` 仍然編得過(它目前不 import `Aapms.Md.Render`)。
```

---

### `.design/subsystems/graph-core/features/F005-store-vault-handle.md`

六條全部只有「**採取**」,沒有任何裁決欄。`## 修訂記錄` 的 REV-1(2026-09-05)只是把 E002 的文字併進本檔,
「程式碼與測試一行未動」,沒有碰任何 ASM。`## 實作備註` 只**部分**回應 ASM-1(見下)。

#### ASM-1

**涉及**:`store/aapms-store.cabal` 的 `exposed-modules` / `other-modules` / `build-depends`(移除 `aapms-md`)

**要裁決什麼**:F005 把七個編不過的模組移出 build 目標、並砍掉 `aapms-md` 依賴,追認嗎?(是/否)

> **同檔 `## 實作備註` 已推翻它的理由但沒推翻結論**:
> 「**更正(編排者查證,2026-08-23)**:上面第一輪回報把「移除 `aapms-md` 的 `build-depends`」寫成「綠燈的必要條件」(待確認假設 ASM-1),編排者查證後確認**不是**……結果(移除該依賴)本身仍然合理……但理由不成立」。
> 也就是說:**理由已結案、結論未經閘門追認**,ASM-1 條目原文未動。

```
- ASM-1(cabal 瘦身與移除 `aapms-md` 依賴):**採取**——把 #6/#8 範圍的七個已編不過模組移出
  `exposed-modules`/`other-modules`,並把 `aapms-md` 移出 `aapms-store` 的 `build-depends`。
  契約卡沒有明文授權改動 cabal 的模組清單與套件依賴,但查證顯示不這麼做 `cabal test
  aapms-store` 連編譯都到不了,本 feature 無法產出任何「如實回報」的測試結果。**影響**:
  若編排者認為應該保留這些死碼在 build 目標內(例如想讓 `cabal build all` 的失敗訊息集中
  在同一個地方),則改為在 `.cabal` 檔加 `-- TODO(F006/F008)` 註解但不移出清單,代價是 F005
  本身就無法達成綠燈,委派模式的「機械性查證不可跳過」會卡死在建置階段
```

#### ASM-2

**涉及**:模組 `Aapms.Store.Vault` → `Aapms.Store.Marker` 改名(檔名與模組路徑)

**要裁決什麼**:模組沿用 design.md 模組表的 `Marker` 名字(而非保留舊檔名 `Vault.hs`)嗎?(是/否)

```
- ASM-2(`Vault.hs` → `Marker.hs` 改名):**採取**。design.md「內部模組劃分」表本就把這個職責
  命名為 `Marker`(而非 `Vault`),且舊名字 `Vault` 現在容易與契約 E 的 `VaultHandle`/
  `VaultKind`/`VaultMarker` 三個型別名稱混淆。**影響**:純粹是檔名與模組路徑,若編排者偏好
  保留舊檔名只改內容,改動範圍縮小但與 design.md 的模組表對不上
```

#### ASM-3

**涉及**:`VaultHandle` / `openVault` / `closeVault` 的模組歸屬(放在 `Marker`)

**要裁決什麼**:接受 `Marker` 模組同時承擔「讀 config.toml」與「組裝 handle、判斷 schema」兩層職責嗎?(是/否)

```
- ASM-3(`VaultHandle`/`openVault`/`closeVault` 放進 `Marker` 模組,不另開模組):**採取**。
  design.md 只為這個 feature 命名了 Marker/Atomic/Schema 三個模組,`VaultHandle` 是「marker +
  根目錄 + 索引連線」的組合,沒有更適合的既有模組名字可以放。**影響**:若後續 feature 覺得
  `Marker` 模組職責過重(混了「讀 config.toml」與「組裝 handle、判斷 schema」兩層),可以在
  #6 或更後面拆成獨立模組,屬於不影響契約簽名的內部重構
```

#### ASM-4

**涉及**:`initVaultAt :: … -> IO (Either StoreError …)`(不建業務子目錄、不寫 `.gitignore`)

**要裁決什麼**:`initVaultAt` 確定不依 `kind` 建骨架子目錄(由 workspace 的 `vault init` 自己負責)嗎?(是/否;答「否」是契約 E 簽名擴充)

```
- ASM-4(`initVaultAt` 不建業務子目錄、不寫 `.gitignore`):**採取**。驗收標準只寫「`.aapms/
  config.toml`……與空索引」,且 `asset`/`story` 兩種 `kind` 的目錄結構完全不同,子目錄清單
  屬於 `kind` 專屬的業務知識,不該寫死在本 feature。**影響**:若判斷錯誤、`workspace` 的
  `vault init` 預期 `initVaultAt` 自己建好子目錄,則要幫 `initVaultAt` 加一個「依 kind 建立
  骨架目錄」的參數或另開函式,屬於契約 E 簽名的擴充(需要回頭走 `/subsys-design` 更新模式)
```

#### ASM-5

**涉及**:`initVaultAt` 內的 `newId PVlt name now 0`(固定 `salt = 0`,不重試)

**要裁決什麼**:`vlt-` id 的碰撞重試責任確定全歸 `workspace` 的全域註冊表嗎?(是/否)

```
- ASM-5(`initVaultAt` 的 `vlt-` id 不做碰撞重試):**採取**,`newId PVlt name now 0`(固定
  `salt = 0`,不重試)。契約卡「明確不做」寫「不讀中樞註冊表」,本 feature 因此**沒有任何
  資料來源**可以拿來檢查新 id 是否與其他已註冊的 vault 撞號——`newId` 本身的說明
  (`core/src/Aapms/Core/Id.hs:99-102`)寫明「唯一性不在這一層」,由「持有索引的那一層」以
  salt 重試保證,但那一層(對 vault id 而言)是全域註冊表,屬 `workspace`,不是本 feature。
  **影響**:若中樞註冊表發現撞號(FNV-1a 64-bit 取低 32 位,實務機率極低但非零),那是
  `workspace` 註冊時的責任(可以要求作者重新 `vault init`),不影響本 feature 的正確性
```

#### ASM-6

**涉及**:`IndexIssue` 的建構子(`SchemaRebuilt`)、`renderIndexIssue`

**要裁決什麼**:`IndexIssue` 由後續 feature「擴充而非重寫」這條協調約束,編排者要不要寫進指派 prompt?(是/否)

> 註:`graph-core/F006` 的 ASM-1 已記載 `IndexIssue` 實際被加到四個建構子(`MetaWarningsFound …`),
> 是「擴充」而非「重寫」——事實上已照 ASM-6 走,但沒有回頭結掉這一條。

```
- ASM-6(`IndexIssue` 只放一個建構子,交由 #6 擴充而非重新定義):**採取**,依委派決策記錄 DEC-3
  逐字指示。**影響**:若 #6 的設計者選擇整個重新定義 `IndexIssue`(而非在既有 `data
  IndexIssue = SchemaRebuilt {..} | ...` 後面加建構子),本 feature 產出的
  `SchemaRebuilt`/`renderIndexIssue`/相關測試都要跟著改,屬跨 feature 的協調風險,建議編排者
  在指派 #6 時明確告知「擴充不是重寫」
```

---

### `.design/subsystems/graph-core/features/F006-store-unified-index.md`

ASM-1 條目標題自寫「已由開發者裁決並落地,不再是待確認項」。ASM-2–ASM-10 九條只有「**採取**」,無裁決欄;
`## 實作備註` 兩度**引用** ASM-10(說明 `hydrateMeta` 多一個 `VaultId` 參數的來由)但沒有結掉它;
`## 修訂記錄` REV-1(2026-09-05)只是併入 E001 的文字,不碰 ASM。

#### ASM-2

**涉及**:`indexOne` 的 `PackDoc` 分支、`assets.name` 唯一性、`IndexIssue` 的 `DuplicateAssetName`

**要裁決什麼**:`assets.name` 撞名時的失敗粒度是「整檔回滾」(而非逐 asset 略過)嗎?(是/否)

```
- ASM-2(`assets.name` 重複時哪一筆保留名字,委派決策記錄明列的待決點):**採取**——granularity
  是整檔:先被索引到的檔案(`rebuildIndex` 依排序後的路徑逐一處理,因此是路徑字母序最先者)
  保留 `name`,之後任何檔案的 asset 撞到同一個 `name` 時,那個檔案的整個 `indexOne` transaction
  回滾、回報 `DuplicateAssetName`,不寫入部分資料。依據:與 `ParseFailed`/`TreeInvalid` 同一個
  「整檔要嘛全進索引要嘛不進」的失敗模型一致,不需要在 `Asset` 之外再發明「部分成功」的語意。
  **影響**:若編排者預期是「單筆 asset 略過、pack 內其餘 asset 照常索引」的更細粒度,
  `indexOne` 對 `PackDoc` 分支要拆成逐 asset 各自小 transaction,是局部實作調整,不影響
  `IndexIssue`/函式簽名
```

#### ASM-3

**涉及**:`NodeFilter.nfIncludeReference`、`listNodes` 的 WHERE 子句

**要裁決什麼**:`nfIncludeReference = False` 要同時排除 reference pack **節點本身**與其 asset(而不只排除 asset)嗎?(是/否)

```
- ASM-3(`nfIncludeReference` 的排除範圍):**採取**——`False`(預設)時排除 `is_reference` 的
  pack 節點**本身**,以及 `owner` 指向該 pack 的全部 asset。依據:design.md 的舉例(「找 GUI
  框時不該跳出參考資料夾的廟宇照片」)是講 asset,但同一個 pack 節點若被 `listNodes` 直接
  列出也同樣不該出現在預設結果裡,兩者是同一條「reference 資料夾預設不可見」規則的一體兩面。
  **影響**:若編排者只要排除 asset、pack 節點本身仍要可見,WHERE 子句拿掉「排除 pack 本身」
  那一段即可,局部調整不影響簽名
```

#### ASM-4

**涉及**:`NodeFilter.nfTags :: [Text]` 的組合語意

**要裁決什麼**:`nfTags` 多個標籤取 AND(而非 OR)嗎?(是/否)

```
- ASM-4(`nfTags` 多個 tag 的組合語意):**採取** AND(節點必須同時擁有全部指定的 tag)。依據:
  契約 F 沒有明定,`nfTags :: [Text]` 的型別本身不排除 AND 或 OR;沿用 legacy `Query.hs`(單一
  `efTag` 只有一個,沒有先例)與一般標籤過濾的直覺慣例(AND 縮小範圍更符合「篩選」語意)。
  **影響**:若編排者要 OR 語意,WHERE 子句改成單一 `EXISTS (... tag IN (...))`,局部調整
```

#### ASM-5

**涉及**:`lookupNode` 對 `PEnt` / `PAst` / `PPck` 的成本模型(每次重讀檔案取 body)

**要裁決什麼**:接受 `lookupNode` 每次回讀並解析整份檔案的成本(不快取 body)嗎?(是/否)

```
- ASM-5(`lookupNode` 對 `PEnt`/`PAst`/`PPck` 每次呼叫都重新讀檔+解析整份檔案取得 body):
  **採取**,與 legacy `lookupEntity` 同一個成本模型。依據:design.md 明寫「`body` 進 FTS 但不進
  `nodes`:正文只有檔案有」,索引故意不重複存 body,而 F006 不建 FTS 表(#7 的範圍),所以除了
  回讀檔案沒有第二條路。**影響**:若某個大 pack.md(1,693 節)的單一 asset 查詢因此變慢到
  無法接受,#7 落地 FTS 後可以考慮用 FTS 的 content 欄位當快取,但那是效能優化,不影響本
  feature 的正確性
```

#### ASM-6

**涉及**:`files.doc_kind` 欄位的字面值、`Aapms.Store.Row` 的兩個轉換函式

**要裁決什麼**:`doc_kind` 用 store 自訂的小寫四字串(不用 `DocKind` 的 `Show`)嗎?(是/否)

```
- ASM-6(`files.doc_kind` 的文字編碼):**採取**——store 自訂 `"topic"`/`"level"`/`"pack"`/
  `"license"` 四個字面字串,不使用 `Aapms.Md.Document.DocKind` 的 `Show` 實例(那會印成
  `TopicDoc` 而非小寫)。依據:`DocKind` 沒有匯出的文字轉換函式,design.md 也沒有規定
  `doc_kind` 欄位的確切文字值,這是索引表的內部持久化細節。**影響**:純命名選擇,不影響任何
  對外契約,即使改了也只是 `Row` 模組內部的兩個函式
```

#### ASM-7

**涉及**:`linksTo :: … -> IO [(Meta, Link)]`(契約 E 字面)

**要裁決什麼**:無需裁決——條目自寫「照契約做,不是待確認的判斷,列在此處只為了提醒不要誤抄 legacy 的 `Id` 版簽名」。**可直接刪除或標為 N/A。**

```
- ASM-7(`linksTo` 的回傳型別 `[(Meta, Link)]` 需要對每個來源 `hydrateMeta`,比 legacy 的
  `[(Id, Link)]` 貴):**採取**,契約 E 字面就是 `(Meta, Link)`,沒有偏離空間。**影響**:無
  (照契約做,不是待確認的判斷,列在此處只為了提醒不要在實作時誤抄 legacy 的 `Id` 版簽名)
```

#### ASM-8

**涉及**:STEP-7 的 `test_rm_index_db_rebuild_equivalent` 與 `contract/test/Aapms/Contract/IndexEquivalenceSpec.hs` 的關係(ADR-013 索引重建等價)

**要裁決什麼**:套件內版本足以驗收 S1、真正的端到端驗證延到 S3 `shell` 落地,接受嗎?(是/否)

```
- ASM-8(「`rm index.db` 後 `openVault` + `rebuildIndex` 與刪除前的 `listNodes`/`linksFrom` 結果
  相同(S0 契約測試)」與 `contract/test/Aapms/Contract/IndexEquivalenceSpec.hs` 的關係):
  **採取**——本 feature 的 STEP-7/`test_rm_index_db_rebuild_equivalent` 是**套件內**(`aapms-store`
  測試,直接呼叫 Haskell 函式)版本,不是跑 `contract/` 那份透過 `aapms` CLI 執行檔的黑盒測試。
  依據:`contract/test/Aapms/Contract/IndexEquivalenceSpec.hs` 呼叫的是 `aapms`/`aapms-serve`
  執行檔(`shell` 子系統,S3 才會存在),本 feature 只到 `aapms-store` 這一層,沒有 CLI 可跑。
  **影響**:S3 `shell` 落地後,`contract/` 那份測試會是本 feature 這條驗收標準的**真正**端到端
  驗證;若屆時發現行為對不上,是那個時間點才會發現的問題,不是本 feature 現在能預先擋下的
```

#### ASM-9

**涉及**:`emptyNodeFilter :: NodeFilter`(契約 F 逐字清單外的新增公開值,`nfLimit` 預設 1000)

**要裁決什麼**:`emptyNodeFilter` 保持公開(而非收進 `Fixtures.hs`)嗎?`nfLimit` 的預設值 1000 追認嗎?(是/否)

```
- ASM-9(`emptyNodeFilter` 這個輔助值不在契約 F 的逐字清單內):**採取**,新增一個最小合理的
  `NodeFilter` 建構捷徑(全部欄位取最寬鬆值,`nfLimit` 給一個大但有限的預設值如 1000,理由是
  `Int` 型別的 `nfLimit` 沒有「無限」的自然值,SQL `LIMIT` 也不接受省略此欄位的語意)。
  依據:`NodeFilter` 全欄必填(不是 `Maybe` 包起來的可選 record),`listNodes`/`childrenOf` 等
  函式的測試與未來 `service` 呼叫端都需要一個起點,比照 F005 對 `IndexIssue`「契約給骨架、
  由後續 feature 依需要擴充」的精神,這是最小夠用的補充,不是新的公開資料結構。**影響**:若
  `/arch-audit feature` 認為這個輔助值超出契約 F 逐字範圍,把它改成非 export 的測試專用工具
  函式(只留在 `Fixtures.hs`),不影響 `NodeFilter` 本身的形狀
```

#### ASM-10

**涉及**:`nodes` 表無 `vault` 欄;`hydrateMeta :: VaultId -> Connection -> NodeRow -> IO Meta`(比文檔多一個 `VaultId` 參數)、`listNodes`、`lookupNode`、`Meta.metaVault`

**要裁決什麼**:`Meta.metaVault` 一律用 handle 自己的 `vmId` 回填、不逐列存 frontmatter 宣告的 `vault:` 標籤,追認嗎?(是/否)

```
- ASM-10(design.md「索引結構」的 `nodes` 表 15 欄裡沒有 `vault` 欄,但 `Meta.metaVault` 是必填
  欄位,`hydrateMeta`/`listNodes`/`lookupNode` 讀回 `Meta` 時要填什麼):**採取**——不逐列存
  `vault`,一律用呼叫端手上那個 `VaultHandle` 自己的身分(`vmId (vhMarker vh)`,零額外 IO,永遠
  可得)回填每一筆 hydrate 出來的 `Meta.metaVault`。依據:design.md 的 `nodeColumnList`/`nodes`
  表逐欄都沒有 `vault`,F006 doc 自己的 Row 段落也白紙黑字寫 15 欄不含它,這不是我自由選的形狀,
  是既有文檔的既定欄位清單;而 md fixture(`Aapms.Md.Fixtures.vaultOf`)已經明寫「frontmatter 的
  `vault:` 只是自由文字標籤,不強制等於 vault 自己的 `vlt-` id」,兩者本來就是不同概念,用
  vault 自己的穩定身分填,兩次 rebuild(含 `rm index.db` 後)永遠一致,S0 契約測試因此不受影響。
  **影響**:若之後某 feature 需要「這個節點檔案 frontmatter 當初宣告的 vault 標籤」(而非它
  實際所在的 vault),要幫 `nodes` 表加回一欄,是純 schema 擴充,不影響本 feature 其餘介面;
  細節見 `Aapms.Store.Row` 模組頂端的 Haddock
```

---

### `.design/subsystems/graph-core/features/F007-store-fts-dual-index.md`

ASM-3 已由 2026-08-24 開發者裁決改寫(條目標題自帶「依開發者裁決改寫,原版見 spec-gaps GAP-5」,GAP-5 狀態 resolved)。
其餘四條無裁決欄;`## 實作備註` 記的是 GAP-3 / GAP-4 / GAP-5 的結案,沒有碰 ASM-1 / ASM-2 / ASM-4 / ASM-5。

#### ASM-1

**涉及**:`insertFtsRows` 的模組歸屬(`Aapms.Store.Schema` vs 新開 `Aapms.Store.Fts`)、`ftsRowOf`、`Aapms.Store.Tokenize`(維持純)

**要裁決什麼**:FTS 列的生命週期歸 `Schema` 模組(不獨立成 `Aapms.Store.Fts`)嗎?(是/否)

```
- **ASM-1**:design.md 把 FTS 列維護的歸屬留白——「Tokenize」的職責寫的是「CJK unigram / bigram 預切、
  查詢路由判斷」(純),「Schema」是「索引表結構、`schema_version`、整庫重建」。
  → **採取**:`insertFtsRows` 放 `Schema`(宣告表結構的人一併負責它的列生命週期,而且 `fts_map` 的
  觸發器本來就是 DDL 的一部分),`Tokenize` 維持純。「模組間公開介面」的 Index → Tokenize 由
  `ftsRowOf` 承接,Index 仍是發起方、預切仍只有一份。
  → **影響**:若編排者認為 FTS 列維護該獨立成一個模組(如 `Aapms.Store.Fts`),要搬的是
  `insertFtsRows` 一個函式與三段 DDL,`Tokenize` 與 `Query` 不受影響。
```

#### ASM-2

**涉及**:`PRAGMA recursive_triggers = ON`、`fts_map` 的 DELETE 觸發器、`search` 側的 `fts_map INNER JOIN nodes`

**要裁決什麼**:依賴 `recursive_triggers` 讓外鍵級聯清 FTS 列(孤兒列只浪費空間、不影響正確性),接受嗎?(是/否)

```
- **ASM-2**:`PRAGMA recursive_triggers = ON` 讓外鍵級聯觸發 `fts_map` 的 DELETE 觸發器——這條已在本機
  以 `files → nodes → fts_map → fts_tri` 的最小範例實測通過(GHC 9.14.1 + `direct-sqlite`
  `+fulltextsearch`),不是文件推論。
  → **採取**:依賴它,並在 `search` 側**同時**以 `fts_map` INNER JOIN `nodes` 過濾,使得即使有孤兒
  FTS 列也不會出現在結果裡(只會浪費空間,不會答錯)。
  → **影響**:若日後換 SQLite 版本導致觸發器不再被叫起,正確性仍然成立,只需補一次
  `rebuildIndex` 前的整批清空。
```

#### ASM-4

**涉及**:`cjkSegment` / `search` 的召回範圍(EX-14:純 ASCII 一、二字元查詢必定空結果)

**要裁決什麼**:接受「純 ASCII 一、二字元查詢恆空」這個召回缺口、寫成 Example 不特例處理嗎?(是/否)

```
- **ASM-4**:純 ASCII 的一、二字元查詢(EX-14)在雙索引下必定空結果——trigram 有三字元下限,`fts_cjk`
  不收非中日韓內容,而 `LIKE` 已依 ADR-016 第二條退場。
  → **採取**:接受並寫成 Example,不特例處理。
  → **影響**:若之後判定這是不可接受的召回缺口,選項是讓 `cjkSegment` 也收錄非中日韓的**詞**
  (unicode61 對 `_` / `-` 斷詞,`ui_gui_...` 會產生 `ui` token),那是 `Tokenize` 內部的改動 +
  一次 `schemaVersion` bump,不動任何介面。
```

#### ASM-5

**涉及**:契約卡的效能驗收標準「索引體積對 6,783 筆 asset 在可接受範圍」(無對應 Law / Example)

**要裁決什麼**:這條驗收標準確定延到 S2 真資料進場才驗、S1 不合成大 fixture 嗎?(是/否)

```
- **ASM-5**:契約卡的「索引體積對 6,783 筆 asset 在可接受範圍」依 DEC-4 等 S2 真資料進場再驗,S1 不合成
  大 fixture。本文檔沒有對應的 Law 或 Example。
```

---

### `.design/subsystems/workspace/features/F001-hub-registry.md`

三條都只有「暫採」,沒有裁決欄。`## 實作備註` 底下的「自裁記錄」(SELF-1–SELF-5)與
「給編排者的注意事項」都是別的事(契約 F 建構子數目那條已註明「本條不再有待辦動作」),
**沒有回答 ASM-1 / ASM-2 / ASM-3 任何一條**。這份文檔沒有 `## 修訂記錄`。

#### ASM-1

**涉及**:`Aapms.Workspace.Types` 匯出的 `Hub`(不透明)、`mkHub`、`hubSourceText`;四個 getter `hubVaults` / `hubProjects` / `hubLlm` / `hubTools`;`saveHub`

**要裁決什麼**:`Hub` 維持不透明並額外公開 `mkHub` / `hubSourceText`(而不是 `Hub (..)` 全欄匯出、也不是把宣告搬去 `Hub.hs`)嗎?(是/否)

```
- ASM-1: `Hub` 做成**不透明型別**並在 `Types.hs` 額外匯出 `mkHub` 與 `hubSourceText` 兩個
  契約沒有的符號。契約 A 只寫 `data Hub -- 已載入的中樞快照,不可變`,沒說建構子露不露、也沒說
  「保住註解」要靠什麼載體;契約卡把四個 getter 指給本 feature,卻沒指出 `Hub` 的表示法住哪裡。
  - 契約錨點:design.md 契約 A 的 `Hub`;契約 B 的 `hubVaults` / `hubProjects` / `hubLlm` /
    `hubTools`;新增符號 `mkHub`、`hubSourceText`
  - 層級自答:出現在邊界上?**會**(它們是 `Aapms.Workspace.Types` 的匯出清單,`service` 與
    F004 / F005 都看得到);改錯驚動其他模組?**要**(F004 的 `setupHub` 要造空中樞、
    `initVault` 要回新的 `Hub`,拿不到建構入口就動不了)
  - 選項:
    a) **`Hub` 不透明 + `mkHub` + `hubSourceText`(本 spec 採用)**——當下成本:多兩個公開符號,
       文件要說明「為什麼有兩個看起來像內部細節的東西」;三個月後代價:`saveHub` 的保留策略若
       要換載體(例如改存解析後的 TOML 文件樹而不是原始文字),`hubSourceText` 這個名字與型別
       (`Text`)會變成必須維護的舊介面,得走一次契約修訂
    b) **`Hub` 匯出全部欄位(`Hub (..)`)**——當下成本:零,照抄 graph-core `VaultHandle`
       「欄位全部匯出」的先例;三個月後代價:`hubSourceText` 與四段之間「同一次載入」的不變量
       沒有任何東西守,任何人都能 record-update 出「文字說有三個 vault、清單只有一個」的 `Hub`,
       而 `saveHub` 會照著這種快照把使用者的檔案寫壞——這是一個沉默的資料損毀路徑
    c) **`Hub` 定義搬到 `Hub.hs`,`Types.hs` 完全不碰它**——當下成本:違反契約卡「Types 一次寫齊
       契約 A–F 的全部型別」的字面;三個月後代價:最小(`Hub` 的表示法確實只有 `Hub` 模組會碰,
       階段二沒有任何 feature 需要改它,DEC-2 的併發理由對它不成立),但「型別一律去 Types 找」
       這條慣例出現一個例外,後續 feature 每次都要多想一次
  - 傾向:a。理由是它同時滿足「Types 一次寫齊」(字面照做)與「不可變快照的不變量有人守」
    (b 守不住),而 c 的唯一好處是省下兩個符號、代價是破壞剛立下的慣例。依賴的前提:F004 的
    `setupHub` / `initVault` 只需要「造一個 `Hub`」與「對 `Hub` 增刪」兩種能力,不需要看見表示法
    ——這一點已由 design.md「模組間公開介面」的 `Lifecycle → Hub | upsertVault / removeVault +
    saveHub` 那一列佐證(它列的就是這兩種能力,不是欄位存取)。可逆性:**有條件可逆**——改成
    b 只要放寬匯出清單、不動任何呼叫端;改成 c 要動 `Types.hs` 與 `Hub.hs` 的匯出並讓全部消費端
    改 import 來源,而那時 F004–F006 已經寫好,是三個檔案的連帶修改
  - 暫採:a(`Hub` 不透明,`Types.hs` 匯出 `Hub` / `mkHub` / `hubSourceText` / 四個 getter)
    → 影響:若裁決成 b,把 `Types.hs` 匯出清單的 `Hub` 改成 `Hub (..)` 並刪掉 `mkHub`,
    Laws 的 LAW-16 改測欄位;若裁決成 c,`Hub` 的 `data` 宣告與 `mkHub` 整段搬到 `Hub.hs`,
    `Types.hs` 刪掉對 `LlmSection` 以外四段型別的引用,`Hub.hs` 的 import 清單同步縮減
```

#### ASM-2

**涉及**:`Aapms.Workspace.Hub` 新增 `upsertProject` / `removeProject`(對稱既有 `upsertVault` / `removeVault`);F005 的 `registerProject` / `forgetProject`;LAW-13

**要裁決什麼**:`Hub.hs` 現在就補上這兩個對稱的純函式(而不是等 F005 撞牆再回頭改)嗎?(是/否)

```
- ASM-2: `Aapms.Workspace.Hub` 除了 design.md 明列的 `upsertVault` / `removeVault` 之外,**補上對稱
  的 `upsertProject` / `removeProject`**。design.md「模組間公開介面」表的 `Projects → aapms-core`
  那一列只寫 `newId PPrj`,沒有寫 Projects 怎麼把新的 `ProjectEntry` 放進 `Hub`;而 F005 的契約卡
  寫「使用……模組間公開介面的 `newId PPrj` 用法(**無新增**)」,代表它預期需要的東西都已存在。
  - 契約錨點:design.md「模組間公開介面」表的 `Lifecycle → Hub`(`upsertVault` / `removeVault`)
    與 `Projects → aapms-core` 兩列;新增符號 `upsertProject`、`removeProject`
  - 層級自答:出現在邊界上?**會**(`Aapms.Workspace.Hub` 的匯出清單,F005 直接呼叫);
    改錯驚動其他模組?**要**(F005 的 `registerProject` / `forgetProject` 必須回新的 `Hub`,
    沒有這兩個函式就只能自己動 `Hub` 的表示法——而 ASM-1 決定表示法不外露)
  - 選項:
    a) **本 feature 現在補上兩個對稱函式(本 spec 採用)**——當下成本:兩個十行以內的純函式與
       兩條 law;三個月後代價:若 F005 最後根本不用它們(例如選擇讓 Projects 自己重建整個 `Hub`),
       就是兩個死碼,而死碼在 `-Wall` 下不會被抓到(它們是匯出的)
    b) **不補,等 F005 自己想辦法**——當下成本:零;三個月後代價:F005 的骨架白名單只有
       `Projects.hs`,它**寫不進** `Hub.hs`,唯一的出路是走 spec-gaps 停下整個 feature、回頭改
       F001 的檔案,而那時 F004 / F006 正在平行跑、`Hub.hs` 已經是「WAVE-1 之後沒人再碰」的檔案
       (DEC-2 的前提被打破)
    c) **改成一組泛用的 `withVaults` / `withProjects` 之類的高階函式**——當下成本:要多設計一層
       抽象;三個月後代價:呼叫端要自己寫 list 操作,「追加或就地取代」這條語意會在 Lifecycle
       與 Projects 各實作一次,兩邊漂移時沒有任何測試會紅
  - 傾向:a。理由是 b 的失敗模式(階段二平行波次被單一檔案的擁有權卡死)正是 DEC-2 想避免的事,
    而 a 的失敗模式(兩個死碼)代價極小且事後刪得掉。依賴的前提:`[[projects]]` 的增刪語意與
    `[[vaults]]` 相同(以 id 為鍵、追加或就地取代、保序)——design.md 契約 B 對 `peId` 寫的
    「中樞內唯一;鍵」與對 `veId` 寫的完全同構,這個前提成立。可逆性:**可逆**——若閘門認為
    不該有,刪掉兩個函式與兩條 law 即可,沒有任何既有呼叫端
  - 暫採:a(`Hub.hs` 提供四個純增刪函式)→ 影響:若裁決不補,刪掉 `upsertProject` /
    `removeProject` 與 LAW-13,並要在指派 F005 時把 `Hub.hs` 加進它的寫入白名單
```

#### ASM-3

**涉及**:`loadHub`、`VaultEntry.veName` / `ProjectEntry.peName` 的值域、`HubMalformed` / `InvalidName`

**要裁決什麼**:`[[vaults]].name` / `[[projects]].name` 為空字串時 `loadHub` 一律回 `HubMalformed`(讀寫兩端同一套值域)嗎?(是/否)

```
- ASM-3: `loadHub` 對 `[[vaults]].name` / `[[projects]].name` 的**空字串一律回 `HubMalformed`**。
  契約卡的驗收標準 3 只點名「`id` 缺、`kind` 不是 asset/story、路徑非絕對」三種不合規,沒有提
  name;但契約 B 的欄位表對 `veName` / `peName` 都寫了值域「非空」。
  - 契約錨點:design.md 契約 B 的 `VaultEntry.veName` 與 `ProjectEntry.peName` 的值域欄;
    契約 F 的 `HubMalformed`、`InvalidName`
  - 層級自答:出現在邊界上?**會**(它決定一份手寫的中樞檔是被接受還是被拒絕,那是 system.md
    第 6 節的對外檔案契約);改錯驚動其他模組?**要**(#2 的 `lookupSelector` 以 `veName` 比對,
    空名稱會讓「`--vault ''`」這種輸入的行為變成未定義)
  - 選項:
    a) **空 name 即 `HubMalformed`(本 spec 採用)**——當下成本:兩條額外的檢查與一條 example;
       三個月後代價:若使用者真的想暫時留一個沒名字的 vault,整份中樞都載不起來,而錯誤訊息
       指的是「name 不得為空」,使用者改得掉——代價可控
    b) **空 name 照收,由 #2 的 selector 比對自然地比不到**——當下成本:零;三個月後代價:
       契約 B 白紙黑字的「非空」變成沒人守的註解,而 `veName` 是要印給使用者看的欄位,
       `doctor` 會印出一列空白;更糟的是寫入路徑的 `InvalidName`(F004 對名稱去空白後長度 ≥ 1)
       與讀取路徑不對稱——工具自己寫不出來的檔案,工具讀得進來
  - 傾向:a。理由是「讀寫兩端對同一個欄位用同一套值域」是可手寫檔案能維持一致的前提,b 造成的
    不對稱會在 `vault add` 之類的往返操作上冒出來。可逆性:**可逆**(放寬檢查比收緊容易,
    收緊會讓既有的檔案突然變非法,放寬不會)
  - 暫採:a → 影響:若裁決成 b,刪掉合規表的兩列 name 檢查與對應的 example,`veName` / `peName`
    的值域註解要同步改成「可為空」
```

---

### `.design/subsystems/workspace/features/F002-vault-discovery.md`

兩條都只有「暫採」。`## 實作備註` 只記了 2026-08-29 閘門對 **LAW-18(b)**(spec-gaps GAP-2)的裁決,
與 ASM-1 / ASM-2 無關;這份文檔沒有 `## 修訂記錄`。

#### ASM-1

**涉及**:`readVaultRef :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)` 與新增的 `readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)`;`ScopeIssue` 的 `VaultPathMissing` / `VaultMarkerBroken` / `VaultIdDrift`;`MarkerUnreadable`;LAW-16

**要裁決什麼**:把 design.md 的 `readVaultRef :: Maybe VaultEntry -> …` 拆成兩個函式(而不是給 `ScopeIssue` 加一個不帶 `VaultEntry` 的建構子)嗎?(是/否)

```
- ASM-1: 把 design.md「模組間公開介面」的
  `readVaultRef :: Maybe VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)`
  **拆成兩個函式**(`readVaultRef :: VaultEntry -> …` 與
  `readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)`)。契約卡沒有答案,
  是因為這不是卡片漏寫,而是 design.md **內部兩處互相矛盾**:模組間介面表允許
  `Maybe VaultEntry`,但契約 C 的 `ScopeIssue` 三個相關建構子**都要求一列 `VaultEntry`**,
  第一參數為 `Nothing` 時失敗通道表達不出來。
  - 契約錨點:design.md「模組間公開介面」表的 `Scope → Discovery` 那一列(`readVaultRef`);
    契約 C 的 `ScopeIssue`(`VaultPathMissing` / `VaultMarkerBroken` / `VaultIdDrift`)與
    `VaultRef.vrEntry`;契約 F 的 `MarkerUnreadable`;新增符號 `readVaultRefAt`
  - 層級自答:出現在邊界上?**會**(它是 `Aapms.Workspace.Discovery` 的匯出清單,F003 / F004
    直接呼叫);改錯驚動其他模組?**要**(F003 的三個裁決函式全部經由它取權威身分,改簽名
    等於改 Scope 的每一條路徑)
  - 選項:
    a) **拆成兩個函式(本 spec 採用)**——當下成本:模組間介面表多一列、F003 的 spec 要知道
       「已註冊走哪個、探測到的走哪個」;三個月後代價:兩個函式的行為要一直保持一致(本 spec
       以 LAW-16 把這條一致性釘成 law,漂移會紅),而且若日後 `ScopeIssue` 真的改成帶
       `Maybe VaultEntry`,`readVaultRefAt` 會變成一個可以合併掉的舊介面,得走一次契約修訂
    b) **給 `ScopeIssue` 加一個不帶 `VaultEntry` 的建構子(例如 `VaultRefUnreadable FilePath
       StoreError`)**——當下成本:要改已交付驗收的 `Types.hs`,而 DEC-2 明訂 Types 一次寫齊、
       階段二三個 feature 平行寫同一個檔案,回頭改它就是併發寫入的風險,整波要重排;
       三個月後代價:最小——語意最直白,`readVaultRef` 保持單一入口,`Scope` 不必分兩條路
    c) **保留 `Maybe VaultEntry`,`Nothing` 的失敗定義成「呼叫端保證不會發生」**——當下成本:
       零,簽名逐字照抄;三個月後代價:`readVaultRef` 在 `Nothing` 分支是 partial function,
       而它的唯一呼叫情境正是「決定寫入目標」——marker 壞掉時使用者拿到的是崩潰或空結果,
       不是一則說得出下一步的錯誤;qa 也寫不出那一格的斷言,會變成一條 spec-gap
  - 傾向:a。理由是它在**不動任何已交付程式碼**的前提下讓每個型別都完整(沒有 partial 分支),
    而且順手給契約卡指名的 `MarkerUnreadable` 找到唯一的生產者——沒有 `readVaultRefAt`,本
    feature 的三個錯誤建構子只實作得出兩個。依賴的前提:`ScopeIssue` 的四個建構子在階段二
    不會再改(DEC-2 已把 Types 凍結,契約 F 也已列全建構子),這個前提成立。b 客觀上是最乾淨的
    終局,但它的成本落在**這一波的排程**而不是設計本身;若編排者願意付停一波的代價,b 值得選。
    可逆性:**有條件可逆**——改成 b 要動 `Types.hs`(加一個建構子)、把 `readVaultRefAt` 併回
    `readVaultRef`,並改 F003 的呼叫端;此刻只有骨架與測試,代價還很小,**等 F003 寫完就會
    變成三個檔案的連帶修改**
  - 暫採:a(`readVaultRef :: VaultEntry -> FilePath -> …` + `readVaultRefAt :: Hub ->
    FilePath -> …`)→ 影響:若裁決成 b,`Types.hs` 的 `ScopeIssue` 加一個建構子、
    `renderWorkspaceError` 不動(它不管 `ScopeIssue`)、`readVaultRefAt` 併回
    `readVaultRef :: Maybe VaultEntry -> …`,Laws 的 LAW-14 / LAW-15 / LAW-16 三條改寫成單一函式的版本,
    Examples 的 EX-19–EX-23 的呼叫形式跟著改;若裁決維持原簽名但不加建構子(選項 c),LAW-15 與
    EX-22 要整條刪掉,並在 spec 明寫「`Nothing` + marker 壞」是未定義行為——那會是一條 spec-gap
```

#### ASM-2

**涉及**:`lookupSelector`;`VaultSelectorAmbiguous` / `VaultSelectorNotFound`;F003 三個 `resolve*` 與 F004 `forgetVault` 的比對規則;LAW-7 / LAW-8

**要裁決什麼**:selector 的兩階段(`veId` → `veName`)都用同一套「撞到就回 `Ambiguous`」+ 逐字精確比對(不 trim、不忽略大小寫)嗎?(是/否)

```
- ASM-2: `lookupSelector` 的**命中集合語意**——(i) `veId` 階段命中兩列以上時,與 `veName` 撞名
  **走同一套處置**(回 `VaultSelectorAmbiguous` 帶全部命中列),而不是取第一列;(ii) 兩階段
  都是**逐字精確比對**(不去前後空白、不忽略大小寫)。契約卡只規定了「id 優先」與「同名撞名
  回全部」兩件事,沒有規定 id 撞號怎麼辦(契約 B 說 `veId` 中樞內唯一,但 `Hub` 是不透明型別、
  `mkHub` 又是公開的建構入口,測試造得出重複 id 的 `Hub`),也沒有規定大小寫與空白。
  - 契約錨點:design.md 契約 C 的 `lookupSelector` 與「第二參數(三個 `resolve*`)」那一列
    (「selector 先比 `veId` 的完整字串,再比 `veName`」);契約 B 的 `veId` 值域(「中樞內
    唯一」)與 `veName` 值域(「非空;允許重複」);契約 F 的 `VaultSelectorAmbiguous`
  - 層級自答:出現在邊界上?**會**(它決定 `--vault X` 這個使用者輸入被接受還是被拒,那是
    system.md 的對外 CLI 契約);改錯驚動其他模組?**要**(F003 三個裁決函式與 F004 的
    `forgetVault` 都寫明「比對規則同 `lookupSelector`」)
  - 選項:
    a) **兩階段同一套命中集合規則 + 逐字精確比對(本 spec 採用)**——當下成本:多兩條 law
       與三個 example;三個月後代價:使用者打 `--vault Alchbees-Assets` 會被拒,要自己改大小寫
       ——但錯誤訊息(`VaultSelectorNotFound`)已經說了「請確認 id 或名稱是否正確,或先執行
       vault list」,改得掉
    b) **id 階段撞號時取第一列,只有 name 撞名才回 `Ambiguous`**——當下成本:零;三個月後
       代價:一份手寫的中樞若真的出現重複 id(`loadHub` 擋得掉,但 `mkHub` 造得出來、
       F004 的 `initVault` 也在撞號時才回 `VaultIdCollision`),`--vault <該 id>` 會**靜默**
       選中其中一個,而 ADR-017 對「兩個東西帶同一個 vault id」的一貫立場是「身分不確定時
       不能靜默帶過」(graph-core 的 `VaultIdCollision`、`loadHub` 的 `HubMalformed` 都是
       這個立場)——這裡開一個例外,以後查起來會很難
    c) **selector 比對前先 `T.strip`、且忽略大小寫**——當下成本:兩行;三個月後代價:
       `veName` 是使用者自己取的 Text,忽略大小寫會讓兩個原本合法共存的名字(`Lore` 與
       `lore`)突然變成撞名,而中樞裡它們是兩列合法的資料;而且 id 是小寫十六進位,放寬對它
       沒有任何好處
  - 傾向:a。理由是它讓「身分不確定就明講」在整個系統只有一種行為(與 `loadHub` 的
    `HubMalformed`、graph-core 的 `VaultIdCollision` 同一個立場),而 c 引入的撞名是**新造
    出來的**問題。依賴的前提:`--vault` 的字串來自 `shell` 原樣傳入、不做任何正規化
    (ADR-015 第三條「`shell` 零業務邏輯」),所以這一層看到的就是使用者打的字——這一點由
    design.md 對外契約段的「`shell` 不直接 import 本套件,只把 `--vault` 的字串原樣交給
    `service`」佐證。可逆性:**可逆**——放寬(改成 b 或 c)不會讓任何既有的中樞檔變成非法,
    也不會讓原本成功的指令失敗;收緊才會
  - 暫採:a → 影響:若裁決成 b,LAW-7 拆成兩條(id 階段取 `head`、name 階段回 `Ambiguous`),
    EX-8 不變、要新增一個「重複 id」的 example;若裁決成 c,LAW-8 整條改寫,EX-11 / EX-12 的預期從
    `VaultSelectorNotFound` 改成 `Right e1`
```

---

### `.design/subsystems/workspace/features/F005-project-registry.md`

ASM-1 / ASM-2 / ASM-5 有 2026-08-29 WAVE-4 閘門裁決欄;ASM-3 / ASM-4 由編排者降級(「不上議程,暫採維持不變」)。
**只剩 ASM-6 沒有裁決欄**——而且它是 WAVE-4 裁決 ASM-1 之後**新造出來**的縫,條目自己寫著
「不定義就是把一條 spec-gap 留到仲裁那一輪」。`## 實作備註` 的「WAVE-4 閘門裁決的回寫」只處理 ASM-1 / ASM-2 / ASM-5。

#### ASM-6

**涉及**:`registerProject` 的 `ProjectAlreadyRegistered Id FilePath` 觸發條件;`ProjectEntry.pePath` 的正規化(`canonicalizePath`);`loadHub` / `parseProjectEntry` 的 `isAbsolute` 檢查;LAW-4(c) / LAW-9 / EX-29

**要裁決什麼**:「同一個路徑」只比對「這次正規化後的 `dir'` 逐字等於既有列的 `pePath` 原文」(不對既有列重新正規化、也不把「必須正規化」升進契約 B)嗎?(是/否)

```
- ASM-6: **「同一個路徑」的判準**——本 spec 以「這次正規化後的 `dir'` **逐字等於**中樞某一列的
  `pePath`」為 `ProjectAlreadyRegistered` 的觸發條件,**不對既有列重新正規化**。這是 WAVE-4 裁決
  (ASM-1 選 b)**新造出來**的一個縫:裁決給了建構子與訊息,但沒有定義「同一個路徑」怎麼算,而那
  正是它唯一的觸發條件——不定義就是把一條 spec-gap 留到仲裁那一輪。
  - 契約錨點:契約 F 的 `ProjectAlreadyRegistered Id FilePath`(WAVE-4 新增)的**觸發條件**;
    契約 B 的 `ProjectEntry.pePath` 值域(「絕對路徑」——**沒有**說「正規化後的絕對路徑」);
    契約 A 的「`loadHub` 的合規判準」(只驗 `isAbsolute`,不驗正規化);契約 D 的 `registerProject`
  - 層級自答:出現在邊界上?**會**(它決定 `registerProject` 什麼時候回 `Right`、什麼時候回
    `ProjectAlreadyRegistered`,那是 WAVE-4 裁決剛剛新增的對外行為);改錯驚動其他模組?**要**
    (`loadHub` 對 `pePath` 只驗 `isAbsolute`,選項 c 會反過來要求它多驗一件事,而 `Hub.hs` 是
    F001 的檔案)
  - 選項:
    a) **逐字比對正規化後的新路徑 vs 既有列的 `pePath` 原文(本 spec 採用)**——當下成本:零,
       純字串比對、不多做任何 IO;三個月後代價:中樞裡**手寫的、未正規化**的絕對路徑
       (`D:/games/../games/Circle`)擋不住,那個目錄仍能被註冊成第二列——而重複列正是 WAVE-4 裁決
       要消滅的東西,所以這個洞是裁決意圖的一個缺口(已由 EX-29 明文斷言,不是靜默的行為)
    b) **對既有每一列的 `pePath` 也跑一次 `canonicalizePath` 再比**——當下成本:每次註冊多 N 次
       檔案系統 IO;三個月後代價:`canonicalizePath` 對**不存在**的路徑雖然不拋例外(WAVE-2 實測),
       但它對已刪除目錄的輸出是「字串層面解 `.` / `..`」而非真實解析,同一列在目錄存在與不存在
       時可能得到不同結果——於是「這次擋不擋得住」會取決於**別的專案目錄還在不在**,那是一條
       很難解釋的行為;而且純函式的部分被拖進 IO
    c) **把「`pePath` 必須是正規化後的路徑」升進契約 B 的值域,由 `loadHub` 驗**——當下成本:
       要改 F001 的 `Hub.hs`(`parseProjectEntry` 多驗一條)與契約 B 的值域欄;三個月後代價:
       最小,判準恒成立,a 的缺口消失。但它會讓**手寫**的中樞更難寫(使用者要自己寫出正規化
       後的路徑,寫錯就是 `HubMalformed`),而 ADR-017 決策二把「可手寫」列為中樞的性質
  - 傾向:a。理由是缺口只出現在「使用者手寫了一個未正規化的絕對路徑」這條路徑上,而由
    `registerProject` 寫出去的列**永遠是正規化後的**(LAW-4(c)),所以工具自己產生的資料一定擋得住;
    b 引入的「行為取決於別的目錄還在不在」比它要解決的問題更難解釋;c 客觀上最乾淨,但它拿
    「可手寫」去換,而那是 ADR-017 明文的性質。依賴的前提:`loadHub` 不會把未正規化的絕對路徑
    判成不合規——成立,`parseProjectEntry` 只呼叫 `isAbsolute`(相依性查證 1)。
    可逆性:**可逆**——改成 b 或 c 只會讓原本成功的第二次註冊變成 `Left`,不會讓任何既有中樞檔
    變成非法(c 除外:c 會讓既有的手寫未正規化列變成 `HubMalformed`,那是**破壞性**的,要配
    遷移說明)
  - 暫採:a → 影響:若裁決成 b,LAW-9 的判準句改寫成「對既有列也正規化後再比」、EX-29 的預期從
    `Right` 改成 `Left (ProjectAlreadyRegistered ...)`;若裁決成 c,除上述之外還要改 F001 的
    `Hub.hs` 與契約 B 的 `pePath` 值域,並補一條「既有手寫中樞可能因此變成 `HubMalformed`」的
    遷移說明
```

---

## 三、已結案假設(50 條,含出處)

| 文檔 | ASM | 結案處 / 一句話 |
|---|---|---|
| graph-core/F002 | ASM-1 | 條目標題自帶「(**已裁決**,2026-08-23 階段一閘門)」——原判斷被開發者推翻,`parseLogicalName` 訂正為 `NamingVocab -> Text -> Either NameError NameParts`、variant/state 語意保留、只留 `nvStates` 一張表 |
| graph-core/F003 | ASM-1 | `## 已裁決假設(2026-08-23 階段一閘門)`:「**接受,維持現狀**」——`imageMeta` / `audioMeta` 留在 `aapms-core` |
| graph-core/F003 | ASM-2 | 同上:「**要改**」——`ManifestAsset.maPack` / `maLicense` 改 `Maybe Ref`,二輪再把 `mpId` / `mlId` / `mpLicense` 一併 vault 化 |
| graph-core/F003 | ASM-3 | 同上:「**接受,維持現狀**」——頂層 `packs` / `licenses` 去重清單保留 |
| graph-core/F003 | ASM-4 | 同上:「**接受,維持現狀**」——`StoryManifest` 保留獨立 `schemaVersion` |
| graph-core/F004 | ASM-8 | `## 已裁決紀錄(2026-08-25 spec 閘門)`:「一半照做,一半推翻」——`nsLevel` 不符維持 `HeadingSkip`,新增 `HeadingTooDeep Int Int` |
| graph-core/F004 | ASM-9 | 同上:「**接受,照做**」——`insertSection` 也檢查 `nsId` 撞號 |
| graph-core/F004 | ASM-10 | 同上:「**接受,但措辭收窄**」——`blankTail` 是冪等的,LAW-33 / LAW-34 改成收窄版本 |
| graph-core/F004 | ASM-11 | 同上:「**裁決:推翻。改用 `newtype FrontExtras = FrontExtras MetaExtras`**」 |
| graph-core/F004 | ASM-12 | 同上:「**裁決:接受**」——`updateFrontmatter` 本體留在原地,由 LAW-45 / LAW-46 的紅燈驅動 |
| graph-core/F006 | ASM-1 | 條目標題自寫「(已由開發者裁決並落地,不再是待確認項,保留記錄供追溯)」——`openVault` 改吃 `TypeRegistry`、`VaultHandle` 加 `vhRegistry`(commit `5de2727` 改契約、`8ae2c31` 落地) |
| graph-core/F007 | ASM-3 | 條目標題自寫「(2026-08-24 依開發者裁決改寫,原版見 spec-gaps GAP-5)」;`spec-gaps.md` GAP-5 狀態 `resolved (2026-08-24 開發者裁決)`——`desegmentCjk` 整個撤除、LAW-4 撤銷、`shSnippet` 一律取自 `fts_tri` 原文 |
| graph-core/F008 | ASM-1 | `## 已裁決的假設(2026-08-25 閘門)` 表:「**接受**,回寫契約 E」(`design.md:317`) |
| graph-core/F008 | ASM-2 | 同表:「**推翻**:15 個建構子併進 `StoreError`,刪 `WriteStore` 與 `renderStoreWriteError`」 |
| graph-core/F008 | ASM-3 | 同表:「**推翻**:改 `IO (Either StoreError Id)`,查詢失敗即失敗」 |
| graph-core/F008 | ASM-4 | 同表:「**推翻**:F004 GAP-2 重跑已把它們放進 `Aapms.Md.Render`,store 改成 re-export」 |
| graph-core/F008 | ASM-5 | 同表:「**推翻**:加 `SectionPlacement`;`UnderParent` 時 `nsLevel` 由 `headingDepthFor` 推導」 |
| graph-core/F008 | ASM-6 | 同表:「**補上**:`Aapms.Store` re-export `Create` 與 `Write`」 |
| graph-core/F009 | ASM-1 | `## 已裁決紀錄(原「待確認假設」)`(2026-08-26 spec 閘門):「**部分推翻 → 分案**」——`listAcross` 走 SQL、`searchAcross` 走 Haskell,ADR-017 第四條已附修訂說明 |
| graph-core/F009 | ASM-2 | 同節(段首「六條假設於 **2026-08-26 的 spec 閘門全部裁決完畢**」);契約 E 已回寫 `closeVaultSet` / `vaultSetIds` / `maxAttachedVaults` |
| graph-core/F009 | ASM-3 | 同節;`DanglingRef` / `DanglingReason` 的形狀已回寫契約 E |
| graph-core/F009 | ASM-4 | 同節;`TooManyVaults` 進 `StoreError`,`renderStoreError` 補分支 |
| graph-core/F009 | ASM-5 | 同節:「**推翻**」——新增 `VaultIdCollision VaultId FilePath FilePath`,不靜默去重(EX-13) |
| graph-core/F009 | ASM-6 | 同節;跨 vault 的 `FacetCounts` 語意已回寫契約 F |
| service/F001 | ASM-1 | 段首「三條全部在 **WAVE-1 的 spec 批准閘門(2026-08-30)裁決完畢,結論一律是「接受暫採」**」;`RegistryUnavailable RegistryError` / `RegistryLoadFailed RegistryError`,design.md 契約 F 已回寫 |
| service/F001 | ASM-2 | 同上;採一組九個 `ServiceM` 動作(八個 `ask*` + `reloadHub`),模組間公開介面表已補 `Machine / Read / Write → Monad` |
| service/F001 | ASM-3 | 同上;`handleFor` 簽名不動,另加 `indexIssuesFor` |
| service/F002 | ASM-1 | 條目末「**已裁決(2026-08-30 WAVE-2 閘門):採 b**」——六個 View 型別搬到 `Aapms.Service.Types` |
| service/F002 | ASM-2 | 同上:「採 b」——`workspaceSetup :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)`,先於環境 |
| service/F002 | ASM-3 | 同上:「採 b」——`vaultInit` 改回 `ServiceM (VaultView, AdoptNotice)` |
| service/F002 | ASM-4 | 同上:「採 b」——模組間公開介面新增 `Machine → Monad`(`handleFor`),`vaultInfo` 直接開目標 vault |
| workspace/F003 | ASM-1 | 條目末「**裁決(2026-08-29 WAVE-3 閘門):選 c**」——契約 F 新增 `WriteTargetIdDrift VaultId FilePath VaultId` |
| workspace/F004 | ASM-1 | 段首「**全部八條已於 2026-08-29 WAVE-4 閘門處理完畢,沒有任何一條未結**」;本條「編排者降級,維持 a」 |
| workspace/F004 | ASM-2 | 同節:「編排者降級,維持 a」——名稱寫進 marker 與中樞前先 `T.strip` |
| workspace/F004 | ASM-3 | 同節:「編排者降級,維持 a」——撞號時回滾剛寫出的 `.aapms/` |
| workspace/F004 | ASM-4 | 同節:「編排者降級,維持 a」——`addVault` 對已在中樞的 id 走 `upsertVault` |
| workspace/F004 | ASM-5 | 同節:「**暫採 a 的前半被推翻,改為 b 的變體(裁決 B)**」——刪索引前先驗身分 |
| workspace/F004 | ASM-6 | 同節:「**選 b**」——契約 F 新增 `VaultInitFailed` |
| workspace/F004 | ASM-7 | 同節:「編排者降級,維持 a」——`setupHub` 寫出空中樞 |
| workspace/F004 | ASM-8 | 同節:「**選 b**」——契約 F 新增 `DeleteTargetIdDrift` |
| workspace/F005 | ASM-1 | 條目內「**2026-08-29 WAVE-4 閘門裁決:選 b**」——契約 F 新增 `ProjectAlreadyRegistered Id FilePath` |
| workspace/F005 | ASM-2 | 同上:「**選 c**」——契約 F 新增 `ProjectSelectorAmbiguous Text [ProjectEntry]` |
| workspace/F005 | ASM-3 | 「**2026-08-29 WAVE-4 閘門:編排者降級,不上議程**」——沿用 WAVE-2 的 `canonicalizePath`,spec 一字不改 |
| workspace/F005 | ASM-4 | 同上降級——trim 是被 WAVE-2 的逐字精確比對裁決逼出來的,不是新選擇 |
| workspace/F005 | ASM-5 | 「**選 a**,而且**升格**」——`allocateProjectId` 直接收進契約 D |
| workspace/F006 | ASM-1 | 條目末「**裁決(2026-08-29 WAVE-4 閘門):選 a,注入接縫進契約**」——契約 E 增列 `ToolSearchPlan` 與 `detectSevenZipIn` |
| workspace/F006 | ASM-2 | 「**編排者降級,不上閘門,暫採 a 即定案**」——`doesFileExist` + `getPermissions.executable`,理由記在 `build-log.md` |
| workspace/F006 | ASM-3 | 同上降級——自走 `PATH`、不用 `findExecutable`;design.md「使用的技術」那一行已依本條理由改掉 |
| workspace/F006 | ASM-4 | 同上降級——`tsSearched` 記「每一個被判準問過的完整檔案路徑」 |
| workspace/F006 | ASM-5 | 同上降級——`tsPath` / `tsSearched` 一律逐字捧著,不正規化 |

> **口徑提醒**:表中 11 條的處置是「**編排者降級,不上閘門,暫採即定案**」
> (workspace/F004 的 ASM-1/2/3/4/7、F005 的 ASM-3/4、F006 的 ASM-2/3/4/5)。
> 它們有明確處置、spec 一字不改,本報告算「已結案」;若貴方要求「必須是開發者裁決」才算結案,
> 把這 11 條移到未結案,總數就是 **51 條未結**。

---

## 四、spec-gaps 未結案的 GAP

掃了三份 `spec-gaps.md`,**只有兩條狀態是 `open`,都在 workspace**:

### GAP-6(workspace/F004-vault-lifecycle / arch-audit)

- 檔案:`.design/subsystems/workspace/spec-gaps.md:107`,狀態 `open`
- **需要回答什麼**(逐字):

```
- **需要 spec 回答什麼**:三個備選,要開發者選一個——(a) LAW-50 改寫成兩個**相異**目錄的等價性,
  並明列比較欄位,把 `vePath` 從「一致」改成「各自等於自己的正規化路徑」;(b) 只補一條
  `initVaultWith` 的 `vePath` 斷言,形狀比照 `LifecycleSpec.hs:605`;(c) 把「`vePath` 一律等於
  `canonicalizePath` 的結果」提成一條獨立的 law,讓兩個入口共用——這比在兩處各寫一條更貼近
  「契約 B 的那一欄只有一種正規化」。
```

- 一句話:`initVaultWith` 這個入口的 `vePath` 目前**零斷言**,靠實作剛好對守著;LAW-50 字面要求的情境不可達(同一個 `d` 呼叫兩次必回 `VaultAlreadyInitialized`)。

### GAP-7(workspace/F004-vault-lifecycle / arch-audit)

- 檔案:`.design/subsystems/workspace/spec-gaps.md:135`,狀態 `open`
- **需要回答什麼**(逐字):

```
- **需要 spec 回答什麼**:二擇一——(a) 補一條逐字比對 `initVault` 簽名行的測試,比照本子系統
  既有的 `lifecycleImportLines` / LAW-42 手法(`LifecycleSpec.hs:1146` 附近),比對前去除行尾 `\r`;
  或 (b) 把 REG-1 的措辭從「逐字等於」放寬成「arity 與參數型別不變」。重點是條文與驗證手段一致。
```

- 一句話:REG-1 說「簽名**逐字**等於」,但驗證手段只是「呼叫端編譯得過」;`type FilePath = String`,換掉字面仍然全過。**實際風險:低**(條目自評)。

### 其餘 GAP 一覽(全部 resolved)

| 檔案 | GAP | 狀態 |
|---|---|---|
| graph-core/spec-gaps.md | GAP-1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 17, 18, 19, 20 | 全部 `resolved` |
| service/spec-gaps.md | GAP-1, 2 | 全部 `resolved` |
| workspace/spec-gaps.md | GAP-1, 2, 3, 4, 5 | 全部 `resolved` |

> 編號註記:`graph-core/spec-gaps.md` **沒有 GAP-10 與 GAP-11**(從 GAP-9 直接跳到 GAP-12,
> 且三份檔案全文都搜不到這兩個編號)。可能是開了又撤、或編號預留;若要對帳 GAP 總數請留意這個缺口。
