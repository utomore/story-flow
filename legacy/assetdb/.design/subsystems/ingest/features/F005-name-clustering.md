---
id: F005
type: feature
title: name-clustering
description: 檔名形狀抽象、叢集推論與命名規則的持久化與套用
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F002]
related-adr: [ADR-004]
---

# F005: 檔名叢集推論

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

素材庫有數千筆資源要命名。逐筆決定不可能;但**同一個素材包內的檔名一定內部一致**,所以把檔名抽象成「形狀」再分群,一包上千個檔案通常塌縮成三五個叢集。人對每個叢集確認一次規則,整群套用。決策量因此從數千降到約一百。

而且資料庫存的是**規則**而不是結果:廠商出更新版時,新檔案只要形狀相同就自動套用既有規則,不需要重新確認一次。

形狀的抽象層級是這個功能最關鍵的設計選擇——太細會碎裂成幾百個叢集,太粗會把語意不同的東西混在一起。實測下來「字母/數字/大小寫的模式,分隔符一律正規化」是恰好的粒度:

```text
UI_TravelBook_Frame01a  ->  U_W_WNa
UI_HoloBook_Alert02b    ->  U_W_WNa     (同一叢集)
ores-minerals13         ->  w_wN
Blue Potion 2           ->  W_W_N
00                      ->  N
idle_down               ->  w_w
```

分群鍵除了形狀還包含**目錄角色**與副檔名。廠商的目錄名千奇百怪但用途只有幾種;這個分類讓「宣傳圖」與「實際素材」即使檔名形狀相同也會落在不同叢集——它們需要完全不同的規則(前者根本不該進索引)。判定時 `preview` 優先於 `sprites`:誤把宣傳圖當素材的代價,比誤把素材當宣傳圖高,而 `Sprites/Preview/` 這種巢狀在廠商包裡真的存在。

有兩件事**必須由人告訴系統**,自動判斷不可靠:

- 尾端數字是變體編號還是動畫格號(`potion10` 的 10 是變體,`00.png` 的 00 是格號,形狀相同)。
- 檔名裡根本沒有主體時,主體是什麼(`idle_down.png` 是誰的 idle?那個資訊只存在人的腦袋裡)。

## 落地位置

| 模組 | 檔案 | 職責 |
|---|---|---|
| `AssetDB.Ingest.Cluster` | `ingest/src/AssetDB/Ingest/Cluster.hs` | 形狀抽象、目錄角色、分群、命名規則套用(**純函數,無 IO**) |
| `AssetDB.Ingest.ClusterDb` | `ingest/src/AssetDB/Ingest/ClusterDb.hs` | 規則的持久化(`name_clusters`)、預覽、批次套用 |

命名文法本身(`NamingVocab`、`NameParts`、`LogicalName`、`NameError`、片段驗證)屬於 catalog 的 `AssetDB.Naming`;本功能只是把檔名轉換成合法的名稱組件再交給它驗證。

## 對外行為

### 純函數層

- `tokenize :: Text -> [Token]` — 把檔名主幹拆成權杖。**任何非英數字元都是分隔符**,且分隔符不保留在形狀裡(`idle_down` 與 `idle-down` 語意相同,讓它們落在不同叢集只會製造無意義的確認工作)。`Token` 拆成字母 / 數字 / 數字後單一字母尾綴三段,因為廠商幾乎都把序號直接黏在名字後面,而那個序號是變體或格號,不屬於主體。
- `fileShape :: Text -> Text` — 權杖序列的形狀字串(`w` 全小寫、`W` 首字大寫、`U` 全大寫兩字以上、`N` 數字、`a` 數字後尾綴、`?` 無法歸類)。
- `dirRole :: Text -> DirRole` / `dirRoleText` — 八種角色,依**優先序**而非路徑順序挑選。
- `clusterKeyOf :: Text -> ClusterKey` / `clusterKeyText :: ClusterKey -> Text` — 單一路徑所屬的叢集鍵與其文字形式(資料庫裡的形狀鍵格式)。分群與反查必須是**同一段程式碼**,否則規則會套到錯的檔案上。
- `clusterBy :: [Text] -> [Cluster]` — 依成員數遞減排序(大群先看)。樣本取字典序的頭、中、尾各幾筆而不是前 N 筆——前 N 筆常常長得一模一樣,看不出叢集的實際跨度。
- `NameRule` — kind 前綴、domain、固定主體、要丟棄的權杖索引、納入主體的目錄層數、尾端數字角色、標籤。
  - 丟棄權杖:`UI_TravelBook_Frame01a` 的 `UI` 與 kind 前綴重複。
  - 納入目錄:某些特效包是 `32x32/A/00.png` 到 `32x32/K/11.png`,不含目錄的話所有叢集成員都叫同一個名字,而邏輯名稱是唯一的。
  - JSON codec **手寫而非 Generic**:這個 JSON 存進 `name_clusters.rule_json`,是跨越工具版本的持久化格式;欄位名不該由 Haskell 的欄位名間接決定,那種寫法在有人重新命名欄位時會讓既有規則全部讀不回來。
