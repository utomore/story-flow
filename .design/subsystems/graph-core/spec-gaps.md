---
id: graph-core-spec-gaps
type: spec-gaps
title: graph-core-spec-gaps
description: graph-core 委派過程中 qa / impl 撞到的 spec 缺口與裁決
status: in-progress
created: 2026-08-24
updated: 2026-08-25
parent: graph-core
---

# graph-core spec 缺口

## G1(F004 / impl → F008 / spec)

- **模糊點**:契約 E 的 `NewSection` 只有 `nsMeta :: MetaOverride` 一個管道寫節層欄位,而
  `MetaOverride`(`md/src/Aapms/Md/Inherit.hs:46-58`,13 個欄位)**沒有** asset 的 `sha256` /
  `entry` / `ext` / `meta` / `license` / `author`,也沒有 license 的八個授權維度
- **卡住的項目**:`appendSection` 與契約 E 的 `addSection` / `createPackFile` 寫不出能通過
  `toPack` / `toLicenses` 驗證的完整新節;F008 的驗收標準「`createPackFile` 在指定目錄寫出 `pack.md`,
  節的順序與給定順序相同」因此做不下去
- **需要 spec 回答什麼**:節層的型別專屬欄位要走哪個管道?
- 狀態:resolved (2026-08-24 開發者裁決)——`NewSection` 改成對節點種類做 sum
  (`NewSectionPayload` = `NSFragment` / `NSAsset` / `NSLicense` / `NSNode`,封閉建構子),
  `addSection` 維持單一入口依 payload 分派。已回寫 `design.md` 契約 D;
  `createPackFile` 第三參數連帶由 `[NewAsset]` 改為 `[NewSection]`(契約 E)

## G2(F008 / spec)—— 已重現的資料遺失缺陷

