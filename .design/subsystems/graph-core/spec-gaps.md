---
id: graph-core-gaps
type: spec-gaps
title: graph-core-gaps
description: graph-core 委派過程中 qa / impl 撞到的 spec 缺口與裁決
status: done
created: 2026-08-24
updated: 2026-09-04
parent: graph-core
---

# graph-core spec 缺口

## GAP-1(graph-core/F004-md-unified-sections / impl → graph-core/F008-store-write-operations / spec)

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
- 修訂:graph-core/F004-md-unified-sections §契約 D / 數據(2026-08-24);`NewSection` 改成依節點種類做 sum(`NewSectionPayload` 四個封閉建構子),`addSection` 維持單一入口;design.md 契約 D 與 graph-core/F008-store-write-operations 的 `createPackFile` 第三參數(契約 E)連帶回寫

## GAP-2(graph-core/F008-store-write-operations / spec)—— 已重現的資料遺失缺陷

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
- 狀態:resolved (2026-08-24,F004 重跑完成並經編排者以原重現案例驗證:`SHA256_KEPT True` / `ENTRY_KEPT True` / `SUMMARY_NEW True`)。原處置:由 **F004 重跑**修復(2026-08-24 開發者裁決),與 GAP-1 同一個根
  (`MetaOverride` 是唯一管道),一併處理:`Render` 要支援 payload 專屬欄位的序列化,
  並新增 payload 保留的編輯路徑讓 `updateSection` 不再吃掉節專屬欄位
- 修訂:graph-core/F004-md-unified-sections §Laws / Examples(2026-08-24);`Render` 補上 payload 專屬欄位的序列化、新增 payload 保留的編輯路徑,F004 重跑並以原重現案例驗過

## GAP-3(graph-core/F007-store-fts-dual-index / qa)

- 模糊點:LAW-23「`store/src` 底下所有 `.hs` 原始碼都不含 `LIKE` 這個 SQL 關鍵字(不分大小寫的
  獨立詞)」沒有說「原始碼」是否包含 Haddock 註解文字。字面讀法(掃描整個檔案的文字,不分
  code/comment)與「只掃實際會送進 SQLite 的字串常量」兩種讀法會給出不同結果——而
  `store/src/Aapms/Store/Query.hs:16` 的骨架註解本身就寫著
  `-- 而不是 @Maybe Double@。__沒有 @LIKE@ 掃描路徑__:那是 trigram 三字元下限的`,
  `LIKE` 以獨立詞出現在雙 `@` 之間。這份骨架是設計階段交付的,qa 依 spec-roles.md 不得修改
  骨架(含註解)
- 卡住的項目:LAW-23 的 property/example test。逐字照字面讀法寫,測試現在就會紅
  (不是因為 `undefined`,是因為骨架註解本身),而且這個紅燈在 impl 填完 `search`/`routeOf`
  等函式本體後也不會消失,因為註解不屬於 impl 的職責範圍(impl 不能改骨架簽名,註解算不算
  骨架的一部分沒有寫清楚);若改成「只掃字串常量」讀法,又需要能分辨字串常量與註解,這已經
  超出「掃原始碼有沒有出現某個獨立詞」這個 Law 字面所定義的機械驗證範圍
- 需要 spec 回答什麼:LAW-23 的「原始碼」是否排除 Haddock 註解?若排除,要不要把
  `Query.hs:16` 的骨架註解改寫(拿掉獨立詞 `LIKE`,例如改成 `%LIKE%` 或拆成
  `LI` <> `KE`)當作骨架修訂的一部分一併發下來,讓這條 Law 對「現在的骨架」就是可驗證的?
- 當初的處置(已被下方的 resolved 取代,保留原文供追溯)(**impl 附註,2026-08-24**:骨架註解 `Query.hs:16` 已由 impl 改寫,拿掉了獨立詞
  `LIKE`——這是註解文字的實作層級調整,不是骨架簽名\/型別,依 spec-roles.md 屬 impl 自主權
  範圍。字面讀法之下,`store/src` 現在確實不含獨立詞 `LIKE`(已用
  `grep -rniE "\bLIKE\b" store/src/` 覆核)。但 GAP-3 問的「原始碼是否排除 Haddock 註解」這個
  語意問題本身仍未解:qa 若已依字面讀法寫死斷言字串,或未來任何人在註解裡再次寫下這個詞,
  同樣的爭議會重演,狀態維持 open 讓編排者\/開發者定調)
- 狀態:resolved (2026-08-24 開發者裁決 → spec 已修訂):**LAW-23 撤銷**,F007 spec 的 Laws 段以刪除線
  保留原文並附撤銷理由,編號不重編;`Query.hs` 的模組 Haddock 改成引用 LAW-9 / LAW-10(「只有兩條路,沒有
  第三條」)。qa 不再需要 LAW-23 的測試,`TokenizeSpec.hs` / `SearchSpec.hs` 開頭關於 LAW-23 的說明可一併移除
- 修訂:graph-core/F007-store-fts-dual-index §Laws(2026-08-24);LAW-23 撤銷,原文以刪除線保留並附撤銷理由,編號不重編

## GAP-4(graph-core/F007-store-fts-dual-index / impl)

- 模糊點:LAW-4「對所有 `t`,`desegmentCjk (cjkSegment t) == T.unwords (cjkRuns t)`」在 `cjkSegment`
  的既定輸出格式(「先所有 unigram、再所有 bigram,以單一空白分隔」,由「介面」段與
  EX-1–EX-3 的具體字串釘死,impl 不能改)之下,對某些輸入**不可能**被任何 `desegmentCjk` 實作滿足
  ——不是實作能力問題,是資訊遺失:可構造出 `t /= t'`(僅差在 CJK 連續段之間的空白位置)使得
  `cjkSegment t == cjkSegment t'`,但 `T.unwords (cjkRuns t) /= T.unwords (cjkRuns t')`
- 卡住的項目:LAW-4(全稱量詞版本)。具體反例:`t = "乙甲 甲甲乙"`、`t' = "乙甲甲 甲乙"`
  (皆為構造用的示意中文字元,重點是同一字元在不同位置重複出現)。兩者 `cjkRuns` 不同
  (`["乙甲","甲甲乙"]` vs `["乙甲甲","甲乙"]`),但因為兩個相鄰 run 邊界處剛好是同一個字元
  的重複(`...甲 | 甲甲...` 這段,邊界落在哪個「甲」純屬巧合地產生相同的 bigram 多重集合,
  且此組"甲甲" bigram 在 token 串裡的相對順序也相同),`cjkSegment` 對兩者的輸出逐字元相同
  (`unigrams = [乙,甲,甲,甲,乙]`、`bigrams = [乙甲,甲甲,甲乙]`,順序皆同)。`desegmentCjk`
  是同一個輸入字串的確定性函式,不可能同時等於兩個不同的 `T.unwords (cjkRuns _)`
