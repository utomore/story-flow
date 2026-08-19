---
id: ADR-001
type: adr
title: haskell-cabal-multipackage
description: 以 Haskell GHC 9.14 與 cabal 多套件建置,沿用 assetdb 工具鏈
status: accepted
created: 2026-08-16
updated: 2026-08-19
---

# ADR-001: 採用 Haskell + cabal 多套件,沿用 assetdb 的工具鏈

## 狀態(Status)

accepted

## 背景(Context)

story-flow 的前身 design-studio 是 Python(uv + FastAPI),約 5,600 行。重寫的動機不是
Python 寫不出來,而是這個系統的本質是**資料模型密集**的:統一 Meta、五種實體、有方向性的
關聯、嚴格樹的合法性、三層衝突偵測的分層結果——這些都是「型別講清楚就少一半 bug」的東西。
design-studio 的 bugfix 紀錄裡有相當比例(session schema 未遷移、並發寫入 lost update、
back stage 留下不一致狀態)屬於「狀態轉換沒被型別約束」這一類。

工作室內已有一個成熟的 Haskell 專案 `assetdb`:GHC 9.14.1 / cabal 3.16.x、9 個套件的
`cabal.project`、`servant` + `sqlite-simple` + `optparse-applicative`、`direct-sqlite` 開啟
`+fulltextsearch` 以取得中文搜尋所需的 FTS5 trigram tokenizer、明確**不使用 stack**、
每個套件統一開 `-Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns`。

## 決策(Decision)

story-flow 全部以 Haskell 撰寫(核心服務與 CLI),並**完整沿用 assetdb 的工具鏈與慣例**:

- GHC 9.14.1、cabal 3.16.x,`cabal.project` 管理多套件,不使用 stack
- 套件切分:`core` / `md` / `store` / `service` / `conflict` / `llm` / `workshop` /
  `server` / `cli` / `mcp`
- 沿用同一組 `ghc-options` 警告設定;`direct-sqlite` 開 `+fulltextsearch`
- `allow-newer` 只對確定安全的套件開放(比照 assetdb 的 `*:base` / `*:template-haskell` /
  `*:ghc-prim`),不全域開放

套件切分的判準是**依賴方向必須單向**:`core` 零 IO 只有型別與純函式,`md` 只依賴 `core`,
`store` 之上才有 IO,`service` 是唯一的業務匯集點,三個介面套件位於最外層。編譯器會強制
執行這個分層——這正是選 Haskell 而非「Python 加型別註解」的實質差別。

## 考慮過的替代方案(Alternatives Considered)

- **維持 Python + uv**:開發最快、design-studio 的程式碼可直接參考。但放棄了型別強制的分層,
  而分層失守正是 design-studio 累積 13 份 enhance 的主因(引擎/UI 邊界滲漏、設定解析散落)。
  且工作室要維護兩套完全不同的工具鏈。
- **Rust**:型別與效能都夠,生態成熟。但工作室沒有 Rust 既有專案,等於再開一條技術債線;
  且本專案沒有任何效能或記憶體控制的硬需求。
- **stack 而非 cabal**:與 assetdb 不一致就失去「兩個工具同一套建置心智」的價值。
- **單一套件(不切多套件)**:初期簡單,但依賴方向就只剩靠自律。本專案明確要求「核心不知道
  介面存在」「核心不依賴工作坊」,用套件邊界表達最可靠。

## 影響(Consequences)

**正面**

- 依賴方向由編譯器保證,不會退化成互相引用的一團
- 工作室兩個 Haskell 工具共用建置心智、共用踩過的坑(FTS5 flag、GHC 9.14 的 base 上界問題)
- `servant` 的 API 型別可同時產生 server 與 client,直接支撐 ADR-006 的 CLI 雙模式

**負面 / 成本**

- 開發速度短期一定慢於 Python,特別是 P1 的 Markdown 解析與 P5 的 LLM 串接
- GHC 9.14 仍偏新,部分套件的 `base` 上界未放寬,可能需要逐一 `allow-newer`(assetdb 已踩過,
  照抄它的作法)
- TOML 解析、MCP protocol 在 Haskell 沒有現成的一等公民套件,可能要自己寫薄層

**中立**

- design-studio 的程式碼不再是可複製的對象,只能當設計參考——這本來就是預期(資料模型已不同)