- **模糊點**:不是 spec 模糊,是**已交付的程式碼有缺陷**。`Aapms.Md.Render.reserialize`
  (`md/src/Aapms/Md/Render.hs:98`)在 `updateSection` 時用 `renderMetaBlock`
  (`:384`)**整塊重寫** ` ```meta ` 區塊,而 `renderMetaBlock` 只認得 `MetaOverride` 的 13 個欄位
  (`field` 的 catch-all 是 `_ -> []`)。`AssetFields` / `LicenseFields`(`Parse.hs:216` / `:281`)
  從同一個區塊解出來,卻不在 `MetaOverride` 裡
- **後果**:對 pack.md 的 asset 節或 licenses.md 的 license 節做**任何** `updateSection`,都會
  **靜默刪掉** `sha256` / `entry` / `ext` / `meta` / `license` / `author` 與八個授權維度。
  依 ADR-013,`pack.md` 是素材中繼資料的**真相**——這等於永久破壞「這個節點指向壓縮檔的哪個條目」
  與內容雜湊
- **編排者實測重現**(2026-08-24,GHCi 對 `c9f6fe4` 的程式碼):對一個含
  `sha256: deadbeef1234` / `entry: PNG/a.png` 的 asset 節呼叫
  `updateSection aid (\o -> o { moSummary = Just "after" })`,寫回後那兩行消失
- **為什麼沒被測到**:`md/test/` 沒有任何測試把 `updateSection` 與 `sha256` 放在一起
- 狀態:resolved (2026-08-24,F004 重跑完成並經編排者以原重現案例驗證:`SHA256_KEPT True` / `ENTRY_KEPT True` / `SUMMARY_NEW True`)。原處置:由 **F004 重跑**修復(2026-08-24 開發者裁決),與 G1 同一個根
  (`MetaOverride` 是唯一管道),一併處理:`Render` 要支援 payload 專屬欄位的序列化,
  並新增 payload 保留的編輯路徑讓 `updateSection` 不再吃掉節專屬欄位

## G3(F007 / qa)

- 模糊點:L23「`store/src` 底下所有 `.hs` 原始碼都不含 `LIKE` 這個 SQL 關鍵字(不分大小寫的
  獨立詞)」沒有說「原始碼」是否包含 Haddock 註解文字。字面讀法(掃描整個檔案的文字,不分
  code/comment)與「只掃實際會送進 SQLite 的字串常量」兩種讀法會給出不同結果——而
  `store/src/Aapms/Store/Query.hs:16` 的骨架註解本身就寫著
  `-- 而不是 @Maybe Double@。__沒有 @LIKE@ 掃描路徑__:那是 trigram 三字元下限的`,
  `LIKE` 以獨立詞出現在雙 `@` 之間。這份骨架是設計階段交付的,qa 依 spec-roles.md 不得修改
  骨架(含註解)
- 卡住的項目:L23 的 property/example test。逐字照字面讀法寫,測試現在就會紅
  (不是因為 `undefined`,是因為骨架註解本身),而且這個紅燈在 impl 填完 `search`/`routeOf`
  等函式本體後也不會消失,因為註解不屬於 impl 的職責範圍(impl 不能改骨架簽名,註解算不算
  骨架的一部分沒有寫清楚);若改成「只掃字串常量」讀法,又需要能分辨字串常量與註解,這已經
  超出「掃原始碼有沒有出現某個獨立詞」這個 Law 字面所定義的機械驗證範圍
- 需要 spec 回答什麼:L23 的「原始碼」是否排除 Haddock 註解?若排除,要不要把
  `Query.hs:16` 的骨架註解改寫(拿掉獨立詞 `LIKE`,例如改成 `%LIKE%` 或拆成
  `LI` <> `KE`)當作骨架修訂的一部分一併發下來,讓這條 Law 對「現在的骨架」就是可驗證的?
- 當初的處置(已被下方的 resolved 取代,保留原文供追溯)(**impl 附註,2026-08-24**:骨架註解 `Query.hs:16` 已由 impl 改寫,拿掉了獨立詞
  `LIKE`——這是註解文字的實作層級調整,不是骨架簽名\/型別,依 spec-roles.md 屬 impl 自主權
  範圍。字面讀法之下,`store/src` 現在確實不含獨立詞 `LIKE`(已用
  `grep -rniE "\bLIKE\b" store/src/` 覆核)。但 G3 問的「原始碼是否排除 Haddock 註解」這個
  語意問題本身仍未解:qa 若已依字面讀法寫死斷言字串,或未來任何人在註解裡再次寫下這個詞,
  同樣的爭議會重演,狀態維持 open 讓編排者\/開發者定調)
- 狀態:resolved (2026-08-24 開發者裁決 → spec 已修訂):**L23 撤銷**,F007 spec 的 Laws 段以刪除線
  保留原文並附撤銷理由,編號不重編;`Query.hs` 的模組 Haddock 改成引用 L9 / L10(「只有兩條路,沒有
  第三條」)。qa 不再需要 L23 的測試,`TokenizeSpec.hs` / `SearchSpec.hs` 開頭關於 L23 的說明可一併移除

## G4(F007 / impl)

- 模糊點:L4「對所有 `t`,`desegmentCjk (cjkSegment t) == T.unwords (cjkRuns t)`」在 `cjkSegment`
  的既定輸出格式(「先所有 unigram、再所有 bigram,以單一空白分隔」,由「介面」段與
  E1–E3 的具體字串釘死,impl 不能改)之下,對某些輸入**不可能**被任何 `desegmentCjk` 實作滿足
  ——不是實作能力問題,是資訊遺失:可構造出 `t /= t'`(僅差在 CJK 連續段之間的空白位置)使得
  `cjkSegment t == cjkSegment t'`,但 `T.unwords (cjkRuns t) /= T.unwords (cjkRuns t')`