- 需要 spec 回答什麼:LAW-4 的「對所有 `t`」是否有意排除這種因重複字元導致 run 邊界資訊遺失的
  病態輸入(改成有條件的 law,例如限定 `t` 不含連續三個以上相同字元跨越邊界,或改用某種
  qa 可驗證的較弱陳述)?或者 `cjkSegment` 的輸出格式需要調整(例如在 bigram 區塊裡插入一個
  非 token 的邊界標記)讓 `desegmentCjk` 原則上可逆——但那會動到 EX-1–EX-3 已經釘死的字面輸出,
  屬架構層級的格式決定,不是 impl 能自主換的
- **impl 已完成的處置**(不腦補、不留 `undefined`):`desegmentCjk` 實作了一個貪婪還原演算法
  (見 `Tokenize.hs` 的 Haddock),對 EX-1–EX-3 給定的 Example 與絕大多數真實輸入(不含上述病態
  重複模式)都能正確還原;僅在上述病態輸入類別下可能給出與 `T.unwords (cjkRuns t)` 不同的
  結果。理由:`search` 的 CJK 片段還原(ASM-3)與其他多條 Law/Example 都直接依賴一個能跑的
  `desegmentCjk`,若整個函式留 `undefined`,會連帶讓所有 CJK 命中路徑的片段輸出崩潰,影響
  範圍遠大於這個病態子集;因此選擇實作可用版本 + 記錄此 gap,而非整項停工。若編排者認為這個
  處置不恰當(應該整項停工等 spec 修訂),請指示回退
- 狀態:resolved (2026-08-24 開發者裁決 → spec 已修訂):**LAW-4 撤銷**,且 `desegmentCjk` 在失去
  snippet 這個唯一消費者後**整個從介面與骨架移除**(`Tokenize.hs` 的匯出與定義都已刪除,`cjkSegment`
  的 Haddock 加了「這個表示法是單向的,沒有反函式」的說明防止有人再加回去)。qa 要刪掉
  `TokenizeSpec.hs` 的 `prop_LAW4` 與對 `desegmentCjk` 的 import
- 修訂:graph-core/F007-store-fts-dual-index §介面 / Laws(2026-08-24);LAW-4 撤銷,`desegmentCjk` 整個從介面與骨架移除

## GAP-5(graph-core/F007-store-fts-dual-index / 編排者仲裁)—— 與 GAP-4 同一個根

- **模糊點**:ASM-3 要求「`fts_cjk` 命中時把 `snippet()` 的輸出經 `desegmentCjk` 還原成連續文字」,
  但 **LAW-4 只定義 `desegmentCjk` 在完整 `cjkSegment t` 輸出上的行為**。FTS5 的 `snippet()` 回的是
  欄位內容的**一段視窗**,永遠不是某個 `t` 的完整 `cjkSegment` 輸出——spec 把函式用在定義域外
- **編排者實測**(2026-08-24,對 impl 交付的程式碼):
  - `cjkSegment "魔法藥水瓶"` = 5 個 unigram + 4 個 bigram,共 9 個 token
  - `desegmentCjk` 吃**完整 9 個 token** → `"魔法藥水瓶"`,**LAW-4 成立(True)**
  - `desegmentCjk` 吃**前 3 個 token** → `"魔 法 藥"`,接不回去(沒有 bigram 佐證相鄰)
  - EX-6 觀察到的 `"魔法藥 水 瓶"` 正是片段輸入的必然結果
- **卡住的項目**:EX-6(`shSnippet` 含「藥水」)。**歸因:spec bug**,不是 impl 錯也不是 qa 誤讀
- **與 GAP-4 的關係**:同一個根——「先所有 unigram、再所有 bigram」這個切詞表示法**本來就不是為了可逆
  而設計的**,而 spec 在兩個地方假設它可逆(LAW-4 的全稱量詞、ASM-3 的 snippet 還原)
- **需要 spec 回答什麼**:CJK 命中時的 snippet 要從哪裡取?
  編排者建議的方向:`fts_tri` 存的是**原始文字**(trigram tokenizer 不做應用層預切),
  所以 snippet 從 `fts_tri` 的內容取就是自然的連續文字,`desegmentCjk` 可以整個退出 snippet 路徑;
  LAW-4 則應改成有條件的 law 或直接撤掉
- 狀態:resolved (2026-08-24 開發者裁決,見下)
- 修訂:graph-core/F007-store-fts-dual-index §Laws(2026-08-24);與 GAP-4 同一次裁決,內容見本檔「2026-08-24 開發者裁決」一節

---

## 2026-08-24 開發者裁決(GAP-3 / GAP-4 / GAP-5)

三條一起解,因為 GAP-4 與 GAP-5 同一個根:**「先所有 unigram、再所有 bigram」的切詞表示法本來就不是為了
可逆而設計的**,而 spec 在兩處假設它可逆。

- **GAP-5(snippet)**:`desegmentCjk` **整個移出 snippet 路徑**。`fts_tri` 存的是**原始文字**
  (trigram tokenizer 不做應用層預切),所以不論命中來自哪張表,`shSnippet` 一律從 `fts_tri` 的
  內容取——拿到的就是自然的連續文字。ASM-3 要改寫,EX-6 的期望(snippet 含「藥水」)因此成立
- **GAP-4(LAW-4)**:`desegmentCjk` 失去 snippet 這個消費者後,LAW-4 的全稱量詞失去存在理由。
  **撤掉 LAW-4**(或改成有條件的 law);`desegmentCjk` 若已無消費者就一併從介面移除
- **GAP-3(LAW-23)**:**撤掉 LAW-23**。用文字掃描斷言「某個關鍵字不在原始碼裡」本來就分不出註解與程式碼
  ——這正是它撞到骨架自身註解的原因。它想保證的事(沒有 `LIKE` 掃描路徑)已由 LAW-9 / LAW-10 的
  路由 law 涵蓋:查詢一定走 trigram 或 cjk 兩條 FTS 路徑之一,沒有第三條路

**執行**:由 spec 角色修訂 F007 的 spec 與骨架,再重跑受影響的 qa 與 impl。

## GAP-9(graph-core/F008-store-write-operations / qa)

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
- 狀態:resolved (2026-08-25 開發者裁決 → spec 已修訂):`isRootNode` 對「id 不在 `doc` 裡」回 `Left (SectionMissing path id)`,與 `headingDepthFor`(LAW-21)對稱——「查無此節」與「這個節不是根」是兩件事,合一會讓錯誤往下游飄;F008 新增 **LAW-24**(三種結果)與 **EX-18**,`Node.hs:71` 的 haddock 已寫明,簽名不變
- 修訂:graph-core/F008-store-write-operations §Laws / Examples(2026-08-25);新增 LAW-24(`isRootNode` 三種結果)與 EX-18,簽名不變

## GAP-7(graph-core/F008-store-write-operations / qa)—— 已縮小範圍:`SqliteError` 的既有訊息與 LAW-15 字面不符

- **模糊點**:LAW-15 要求「`renderStoreError e` 非空,且含至少一個以『請』起頭的子句」,範圍是
  `StoreError` 的全部 21 個建構子,__含 F005 已實作的 6 個__(spec 明說這 6 個應為綠)。
  但 `Aapms.Store.Error.renderStoreError` 對 `SqliteError` 的既有實作(`Error.hs:96-97`)是
  `"索引操作失敗 —— " <> msg <> ";可以嘗試重新開啟 vault"`——用「可以嘗試」收尾,**不含任何
  以「請」起頭的子句**。這與 F005 原本 `Aapms.Store.ErrorSpec` 的 `actionable` 判準
  (「請」/「改用」/「可以」/「才」四選一)不同;F008 的 LAW-15 字面把可接受的動詞窄化成只剩「請」
