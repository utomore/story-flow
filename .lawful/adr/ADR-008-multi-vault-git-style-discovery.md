---
id: ADR-008
type: adr
title: multi-vault-git-style-discovery
description: 一個 Vault 一個世界,以 git 式向上搜尋加全域註冊表定位
status: accepted
created: 2026-08-16
updated: 2026-08-19
---

# ADR-008: 多 Vault 架構,以 git 式向上搜尋 + 全域註冊表定位

## 狀態(Status)

accepted

## 背景(Context)

alchbees 是工作室,不是單一作品。design-studio 已經把「跨專案共享」列為設計目標(遊戲專案層 +
集中資源庫),理由是世界觀、美術風格、通用道具這些資產應該能被未來的其他作品引用,不綁死在
單一遊戲裡。

同時,設定資料要進 git(ADR-002),而不同作品的設定顯然不該混在同一部 commit 歷史裡。

還有一個實務問題:CLI 怎麼知道現在要操作哪個世界?

## 決策(Decision)

**一個 Vault = 一個世界/作品 = 一個 git repo。**

```
alchbees-dev/story-flow/         ← 程式碼,獨立 repo
~/story-vaults/liftgame/         ← 資料 Vault,自己的 repo
  .storyflow/config.toml
  .storyflow/index.db            ← gitignored
~/story-vaults/shared-lore/      ← 共用設定 Vault,被其他 Vault 引用
~/.config/story-flow/vaults.toml ← 全域註冊表(名稱 → 路徑)
```

**跨 Vault 引用**:Entity 以 `<vault>:<id>` 定址。Vault 的 `config.toml` 宣告它引用哪些其他
Vault;被引用的 Vault 對本 Vault 而言是**唯讀**的——共用美術風格、通用道具可以被引用與比對,
但不會被某個作品改掉。

**Vault 定位規則**(與 git 同一個心智模型):

1. 明確給了 `--vault <名稱>` → 查全域註冊表取得路徑
2. 否則從目前工作目錄**向上搜尋** `.storyflow/`,找到就是它
3. 都找不到 → 報錯並提示 `story-flow vault init` 或 `--vault`

程式碼與資料徹底分開:`story-flow` 這個 repo 不含任何 Vault 資料,設計資產的 git 歷史不會
和工具的開發歷史混在一起。

## 考慮過的替代方案(Alternatives Considered)

- **單一 Vault(一個資料夾一個世界,不做註冊表)**:最簡單,`cd` 進去就是那個世界。但跨 Vault
  引用只能靠手動複製檔案,共用設定會出現多份不同步的副本——這正是「跨專案共享」要解決的問題。
- **單一全域資料庫,靠 `project` 欄位區分**:跨世界查詢最方便。但所有作品的設定檔混在同一個
  資料夾與同一部 git 歷史裡,無法按作品分開版控、分開備份、分開交付。
- **Vault 資料放在 `story-flow/vaults/`**:程式碼與資料同 repo,設定最省事。但工具的 commit
  歷史會被設計資產的修訂淹沒,而且要把某個世界交給別人時得整個工具一起給。
- **只用全域註冊表、不做向上搜尋**:行為最可預測(不會因為 `cd` 錯地方而寫錯庫),但每道指令
  都要帶 `--vault`。折衷是兩者都支援,且 CLI 在非 `--json` 模式下於輸出開頭顯示目前作用的
  Vault 名稱與路徑,避免寫錯庫。

## 影響(Consequences)

**正面**

- 每個作品的設定有獨立的 git 歷史,可獨立備份、獨立交付、獨立設定權限
- 共用設定只有一份真相,不會出現多個不同步的副本
- `cd` 進 Vault 就能直接下指令,符合開發者對 git 的既有習慣
- 工具的 repo 保持乾淨,不被設計資產撐大

**負面 / 成本**

- 跨 Vault 查詢要同時開多個 SQLite 索引,查詢與排序邏輯比單庫複雜
- 跨 Vault 引用會產生**跨 repo 的懸空參照**:被引用的 Vault 刪掉某個 Entity 時,引用方會斷。
  需要一個 `story-flow vault check` 檢查懸空引用;唯讀約束能防止意外改動,但防不了刪除
- 全域註冊表是機器本機狀態,換機器要重建。`vaults.toml` 應保持可手寫、格式簡單
- 「目前在哪個 Vault」有兩條決定路徑,誤操作的風險真實存在。緩解:CLI 明確顯示作用中的 Vault;
  破壞性操作(刪除、批次修改)一律先印出 Vault 路徑再確認
