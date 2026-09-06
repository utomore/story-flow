---
id: P-021
description: 型別宣告清單經五條規則驗證建成註冊表,再據以查型別、查目錄與檢查節點
status: frozen
updated: 2026-09-06
---
# P-021-registry-build:型別宣告清單經五條規則驗證建成註冊表,再據以查型別、查目錄與檢查節點

## Brief
把 `types/registry/` 宣告的型別變成一份可查、可據以檢查節點的註冊表(ADR-005、ADR-012)。input 是一組已經解析好的 `TypeDecl`(entity 族與 asset 族共用同一個形狀);output 是不透明的 `TypeRegistry`,以及對單一節點的一串 `MetaWarning`。流向:家族文字互轉 → 保留鍵清單 → 五條規則一次驗完並建表 → 查型別 / 列型別 / 查新建檔案的目錄 / 對節點產警告。TOML 檔怎麼找、怎麼讀、怎麼解析成 `[TypeDecl]` 不在這條裡——那是 `Aapms.Types.Loader`(shell),由 P-004-vault-scope 的 `!` 列讀檔案再把結果餵進來。它是子流:P-001-index-rebuild 的 `checkMeta` 一步、以及後續每一條要問「這個 type 存不存在」的 pipeline 都引用它。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `renderFamily :: Family -> Text` | 家族的穩定小寫文字,進 DB 與 JSON 用同一份 | `Aapms.Core.Registry` | types |
| 2 | `parseFamily :: Text -> Maybe Family` | TOML 的 `family` 值反解成家族 | `Aapms.Core.Registry` | types |
| 3 | `reservedTypeKeys :: [TypeKey]` | 引擎保留、不可出現在註冊表的三個鍵 | `Aapms.Core.Registry` | types |
| 4 | `lookupType :: TypeRegistry -> TypeKey -> Maybe TypeDecl` | 依鍵查一份宣告 | `Aapms.Core.Registry` | types |
| 5 | `listTypes :: TypeRegistry -> [TypeDecl]` | 全部宣告,依鍵排序讓輸出穩定 | `Aapms.Core.Registry` | types |
| 6 | `lookupDir :: TypeRegistry -> TypeKey -> Maybe FilePath` | 型別鍵到新建檔案該落的子目錄,查不到再掃 `owner_type` | `Aapms.Core.Registry` | types |
| 7 | `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` | 一個節點對它的型別宣告:必填欄位、關聯、asset 的命名第一段,只回警告 | `Aapms.Core.Registry.Build` | pure |
| = | `buildRegistry :: [TypeDecl] -> Either [RegistryError] TypeRegistry` | 純的整條:五條規則一次驗完,全過才建得出註冊表 | `Aapms.Core.Registry` | types |

## Laws
- LAW-1 [invariant] 保留鍵一律進不了註冊表
  - forall d in TypeDecl
  - given tdKey d in reservedTypeKeys
  - |- isLeft (buildRegistry [d])
- LAW-2 [total] 任何宣告清單丟給 buildRegistry 都有值,不拋例外
  - forall ds in [TypeDecl]
  - |- total (buildRegistry ds)
- LAW-3 [invariant] 同一份宣告出現兩次一定被拒,鍵不可重複
  - forall d in TypeDecl
  - |- isLeft (buildRegistry [d, d])
- LAW-4 [relation] 建得起來的註冊表列得出送進去的每一份宣告
  - forall ds in [TypeDecl], reg in rights [buildRegistry ds], d in ds
  - |- tdKey d in map tdKey (listTypes reg)
- LAW-5 [relation] listTypes 列出來的每一份,lookupType 都查得到,而且查到的就是它自己
  - forall ds in [TypeDecl], reg in rights [buildRegistry ds], d in listTypes reg
  - |- lookupType reg (tdKey d) == Just d