- **已排除的偽陽性**:同一輪還發現 `VaultAlreadyInitialized`(F005 既有,亦應綠)的訊息
  「……不會覆寫;如需重建,請先手動移除該檔案」__其實有__以「請」起頭的子句(在 ASCII 逗號
  `,` 之後),第一版測試的 `hasQingClause` 判準漏了 ASCII 逗號這個分句符號,已在
  `StoreErrorL15Spec.hs` 修正、該筆現在正確判定為綠——只有 `SqliteError` 是真正的字面不符
- **卡住的項目**:`StoreErrorL15Spec.hs` 對 `SqliteError` 的「含以請起頭的子句」斷言;已改寫成
  一則刻意會紅、標明「spec-gaps GAP-7」的測試,而不是悄悄放寬判準讓它變綠
- **需要 spec 回答什麼**:LAW-15 的「以『請』起頭的子句」是否要放寬回 F005 `actionable` 的四選一
  (「請」/「改用」/「可以」/「才」),或者 `SqliteError` 的訊息文字要改成含「請」的子句(例如
  「……；請嘗試重新開啟 vault」)?這是文字選擇,但既然 LAW-15 把它寫成可機械驗證的斷言,誰改
  由開發者定
- 狀態:resolved (2026-08-25 開發者裁決 → spec 已修訂):**LAW-15 不放寬**(維持「含至少一個以『請』起頭的子句」),改的是訊息文字——`SqliteError` 改成 `"索引操作失敗 —— " <> msg <> ";請嘗試重新開啟 vault"`,**由 impl 這一輪改**(F005 其餘 5 則不得更動);理由是 21 則訊息只有一種形狀,放寬成四選一日後只要戴個「可以」就混得過去。F008 已補「`SqliteError` 的訊息要改」一節與 **EX-17**
- 修訂:graph-core/F008-store-write-operations §實作備註 / Examples(2026-08-25);LAW-15 不放寬,改的是 `SqliteError` 的訊息文字,補「`SqliteError` 的訊息要改」一節與 EX-17

## GAP-8(graph-core/F008-store-write-operations / qa)

- **模糊點**:EX-6「人為製造碰撞」的情境是「索引裡已存在 `newId p c t 0` 與 `newId p c t 1`
  兩個 id;`allocateId vh p c` 回 `Right i`,且 `i` 與那兩個都不同(實作上即 salt = 2 的
  那一個)」。但 `allocateId :: VaultHandle -> IdPrefix -> Text -> IO (Either StoreError Id)`
  的簽名__沒有時間注入點__——`t`(`newId` 的第三個參數)是 `allocateId` 內部呼叫
  `getCurrentTime`(或等價機制)取得的,呼叫端無從得知、也無法控制它會在呼叫的哪一刻取樣
- **卡住的項目**:EX-6 本身。要「人為製造碰撞」必須預先把 `newId p c t 0` / `newId p c t 1`
  寫進索引,但這需要**先知道** `allocateId` 這次呼叫內部即將使用的確切 `t`——這在公開介面上
  觀察不到,也控制不到(呼叫兩次 `allocateId` 之間去猜測、去外部量測目前時間再手算
  `newId`,仍可能與函式內部實際取樣的時間點有微秒級落差,導致預先插入的 id 根本不是它會
  嘗試的那個候選)。`WriteSpec.hs` 因此只測了 LAW-14(連續呼叫互異,每次把結果寫回索引)與
  L14b/EX-15(索引查詢失敗即失敗,用 `DROP TABLE nodes` 觸發,不需要預測碰撞),EX-6 整項停下
- **需要 spec 回答什麼**:`allocateId` 要不要在契約 E 之外另開一個__僅供測試\/可控時間源__的
  管道(例如帶一個 `UTCTime` 參數的內部變體,契約 E 的 `allocateId` 只是取現在時間再呼叫它)?
  或者 EX-6 改成只斷言「碰撞後 salt 會遞增」這個性質、不要求可從外部精確重現特定的碰撞情境?
- 狀態:resolved (2026-08-25 開發者裁決 → spec 已修訂):`allocateId` 收**明碼 `UTCTime`**(`VaultHandle -> IdPrefix -> Text -> UTCTime -> IO (Either StoreError Id)`,契約 E 已回寫 `design.md:326`)——藏在內部取樣就永遠測不到 salt 重試迴圈;F008 的介面表、LAW-14(收緊成「同一個 `t` 連續呼叫 n 次」)、L14b、EX-6(重寫成可精確構造)、EX-15 已改,骨架 `Write.hs:179` 已改簽名,四個 create 函式對外簽名不變(自己取時間再傳入)
- 修訂:graph-core/F008-store-write-operations §介面 / Laws / Examples(2026-08-25);`allocateId` 收明碼 `UTCTime`,介面表、LAW-14、L14b、EX-6、EX-15 已改,design.md 契約 E 回寫

## GAP-12(graph-core/F008-store-write-operations / qa)

- **模糊點**:LAW-17 第三個子句要求「所有檔案 IO(`readTextFile` / `atomicWriteText` /
  `removeFile` / `createDirectoryIfMissing`)與所有 md 序列化都不在任何 SQLite 呼叫的括號內」。
  前兩個子句(`withTransaction` 出現 0 次、不出現字面量 `"BEGIN"` / `"COMMIT"`;
  `Database.SQLite.Simple` 只在 `Edit` / `Write` 被 import)是單純的關鍵字\/import 行掃描,
  機械可判定。但「X 是否巢狀在 Y 呼叫的括號內」是一個**語法樹層級的問題**,單純掃字串
  (數括號深度、找關鍵字出現的相對位置)在真實的多行 `do` \/ `let` \/ 縮排排版下容易做出
  偽陽性(把沒有巢狀關係、只是剛好在附近的兩段程式碼判定成巢狀)或偽陰性(漏掉真正巢狀的情況,
  例如經過一層 helper 函式間接呼叫)。這已經超出「掃原始碼有沒有出現某個獨立詞」這個 Law 字面
  定義的機械驗證範圍——與 `spec-gaps.md` 的 GAP-3(F007,同樣是「文字掃描分不出語法結構」)同一個根
- **卡住的項目**:LAW-17 的第三個子句,`WriteLockBudgetSpec.hs` 只驗證前兩個子句,第三個子句
  整項停下,不寫斷言(不腦補一個容易誤判的文字掃描規則來假裝涵蓋)
- **需要 spec 回答什麼**:第三個子句要不要降級為「code review 檢查項」而不是 qa 的自動化測試
  (由 `/arch-audit` 或人工審查在 impl 交付時檢查),或者能不能提供一個機械可判定的替代形式
  (例如：要求 SQLite 呼叫全部集中在具名的一小組函式內,qa 只需驗證檔案 IO \/ md 序列化的呼叫點
  不落在那組函式的原始碼範圍內——這仍然是文字掃描,但至少把「巢狀」換成「是否在同一個具名定義
  的範圍內」,少了括號配對的模糊地帶)?