- 卡住的項目:L4(全稱量詞版本)。具體反例:`t = "乙甲 甲甲乙"`、`t' = "乙甲甲 甲乙"`
  (皆為構造用的示意中文字元,重點是同一字元在不同位置重複出現)。兩者 `cjkRuns` 不同
  (`["乙甲","甲甲乙"]` vs `["乙甲甲","甲乙"]`),但因為兩個相鄰 run 邊界處剛好是同一個字元
  的重複(`...甲 | 甲甲...` 這段,邊界落在哪個「甲」純屬巧合地產生相同的 bigram 多重集合,
  且此組"甲甲" bigram 在 token 串裡的相對順序也相同),`cjkSegment` 對兩者的輸出逐字元相同
  (`unigrams = [乙,甲,甲,甲,乙]`、`bigrams = [乙甲,甲甲,甲乙]`,順序皆同)。`desegmentCjk`
  是同一個輸入字串的確定性函式,不可能同時等於兩個不同的 `T.unwords (cjkRuns _)`
- 需要 spec 回答什麼:L4 的「對所有 `t`」是否有意排除這種因重複字元導致 run 邊界資訊遺失的
  病態輸入(改成有條件的 law,例如限定 `t` 不含連續三個以上相同字元跨越邊界,或改用某種
  qa 可驗證的較弱陳述)?或者 `cjkSegment` 的輸出格式需要調整(例如在 bigram 區塊裡插入一個
  非 token 的邊界標記)讓 `desegmentCjk` 原則上可逆——但那會動到 E1–E3 已經釘死的字面輸出,
  屬架構層級的格式決定,不是 impl 能自主換的
- **impl 已完成的處置**(不腦補、不留 `undefined`):`desegmentCjk` 實作了一個貪婪還原演算法
  (見 `Tokenize.hs` 的 Haddock),對 E1–E3 給定的 Example 與絕大多數真實輸入(不含上述病態
  重複模式)都能正確還原;僅在上述病態輸入類別下可能給出與 `T.unwords (cjkRuns t)` 不同的
  結果。理由:`search` 的 CJK 片段還原(A3)與其他多條 Law/Example 都直接依賴一個能跑的
  `desegmentCjk`,若整個函式留 `undefined`,會連帶讓所有 CJK 命中路徑的片段輸出崩潰,影響
  範圍遠大於這個病態子集;因此選擇實作可用版本 + 記錄此 gap,而非整項停工。若編排者認為這個
  處置不恰當(應該整項停工等 spec 修訂),請指示回退
- 狀態:resolved (2026-08-24 開發者裁決 → spec 已修訂):**L4 撤銷**,且 `desegmentCjk` 在失去
  snippet 這個唯一消費者後**整個從介面與骨架移除**(`Tokenize.hs` 的匯出與定義都已刪除,`cjkSegment`
  的 Haddock 加了「這個表示法是單向的,沒有反函式」的說明防止有人再加回去)。qa 要刪掉
  `TokenizeSpec.hs` 的 `prop_L4` 與對 `desegmentCjk` 的 import

## G5(F007 / 編排者仲裁)—— 與 G4 同一個根

- **模糊點**:A3 要求「`fts_cjk` 命中時把 `snippet()` 的輸出經 `desegmentCjk` 還原成連續文字」,
  但 **L4 只定義 `desegmentCjk` 在完整 `cjkSegment t` 輸出上的行為**。FTS5 的 `snippet()` 回的是
  欄位內容的**一段視窗**,永遠不是某個 `t` 的完整 `cjkSegment` 輸出——spec 把函式用在定義域外
- **編排者實測**(2026-08-24,對 impl 交付的程式碼):
  - `cjkSegment "魔法藥水瓶"` = 5 個 unigram + 4 個 bigram,共 9 個 token
  - `desegmentCjk` 吃**完整 9 個 token** → `"魔法藥水瓶"`,**L4 成立(True)**
  - `desegmentCjk` 吃**前 3 個 token** → `"魔 法 藥"`,接不回去(沒有 bigram 佐證相鄰)
  - E6 觀察到的 `"魔法藥 水 瓶"` 正是片段輸入的必然結果