- LAW-6 [invariant] listTypes 依鍵排序且鍵不重複,CLI 與 API 的輸出因此穩定
  - forall ds in [TypeDecl], reg in rights [buildRegistry ds]
  - |- sortOn tdKey (listTypes reg) == listTypes reg and nub (map tdKey (listTypes reg)) == map tdKey (listTypes reg)
- LAW-7 [relation] 型別自己宣告了 dir 時,lookupDir 就回那一個,不去掃 owner_type
  - forall ds in [TypeDecl], reg in rights [buildRegistry ds], d in listTypes reg
  - given isJust (tdDir d)
  - |- lookupDir reg (tdKey d) == tdDir d
- LAW-8 [roundtrip] 家族的文字表示與解析互為反函式
  - forall f in Family
  - |- parseFamily (renderFamily f) == Just f
- LAW-9 [relation] 型別沒宣告時,checkMeta 只回一則 UnknownNodeType
  - forall reg in TypeRegistry, n in AnyNode
  - given lookupType reg (metaType (anyMeta n)) == Nothing
  - |- checkMeta reg n == [UnknownNodeType (metaType (anyMeta n))]
- LAW-10 [relation] 型別已宣告、沒有必填欄位、沒有 allowed_links、沒有 name_kinds 時,任何節點都不產生警告
  - forall reg in TypeRegistry, n in AnyNode, d in listTypes reg
  - given metaType (anyMeta n) == tdKey d and null (filter fdRequired (tdFields d)) and null (tdAllowedLinks d) and null (tdNameKinds d)
  - |- checkMeta reg n == []
- LAW-11 [relation] 宣告了 allowed_links 之後,不在裡面的關聯逐條產生 LinkNotAllowed
  - forall reg in TypeRegistry, n in AnyNode, d in listTypes reg, l in metaLinks (anyMeta n)
  - given metaType (anyMeta n) == tdKey d and not (null (tdAllowedLinks d)) and notElem (linkKind l) (tdAllowedLinks d)
  - |- LinkNotAllowed (tdKey d) (renderLinkKind (linkKind l)) in checkMeta reg n

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `buildRegistry []`(空目錄是合法的) | `Right`,`listTypes` 為 `[]` | LAW-2、LAW-6 |
| EX-2 | 一份 `tdKey = TypeKey "level"` 的宣告;`"asset-pack"`、`"asset-license"` 同 | `Left [ReservedTypeKey (TypeKey "level")]` 等三則 | LAW-1 |
| EX-3 | 同一個 `tdKey` 的兩份宣告 | `Left`,錯誤含 `DuplicateTypeKey`,且該鍵只列一次 | LAW-3 |
| EX-4 | `character-fragment`(`tdDir = Just "characters"`)與 `dialogue` 兩份宣告 | `Right`;`listTypes` 依鍵字母序回兩份;兩個鍵 `lookupType` 都是 `Just` | LAW-4、LAW-5、LAW-6 |
| EX-5 | `lookupDir reg (TypeKey "character-fragment")` | `Just "characters"` | LAW-7 |
| EX-6 | 一份宣告了 `[[fields]] name = "ghost"` 的型別(`metaFieldNames` 沒有這個欄位) | `Left`,錯誤含 `UnknownMetaField (TypeKey …) "ghost"` | LAW-2 |
| EX-7 | 一份宣告的 `tdKey` 是空白字串,同時另一份宣告用了保留鍵 | `Left`,兩類錯誤都在同一個清單裡,不是只回第一個 | LAW-1、LAW-2 |
| EX-8 | `renderFamily FEntity` / `renderFamily FAsset` / `parseFamily "ghost"` | `"entity"` / `"asset"` / `Nothing` | LAW-8 |
| EX-9 | 一個 `metaType` 為註冊表沒有的 `TypeKey "ghost"` 的主題節點 | `checkMeta` 回 `[UnknownNodeType (TypeKey "ghost")]`,恰好一則 | LAW-9 |
| EX-10 | `asset-archive`(`tdNameKinds = []`、`tdAllowedLinks = []`、無必填欄位)底下一個已命名的 asset | `checkMeta` 回 `[]`——空清單是「未宣告限制」而不是「什麼都不准」 | LAW-10 |
| EX-11 | `asset-image`(`tdAllowedLinks = [Depicts]`)底下一個帶 `Involves` 關聯的 asset | `checkMeta` 含 `LinkNotAllowed (TypeKey "asset-image") "involves"` | LAW-11 |
| EX-12 | `asset-image`(`tdNameKinds = [spr, tex, atlas, ui]`)底下 `astName` 為 `ui_gui_travel-book-frame_001` 與 `sfx_ui_click_001` 的兩個 asset | 前者不產生 `NameKindNotAllowed`,後者產生;`astName = Nothing` 時兩者都不產生 | LAW-10 |