- 狀態:resolved (2026-08-25 開發者裁決 → spec 已修訂):**第三個子句從 LAW-17 移除**,降級為 `/arch-audit subsys graph-core` 在階段閘門的人工檢查項(寫進 F008 的「實作備註」);LAW-17 只保留兩個機械可判定的子句,`WriteLockBudgetSpec` 現有的涵蓋範圍就是完整範圍。理由:ADR-022 把 code review 與靜態檢測並列,而「X 是否巢狀在 Y 的括號內」是語法樹層級的問題,文字掃描會製造偽陽性與偽陰性(與 F007 的 GAP-3 同一個根)
- 修訂:graph-core/F008-store-write-operations §Laws / 實作備註(2026-08-25);LAW-17 第三個子句移除,降級為階段閘門的人工檢查項

## GAP-6(graph-core/F004-md-unified-sections / qa)

- 模糊點:F004 spec(2026-08-25 追加段)在多處敘述「既有 14 個建構子」(`MdErrorKind` 扣掉新增的
  `HeadingTooDeep` 之後),包括 LAW-39「既有 14 個建構子的訊息逐字不變(回歸 law)」與 EX-22「既有 14 個
  `MdErrorKind` 建構子各取一個代表值」。實際數 `md/src/Aapms/Md/Error.hs:33-71` 的 `data MdErrorKind`
  定義,扣掉 `HeadingTooDeep` 是 **15 個**:`NoFrontmatter` / `UnterminatedFrontmatter` /
  `FrontmatterYaml` / `SectionYaml` / `HeadingWithoutId` / `DuplicateSectionId` / `IdPrefixMismatch` /
  `HeadingSkip` / `HeadingAboveRoot` / `UnterminatedMetaBlock` / `MissingNodeKind` / `RootMismatch` /
  `RequiredFieldMissing` / `SectionFieldMissing` / `UnknownSectionId`——與 `md/test/Aapms/Md/ErrorSpec.hs`
  既有的「每一種錯誤都有非空訊息」測試枚舉的清單一致(該測試同樣是 15 筆)
- 卡住的項目:EX-22 的字面數字(「14 個」)與骨架\/既有測試對不上,不影響能不能寫斷言(15 個建構子
  的清單是機械可數的事實,不是行為推論),只是 spec 原文的計數有誤,回報供編排者修訂措辭
- 需要 spec 回答什麼:F004 spec 的「既有 14 個建構子」是否應更正為「既有 15 個建構子」(LAW-39 與
  EX-22 兩處一併改)?
- **qa 已完成的處置**(未整項停工):`Aapms.Md.InsertSectionSpec` 的 EX-22 測試依**實際的 15 個**既有
  建構子撰寫(與 `ErrorSpec.hs` 既有清單一致),逐字轉錄自現行(本次委派未改動)的
  `renderMdErrorKind`;LAW-39 的回歸半句(既有建構子訊息不變)由 EX-22 覆蓋,不受此計數誤差影響
  (LAW-39 前半句——`HeadingTooDeep` 訊息本身——單獨有測試覆蓋,見同檔 LAW-39)
- 狀態:resolved (2026-08-25,spec 措辭修正:既有建構子數 14 → 15)
- 修訂:graph-core/F004-md-unified-sections §數據(2026-08-25);措辭修正,既有建構子數 14 → 15

## GAP-13(graph-core/F008-store-write-operations / impl)—— `sanitizeFileName` 的 LAW-20 與 EX-11 對同一件事給出不同答案

- **模糊點**:LAW-20「t 被清空時結果等於 fb」與 EX-11「`sanitizeFileName "第一章: 序幕 " fb` ==
  `"第一章- 序幕"`(冒號換成 `-`)」隱含兩種互斥的清理策略。EX-11 要求非法字元被**替換**成
  `-`(保留在結果裡,佔一個字元);但 `NodeSpec2.hs` 對 LAW-20 的 property test 用
  `genOnlyStrippable` 產生**只含**非法字元(觀察到的反例是單一字元 `"<"`)的輸入,斷言結果
  等於 `fb`——若非法字元被替換成 `-`,單一 `"<"` 會變成 `"-"`(非空、非法字元清單也不含
  `-`),不會落到「清空」分支。兩種讀法只有在「t 混合合法與非法字元」時才會一致(EX-11 正是
  這種情況,兩種策略在此都給 `"第一章- 序幕"`);純非法字元組成的輸入時才會分岔
- **卡住的項目**:LAW-20 的「t 被清空時結果等於 fb」這條 property test。impl 已依 EX-11 逐字實作
  「替換」策略(唯一有逐字文本釘死的行為),因此該 property test 目前為紅
- **需要 spec 回答什麼**:非法字元(`< > : " / \ | ? *` 與控制字元)該**替換成 `-`**(EX-11 的
  讀法)還是**整個移除**(LAW-20 property test 的讀法)?兩者只有「純非法字元輸入」時行為不同,
  但那正是這條 law 在測的情境
- 狀態:resolved (2026-08-25 開發者裁決 → spec 已修訂):**替換**。EX-11 的逐字例子是權威(逐字例子是最難被誤讀的一種 spec),`sanitizeFileName` 維持「非法字元換成 `-`」;改的是 **LAW-20 的措辭**——「被清空」只指「去掉頭尾空白與 `.` 之後為空」,**不含**「輸入只由非法字元組成」。機械定義:`t` 的每一個字元都是空白或 `.`(空字串亦然)才算被清空。所以 `"<"` 的正確結果是 `"-"`、`"   "` 與 `"..."` 才回 `fb`;qa 的 `genOnlyStrippable` 要改成只產生空白與 `.`。F008 已改寫 LAW-20(四條子句)並新增 **EX-19**(全空白 / 全 `.` → `fb`)、**EX-20**(`"<"` → `"-"`、`"<>?"` → `"---"`)、**EX-21**(合法字元原樣回傳)
- 修訂:graph-core/F008-store-write-operations §Laws / Examples(2026-08-25);LAW-20 改寫成四條子句,新增 EX-19 / EX-20 / EX-21

## GAP-14(graph-core/F008-store-write-operations / impl)—— L12a / L12b 的「前面節位元組不變」與 `appendSection` / `insertSection`
  自身文件明載的行為衝突

- **模糊點**:L12a「addSection vh i AtEnd s 成功之後前 n 節的 renderSection 位元組不變」與
  L12b 的子句 2「該位置之前與之後的每一節的 renderSection 位元組都與呼叫前相同」都是全稱
  斷言,不留例外。但 `Aapms.Md.Render.appendSection` / `insertSection`(F004 已交付、本 feature
  不得修改)**自己的 haddock 明載**它們會用 `blankTail` 把插入點**前一節**的 `secBodyRaw`
  補到剛好隔一個空行(若原本沒有的話),並主張「被動到的是插入點,不是『未經修改的區塊』,
  所以不違反 ADR-010」——這條「插入點前一節可能被動」的但書,L12a / L12b 的文字都沒有繼承
  過來