- **卡住的項目**:E6(`shSnippet` 含「藥水」)。**歸因:spec bug**,不是 impl 錯也不是 qa 誤讀
- **與 G4 的關係**:同一個根——「先所有 unigram、再所有 bigram」這個切詞表示法**本來就不是為了可逆
  而設計的**,而 spec 在兩個地方假設它可逆(L4 的全稱量詞、A3 的 snippet 還原)
- **需要 spec 回答什麼**:CJK 命中時的 snippet 要從哪裡取?
  編排者建議的方向:`fts_tri` 存的是**原始文字**(trigram tokenizer 不做應用層預切),
  所以 snippet 從 `fts_tri` 的內容取就是自然的連續文字,`desegmentCjk` 可以整個退出 snippet 路徑;
  L4 則應改成有條件的 law 或直接撤掉
- 狀態:resolved (2026-08-24 開發者裁決,見下)

---

## 2026-08-24 開發者裁決(G3 / G4 / G5)

三條一起解,因為 G4 與 G5 同一個根:**「先所有 unigram、再所有 bigram」的切詞表示法本來就不是為了
可逆而設計的**,而 spec 在兩處假設它可逆。

- **G5(snippet)**:`desegmentCjk` **整個移出 snippet 路徑**。`fts_tri` 存的是**原始文字**
  (trigram tokenizer 不做應用層預切),所以不論命中來自哪張表,`shSnippet` 一律從 `fts_tri` 的
  內容取——拿到的就是自然的連續文字。A3 要改寫,E6 的期望(snippet 含「藥水」)因此成立
- **G4(L4)**:`desegmentCjk` 失去 snippet 這個消費者後,L4 的全稱量詞失去存在理由。
  **撤掉 L4**(或改成有條件的 law);`desegmentCjk` 若已無消費者就一併從介面移除
- **G3(L23)**:**撤掉 L23**。用文字掃描斷言「某個關鍵字不在原始碼裡」本來就分不出註解與程式碼
  ——這正是它撞到骨架自身註解的原因。它想保證的事(沒有 `LIKE` 掃描路徑)已由 L9 / L10 的
  路由 law 涵蓋:查詢一定走 trigram 或 cjk 兩條 FTS 路徑之一,沒有第三條路

**執行**:由 spec 角色修訂 F007 的 spec 與骨架,再重跑受影響的 qa 與 impl。

## G9(F008 / qa)

- **模糊點**:`Aapms.Store.Node.isRootNode :: FilePath -> Document -> Id -> Either StoreError Bool`
  (骨架 `Node.hs:60`)__沒有任何 Law 或 Example 定義它的行為__。它的 haddock 只說「這個 id
  是不是該 Level 檔的根 Node」,對「`id` 不在檔案裡時」該回 `Right False`(不是根,合法回答)
  還是 `Left (SectionMissing _ id)`(id 查無此節,錯誤)完全沒有著墨——兩種讀法都與
  「是不是根 Node」這句話字面相容
- **卡住的項目**:`isRootNode` 的 property test 與 example test,整條停下,本檔（`NodeSpec2.hs`）
  未對它寫任何斷言
- **需要 spec 回答什麼**:`isRootNode` 對「`id` 不在 `doc` 裡」這個輸入該回什麼?比照
  `headingDepthFor` / `subtreeAfter`(haddock 明說「節不存在時是空清單」)訂出對稱的規則,
  或者乾脆補一條 Law
- 狀態:open

## G7(F008 / qa)—— 已縮小範圍:`SqliteError` 的既有訊息與 L15 字面不符

- **模糊點**:L15 要求「`renderStoreError e` 非空,且含至少一個以『請』起頭的子句」,範圍是
  `StoreError` 的全部 21 個建構子,__含 F005 已實作的 6 個__(spec 明說這 6 個應為綠)。
  但 `Aapms.Store.Error.renderStoreError` 對 `SqliteError` 的既有實作(`Error.hs:96-97`)是
  `"索引操作失敗 —— " <> msg <> ";可以嘗試重新開啟 vault"`——用「可以嘗試」收尾,**不含任何
  以「請」起頭的子句**。這與 F005 原本 `Aapms.Store.ErrorSpec` 的 `actionable` 判準
  (「請」/「改用」/「可以」/「才」四選一)不同;F008 的 L15 字面把可接受的動詞窄化成只剩「請」
