---
id: G-B001
type: bugfix
title: contract-rules-frozen-out-of-build
description: 相依方向的四條硬規則在 S1 期間無人斷言,違規可靜默通過
status: done
created: 2026-08-26
updated: 2026-09-04
depends-on: []
related-adr: [ADR-015, ADR-018]
related-feature: [graph-core/F001]
subsystems: [graph-core]
code-paths: [contract/aapms-contract.cabal, contract/test/RulesMain.hs, cabal.project]
---

# G-B001: 契約層的相依方向規則被凍結出建置範圍

## 症狀

`system.md`「通訊拓撲與原則」定義四條硬規則,由 `contract/test/Aapms/Contract/CabalRulesSpec.hs`
逐字釘住。ADR-018 決策二明訂這組契約測試「**整個重建期都有效**」。

實際上從 S1 開跑起,這四條規則**一條都沒有在跑**:

| 規則 | 應由誰斷言 | 現在誰在斷言 |
|---|---|---|
| 1 契約層單向(`service` 不 import 領域/外殼) | `CabalRulesSpec` | 無人 |
| 2 地基不認識上面(`core`/`types`/`md`/`store` 不 import `service` 以上) | `CabalRulesSpec` | 無人 |
| 3 重量級相依隔離(`api`/`server`/`mcp` 不碰 archive/ingest/reorg 與影像、壓縮、子程序) | `CabalRulesSpec` | 無人 |
| 4 `aapms-core` 的相依**白名單** | `CabalRulesSpec` | 只剩 `core/test/Aapms/Core/CabalSpec.hs` 的 8 項**黑名單** |

規則 4 的降級要單獨看:`system.md` 在四條硬規則的段落明文寫著「**黑名單只擋得住想得到的名字**」,
而白名單版本被關掉之後,留下的正好是它點名不夠用的那一種。

影響範圍:S1 正在重建的就是規則 2 所管的那四個地基套件,守衛卻是零;而 S3 要重建 `service` 與
`shell` 時,規則 1 與 3 才是主要的防線,依現況也不會回來。

## 重現步驟

現況下 `cabal build all` 只涵蓋四個套件,`aapms-contract` 完全不在建置圖裡:

```
$ cabal build all --dry-run
 - aapms-core-0.1.0.0 (test:aapms-core-test)
 - aapms-md-0.1.0.0 (test:aapms-md-test)
 - aapms-store-0.1.0.0 (test:aapms-store-test)
 - aapms-types-0.1.0.0 (test:aapms-types-test)
```

突變注入,證明違規可以靜默通過。挑 `directory` 的理由:它是 IO 套件(`aapms-core` 契約上**零 IO**、
是遊戲本體唯一的相依面),不在 `core` 那份黑名單的 8 個名字裡,也不在 `CabalRulesSpec` 的白名單
`coreAllowed` 裡——正好落在「想不到的名字」那一格。

```
1. 在 core/aapms-core.cabal 的 library build-depends 加一行 ", directory"
2. cabal test aapms-core
```

- **預期**:規則 4 紅燈,指出 `aapms-core` 多了清單外的相依
- **實際**:`224 examples, 0 failures` / `Test suite aapms-core-test: PASS`(2026-08-26 實跑)

## 根因分析

根因**不在** `CabalRulesSpec` 自己。它的檔頭就寫明是為了在重建期存活而設計的:

- `contract/test/Aapms/Contract/CabalRulesSpec.hs:1-8`「只讀 `.cabal` 檔的文字,不依賴 Cabal library」
  「套件還沒建的(S3 之後才有的 workspace / archive / …)**自動略過**;建了就自動受檢」
- `forbid` 對 `M.lookup` 失敗直接 `pure ()`,`findCabals` 掃的是**磁碟上的目錄**而不是 `cabal.project`

也就是說,它本來就不需要任何下游套件存在。真正的原因在打包方式:

`contract/aapms-contract.cabal:49-52` 把**六組契約測試放在同一個 test-suite**,而該 stanza 帶著

```
build-tool-depends:
    , aapms-cli:aapms
    , aapms-server:aapms-serve
```

其中五組(CLI 信封、Markdown roundtrip、索引等價、OpenAPI golden、命名文法)確實要跑執行檔,
只有 `CabalRulesSpec` 不用。build-log DEC-1 凍結下游套件時,`cabal.project:20` 把 `contract/` 整個
註解掉——**一條不吃執行檔的規則測試,被連坐進了吃執行檔的凍結範圍**。

DEC-1 的處置「契約測試到 S3 重建 service / shell 時回來」在當時是對的判斷,但它把粒度定在整個
`contract/` 套件,而缺陷的粒度是單一 stanza。

## 修復方向

把「吃執行檔」與「不吃執行檔」拆成兩個 test-suite,只讓後者回到建置圖:

1. `contract/test/RulesMain.hs` — 規則測試的專屬入口,**不走 hspec-discover**(走了就會把另外五組
   `*Spec.hs` 一起吸進來,又繞回原問題)
2. `contract/aapms-contract.cabal` 拆出 `aapms-contract-rules-test`,不帶 `build-tool-depends`;
   原本的 `aapms-contract-test` 以 `flag executables`(`default: False`)收起來,S3 重建
   `shell` 時把 default 翻成 True 即可,不必再動結構
3. `cabal.project` 把 `contract/` 取消註解

**與 DEC-1 的偏差**:DEC-1 寫「契約測試到 S3 才回來」,本修復讓其中一組提前回來。依 `doc-lifecycle.md`
的權威順序,ADR-018(開發者已 accepted)高於 build-log 的編排決策,而 ADR-018 決策二要求的正是
「整個重建期都有效」。DEC-1 的凍結**範圍**被收窄,凍結**理由**(下游編不過)完全保留。