- **已重現**(impl 這一輪,`Aapms.Store.Create` 呼叫 `appendSection` 走 F004 的既有實作,
  未另寫序列化邏輯):對一份倒數第二節結尾只有單一 `\n`(無空行)的主題檔追加片段,
  `appendSection` 依其文件行為把該節補成 `\n\n`,導致 `CreateSpec.hs` 的 L12a 測試(比對
  該節 `renderSection` 逐字不變)為紅;`E12/LAW-12b` 系列測試在能夠重現到這一步之前先撞上
  GAP-15(見下),尚未individually驗證是否也有同一個落差
- **需要 spec 回答什麼**:L12a / L12b 是否要比照 `insertSection` 自己文件的但書,把「插入點
  前一節的空行補齊」排除在「位元組不變」的斷言之外(即「不變」只保證**除插入點外**的節,
  且插入點前一節僅允許『補齊到剛好一個空行』這一種變化)?
- 狀態:resolved (2026-08-25 開發者裁決 → spec 已修訂):**是**,L12a / L12b 照 F004 的 ASM-10 收窄措辭改(同一個根,同一次裁決)。新措辭:插入一節之後其餘每一節位元組不變——**唯一的例外是插入點之前那一段的行尾**:它還沒有以空行結尾時會被補齊(`blankTail` 冪等,已經是空行結尾就原樣不動),`appendSection` 走同一條規則;被動到的是插入點而不是「未經修改的區塊」,不違反 ADR-010。F008 的 L12a / L12b 已改寫並新增「插入點行尾的但書」(附兩個機械可判定的推論供 qa 寫斷言:原本就以空行結尾 → 全檔不變;否則差異只允許在尾端、`T.stripEnd` 後逐位元組相同),EX-12 補註「`nod-b` 在插入點之後,不受但書影響」。**LAW-3 / LAW-6 / LAW-16 不走插入路徑,那裡的「位元組不變」仍是無條件的**(已 grep 全文 `位元組` 逐處確認)
- 修訂:graph-core/F008-store-write-operations §Laws / Examples(2026-08-25);L12a / L12b 收窄並補「插入點行尾的但書」,EX-12 補註

## GAP-15(graph-core/F008-store-write-operations / impl)—— `Aapms.Store.Node` 的「新增的依賴邊」清單漏列 `validateLevelDoc`
  需要的兩條邊

- **模糊點**:F008 的「新增的依賴邊」逐條列出四個模組本次會新增的 import,對
  `Aapms.Store.Node` 只列了 `Aapms.Core.Id`、`Aapms.Md.Document`、`Aapms.Store.Error`(且
  明說「不再需要 `Aapms.Store.Edit`」),「實作階段還會新增」那個補充清單裡也完全沒有提到
  `Node.hs`。但 LAW-23 把 `validateLevelDoc` 的行為定義成「`toLevel doc` 成功且 `buildTree`
  回 `Right`」——這兩個函式分別來自 `Aapms.Md.Parse` 與 `Aapms.Core.Tree`,不在上面任何一份
  清單裡。不呼叫這兩個函式、只用 `Node.hs` 已授權的三個依賴,寫不出滿足 LAW-23 的
  `validateLevelDoc`(自己重寫一份等價的樹驗證邏輯,又違反「父子關係的標題層級只有一個
  推導點」與「序列化規則只有一份」的知識歸屬原則)
- **impl 已完成的處置**(未整項停工):`Node.hs` 補上 `Aapms.Md.Parse`(只用 `toLevel`)與
  `Aapms.Core.Tree`(只用 `buildTree`)兩條依賴,`validateLevelDoc` 逐字依 LAW-23 實作。這兩個
  依賴都已經是 `aapms-store` 對 `aapms-md` / `aapms-core` 既有 `build-depends` 的一部分,
  不新增套件層的邊,也不成環(`Aapms.Md.Parse` / `Aapms.Core.Tree` 都不 import 任何
  `Aapms.Store.*`)
- **已重現的後果**:`NodeSpec2.hs` 的「LAW-23:合法的 Level 檔:validateLevelDoc 回 `Right ()`」
  目前為紅——但歸因見下一條(GAP-16),紅燈的直接原因是 fixture 本身未通過 `toLevel` 驗證,
  不是這條依賴邊補齊與否
- **需要 spec 回答什麼**:請把這兩條邊回寫進 design.md 的「新增的依賴邊」清單,補上
  `Aapms.Store.Node → Aapms.Md.Parse(僅 toLevel)、Aapms.Core.Tree(僅 buildTree)`
- 狀態:resolved (2026-08-25 編排者回寫 design.md):**不照字面登記每一條 import**——逐條列 `import Aapms.Core.Entity` 之類屬 Level 3 實作細節,`conventions.md` 的抽象邊界規範明文禁止寫進 Level 2 文檔。改為登記這兩條**確實屬於 Level 2、而 design.md 原本漏掉**的事實:① 寫入管線補上「寫檔前驗證(Level 檔):`toLevel` + `buildTree`,樹不合法即 `TreeInvalidOnWrite` 中止,檔案未動」一段;② 模組間公開介面的 `aapms-store → aapms-md` 列補「**並反向用 `to*` 讀回目標目前的 `Meta`**」(樂觀鎖來源是重讀的檔案而非索引),`→ aapms-core` 列補「`buildTree` 另在寫入路徑被呼叫一次」。impl 把共用的 `currentMetaAt` / `currentAssetAt` 集中放進 `Edit.hs` 屬實作自主權,編排者不介入。
- 修訂:graph-core/F008-store-write-operations §新增的依賴邊(2026-08-25);裁決為不逐條登記 import,改回寫 graph-core/design.md 的「資料流管線」與「模組間公開介面」兩處

## GAP-16(graph-core/F008-store-write-operations / impl)—— `Aapms.Store.Write` / `Aapms.Store.Create` 需要的
  `Aapms.Core.{Entity,Level,Pack}` 依賴邊未列在「新增的依賴邊」

- **模糊點**:`writeMeta` / `writeBody` / `addLink` / `removeLink` 的 haddock 都明說「節與
  檔案層主體都支援」,四種文件(`TopicDoc` / `LevelDoc` / `PackDoc` / `LicenseDoc`)通用。
  要在寫入前用「重讀的檔案」取得目標**目前真正的 Meta**(不可逆決定 2),唯一的管道是
  `Aapms.Md.Parse` 的 `toTopic` / `toLevel` / `toPack` / `toLicenses`,四者分別回傳
  `Entity` / `(Level, [Node])` / `(Pack, [Asset])` / `[License]`——要取出裡面的 `Meta`
  (`entMeta` / `lvlMeta` / `nodMeta` / `pckMeta` / `astMeta` / `licMeta`),就得 import
  `Aapms.Core.Entity` / `Aapms.Core.Level` / `Aapms.Core.Pack`。但 F008 的「新增的依賴邊」
  對 `Aapms.Store.Write` 只列了 `Aapms.Core.{Asset,Id,License,Link,Meta}`(缺 `Entity` /
  `Level` / `Pack`),`Aapms.Store.Create` 同樣缺這三個(`deleteNode` 需要
  `Aapms.Md.Document.sectionIds` 取得整檔 id 清單,也不在清單裡)
