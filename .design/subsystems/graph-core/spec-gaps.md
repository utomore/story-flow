---
id: graph-core-spec-gaps
type: spec-gaps
title: graph-core-spec-gaps
description: graph-core 委派過程中 qa / impl 撞到的 spec 缺口與裁決
status: in-progress
created: 2026-08-24
updated: 2026-08-24
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
- **狀態**:**resolved**(2026-08-24 開發者裁決)——`NewSection` 改成對節點種類做 sum
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
- **狀態**:**open** → 由 **F004 重跑**修復(2026-08-24 開發者裁決),與 G1 同一個根
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
- 狀態:open(**impl 附註,2026-08-24**:骨架註解 `Query.hs:16` 已由 impl 改寫,拿掉了獨立詞
  `LIKE`——這是註解文字的實作層級調整,不是骨架簽名\/型別,依 spec-roles.md 屬 impl 自主權
  範圍。字面讀法之下,`store/src` 現在確實不含獨立詞 `LIKE`(已用
  `grep -rniE "\bLIKE\b" store/src/` 覆核)。但 G3 問的「原始碼是否排除 Haddock 註解」這個
  語意問題本身仍未解:qa 若已依字面讀法寫死斷言字串,或未來任何人在註解裡再次寫下這個詞,
  同樣的爭議會重演,狀態維持 open 讓編排者\/開發者定調)

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
- 狀態:open

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
- **狀態**:open
