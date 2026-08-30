# legacy `service-and-interfaces`(移植參考,不建置)

2026-08-30 由 `/subsys-build service` 的前置檢查搬進來(開發者裁決)。原位置是專案根目錄的
`service/src` 與 `service/test`,`aapms-service.cabal` 改名為 `.bak` 以免被任何 cabal 掃描撿走。

## 這是什麼

舊 `service-and-interfaces` 子系統的實作,共 3266 行(5 個 src 模組 + 20 餘個 test spec)。
最後一次實質改動是 2026-08-23 的全樹改名(`storyflow-* → aapms-*`);此後 graph-core 重建、
核心型別換成統一 `Meta`,它就編不過了,`cabal.project` 從 P1 起把它連同其他下游一起註解掉
(D1 凍結,ADR-018)。

## 為什麼不是直接刪掉

它的 28 個操作**是真的跑過的**,裡面有新 `design.md` 未必想得到的邊界情境。寫新 spec 時可以打開
它對照,但**不要照抄形狀** —— 新設計已經明文否決了它的幾個核心選擇:

| legacy 的做法 | 新 `design.md` 的裁決 |
|---|---|
| `EntityView` / `LevelView` / … 每種節點一個 View 型別 | **否決**。統一成 `NodeView` + `NodeDetail` sum(不可逆決定表:「統一 `Meta` 的價值就在抽象成本只付一次」) |
| 鎖與 handle 快取住 `aapms-server` 的 `AppState` | **否決**。移進 `service` 的 `Env`(每個殼都要記得包一層,漏包不會有編譯錯誤) |
| `api` / `server` / `cli` 與 service 同一個子系統 | 依 ADR-015 拆進 `shell`,本子系統不涵蓋 |
| 四個內嵌出口(`linkGraph` / `aliasIndex` / `vaultConfig` / 連動查詢)原樣存在 | **暫不定案**,等 `conflict` / `ai` / `project` 建檔後由 B 段對帳決定形狀 |

新子系統的權威是 `.design/subsystems/service/design.md`,不是這裡的程式碼。

## 什麼時候可以刪

`service` 八個 feature 全數 done、且階段閘門的 arch-audit 沒有從這裡撈出遺漏的邊界情境之後。