- **impl 已完成的處置**(未整項停工):把「讀出目標目前的 Meta / Asset」這段共用邏輯集中放進
  `Aapms.Store.Edit`(export 新增 `currentMetaAt` / `currentAssetAt`,供 `Write` 與
  `Create` 一起用,理由與 `Edit.hs` 本來的定位「所有寫入路徑共用的那一條紀律」一致,不重複
  寫兩份),`Edit.hs` 因此補上 `Aapms.Core.{Asset,Entity,Level,License,Pack}` 與
  `Aapms.Md.Parse`;`Create.hs` 另外補 `Aapms.Md.Document`(`sectionIds` /
  `Document`)。都是套件層既有 `build-depends` 範圍內的邊,不成環
- **需要 spec 回答什麼**:請把上述邊回寫進 design.md;若編排者認為這些依賴不該集中在
  `Edit.hs`(例如希望 `Write` / `Create` 各自 import),也請一併定調,impl 目前的擺放只是
  「同一段邏輯只寫一份」的實作自主權選擇,不是契約要求
- 狀態:resolved (2026-08-25 編排者回寫 design.md):**不照字面登記每一條 import**——逐條列 `import Aapms.Core.Entity` 之類屬 Level 3 實作細節,`conventions.md` 的抽象邊界規範明文禁止寫進 Level 2 文檔。改為登記這兩條**確實屬於 Level 2、而 design.md 原本漏掉**的事實:① 寫入管線補上「寫檔前驗證(Level 檔):`toLevel` + `buildTree`,樹不合法即 `TreeInvalidOnWrite` 中止,檔案未動」一段;② 模組間公開介面的 `aapms-store → aapms-md` 列補「**並反向用 `to*` 讀回目標目前的 `Meta`**」(樂觀鎖來源是重讀的檔案而非索引),`→ aapms-core` 列補「`buildTree` 另在寫入路徑被呼叫一次」。impl 把共用的 `currentMetaAt` / `currentAssetAt` 集中放進 `Edit.hs` 屬實作自主權,編排者不介入。
- 修訂:graph-core/F008-store-write-operations §新增的依賴邊(2026-08-25);與 GAP-15 同一次裁決,同樣改回寫 graph-core/design.md 的兩處事實

## GAP-17(graph-core/F008-store-write-operations / impl)—— `createPackFile` 寫不出 Pack 專屬的 frontmatter 欄位

- **模糊點**:`Aapms.Core.Json` 的 `FromJSON Pack` / `ToJSON Pack` 實例(`toPack` 實際依賴的
  解碼路徑)把 `vendor` / `archive` / `sha256` / `license` / `author` / `source_url` /
  `ai_disclosure` 這些 pack 專屬欄位,與 `Meta` 的 14 個欄位**攤平在同一層 frontmatter
  物件**解碼。但 `Aapms.Md.Render` 對外公開的 frontmatter 寫入介面
  (`newDocument` / `renderFrontmatter` / `updateFrontmatter`)只吃 `Meta`,`frontmatterFieldOrder`
  是寫死的 14 個 `Meta` 欄位,沒有任何管道可以多寫幾個 pack 專屬欄位進去——節層有
  `MetaExtras` / `payloadExtras` 處理型別專屬欄位,**檔案層沒有對應的機制**
- **卡住的項目**:`createPackFile` 目前只寫出標準 `Meta` 欄位,`NewPack` 帶進來的
  `npVendor` / `npArchive` / `npSha256` / `npLicense` / `npAuthor` / `npSourceUrl` /
  `npAiDisclosure` 完全沒有落地——重讀後 `toPack` 會把這些欄位全部解成 `Nothing` /
  `AiUnknown`,不是呼叫端給的值。**沒有任何 Law 或 Example 測到這個往返**(EX-3 只驗證
  `crPath` 與 asset 節順序),所以測試套件目前全線是綠的,但這是可觀察到的真實資料遺失,
  只是現有 spec 沒有斷言去抓
- **不在 impl 授權範圍內的修法**:唯一的正確修法是替 `Aapms.Md.Render` 加一個檔案層的
  「extras」機制(對稱 `MetaExtras`),但 `md/` 不在本次委派可修改的檔案清單內
- **需要 spec 回答什麼**:`createPackFile` 是否本來就不該負責這些欄位(留給 `asset-ingest`
  之後用另一條路徑補寫)?若需要,請對 `aapms-md` 開一個 feature/enhancement 補上檔案層
  extras 的寫入管道
- 狀態:resolved (2026-08-25 開發者裁決 → spec 已修訂,**實作待 F004**):`createPackFile` **本來就該**負責這七個欄位。**重新打開 F004**,替 `aapms-md` 補上**檔案層 extras** 的寫入管道(對稱節層的 `MetaExtras`),F008 的 `createPackFile` 接上它。F008 新增 **LAW-25**(`createPackFile` 之後重讀,`toPack` 解出的 `Pack` 在 `pckVendor` / `pckArchive` / `pckSha256` / `pckLicense` / `pckAuthor` / `pckSourceUrl` / `pckAiDisclosure` 七欄逐欄等於傳入的 `NewPack`)與 **EX-22**(七欄全給非預設值),並在「實作備註 → 阻塞:LAW-25 / EX-22 依賴 F004 的檔案層 extras」寫明:**這條 law 現在會紅,而且要一直紅到 F004 那一半落地為止,紅燈就是它的工作**;不得為了轉綠而寫弱、標 pending 或在 store 側手拼 frontmatter。編排者在 F004 交付後再委派一輪 F008 impl 接上
- 修訂:graph-core/F004-md-unified-sections §介面 / Laws(2026-08-25);重新打開 F004 補上檔案層 extras 的寫入管道,graph-core/F008-store-write-operations 新增 LAW-25 讓 `createPackFile` 接上
- **impl 接上完成**(2026-08-25,第二輪委派):`aapms-md` 落地 `newDocumentWith` /
  `packFrontExtras` / `NewPackFront` 之後,`createPackFile`(`Create.hs`)改用
  `newDocumentWith PackDoc meta (packFrontExtras front) npBody` 取代原本的 `newDocument`;
  `front` 是私有的 `NewPack → NewPackFront` 逐欄映射(七欄同形,只換前綴 `np` → `npf`),
  沒有在 store 側自己拼任何 frontmatter 字串。`cabal test aapms-store` 連跑三次皆
  **208 examples, 0 failures**,LAW-25 / EX-22 轉綠,其餘 207 條維持全綠

## GAP-18(graph-core/F009-store-multi-vault-read / qa)—— EX-2 第二次呼叫的期望值,是否也隱含「只看 ent- 的部分」

