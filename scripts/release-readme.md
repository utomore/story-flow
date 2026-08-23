# aapms

故事設定的片段圖譜與場景樹管理工具。這個資料夾解開就能跑,不需要安裝 Haskell、cabal 或原始碼。

## 裡面有什麼

| 檔案 | 用途 |
|---|---|
| `aapms` | 主要的命令列工具。建 Vault、寫片段、查關聯、偵測衝突、工作坊,全部在這裡 |
| `aapms-serve` | REST API 伺服器。只有在要用 MCP、或從別台機器操作時才需要 |
| `aapms-mcp` | MCP stdio adapter,讓 claude code / codex 直接操作圖譜。要先起 `aapms-serve` |
| `registry/` | 型別註冊表(五份 TOML)。**必須跟執行檔放在同一個資料夾**,不要搬走 |
| `README.md` | 這份說明 |

## 第一步

```
aapms doctor
```

它會告訴你:版本、型別註冊表從哪裡載入、目前目錄有沒有 Vault、全域註冊表正不正常、`[llm]` 段有沒有設。
五項全部 `[ok]` 就可以開始;哪一項 `[!!]` 就照它說的下一步做。

## 開始用

```
aapms vault init ./my-world --name myworld     # 把一個資料夾變成 Vault
cd my-world
aapms type list                                 # 看有哪些片段型別、各自要填什麼
aapms entity new --type character-fragment --title 琳達 --summary "…" --body "…"
aapms conflict check --draft draft.txt          # 新草稿跟既有設定矛不矛盾
```

每個指令都支援 `--json`,給 AI Agent 用。

## 型別註冊表放哪裡

執行檔啟動時依序找三個地方,找到第一個就用:

1. 環境變數 `STORYFLOW_REGISTRY` 指到的目錄(**自訂型別時才需要**:複製 `registry/` 出去改,再把變數指過去)
2. 執行檔旁邊的 `registry/`(**這個資料夾的預設**,什麼都不用設)
3. 用 `cabal install` 裝的才有的 data-files 目錄

平常不必碰第 1 項。

## 接 claude code(MCP)

```
aapms-serve --port 8080
claude mcp add aapms -- aapms-mcp --url http://127.0.0.1:8080
```

之後 claude code 會看到全部 REST 操作對應的 tool,參數形狀直接來自 API 定義。

## 地端 LLM(衝突偵測第 3 層、工作坊)

在 Vault 的 `.storyflow/config.toml` 加:

```toml
[llm]
base_url = "http://127.0.0.1:8080/v1"   # llama.cpp / Ollama 等 OpenAI 相容端點
model    = "…"
```

沒設的話 `conflict check` 會退化成前兩層(不會失敗),`workshop` 跑不起來。