## 決定
- **`buildRegistry` 是 `TypeRegistry` 唯一的 smart constructor,與型別住同一個模組。** 否決:驗證搬到另一個模組、型別另開建構入口。理由:守門人搬到被守的型別之外,就得開一個繞過驗證的入口;那個入口一旦存在,不變量就只剩註解在守
- **一次回報全部錯誤,不是第一個。** 否決:遇到第一個錯就中止。理由:作者一次改壞好幾份 TOML 是常態,一次列完比修一個跑一次有用
- **保留鍵是 `level` / `asset-pack` / `asset-license` 三個。** 否決:只保留 `level`。理由:後兩者是 `pack.md` 與 `licenses.md` 的檔案層 `type`,不是「某個型別的 asset」,被註冊表佔用就分不出檔案種類
- **`checkMeta` 只回警告,不決定要不要擋。** 否決:缺必填欄位就拒絕寫入。理由:契約卡「不決定警告要不要擋」;擋不擋是 service 的事,同一件事不能在兩層各判一次
- **`tdAllowedLinks` 與 `tdNameKinds` 為空清單一律讀成「未宣告限制」。** 否決:空清單讀成「什麼都不允許」。理由:`asset-archive` 依 legacy `KindPrefix` 對照表算出來剛好是空的,反過來解讀會讓它任何名稱都變成警告(F002 ASM-3)
- **`checkMeta` 不呼叫 `parseLogicalName`,直接切 `LogicalName` 文字第一個 `_` 之前的片段當 kind 用。** 否決:給 `checkMeta` 的簽名加一個 `NamingVocab` 參數。理由:`astName` 的唯一建構路徑是 `mkLogicalName`(見 P-022-logical-name),第一段的合法性寫入時已經保證過,這裡只需要文字本身(F002 ASM-6)
- **`checkMeta` 住 pure 層的 `Aapms.Core.Registry.Build`,不與型別宣告同居。** 否決:併回 `Aapms.Core.Registry`。理由:它要讀 `AnyNode` 與 `Meta` 的內容做推導,型別層不可以反過來依賴推導層;方向是單向的
- **TOML 到 `[TypeDecl]` 的載入不在這條:`Aapms.Types.Loader` 是 shell,由 P-004-vault-scope 的 `!` 列讀檔案。** 否決:把 `loadRegistry` 列成本條的 stage。理由:子流不碰 shell,註冊表的檔案 I/O 在 system.md 的對外 I/O 表上
- **載入失敗讓程序失敗,不退回一份空註冊表。** 否決:讀不到就給空的繼續跑。理由:空註冊表會讓每個節點都變成 `UnknownNodeType`,把設定錯誤偽裝成資料錯誤
- **`RegistryError` 一個型別涵蓋純驗證與 TOML 載入兩類問題,多個問題包成 `RegistryErrors`。** 否決:純驗證與載入各一個錯誤 ADT。理由:契約 G 只有一個 `RegistryError`,而 `loadRegistry` 的回傳是單一值;要保住「一次回報全部」就得有一個聚合建構子

## 修訂記錄
無