- **已排除的偽陽性**:同一輪還發現 `VaultAlreadyInitialized`(F005 既有,亦應綠)的訊息
  「……不會覆寫;如需重建,請先手動移除該檔案」__其實有__以「請」起頭的子句(在 ASCII 逗號
  `,` 之後),第一版測試的 `hasQingClause` 判準漏了 ASCII 逗號這個分句符號,已在
  `StoreErrorL15Spec.hs` 修正、該筆現在正確判定為綠——只有 `SqliteError` 是真正的字面不符
- **卡住的項目**:`StoreErrorL15Spec.hs` 對 `SqliteError` 的「含以請起頭的子句」斷言;已改寫成
  一則刻意會紅、標明「spec-gaps G7」的測試,而不是悄悄放寬判準讓它變綠
- **需要 spec 回答什麼**:L15 的「以『請』起頭的子句」是否要放寬回 F005 `actionable` 的四選一
  (「請」/「改用」/「可以」/「才」),或者 `SqliteError` 的訊息文字要改成含「請」的子句(例如
  「……；請嘗試重新開啟 vault」)?這是文字選擇,但既然 L15 把它寫成可機械驗證的斷言,誰改
  由開發者定
- 狀態:open

## G8(F008 / qa)

- **模糊點**:E6「人為製造碰撞」的情境是「索引裡已存在 `newId p c t 0` 與 `newId p c t 1`
  兩個 id;`allocateId vh p c` 回 `Right i`,且 `i` 與那兩個都不同(實作上即 salt = 2 的
  那一個)」。但 `allocateId :: VaultHandle -> IdPrefix -> Text -> IO (Either StoreError Id)`
  的簽名__沒有時間注入點__——`t`(`newId` 的第三個參數)是 `allocateId` 內部呼叫
  `getCurrentTime`(或等價機制)取得的,呼叫端無從得知、也無法控制它會在呼叫的哪一刻取樣
- **卡住的項目**:E6 本身。要「人為製造碰撞」必須預先把 `newId p c t 0` / `newId p c t 1`
  寫進索引,但這需要**先知道** `allocateId` 這次呼叫內部即將使用的確切 `t`——這在公開介面上
  觀察不到,也控制不到(呼叫兩次 `allocateId` 之間去猜測、去外部量測目前時間再手算
  `newId`,仍可能與函式內部實際取樣的時間點有微秒級落差,導致預先插入的 id 根本不是它會
  嘗試的那個候選)。`WriteSpec.hs` 因此只測了 L14(連續呼叫互異,每次把結果寫回索引)與
  L14b/E15(索引查詢失敗即失敗,用 `DROP TABLE nodes` 觸發,不需要預測碰撞),E6 整項停下
- **需要 spec 回答什麼**:`allocateId` 要不要在契約 E 之外另開一個__僅供測試\/可控時間源__的
  管道(例如帶一個 `UTCTime` 參數的內部變體,契約 E 的 `allocateId` 只是取現在時間再呼叫它)?
  或者 E6 改成只斷言「碰撞後 salt 會遞增」這個性質、不要求可從外部精確重現特定的碰撞情境?
- 狀態:open

## G12(F008 / qa)

