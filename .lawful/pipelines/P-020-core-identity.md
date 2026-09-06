---
id: P-020
description: 短 id 與跨 vault Ref 的生成、解析與渲染往返
status: ready
updated: 2026-09-06
---
# P-020-core-identity:短 id 與跨 vault Ref 的生成、解析與渲染往返

## Brief
把「這是哪一個節點」壓成一段能寫進 Markdown、存進索引、又能跨 vault 定址的短文字(ADR-014)。input 是節點種類、要雜湊的內容、時間與碰撞重試用的 salt,或是一段從檔案讀來的參照字串;output 是 `<prefix>-<8 位小寫十六進位>` 的 `Id`,以及 `<vault-id>:<id>` 與裸 `<id>` 兩種寫法的 `Ref`。流向:雜湊位元組 → 前綴文字 → 生成 id → 渲染 id → 解析回前綴與 id → 取前綴 → 包成本 vault 參照 → 解析參照 → 渲染參照。整條零 IO 也零重量級相依:時間由呼叫端給,唯一性由持有索引的那一層以 salt 遞增重試保證,這裡只保證相同輸入穩定、不同輸入分散。它是子流,P-001-index-rebuild 之後每一條 pipeline 的節點身分與關聯 target 都建立在它上面。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `fnv1a64 :: BS.ByteString -> Word64` | FNV-1a 64-bit,雜湊 id 的內容 | `Aapms.Core.Id` | types |
| 2 | `renderIdPrefix :: IdPrefix -> Text` | 八種節點前綴的三字母文字 | `Aapms.Core.Id` | types |
| 3 | `parseIdPrefix :: Text -> Either IdError IdPrefix` | 三字母文字反解成前綴 | `Aapms.Core.Id` | types |
| 4 | `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | 由前綴、內容、時間、salt 產生 id | `Aapms.Core.Id` | types |
| 5 | `renderId :: Id -> Text` | id 的文字表示 | `Aapms.Core.Id` | types |
| 6 | `parseId :: Text -> Either IdError (IdPrefix, Id)` | 文字解析成前綴與 id,接受 1–8 位十六進位 | `Aapms.Core.Id` | types |
| 7 | `idPrefix :: Id -> IdPrefix` | 取出 id 的前綴 | `Aapms.Core.Id` | types |
| 8 | `localRef :: Id -> Ref` | 包成本 vault 的參照 | `Aapms.Core.Id` | types |
| 9 | `parseRef :: Text -> Either IdError Ref` | 解析 `id` 或 `<vault-id>:id` 兩種寫法 | `Aapms.Core.Id` | types |
| = | `renderRef :: Ref -> Text` | 純的整條:參照回到可寫進檔案的文字 | `Aapms.Core.Id` | types |

## Laws
- LAW-1 [roundtrip] 參照渲染成文字再解析,拿回同一個參照
  - forall r in Ref
  - |- parseRef (renderRef r) == Right r
- LAW-2 [roundtrip] 合法的參照字串解析後渲染回來逐字相同,兩種寫法都是
  - forall t in Text
  - given isRight (parseRef t)
  - |- fmap renderRef (parseRef t) == Right t
- LAW-3 [roundtrip] 八種前綴的文字表示與解析互為反函式
  - forall p in IdPrefix
  - |- parseIdPrefix (renderIdPrefix p) == Right p
- LAW-4 [roundtrip] id 渲染成文字再解析,拿回同一個 id
  - forall i in Id
  - |- fmap snd (parseId (renderId i)) == Right i
- LAW-5 [relation] 生出來的 id,前綴就是給它的那一個
  - forall p in IdPrefix, c in Text, tm in UTCTime, s in Int
  - |- idPrefix (newId p c tm s) == p
- LAW-6 [invariant] newId 一律產生三字母前綴加八位十六進位,全長固定 12,不因雜湊值小而變短
  - forall p in IdPrefix, c in Text, tm in UTCTime, s in Int
  - |- length (renderId (newId p c tm s)) == 12 and isPrefixOf (renderIdPrefix p) (renderId (newId p c tm s))
- LAW-7 [relation] 同一組輸入換一個 salt 就得到不同的 id,這是碰撞重試的基礎
  - forall p in IdPrefix, c in Text, tm in UTCTime, s1 in Int, s2 in Int
  - given not (s1 == s2)
  - |- not (newId p c tm s1 == newId p c tm s2)
- LAW-8 [relation] localRef 只換包裝:vault 段落是空的,id 原封不動
  - forall i in Id
  - |- refVault (localRef i) == Nothing and refId (localRef i) == i
- LAW-9 [total] 任何文字丟給 parseId 都有值,不拋例外
  - forall t in Text
  - |- total (parseId t)
- LAW-10 [total] 任何文字丟給 parseRef 都有值,不拋例外
  - forall t in Text
  - |- total (parseRef t)
- LAW-11 [identity] 空的位元組序列不折疊任何東西,雜湊值就是 FNV-1a 的 offset basis
  - forall bs in ByteString
  - given null bs
  - |- fnv1a64 bs == 0xcbf29ce484222325

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `parseRef "vlt-a0c4e1f8:ent-7f3b2a91"` | `refVault` 為 `Just (VaultId "vlt-a0c4e1f8")`;再 `renderRef` 得回 `"vlt-a0c4e1f8:ent-7f3b2a91"` | LAW-1、LAW-2 |
| EX-2 | `parseRef "ent-7f3b2a91"`(裸 id,本 vault) | `refVault` 為 `Nothing`;`renderRef` 得回 `"ent-7f3b2a91"` | LAW-2、LAW-8 |
| EX-3 | `parseRef ":ent-7f3a"`(vault 段落為空) | `Left (BadRefFormat ":ent-7f3a")` | LAW-10 |
| EX-4 | `parseRef "ent-00000000:ent-7f3a"`(vault 段落的前綴不是 `vlt`) | `Left (BadRefFormat "ent-00000000:ent-7f3a")`;`parseRef "a:b:ent-7f3a"` 同 | LAW-10 |
| EX-5 | `map renderIdPrefix [PEnt, PAst, PPck, PLic, PLvl, PNod, PVlt, PPrj]` | `["ent", "ast", "pck", "lic", "lvl", "nod", "vlt", "prj"]`,逐一 `parseIdPrefix` 回原值 | LAW-3 |
| EX-6 | `parseId "nod-0001"`(system.md 範例的短寫,只有四位十六進位) | `Right (PNod, …)`,`renderId` 回 `"nod-0001"` | LAW-4 |
| EX-7 | `parseId "ent7f3a"` / `"ent-"` / `"ent-7g3a"` / `"ent-7f3a1c92f"` | 依序 `Left (BadIdFormat …)`:沒有連字號、空的十六進位段、非法字元、超過八位 | LAW-9 |
| EX-8 | `parseId "xyz-7f3a"` | `Left (UnknownIdPrefix "xyz")` | LAW-9 |
| EX-9 | `newId PEnt "琳達" time0 0` 對上 `newId PEnt "琳達" time0 1`;salt 取 0..9 | 兩者相異;十個 salt 得到十個互不相同的 id | LAW-7 |
| EX-10 | `renderId (newId PEnt "埃提亞崩塌前的織紋刀" time0 0)` | 以 `"ent"` 起頭,連字號之後恰好八位小寫十六進位,全長 12;`idPrefix` 為 `PEnt` | LAW-5、LAW-6 |
| EX-11 | `fnv1a64 ""` | `0xcbf29ce484222325`(offset basis);對照 `fnv1a64 "a"` 為 `0xaf63dc4c8601ec8c` | LAW-11 |

## 決定
- **`newId` 一律產生八位十六進位,`parseId` 放寬到一至八位。** 否決:解析端也只收八位。理由:system.md 全篇的範例(`ent-7f3a`、`nod-0001`)與作者手寫的 `{#ent-7f3b}` 錨點都是短寫,拒收它們會讓文件自己的範例檔變成非法輸入
- **雜湊用 FNV-1a 64-bit 取低 32 位,不用 SHA-256。** 否決:密碼學強度的雜湊。理由:`aapms-core` 要維持零重量級相依(F001 的 `CabalSpec` 逐字擋八個套件),而 id 只需要夠分散且可重現
- **唯一性不在這一層:`newId` 只保證相同輸入穩定、不同輸入分散,撞到既有 id 由呼叫端 `salt + 1` 重算。** 否決:core 自己保證唯一。理由:唯一性是「相對於某一份索引」的性質,型別層看不到索引
- **時間由呼叫端以 `UTCTime` 參數傳入,模組零 IO。** 否決:內部取 `getCurrentTime`。理由:整條要能在 property test 裡重跑,時間是輸入不是環境
- **`Ref` 的 vault 段落本身必須是合法的 `vlt-<hex>` id,不是任意文字的 vault 名稱。** 否決:沿用 assetdb 的自由文字 vault 名。理由:ADR-014 之後 vault 的身分就是它自己的短 id
- **`idPrefix` 回 `IdPrefix` 而不是 `Maybe IdPrefix`。** 否決:回 `Maybe` 讓呼叫端處理。理由:`Id` 的建構子不外露,拿得到 `Id` 就代表已經解析過,不變量由型別守而不是由每個呼叫端重驗一次
- **八種前綴是封閉列舉,`vlt` / `prj` 不對應任何 `AnyNode` 建構子。** 否決:開放前綴、另加一個 `kind` 判別鍵。理由:id 前綴唯一對應節點種類(ADR-014),JSON 解碼讀 `id` 的前綴就夠,不必再多一個欄位重複同一件事
- **關聯的 target 一律是 `Ref` 而非 `Id`。** 否決:同 vault 用 `Id`、跨 vault 另開一種欄位。理由:跨 vault 引用從型別上就是一等公民,不是後補的字串慣例

## 修訂記錄
無
