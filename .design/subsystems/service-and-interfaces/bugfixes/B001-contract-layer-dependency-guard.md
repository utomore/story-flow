---
id: B001
type: bugfix
title: contract-layer-dependency-guard
description: system.md 宣稱契約層單向由 CabalSpec 釘住,但該斷言不存在,唯一撐住依賴敘事的不變量沒有守衛
status: done
created: 2026-08-21
updated: 2026-08-22
depends-on: []
related-adr: [ADR-006, ADR-011]
related-feature: [F001]
---

# B001: 契約層單向的守衛不存在

> 本文檔由 `/arch-audit system`(2026-08-21)建立,開發者裁定「記成 bugfix」;
> 2026-08-22 走 `/bugfix` 修復完成。

## 缺陷

`.design/system.md` 的「通訊拓撲與原則」寫著:

> - **契約層單向**:`storyflow-service` **不 import 任何比它上層的東西**——不 import
>   `storyflow-conflict`、不 import `storyflow-llm`。**這條由 `CabalSpec` 的相依斷言釘住,
>   不是靠自律**

粗體那句話**不成立**。`service/test/StoryFlow/Service/CabalSpec.hs` 的實際內容是:

```haskell
-- | 介面層才該有的相依。出現在這裡就是架構違規。
forbidden :: [String]
forbidden = ["servant", "warp", "optparse-applicative", "http-client"]

required :: [String]
required = ["storyflow-core", "storyflow-md", "storyflow-store", "storyflow-types"]
```

擋的是**第三方介面套件**——那是 ADR-006 的「`service` 不涉及 HTTP 與終端輸出」,是另一件事。
句子點名的 `storyflow-conflict` 與 `storyflow-llm` **一個都沒有被擋**。

`required` 也補不上這個洞:它斷言的是「這四個**有**在」,不是「**只有**這四個」。

## 為什麼要緊

子系統層級的依賴圖有一個三跳的環:

```text
service-and-interfaces ──► conflict-detection ──► llm-workshop-mcp ──► service-and-interfaces
  (api / server / cli)       (storyflow-conflict)   (storyflow-llm)      (storyflow-service)
```

它之所以**不是**真的循環相依,完全靠 `storyflow-service` 的 `build-depends` 乾淨——
ADR-011 把敘事拆成「契約層單向」與「介面包裝層是全面下游」,整套論證的地基就是這一條。

也就是說:**這是唯一撐住當前架構敘事的不變量,而它現在沒有守衛,文件卻說有。**

對照之下,葉子子系統 `storyflow-conflict` 的 `CabalSpec` 反而守得更緊:2026-08-21 的階段二
閘門把它改成雙向斷言,並逐字釘住完整相依清單,「保證沒有第七個名字趁這一次順道混進來」。
守衛的嚴格程度與該套件的架構重要性目前是**反過來的**。

## 現況不是違規

實測 `storyflow-service` 的 library `build-depends` 為
`storyflow-core` / `storyflow-md` / `storyflow-store` / `storyflow-types`,**乾淨**。

所以這是「缺守衛 + 文件過度宣稱」,不是「不變量已經破了」。修復的價值在於**未來**:
`llm-workshop-mcp` 還有 4 個 feature 未展開(workshop、mcp adapter),而 `storyflow-workshop`
的定位是「Entity 的產生器之一」——那正是最容易讓人想往 `service` 加一條相依的方向。

## 重現方式

往 `service/storyflow-service.cabal` 的 library `build-depends` 加一行 `, storyflow-conflict`,
然後跑 `cabal test all`:

- **預期**:`StoryFlow.Service.CabalSpec` 失敗,指出架構違規
- **實際**:兩條斷言都通過(`forbidden` 沒有這個名字;`required` 的四個仍然都在),測試全綠

註:加了這行之後 `cabal build all` 會不會過是另一回事(可能因套件循環而失敗),
但**測試層級的守衛確實不會響**——而測試才是文件宣稱的那道防線。

