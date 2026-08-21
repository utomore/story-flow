---
id: B001
type: bugfix
title: contract-layer-dependency-guard
description: system.md 宣稱契約層單向由 CabalSpec 釘住,但該斷言不存在,唯一撐住依賴敘事的不變量沒有守衛
status: open
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: [ADR-006, ADR-011]
related-feature: [F001]
---

# B001: 契約層單向的守衛不存在

> 本文檔由 `/arch-audit system`(2026-08-21)建立,開發者裁定「記成 bugfix」。
> **尚未修復**,也**尚未寫重現測試**;動手時走 `/bugfix`。

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

## 重現方式(尚未寫成測試)

往 `service/storyflow-service.cabal` 的 library `build-depends` 加一行 `, storyflow-conflict`,
然後跑 `cabal test all`:

- **預期**:`StoryFlow.Service.CabalSpec` 失敗,指出架構違規
- **實際**:兩條斷言都通過(`forbidden` 沒有這個名字;`required` 的四個仍然都在),測試全綠

註:加了這行之後 `cabal build all` 會不會過是另一回事(可能因套件循環而失敗),
但**測試層級的守衛確實不會響**——而測試才是文件宣稱的那道防線。

## 修復方向(走 `/bugfix` 時決定)

至少要讓 `storyflow-conflict` 與 `storyflow-llm` 進 `forbidden`。可以考慮更強的作法,
與 `storyflow-conflict` 的 `CabalSpec` 對齊:改成**逐字釘住完整相依清單的雙向斷言**,
這樣未來任何新套件(`storyflow-workshop`、`storyflow-mcp`)混進契約層都會立刻紅。

取捨要在 `/bugfix` 裡談:逐字釘住的清單每次合法新增相依都要改測試,而 `service` 是
**所有業務操作的唯一定義處**,合法新增相依的頻率不會低。

## 連帶的文檔修正

`system.md` 那句話在守衛補上之前是**不準確的**;補上之後才會變成事實。兩者要一起完成,
否則就是把一句錯的話留在 Level 1 燈塔文件裡。