- **模糊點**:L17 第三個子句要求「所有檔案 IO(`readTextFile` / `atomicWriteText` /
  `removeFile` / `createDirectoryIfMissing`)與所有 md 序列化都不在任何 SQLite 呼叫的括號內」。
  前兩個子句(`withTransaction` 出現 0 次、不出現字面量 `"BEGIN"` / `"COMMIT"`;
  `Database.SQLite.Simple` 只在 `Edit` / `Write` 被 import)是單純的關鍵字\/import 行掃描,
  機械可判定。但「X 是否巢狀在 Y 呼叫的括號內」是一個**語法樹層級的問題**,單純掃字串
  (數括號深度、找關鍵字出現的相對位置)在真實的多行 `do` \/ `let` \/ 縮排排版下容易做出
  偽陽性(把沒有巢狀關係、只是剛好在附近的兩段程式碼判定成巢狀)或偽陰性(漏掉真正巢狀的情況,
  例如經過一層 helper 函式間接呼叫)。這已經超出「掃原始碼有沒有出現某個獨立詞」這個 Law 字面
  定義的機械驗證範圍——與 `spec-gaps.md` 的 G3(F007,同樣是「文字掃描分不出語法結構」)同一個根
- **卡住的項目**:L17 的第三個子句,`WriteLockBudgetSpec.hs` 只驗證前兩個子句,第三個子句
  整項停下,不寫斷言(不腦補一個容易誤判的文字掃描規則來假裝涵蓋)
- **需要 spec 回答什麼**:第三個子句要不要降級為「code review 檢查項」而不是 qa 的自動化測試
  (由 `/arch-audit` 或人工審查在 impl 交付時檢查),或者能不能提供一個機械可判定的替代形式
  (例如：要求 SQLite 呼叫全部集中在具名的一小組函式內,qa 只需驗證檔案 IO \/ md 序列化的呼叫點
  不落在那組函式的原始碼範圍內——這仍然是文字掃描,但至少把「巢狀」換成「是否在同一個具名定義
  的範圍內」,少了括號配對的模糊地帶)?
- 狀態:open

## G6(F004 / qa)

- 模糊點:F004 spec(2026-08-25 追加段)在多處敘述「既有 14 個建構子」(`MdErrorKind` 扣掉新增的
  `HeadingTooDeep` 之後),包括 L39「既有 14 個建構子的訊息逐字不變(回歸 law)」與 E22「既有 14 個
  `MdErrorKind` 建構子各取一個代表值」。實際數 `md/src/Aapms/Md/Error.hs:33-71` 的 `data MdErrorKind`
  定義,扣掉 `HeadingTooDeep` 是 **15 個**:`NoFrontmatter` / `UnterminatedFrontmatter` /
  `FrontmatterYaml` / `SectionYaml` / `HeadingWithoutId` / `DuplicateSectionId` / `IdPrefixMismatch` /
  `HeadingSkip` / `HeadingAboveRoot` / `UnterminatedMetaBlock` / `MissingNodeKind` / `RootMismatch` /
  `RequiredFieldMissing` / `SectionFieldMissing` / `UnknownSectionId`——與 `md/test/Aapms/Md/ErrorSpec.hs`
  既有的「每一種錯誤都有非空訊息」測試枚舉的清單一致(該測試同樣是 15 筆)
- 卡住的項目:E22 的字面數字(「14 個」)與骨架\/既有測試對不上,不影響能不能寫斷言(15 個建構子
  的清單是機械可數的事實,不是行為推論),只是 spec 原文的計數有誤,回報供編排者修訂措辭
- 需要 spec 回答什麼:F004 spec 的「既有 14 個建構子」是否應更正為「既有 15 個建構子」(L39 與
  E22 兩處一併改)?
- **qa 已完成的處置**(未整項停工):`Aapms.Md.InsertSectionSpec` 的 E22 測試依**實際的 15 個**既有
  建構子撰寫(與 `ErrorSpec.hs` 既有清單一致),逐字轉錄自現行(本次委派未改動)的
  `renderMdErrorKind`;L39 的回歸半句(既有建構子訊息不變)由 E22 覆蓋,不受此計數誤差影響
  (L39 前半句——`HeadingTooDeep` 訊息本身——單獨有測試覆蓋,見同檔 L39)
- 狀態:resolved (2026-08-25,spec 措辭修正:既有建構子數 14 → 15)