**實際重現(2026-08-22)**:上述步驟沒辦法真的跑,因為 `storyflow-conflict` 反過來依賴
`storyflow-service`,cabal 連 build plan 都解不出來。因此改成把**舊守衛的判斷邏輯**套在一份
合成的 build-depends 上重現:

```
守衛擋得住往契約層加 storyflow-conflict(B001 重現) [✘]
     expected: ["storyflow-conflict"]
      but got: []
98 examples, 1 failure
```

守衛回報零違規 —— 缺陷成立。

## 修復方向

開發者 2026-08-22 裁定:**內部 `storyflow-*` 相依逐字釘住,第三方維持黑名單**。

兩種強度分開用,理由是兩者要抓的東西不同:

- **第三方介面套件**(`servant` / `warp` / `optparse-applicative` / `http-client`)沿用
  `forbidden` 黑名單。那是 ADR-006 的「`service` 不涉及 HTTP 與終端輸出」,與本缺陷是兩件事;
  而其餘第三方套件(`time` / `containers` …)沒有架構意義,合法新增時不該讓測試噪音
- **內部 `storyflow-*` 相依**改用**逐字釘住的完整清單**(library 與 test-suite 各一份)。
  黑名單抓不住「還沒被想到的那個名字」——`storyflow-workshop` 與 `storyflow-mcp` 都還不存在,
  任何黑名單此刻都列不到它們,而它們正是最可能被往契約層加的兩個

## TodoList

- [x] T1: 撰寫重現缺陷的測試(修復前應失敗)  `dep: -`
- [x] T2: 新增 `internalDeps`,把一段 build-depends 裡的 `storyflow-*` 名字抽出來排序  `dep: T1`
- [x] T3: library / test-suite 兩段各以完整清單逐字斷言  `dep: T2`
- [x] T4: 補一條「未來才出現的套件也擋得住」的測試(`storyflow-workshop` / `-mcp` / `-llm`)  `dep: T3`
- [x] T5: 回寫 `system.md` 那句宣稱,讓它與守衛的實際形式相符  `dep: T3`

## 驗證方式

```
cabal build all   零 error、零 warning
cabal test all    10/10 suites PASS,1270 examples,0 failures
```

重現測試轉綠;`storyflow-service` 套件 97 → 101 examples(+4)。

## 修復紀錄

**根因**:守衛只有黑名單一種形式,而黑名單的涵蓋範圍是「已經想到的名字」。
`storyflow-conflict` / `storyflow-llm` 不在上面,未來的 `storyflow-workshop` /
`storyflow-mcp` 更不可能在上面。

**修法**:`service/test/StoryFlow/Service/CabalSpec.hs` 加一個純函式 `internalDeps`
(取一段 build-depends 裡的 `storyflow-*` 名字,排序後回傳;取名字而非整行,版本約束
改動不會讓斷言紅),再對 library 與 test-suite 兩段各做一次完整清單的逐字斷言。

**與「修復方向」的偏差**:無。

**過程中發現、值得記下來的一件事**:B001 原本寫的重現步驟(往真的 `.cabal` 加一行
`storyflow-conflict`)**執行不了**——那會造成套件循環,cabal 連 build plan 都解不出來。
乍看之下這代表「cabal 自己就擋得住,守衛是多餘的」,但**不是**:

- cabal 擋的是**循環**,而這裡要守的是**分層方向**,後者比無環更強
- 一個未來的套件只要**自己不依賴 `storyflow-service`**,把它加進 service 的相依
  **不會有循環、cabal 完全放行**,但契約層就此認識了比它上層的東西,ADR-011 的敘事就破了
- `storyflow-workshop` 的定位是「Entity 的產生器之一,核心不依賴它」——正是這一類

所以守衛守的是 cabal 守不到的那一段,而那一段恰好就是最容易發生的那一段。

## 連帶的文檔修正

## 連帶的文檔修正

`system.md` 那句話在守衛補上之前是**不準確的**;補上之後才變成事實。已於同一次修復中
把它改寫成與守衛的實際形式相符(點明內部相依是逐字釘住、第三方是黑名單),
不再只說「由相依斷言釘住」。