**替代方案與否決理由**:

- **另開 `contract-rules/` 套件**:界線最乾淨,但把 ADR-018 的契約層拆成兩個套件,S3 之後要再合回來
  或永久維護兩份 `.cabal`。為了一個 stanza 的粒度問題付一個套件的代價,不划算
- **等 S3 一起處理**:零當下成本。三個月後的代價是 S3 重建 `service` 與 `shell` 的整段期間——正是
  規則 1 與 3 最需要防線的時候——仍然沒有守衛,而 DEC-11 已經記下 `service` 現在就有一條穿透
  `aapms-store` 內部模組的 import 等著被搬進新程式碼

**不動的東西**:`CabalRulesSpec.hs` 的規則內容一行不改(它現在的四條規則是對的,只是沒在跑);
另外五組契約測試的內容一行不改。

## TodoList

- [x] STEP-1: 突變注入確認現況守衛抓不到(缺陷存在證明)  `dep: -`
- [x] STEP-2: 新增 `contract/test/RulesMain.hs` 專屬入口  `dep: T1`
- [x] STEP-3: `contract/aapms-contract.cabal` 拆出 `aapms-contract-rules-test`,原 suite 收進 `flag executables`  `dep: T2`
- [x] STEP-4: `cabal.project` 取消註解 `contract/`  `dep: T3`
- [x] STEP-5: 重跑突變確認轉紅、還原後全綠  `dep: T4`

## 驗證方式

1. 還原突變後 `cabal build all --dry-run` 應含 `aapms-contract (test:aapms-contract-rules-test)`,
   且**不含** `aapms-contract-test`(被 flag 收起來)
2. `cabal test all` 全綠,四條規則各出現一條通過的斷言
3. 重新注入突變 → 規則 4 紅燈並指名 `directory`;還原 → 轉綠。這一組紅綠就是缺陷的回歸證明

## 修復紀錄

**與「修復方向」完全一致,無偏差。** 動到四個檔案:

| 檔案 | 改了什麼 |
|---|---|
| `contract/test/RulesMain.hs`(新) | 規則測試的專屬 `main`,逐一列出要跑的 spec,不走 `hspec-discover` |
| `contract/aapms-contract.cabal` | 新增 `flag executables`(`default: False`)與 `test-suite aapms-contract-rules-test`;原 `aapms-contract-test` 加 `if !flag(executables) / buildable: False` |
| `cabal.project` | `contract/` 取消註解,並註明只建規則那一組 |
| `core/aapms-core.cabal` | **無淨變更**——只在重現與驗證時暫時注入 `, directory`,兩次都已還原(`git status` 乾淨) |

`CabalRulesSpec.hs` 一行未改,另外五組契約測試一行未改。

**驗證結果**(2026-08-26 實跑):

1. `cabal build all --dry-run` → 含 `aapms-contract-0.1.0.0 (test:aapms-contract-rules-test)`,
   不含 `aapms-contract-test`(flag 收著),符合預期
2. 四條規則各一條斷言,全部通過:

   ```
   Aapms.Contract.CabalRulesSpec
     相依方向(CabalSpec,逐字清單)
       找得到套件(至少 aapms-core / aapms-service / aapms-contract) [✔]
       規則 1:契約層單向——aapms-service 不 import 任何領域或外殼套件 [✔]
       規則 2:地基不認識上面——graph-core / workspace 不 import service 以上 [✔]
       規則 3:重量級相依隔離——api / server / mcp 不依賴 archive / ingest / reorg … [✔]
       規則 4:aapms-core 的 build-depends 只能是逐字清單上的純套件 [✔]
       自檢:契約測試本身不依賴任何 aapms-* library [✔]
   6 examples, 0 failures
   ```

3. 紅綠回歸(同一個突變,修復前後對照):

   | | 修復前 | 修復後 |
   |---|---|---|
   | `aapms-core` 加 `, directory` | `224 examples, 0 failures` **PASS** | **FAIL** —— `aapms-core 多了清單外的相依:["directory"];要加就同時更新 CabalRulesSpec.coreAllowed` |

4. 還原突變後 `cabal test all` 五組全綠:contract-rules 6 / types 42 / core 224 / md 327 / store 260
   = **859 examples, 0 failures**

**一個超出預期的收穫**:`findCabals` 掃的是磁碟上的目錄而非 `cabal.project`,所以規則 1 與 3 現在
**連被凍結的 `service` / `api` / `server` / `mcp` 都在受檢**(測試輸出的第一條斷言證實找得到
`aapms-service`)。S3 重建時這些規則不是「才回來」,而是**一路都在**。

**依賴檢查**:新 test-suite 的 `build-depends` 只有 base / bytestring / containers / directory /
filepath / hspec / text,無任何 `aapms-*`——`CabalRulesSpec` 的自檢斷言(第 6 條)本身就在守這件事,
已通過。production 程式碼零改動,無新增 import 方向。

**留給 S3 的一個動作**:`contract/aapms-contract.cabal` 的 `flag executables` 要在 `cli/` 與
`server/` 加回 `cabal.project` 時翻成 `default: True`,另外五組契約測試才會回來。flag 的
`description` 已寫明這件事。

**順帶發現、不在本次修復範圍**:`build-log.md` 的 DEC-1 決策文字仍寫「契約測試到 S3 重建
service / shell 時回來」,與現況不符(規則那一組已提前回來)。建議在 DEC-1 那一列補一句指向本文檔的
交叉引用,但那是編排紀錄的維護,不由本次 bugfix 代改。
