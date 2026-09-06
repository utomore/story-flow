-- | @aapms-store@ 全部對外__型別__的定義:錯誤語彙、vault marker 的內容、
-- 索引問題回報、查詢條件與結果、寫入結果。
--
-- __為什麼獨立成一個模組__:這些型別是門面上每一條簽名的名詞,而消費端
-- (@aapms-workspace@ 與 @aapms-service@ 的 Types)本身也是型別層的模組——
-- 它們只需要「'StoreError' 長什麼樣」,不需要 sqlite 連線、檔案系統與
-- @openVault@ 那一整條 IO 相依鏈。型別與碰 IO 的函式住同一個模組時,
-- 「只要型別」在 import 層級就表達不出來。
--
-- 本模組因此__只 import 型別層的模組__(@aapms-core@ 的值型別、
-- "Aapms.Md.Document"、"Aapms.Md.Error")與 base \/ text;它不 import 任何
-- @Aapms.Store.*@,是 @aapms-store@ 內部依賴圖的葉子,誰都可以往上帶,沒有模組環。
--
-- 各原模組("Aapms.Store.Error" \/ "Aapms.Store.Schema" \/ "Aapms.Store.Marker" \/
-- "Aapms.Store.Query" \/ "Aapms.Store.Edit")原樣 re-export 自己那一份,匯出清單
-- 與既有呼叫端逐字不變;門面 "Aapms.Store" 也把本模組收進去。
module Aapms.Store.Types
  ( -- * 錯誤(契約 G)
    StoreError (..)
  , renderStoreError

    -- * VaultKind
  , VaultKind (..)
  , renderVaultKind
  , parseVaultKind

    -- * vault marker
  , VaultMarker (..)

    -- * 索引問題回報
  , IndexIssue (..)
  , renderIndexIssue

    -- * 查詢的過濾條件(契約 F)
  , NodeFilter (..)
  , emptyNodeFilter

    -- * 全文檢索(契約 F,graph-core\/F007)
  , SearchQuery (..)
  , emptySearchQuery
  , SearchHit (..)
  , FacetCounts (..)
  , SearchResult (..)

    -- * 寫入結果(graph-core\/F008)
  , WriteResult (..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Id (Id, IdPrefix, Ref, VaultId (..), renderId, renderRef)
import Aapms.Core.Level (TreeError, renderTreeError)
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta (Meta, MetaWarning (..), Revision (..), Status, TypeKey (..))
import Aapms.Md.Document (DocKind (..))
import Aapms.Md.Error (MdError, renderMdError)

--------------------------------------------------------------------------------
-- 錯誤(契約 G)

-- | __'StoreError' 是 @aapms-store@ 的唯一錯誤型別__(design.md 契約 G,
-- 2026-08-24 釐清):寫入、索引、marker、跨 vault 的失敗全部是它的建構子,由各
-- feature 依需要__擴充__(F005 建骨架、F006 加索引類、graph-core\/F008 加寫入類),
-- __不得另立平行的錯誤型別再橋接__ ——契約 E 的每個函式都寫
-- @Either StoreError a@,多一個型別就是多一套 @render*@ 與多一次翻譯。
data StoreError
  = -- | 該路徑沒有 @.aapms\/config.toml@。'Aapms.Store.Marker.openVault' 不會
    -- 因此自動建檔
    VaultMarkerMissing FilePath
  | -- | marker 存在但欄位不合法;'Text' 指出是哪個欄位、為什麼不合法
    VaultMarkerInvalid FilePath Text
  | -- | 'Aapms.Store.Marker.initVaultAt' 對已有 marker 的目錄再次呼叫
    VaultAlreadyInitialized FilePath
  | FileReadFailed FilePath Text
  | FileWriteFailed FilePath Text
  | -- | 本套件與 SQLite 之間的例外都收斂到這裡
    SqliteError Text
  | -- | 索引裡查不到這個 id(graph-core\/F008)
    NodeNotFound Id
  | -- | 索引說某檔有這一節,重讀檔案卻找不到 —— 索引過時,不是資料不見
    SectionMissing FilePath Id
  | -- | 節點 id、呼叫端手上的 revision、檔案裡的實際 revision
    RevisionMismatch Id Revision Revision
  | -- | 檔案、'Aapms.Md.Error.MdError'。md 的編輯\/解析函式回 'Left'
    MdWriteFailed FilePath MdError
  | -- | 檔案、'Aapms.Core.Level.TreeError' 清單。編輯後的 Level 樹不合法,__寫檔之前__就中止
    TreeInvalidOnWrite FilePath [TreeError]
  | -- | 檔案、原因。__檔案已經落地__,只有索引沒跟上;'Aapms.Store.Index.rebuildIndex' 修得回來
    IndexUpdateFailed FilePath Text
  | -- | 呼叫端明確指定的路徑已經有檔案(推導出來的路徑會自動遞增,不走這裡)
    FileAlreadyExists FilePath
  | -- | 型別註冊表查不到這個型別該落在哪個目錄
    RegistryDirUnknown TypeKey
  | -- | 對非 asset 的節點呼叫 'Aapms.Store.Write.writeAssetFields'
    NotAnAsset Id
  | -- | 對非 license 的節點呼叫 'Aapms.Store.Write.upsertLicense'
    NotALicense Id
  | -- | 目標節點、目標檔案的種類。'Aapms.Store.Create.addSection' 的
    -- 'Aapms.Md.Section.NewSectionPayload' 與檔案種類不相容
    BadSectionPayload Id DocKind
  | -- | 節點、要刪的那一筆關聯。一筆都沒命中時回這個而不是靜默成功
    LinkNotFound Id Link
  | -- | 被刪的節點、指向它的 (來源節點, 關聯)。'Aapms.Store.Create.DeleteSafe' 專用
    ReferencedBy Id [(Id, Link)]
  | -- | Level 的根 Node 刪不得(刪了就解析不出 @root@),請改刪整份 Level 檔
    CannotDeleteRootNode Id
  | -- | 父節點、算出來的標題層級。Markdown 只有六級標題
    NodeDepthExceeded Id Int
  | -- | __去重後__的 vault 數量、上限(graph-core\/F009;契約 G:兩個數字都要
    -- 列出來)。'Aapms.Store.MultiVault.openVaultSet' 一次接得住幾個索引由
    -- @SQLITE_MAX_ATTACHED@ 決定;超過時是使用者看得懂的錯誤,不是靜默截斷
    -- (ADR-017 第四條)
    TooManyVaults Int Int
  | -- | 撞號的 vault id、兩個不同的 vault 根目錄(graph-core\/F009)。依
    -- ADR-017,__vault 的身分就是 marker 裡的 id__;兩個不同路徑帶著相同的 id
    -- 代表有人複製了整個 vault 目錄,此時任何跨 vault 的
    -- 'Aapms.Core.Id.Ref' 解析都是不確定的,不能靜默去重帶過。__同一個路徑被
    -- 傳兩次__不走這裡——那是無害的呼叫端疏忽,保序去重即可
    VaultIdCollision VaultId FilePath FilePath
  deriving stock (Show, Eq)

-- | 繁中訊息,__每一則說出下一步該做什麼__(契約 G;system.md 全域錯誤處理策略
-- 第 2 條)。
--
-- graph-core\/F008 把寫入路徑的十五個建構子併進來之後,本函式的責任範圍是
-- __'StoreError' 的全部建構子__(含 F005\/F006 原有的六個),不再有第二個
-- @render*@。
renderStoreError :: StoreError -> Text
renderStoreError = \case
  VaultMarkerMissing fp ->
    pack fp
      <> ": 找不到 vault marker(.aapms/config.toml 不存在);"
      <> "請先執行 vault init 建立"
  VaultMarkerInvalid fp msg ->
    pack fp <> ": vault marker 無法解析 —— " <> msg <> ";請修正後再試"
  VaultAlreadyInitialized fp ->
    pack fp
      <> ": 這裡已經有 vault marker(.aapms/config.toml 已存在),不會覆寫;"
      <> "如需重建,請先手動移除該檔案"
  FileReadFailed fp msg ->
    pack fp <> ": 讀檔失敗 —— " <> msg <> ";請確認檔案存在且可讀"
  FileWriteFailed fp msg ->
    pack fp <> ": 寫檔失敗 —— " <> msg <> ";請確認目錄存在且可寫"
  SqliteError msg ->
    "索引操作失敗 —— " <> msg <> ";請嘗試重新開啟 vault"
  -- graph-core/F008 的寫入路徑
  NodeNotFound i ->
    "找不到節點 " <> renderId i <> "(索引裡沒有這個 id);請確認 id 是否正確,"
      <> "或先重新整理索引後再試"
  SectionMissing fp i ->
    pack fp
      <> ": 索引記錄了節點 "
      <> renderId i
      <> ",但重讀檔案時找不到 —— 索引已經過時;請重建索引(rebuildIndex)後再試"
  RevisionMismatch i expected actual ->
    "節點 "
      <> renderId i
      <> " 的 revision 不符(你手上的是 "
      <> renderRevision expected
      <> ",檔案目前是 "
      <> renderRevision actual
      <> ");請重新讀取最新內容後再修改"
  MdWriteFailed fp e ->
    pack fp <> ": Markdown 編輯失敗 —— " <> renderMdError e <> ";請修正後再試"
  TreeInvalidOnWrite fp errs ->
    pack fp
      <> ": 編輯後的 Level 場景樹不合法 —— "
      <> T.intercalate "; " (map renderTreeError errs)
      <> ";請調整標題層級後再試"
  IndexUpdateFailed fp msg ->
    pack fp
      <> ": 資料已經寫入檔案,但索引更新失敗 —— "
      <> msg
      <> ";請重建索引(rebuildIndex)"
  FileAlreadyExists fp ->
    pack fp <> ": 這個路徑已經有檔案;請換一個路徑,或省略路徑讓系統自動推導"
  RegistryDirUnknown (TypeKey k) ->
    "型別 "
      <> k
      <> " 沒有在型別註冊表宣告落點目錄(dir);請先在型別註冊表補上 dir,"
      <> "或改用已宣告的型別"
  NotAnAsset i ->
    "節點 " <> renderId i <> " 不是 asset;請確認 id 指向 pack.md 底下的 asset 節"
  NotALicense i ->
    "節點 " <> renderId i <> " 不是 license;請確認 id 指向 licenses.md 底下的 license 節"
  BadSectionPayload i kind ->
    "節點 "
      <> renderId i
      <> " 的內容種類與目標檔案("
      <> docKindText kind
      <> ")不相容;請改用符合該檔案種類的節內容"
  LinkNotFound i l ->
    "節點 "
      <> renderId i
      <> " 找不到要刪除的關聯("
      <> renderLinkKind (linkKind l)
      <> " -> "
      <> renderRef (linkTarget l)
      <> ");請確認這筆關聯是否已經被刪除"
  ReferencedBy i refs ->
    "節點 "
      <> renderId i
      <> " 仍被 "
      <> T.pack (show (length refs))
      <> " 筆關聯指向,無法安全刪除;請先移除來源端的關聯,或改用強制刪除(DeleteForce)"
  CannotDeleteRootNode i ->
    "節點 " <> renderId i <> " 是 Level 的根 Node,刪不得;請改刪整份 Level 檔"
  NodeDepthExceeded i lvl ->
    "父節點 "
      <> renderId i
      <> " 底下算出的標題層級是第 "
      <> T.pack (show lvl)
      <> " 級,超過 Markdown 六級標題的上限;請改插到較淺的父節點底下,"
      <> "或先把中間的層級壓平"
  -- graph-core/F009 的跨 vault 讀
  TooManyVaults n limit ->
    "一次最多只能同時查詢 "
      <> T.pack (show limit)
      <> " 個 vault,這次收到 "
      <> T.pack (show n)
      <> " 個;請用 --vault 收窄查詢範圍,或先取消註冊用不到的 vault"
  VaultIdCollision (VaultId v) p1 p2 ->
    "兩個不同的目錄帶著同一個 vault id "
      <> v
      <> ":"
      <> pack p1
      <> " 與 "
      <> pack p2
      <> " —— 這通常是整個 vault 目錄被複製過;請只保留其中一個,"
      <> "或對複製出來的那一份重新執行 vault init 取得新的 id 後再試"
  where
    pack = T.pack
    renderRevision (Revision n) = T.pack (show n)
    docKindText = \case
      TopicDoc -> "主題檔"
      LevelDoc -> "Level 檔"
      PackDoc -> "pack.md"
      LicenseDoc -> "licenses.md"

--------------------------------------------------------------------------------
-- VaultKind 與 marker

-- | 一個 vault 主要裝什麼(ADR-017)。運維分界,不是資料模型分界。
data VaultKind = AssetVault | StoryVault
  deriving stock (Show, Eq)

renderVaultKind :: VaultKind -> Text
renderVaultKind AssetVault = "asset"
renderVaultKind StoryVault = "story"

-- | 只認 @"asset"@\/@"story"@,其餘一律 'Nothing'。
parseVaultKind :: Text -> Maybe VaultKind
parseVaultKind "asset" = Just AssetVault
parseVaultKind "story" = Just StoryVault
parseVaultKind _ = Nothing

-- | @\<root\>\/.aapms\/config.toml@ 的內容。讀寫走 "Aapms.Store.Marker"。
--
-- __不含連線__:那是 'Aapms.Store.Marker.VaultHandle' 的事,它捧著一個已開的
-- @Connection@,只能住在碰 IO 的那一層。
data VaultMarker = VaultMarker
  { vmId :: VaultId
  , vmKind :: VaultKind
  , vmName :: Text
  , vmRefs :: [VaultId]
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 索引問題回報

-- | 索引重建\/索引時回報的問題。graph-core\/F005 只有 'SchemaRebuilt';
-- graph-core\/F006__擴充__加三個建構子(不重新定義,契約 G「骨架」原則):
-- 單檔解析\/驗證失敗時「整檔不進索引」的三種理由。
data IndexIssue
  = SchemaRebuilt
      { irOldVersion :: Maybe Int
      -- ^ @meta_info@ 讀到的舊值;'Nothing' 代表全新索引檔(表都還不存在)
      , irNewVersion :: Int
      }
  | -- | 檔案、'Aapms.Md.Error.MdError'。@parseDocument@ 或 @to*@ 解析失敗,
    -- 整檔不進索引
    ParseFailed FilePath MdError
  | -- | 檔案、'Aapms.Core.Level.TreeError' 清單。@LevelDoc@ 的 @buildTree@
    -- 驗證失敗,整檔不進索引
    TreeInvalid FilePath [TreeError]
  | -- | 檔案、撞名的 'LogicalName'。@assets.name UNIQUE@ 與既有索引衝突,
    -- 整個 @indexOne@ transaction 回滾,整檔不進索引
    DuplicateAssetName FilePath LogicalName
  | -- | 檔案、節點 id、'Aapms.Core.Registry.Build.checkMeta' 的警告清單。__不__讓
    -- 該節點不進索引('checkMeta' 本身的契約是「只回警告,不決定要不要擋」)
    -- ——節點正常寫入,警告只是附帶回報,供上層(@service@)決定怎麼辦
    MetaWarningsFound FilePath Id [MetaWarning]
  deriving stock (Show, Eq)

renderIndexIssue :: IndexIssue -> Text
renderIndexIssue (SchemaRebuilt old new) =
  "索引已重建:schema 版本從 "
    <> maybe "(全新索引檔)" (T.pack . show) old
    <> " 變成 "
    <> T.pack (show new)
renderIndexIssue (ParseFailed fp e) =
  T.pack fp <> ": 解析失敗,不進索引 —— " <> renderMdError e
renderIndexIssue (TreeInvalid fp es) =
  T.pack fp
    <> ": Level 場景樹不合法,不進索引 —— "
    <> T.intercalate "; " (map renderTreeError es)
renderIndexIssue (DuplicateAssetName fp (LogicalName nm)) =
  T.pack fp <> ": asset 名稱 `" <> nm <> "` 與既有索引重複,整檔不進索引"
renderIndexIssue (MetaWarningsFound fp nodeId ws) =
  T.pack fp
    <> ": 節點 "
    <> renderId nodeId
    <> " 的型別檢查警告(不擋索引)—— "
    <> T.intercalate "; " (map renderMetaWarning ws)

-- | 本模組自己的 'MetaWarning' 文字化——"Aapms.Core.Registry.Build" 只匯出
-- @checkMeta@ 本身,沒有匯出對應的 render 函式(只有型別 'MetaWarning (..)'
-- 公開),索引層要顯示訊息只能自己寫一份。
renderMetaWarning :: MetaWarning -> Text
renderMetaWarning = \case
  MissingRequiredField (TypeKey k) f -> "型別 " <> k <> " 缺少必填欄位 `" <> f <> "`"
  LinkNotAllowed (TypeKey k) kind -> "型別 " <> k <> " 不允許關聯 `" <> kind <> "`"
  UnknownNodeType (TypeKey k) -> "型別 `" <> k <> "` 不在註冊表內"
  NameKindNotAllowed (TypeKey k) kind ->
    "型別 " <> k <> " 的命名第一段 `" <> kind <> "` 不在允許的 name_kinds 內"

--------------------------------------------------------------------------------
-- 查詢的過濾條件(契約 F)

data NodeFilter = NodeFilter
  { nfPrefixes :: [IdPrefix]
  , nfTypes :: [TypeKey]
  , nfStatus :: [Status]
  , nfTags :: [Text]
  , nfOwner :: Maybe Id
  , nfLicense :: Maybe Ref
  , nfNamedOnly :: Bool
  , nfIncludeReference :: Bool
  , nfLimit :: Int
  , nfOffset :: Int
  }
  deriving stock (Show, Eq)

-- | 全部欄位取最寬鬆的預設值(待確認假設 ASM-9:'nfLimit' 給一個大但有限的值,
-- 契約 F 沒有逐字列出這個輔助值,比照 F005 對 'IndexIssue'
-- 「契約給骨架、由後續 feature 依需要擴充」的精神補上)。
emptyNodeFilter :: NodeFilter
emptyNodeFilter =
  NodeFilter
    { nfPrefixes = []
    , nfTypes = []
    , nfStatus = []
    , nfTags = []
    , nfOwner = Nothing
    , nfLicense = Nothing
    , nfNamedOnly = False
    , nfIncludeReference = False
    , nfLimit = 1000
    , nfOffset = 0
    }

--------------------------------------------------------------------------------
-- 全文檢索(契約 F,graph-core/F007)

-- | 一次檢索:文字條件(可無)+ 結構條件 + 要不要順便算 facet。
data SearchQuery = SearchQuery
  { sqText :: Maybe Text
  -- ^ 全文條件。'Nothing' 或去掉頭尾空白後為空字串時__不__走 FTS,退化成
  -- 純結構查詢(等同 'Aapms.Store.Query.listNodes')。
  , sqFilter :: NodeFilter
  -- ^ 結構條件,語意與 'Aapms.Store.Query.listNodes' 完全相同(含 'nfLimit' \/ 'nfOffset')。
  , sqFacets :: Bool
  -- ^ 'True' 時 'srFacets' 為 'Just',否則為 'Nothing'。
  }
  deriving stock (Show, Eq)

-- | 沒有文字條件、最寬鬆的結構條件、不算 facet。
emptySearchQuery :: SearchQuery
emptySearchQuery =
  SearchQuery
    { sqText = Nothing
    , sqFilter = emptyNodeFilter
    , sqFacets = False
    }

-- | 一筆命中。'shVault' 讓跨 vault 的 @searchAcross@(graph-core\/F009)與單一
-- vault 的 'Aapms.Store.Query.search' 回同一種形狀。
data SearchHit = SearchHit
  { shVault :: VaultId
  , shMeta :: Meta
  , shSnippet :: Text
  -- ^ 命中片段的純文字,不含任何標記;沒有文字條件時為空字串。
  , shScore :: Double
  -- ^ 相關度,愈大愈相關。有文字條件時恆 @> 0@;沒有文字條件時恆 @0@。
  }
  deriving stock (Show, Eq)

-- | 五個維度的分面計數。每個維度都是(值, 筆數),計數遞減、同計數以值遞增;
-- 值為 NULL 或計數為 0 的不出現。
data FacetCounts = FacetCounts
  { fcTypes :: [(Text, Int)]
  , fcVaults :: [(Text, Int)]
  , fcTags :: [(Text, Int)]
  , fcOwners :: [(Text, Int)]
  , fcLicenses :: [(Text, Int)]
  }
  deriving stock (Show, Eq)

-- | 'srTotal' 是套用全部條件、__未__套用 'nfLimit' \/ 'nfOffset' 的總筆數。
data SearchResult = SearchResult
  { srHits :: [SearchHit]
  , srTotal :: Int
  , srFacets :: Maybe FacetCounts
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 寫入結果(graph-core/F008)

-- | 一次成功寫入的結果。
--
-- @wrIssues@ 是寫入後 'Aapms.Store.Index.indexFile' 對__該檔__回報的問題
-- (@checkMeta@ 警告等);它不是失敗,是附帶回報,由 @service@ 決定怎麼辦。
data WriteResult = WriteResult
  { wrId :: Id
  , wrPath :: FilePath
  -- ^ Vault 相對路徑,與索引裡存的形式一致
  , wrRevision :: Revision
  -- ^ 寫入後的新 revision(= 傳入的 expected + 1)
  , wrIssues :: [IndexIssue]
  }
  deriving stock (Show, Eq)