- **模糊點**:EX-2 原文「`listAcross vsAB emptyNodeFilter { nfLimit = 10 }`,再取
  `listAcross vsAB emptyNodeFilter { nfOffset = 1, nfLimit = 2 }`」,預期輸出寫
  「第一次(只看 ent- 的部分)依序是 `[...]`;第二次是 `[(B, ent-…01), (B, ent-…03)]`」。
  「(只看 ent- 的部分)」這個限定語只出現在「第一次」後面,但 fixture 前提明訂 F-B 還有
  `pck-00000001`(非 reference,預設不被排除)與它底下的 `ast-00000002`;`ast-00000002` 的
  metaId 字典序 `"ast-…" < "ent-…"`,若「第二次」是對__完整__(不限定 ent- 前綴)的
  `listAcross` 結果做 `offset=1, limit=2`,則排在最前面的會是 `(B, ast-00000002)`,
  第二次視窗落在 `[(A, ent-00000001), (B, ent-00000001)]`,與 spec 給的
  `[(B, ent-…01), (B, ent-…03)]` 不符
- **卡住的項目**:EX-2 的第二個斷言,寫不出兩種解讀都能滿足的單一斷言——只能二選一:
  (a) 「只看 ent- 的部分」限定語其實同時管兩次呼叫(第二次也先過濾成 ent- 前綴子集再看
  `drop 1 . take 2`);(b) 第二次呼叫真的是對完整結果切窗,但那樣 fixture 給的字面期望值
  對不上任何合理的 F-B 內容(除非 fixture 刻意不讓 `ast-00000002` 出現在預設結果裡,
  而這與 fixture 前提要求 `ast-00000002` 要能被 EX-1 的全文檢索命中並不衝突,但**沒有一句
  fixture 前提說它該被排除在 listAcross 之外**)
- **qa 目前的處置**:採 (a),`store/test/Aapms/Store/MultiVaultSpec.hs` 的 `e2Spec` 兩個
  `it` 都先對 `listAcross` 的完整結果過濾出 `idPrefix (metaId m) == PEnt` 的子集,再比對
  spec 給的期望序列——這是唯一能讓兩個斷言在目前的 fixture(F-A/F-B 均含非 ent- 的
  pack/asset 節點)下同時成立、且不需要臆測系統行為的寫法。**若編排者\/設計角色認定
  (b) 才是本意,fixture 需要調整(例如把 F-B 的 `library/packs/potions/` 移到
  `library/reference/` 底下,讓它預設被排除),`e2Spec` 的第二個斷言要改成對完整結果
  切窗**
- **需要 spec 回答什麼**:EX-2 第二次呼叫的期望值,是對「只看 ent- 的部分」的子集切窗,
  還是對完整 `listAcross` 結果切窗(兩者在目前 fixture 下不等價)?
- 狀態:resolved (2026-08-26 開發者裁決 → spec 已修訂):兩者皆非——「只看 ent-」寫進**過濾器本身**,EX-2 的兩次呼叫都改成 `emptyNodeFilter { nfPrefixes = [PEnt], … }`,散文的括號限定語刪除;理由是留在測試端過濾會讓 `nfOffset` / `nfLimit` 根本沒被驗到,而契約卡驗收 2 要驗的就是分頁
- 修訂:graph-core/F009-store-multi-vault-read §Examples(2026-08-26);EX-2 的兩次呼叫改成帶 `nfPrefixes = [PEnt]` 的過濾器,散文括號限定語刪除

## GAP-19(graph-core/F009-store-multi-vault-read / impl)—— F-A/F-B fixture 的實際資料似乎比 spec 的 fixture-note 更寬,讓四條斷言的「窄命中」前提不成立

- **模糊點**:F009 spec 的 fixture-note(EX-1–EX-12 共用)只講了「F-A 的 `ent-00000001` 帶
  `metaTags = ["琳達", "canon"]`」與「F-B 的 `ast-00000002`(metaTitle = 魔法藥水瓶)」,
  沒有明講 F-A 另外兩個片段(`ent-00000005` / `ent-00000007`)是否也帶這兩個標籤、也沒有明講
  F-B 的 `pck-00000001`(`library/packs/potions/pack.md`)的 `metaTitle` 是什麼。但實測跑
  出來的索引資料顯示:① `ent-00000005`、`ent-00000007` 的 `metaTags` __也是__
  `["canon", "琳達"]`(與 `ent-00000001` 逐字相同,證據見下);② `pck-00000001` 的
  `metaTitle` 是「藥水素材包」,字面含「藥水」二字,會被全文檢索命中
- **卡住的項目與證據**:
  1. **EX-17**(`nfTags=["琳達"]` 應該只回 `ent-00000001`):
     `listAcross vsAB emptyNodeFilter{nfTags=["琳達"]}` 這段 SQL 是 `whereOfIn`/`baseFromIn`
     逐字重用單一 vault 的 `EXISTS (SELECT 1 FROM <schema>node_tags nt WHERE nt.node_id = n.id
     AND nt.tag = ?)`,__不是 impl 自己寫的新邏輯__——實測回傳
     `[(vlt-aaaa0001, ent-00000001), (vlt-aaaa0001, ent-00000005), (vlt-aaaa0001, ent-00000007)]`
     三筆,代表 `node_tags` 表裡這三個 id 確實都有一列 `tag = '琳達'`,不是查詢語法錯誤
     (若是 schema 前綴漏掉,錯的實作會拿__另一個 vault__ 的 `node_tags` 來篩,不會篩出
     __同一個 vault__ 裡的另外兩個片段)。`nfTags=["canon"]` 那一斷言同一個成因,多出的也是
     這兩個片段
  2. **LAW-4 非退化**(「8 個維度各自的非預設值也都跟逐 vault `listNodes` 一致,且真的篩掉
     東西」):連跑三次 `cabal test`,同一個子句一致失敗於 `predicate failed on: 12`
     (非 hedgehog 隨機噪音,三次 seed 不同但結果相同,見下方「機械性查證」的三次輸出);
     懷疑同一個成因——若 hedgehog 選中 `nfTags` 當作八個維度之一,用的是同一份
     F-A/F-B 索引,`["琳達"]` 篩不掉 `ent-00000005`/`ent-00000007` 會讓「真的篩掉東西」
     這個非退化條件不成立
  3. **EX-1**(`searchAcross vsAB {sqText = Just "藥水"}` 應該恰兩筆):實測 `srHits` 長度是
     3 不是 2。**這不是 `searchAcross` 的合併邏輯錯誤**——`LAW-8`(`searchAcross` 與
     `concat [search h q' | h <- hs]` 逐欄相同,三次都綠)已經證明 `searchAcross` 逐字反映
     每個 vault 各自呼叫既有的、未改動的 `Aapms.Store.Query.search` 的結果;第三筆命中應
     來自 `pck-00000001`(`metaTitle = "藥水素材包"`)的標題比對——它不是 reference pack,
     預設不會被排除,標題含「藥水」二字合乎全文檢索邏輯
  4. **EX-12**(`fcVaults` 應為 `[("vlt-aaaa0001",1),("vlt-bbbb0002",1)]`):實測
     `vlt-bbbb0002` 的計數是 2 不是 1,與 EX-1 多出的那一筆(`pck-00000001`)是同一個成因