- `applyRule :: NamingVocab -> NameRule -> Text -> Either NameError LogicalName` — 由右往左剝:先剝最後一個帶數字的權杖,再剝屬於狀態詞彙的權杖。**非末尾權杖的數字必須保留**——否則同一系列的不同變體會產生同一個邏輯名稱而撞名。尾端數字在 `NumAuto` 下只在形狀明確時才下結論(三位數以上或超過兩位數上限不可能是變體,只能是序號)。

### IO 層

- `listPacks :: Store -> Maybe Text -> IO [PackRef]` / `packPaths :: Store -> Int -> IO [Text]` / `packClusters :: Store -> Int -> IO [Cluster]` — 素材包列舉與其項目路徑的分群。
- `saveRule :: Store -> Int -> Cluster -> NameRule -> IO ()` — 以 (素材包, 形狀鍵) upsert;同一叢集重複確認是覆寫而非新增。同時存下成員數與樣本,供之後檢視。
- `loadRules :: Store -> Int -> IO (Map Text NameRule)` — 形狀鍵 → 規則。
- `previewCluster :: NamingVocab -> NameRule -> [Text] -> [NamePreview]` — **不寫入任何東西**。確認之前一定要看得到結果:規則的參數抽象到人腦裡難以驗證,但「這 5 個檔案會變成這 5 個名字」一眼就能判斷對錯。
- `applyNames :: Store -> NamingVocab -> Int -> IO ApplyNames` — 對一個素材包套用所有已確認的規則。**撞名在寫入之前就攔下來**:邏輯名稱有唯一約束,邊算邊寫的話第一個撞到的會讓整批交易失敗,而且不知道還有多少個。先全部算完、找出所有撞名、一次回報,人才能一次修完規則。有失敗或撞名時**一筆都不寫**——半套用的命名比沒有命名更難收拾,你不知道哪些是舊的、哪些是新的。
- `ApplyNames` — 已命名數、跳過數(所屬叢集尚未確認規則)、失敗清單(路徑 + 錯誤)、撞名清單(邏輯名稱 + 撞名的路徑)。

delivery 的 `cli` 另有一條 AI 輔助流程會消費 `Cluster` / `clusterKeyOf` / `clusterKeyText` 來提出規則建議;規則的最終確認與寫入仍走本功能的介面。

## 驗收依據

- `ingest/test/AssetDB/Ingest/ClusterSpec.hs`(純函數,以真實廠商檔名為案例)
  - `fileShape`:形狀對照表逐筆驗證;「同一系列的不同成員形狀相同 —— 這就是分群能成立的前提」「分隔符不影響形狀」
  - `dirRole`:「認得廠商的通用目錄慣例」「preview 優先於 sprites」「沒有可辨識的目錄時是 other」
  - `clusterBy`:「同形狀同角色歸為一群」「副檔名不同就分開 —— aseprite 與 png 需要不同規則」「依數量遞減排序,大群先看」
  - `applyRule`(每個案例對應一家真實廠商的命名慣例):「Crusenho:丟掉與 kind 重複的 UI 前綴」「Crusenho 動畫:尾端序號當格號」「MattzArt:檔名裡沒有主體,由規則提供」「BDragon:純數字檔名,主體來自目錄」「Kibyra:小寫加序號」「Cainos:空格分隔的 Title Case」「三位數以上自動判為格號而非變體」「產生的名稱一律通過命名文法的驗證」「純中文檔名回報錯誤而不是產生垃圾」
- `ingest/test/AssetDB/Ingest/ClusterDbSpec.hs`(對真實 SQLite)
  - 規則的存取:「存進去讀得回來」「同一個叢集重複確認是覆寫而非新增」
  - 套用:「只套用已確認叢集,其餘跳過」「沒有任何規則時什麼都不做」
  - 撞名:「在寫入之前攔下,並回報所有撞名而不是第一個」「有撞名就一筆都不寫」
  - 預覽:「不寫入任何東西」
