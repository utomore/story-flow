---
id: ADR-011
type: adr
title: interface-layer-downstream-of-all-subsystems
description: 契約層單向向下,介面包裝層是所有子系統的下游
status: superseded
created: 2026-08-20
updated: 2026-08-23
---

# ADR-011: 契約層單向、介面包裝層全面下游

## 狀態(Status)

superseded by ADR-015(2026-08-23):合併 assetdb 後業務領域從一個變成四個,「只有一個業務契約層」的前提不成立,`shell` 拆為獨立子系統。

## 背景(Context)

`system.md` 原本把依賴方向寫成一句話:「依賴方向單向向下,編號小的不知道編號大的存在」,
並附一張 `entity-graph-core ──► service-and-interfaces ──► conflict-detection` 的圖。

`conflict-detection` 的 `context-command`(S4)落地後,這句話變成假的:`storyflow-api`、
`storyflow-server`、`storyflow-cli` 三個套件都 `build-depends` 了 `storyflow-conflict`
——因為 `POST /conflict/context` 與 `story-flow context` 的路由型別與指令定義住在那裡。
而這三個套件都屬於 `service-and-interfaces`,一個「排在 `conflict-detection` 前面」的子系統。

第一直覺是「出現了層級倒轉,要修」。但把套件依賴圖攤開會看到,`system.md` 自己的架構圖
**早就畫對了**:`storyflow-conflict` / `storyflow-llm` / `storyflow-workshop` 畫在
`storyflow-api` 的**上方**,箭頭往下流進 api。錯的一直是文字敘述,不是結構。

根本原因是 **`service-and-interfaces` 這個子系統橫跨依賴順序的兩端**:

| 套件 | 位置 |
|---|---|
| `storyflow-service` | 契約層。在所有業務子系統**下面** |
| `storyflow-api` / `storyflow-server` / `storyflow-cli` | 介面包裝層。在所有業務子系統**上面** |

任何以「子系統」為單位的線性順序都表達不出這件事,因為那個子系統本身就不是線性順序上的
一個點。

這不是 story-flow 特有的問題:任何有「最外層 adapter」的分層系統都會這樣——adapter 的職責
就是暴露每一個要被暴露的東西,所以它必然認識每一個。

## 決策(Decision)

**依賴方向分兩層陳述,不再用單一句「單向向下」。**

1. **契約層單向**:`storyflow-service` 不 import 任何比它上層的東西——不 import
   `storyflow-conflict`、不 import `storyflow-llm`、不 import `storyflow-workshop`。
   **這條由各套件 test-suite 的 `CabalSpec` 相依斷言釘住,不是靠自律。**
   它是「業務邏輯只有一份」(ADR-006)真正的守門員

2. **介面包裝層全面下游**:`storyflow-api` / `-server` / `-cli` / `-mcp` **必然**認識每一個
   被它們暴露的子系統。新的子系統長出對外出口時,包裝層增加一條相依是**預期行為**,
   不是架構違規,不需要為此開例外清單

3. **橫向相依仍然只有一條**,且必須是介面相依:`conflict-detection` 第 3 層用
   `llm-workshop-mcp` 的 `chat` 簽名。要再增加橫向相依必須另開 ADR

**`api` / `server` / `cli` 不拆成獨立子系統。** 它們存在的唯一目的是暴露 `storyflow-service`
的契約;ADR-006 的「三種介面的行為由型別強制一致」靠的正是包裝與它所包的契約住在同一個
子系統、由同一份 Level 2 設計管轄。拆開會讓那條約束失去歸屬——沒有人負責回答「CLI 與 REST
為什麼必須行為一致」。

## 考慮過的替代方案(Alternatives Considered)

- **把 `api` / `server` / `cli` 拆成獨立子系統(如 `interfaces`)**:子系統的依賴順序就真的
  線性單向了,敘述不必分兩層。代價是把「薄包裝」與「它所包的契約」拆到兩份 Level 2 文件,
  而 ADR-006 的核心約束正好跨在那條縫上;另外要動 `system.md` 的 `subsystems` 權威清單、
  新建一份 `design.md`、搬遷兩份已完成的 feature 文檔。**為了讓一句話成立而拆結構,方向反了。**
- **保留「單向向下」主句,把包裝層列為第二個例外**:改動最小。但 S5 的 `workshop-interface`
  與 `mcp-adapter` 上線後還會再加邊,例外清單會越長越像在掛病號——而它們全部是同一個原因。
  例外清單不斷增長,通常代表主句的模型錯了。
- **禁止 `api` 依賴 `conflict`,改用某種註冊機制反轉**:讓 `storyflow-conflict` 自己把路由
  註冊進去。這在 servant 的型別級路由下代價極高(路由型別要能動態組合),而且換來的只是
  讓一句敘述成立;OpenAPI 由型別推導這個性質也會一起賠掉。

## 影響(Consequences)

**正面**

- 「架構違規」與「正常成長」分得開了:包裝層多一條相依是預期的,契約層多一條就是紅線,
  而且有 `CabalSpec` 直接擋
- `arch-audit` 有一條可引用的依據,不必每次重新辯論
- S5 的 `workshop-interface`、`mcp-adapter` 落地時不會再觸發同一輪討論

**負面 / 成本**

- 依賴規則從一句話變成兩句,新讀者要多讀一段才知道界線在哪
- 「`service-and-interfaces` 橫跨兩端」需要每次講依賴時附帶說明;子系統名稱本身
  (`service` **and** `interfaces`)其實已經預告了這件事,但要讀的人注意到

**中立**

- 契約層的單向性從此**完全依賴 `CabalSpec` 的斷言**。那些斷言若被放寬(例如為了省事把某個
  名字從 `forbidden` 清單移掉),這條 ADR 就失去強制力。放寬任何一條 `forbidden` 都應該
  當成架構決策處理,而不是測試維護