- **impl 已排除的可能性**:`crossListIds`(`listAcross` 的 SQL 組裝)本身沒有寫任何裸表名
  (`grep -nE "FROM [A-Za-z_]+|JOIN [A-Za-z_]+"` 只掃到 `whereOfIn`/`baseFromIn` 回傳的、
  已經帶 schema 前綴的片段,沒有 impl 自己新寫的裸表名);`searchAcross` 完全不重新計算
  bm25 或候選集,只逐 vault 呼叫既有的 `search` 再在 Haskell 合併——LAW-8/LAW-9/LAW-10/LAW-11/LAW-19/EX-11
  都綠,證明合併邏輯本身正確。四條斷言失敗的共同點都是「WHERE/FTS 過濾的__輸入資料__比
  fixture-note 暗示的更寬」,不是 impl 新寫的程式碼在錯誤地過濾或合併
- **需要 spec 回答什麼**:
  1. F-A 的 `ent-00000005` / `ent-00000007` 這兩個片段,fixture 建構時是否也該帶
     `metaTags = ["canon", "琳達"]`?若是,EX-17 的「只回 `ent-00000001`」與 LAW-4 非退化的
     「`nfTags` 那組非預設值要真的篩掉東西」這兩個期望值需要換一個能保證窄命中的標籤
     (例如只在 `ent-00000001` 身上加一個獨有標籤);若否,fixture 建構(不在本次 impl
     的委派檔案清單內)需要修正,讓片段不繼承主體的標籤
  2. F-B 的 `pck-00000001` 的 `metaTitle` 是否不該含「藥水」二字?若 fixture 本來就要讓它
     命中(例如刻意測「pack 標題也算進全文檢索」),EX-1 的「恰兩筆」與 EX-12 的
     `vlt-bbbb0002` 計數 1 這兩個期望值需要改成 3 筆/計數 2;若不該命中,fixture 的
     `pck-00000001` 標題需要改掉
- 狀態:resolved (2026-08-26 開發者裁決 → spec 已修訂):qa 的 fixture 設計失誤,不是實作錯誤(LAW-8 已證明合併邏輯正確)——law 與 example 的期望值一條不改,改的是 F009「Examples → fixture 前提」新增兩條約束:**區辨用標籤必須放節層**(檔案層的 `tags` 依節層繼承規則聯集去重被同檔每一個節繼承)、**窄命中的查詢字串不得出現在同 vault 其他節點的標題或正文**;LAW-4 非退化子句與 EX-1 / EX-12 / EX-17 一併補上這兩個前提的措辭,fixture 那一側由 qa 修
- 修訂:graph-core/F009-store-multi-vault-read §Examples(2026-08-26);「Examples → fixture 前提」新增兩條約束,law 與 example 的期望值一條不改

## GAP-20(graph-core/E001-store-internal-module-boundary / qa,編排者歸因)—— `statOf` 回傳的 tuple 順序,spec 自己前後矛盾

- 模糊點:E001 對同一件事給了兩個互相衝突的答案。
  1. **「數據與介面變動」表的語意欄**寫 `statOf` 是「回傳檔案的 **(size, mtime)** 供過時偵測」;
     骨架 `store/src/Aapms/Store/Walk.hs` 的 haddock 也寫「檔案的 **(size, mtime)**」
  2. **REG-4** 寫「對任意路徑,`statOf` 的結果與**搬模組前相同**」,而搬移前
     (`git show HEAD:store/src/Aapms/Store/Index.hs`,第 104 行起)的本體是
     `pure (floor (utcTimeToPOSIXSeconds t * 1e9), fromIntegral s)` —— 第一個分量是
     **奈秒 mtime**,第二個才是 size,也就是 **(mtime, size)**,與 1 的順序相反

  兩條不可能同時成立:照語意欄做就違反 REG-4(改了行為),照 REG-4 做就違反語意欄。
  **簽名擋不住這個矛盾**——`(Int64, Int64)` 兩個分量同型別,順序寫反了型別檢查照樣過,
  `/enhance-design` 的一致性檢查比對的是簽名原文,因此沒有攔下來。

- 卡住的項目:`WalkSpec.hs:78` 的 REG-4 size 斷言
  (`Right (size, _mtime) -> size === fromIntegral (BS.length content)`)。
  實測第一個分量是 `1787759371780749400`(奈秒時間戳量級),不是位元組數。
  EX-5(不存在的路徑回 `Left`)與另一條 REG-4 冪等斷言不受影響,兩條都綠。

- 需要 spec 回答什麼:**`statOf` 的回傳 tuple 到底是 `(mtime, size)` 還是 `(size, mtime)`?**
  —— 亦即要改的是「語意欄與骨架 haddock 的文字」,還是「實作的順序」?
  注意後者會與 REG-4「原樣搬移、行為不變」直接衝突,且 `Index.hs` 現有兩個呼叫端都是照
  `(mtime, size)` 在解構的——`:129` 寫 `Right (mtime, size) -> ...`(逐字命名,不是位置巧合)、
  `:412` 寫 `Right (m', s') -> pure (m /= m' || s /= s')`——改順序等於同時改這兩處的行為,
  已超出 E001 定案的 scope(「行為不變、只動可見度與所在模組」)。

  **編排者的傾向**:改 spec 的文字(語意欄與骨架 haddock 都改成 `(mtime, size)`),
  不動實作。理由:實作、兩個呼叫端、REG-4 三者本來就一致,錯的只有我在 `/enhance-design`
  時寫進語意欄的那五個字;而且「過時偵測」比較的是兩個分量的相等性,順序對它沒有語意差別,
  改實作等於為了一句寫錯的文件去動一個正在正確運作的函式。此決定可逆。

- 狀態:resolved (2026-08-27 開發者裁決 → spec 已修訂):**改 spec 的文字,不動實作**。
  實作、`Index.hs:129` 的 `Right (mtime, size)`、`:412` 的 `m/m'` `s/s'` 比對、REG-4 四者本來就一致,
  錯的只有語意欄那五個字;過時偵測比的是兩個分量的相等性,順序對它沒有語意差別,改實作等於為
  一句寫錯的文件去動一個正確運作的函式,還會撞破 E001「行為不變」的 scope。
  已修訂:①「數據與介面變動」語意欄改成 **`(mtime, size)`** 並寫明哪個分量是什麼;② **REG-4** 補上
  機械可判定的子句(只對**第二**分量斷言長度,第一分量是奈秒時間戳);③ 新增 **EX-6** 把順序釘成
  一個具體例子(5 位元組的檔 → `Right (m, 5)`);④ `Walk.hs` 的 `statOf` haddock 補上順序、
  補回「mtime 取奈秒」的理由、並寫明為什麼順序必須寫出來。
  **教訓**:同型別的 tuple 分量(這裡兩個都是 `Int64`),順序寫反時型別檢查、簽名比對、呼叫端
  編譯全部照過——`/enhance-design` 的一致性檢查只比對簽名原文,結構上抓不到。這種欄位的順序
  必須在語意欄與 law 裡寫成機械可判定的句子,不能只給一個 `(a, b)` 讓讀者自己對。
  順帶查出:搬移前的原始 haddock **從頭到尾沒寫過順序**(只說「過時偵測的兩個依據」),
  順序只存在於函式本體那一行——這正是第一版 spec 會寫反的直接原因。
- 修訂:graph-core/E001-store-internal-module-boundary §數據與介面變動 / Laws(2026-08-27);`statOf` 的 tuple 順序在 spec 內統一成 `(mtime, size)`,只改 spec 文字不動實作
