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
-- "Aapms.Store.Query" \/ "Aapms.Store.Edit" \/ "Aapms.Store.Write" \/
-- "Aapms.Store.Create")原樣 re-export 自己那一份,匯出清單
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

    -- * 寫入路徑的定位(graph-core\/F008)
  , Located (..)

    -- * asset 的人給欄位(graph-core\/F008)
  , AssetPatch (..)

    -- * 輸入:整份新檔(graph-core\/F008)
  , NewEntity (..)
  , NewLevel (..)
  , NewPack (..)

    -- * 建立與刪除的結果(graph-core\/F008)
  , SectionPlacement (..)
  , CreateResult (..)
  , DeleteMode (..)
  , DeleteResult (..)

    -- * 全文檢索的路由(P-002-search;自 "Aapms.Store.Tokenize" 搬進型別層,
    -- 讓 effects 層的 @ftsMatch@ 用得到它而不必 import pure 層)
  , SearchRoute (..)
  , usesTrigram
  , usesCjk

    -- * 索引狀態與記憶體 vault(P-001-index-rebuild)
  , FileStat (..)
  , IndexedNode (..)
  , FileIndex (..)
  , IndexState (..)
  , VaultFiles
  , emptyIndex
  , vaultPaths
  , fileAt
  , statsDistinguish
  , indexedPaths
  , indexedNodes
  , indexedIds
  , assetNames
  , warnedIds

    -- * 搜尋的觀察點(P-002-search)
  , hitKey
  , nodeKey
  , keysOf
  , wide
  , page
  , withTypes
  , withTags

    -- * 寫入請求與結果(P-003-node-write)
  , WriteOp (..)
  , WriteOutcome (..)
  , WriteRun (..)
  , PackFields (..)
  , opTarget
  , opRevision
  , isInsertOp
  , isDeleteOp
  , idsNeeded
  , outcomeRevision
  , outcomePath
  , outcomeId
  , removedIds
  , brokenLinks
  , locatedFile
  , packFields
  , newPackFields
  , patchedName
  , fileStatsOf
  , stripStamps
  ) where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256)
import Aapms.Core.Id (Id, IdPrefix (..), Ref, VaultId (..), newId, renderId, renderRef)
import Aapms.Core.Level (NodeKind, TreeError, renderTreeError)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta (Meta (..), MetaWarning (..), Revision (..), Source, Status, Timeline, TypeKey (..))
import Aapms.Core.Pack (AiDisclosure, Author, Pack (..))
import Aapms.Md.Document (DocKind (..))
import Aapms.Md.Error (MdError, renderMdError)
import Aapms.Md.Section (MetaOverride, NewSection)

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

--------------------------------------------------------------------------------
-- 寫入路徑的定位(graph-core/F008)

-- | 索引裡的 @nodes.file_path@ \/ @nodes.section_anchor@ 與 @files.doc_kind@。
--
-- 索引在寫入路徑上__只做定位__:哪個檔、哪一節、那是哪一種文件。所有會被比對
-- 或寫回的值一律重讀檔案取得。
data Located = Located
  { locPath :: FilePath
  -- ^ Vault 相對路徑
  , locAnchor :: Maybe Id
  -- ^ @Nothing@ = 檔案層主體(meta 在 frontmatter,不在任何一節)
  , locKind :: DocKind
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- asset 的人給欄位(graph-core/F008)

-- | 'Aapms.Store.Write.writeAssetFields' 能改的__全部__欄位。
--
-- @sha256@ \/ @entry@ \/ @ext@ \/ @meta@ __不在這裡,而且是刻意的__:那四欄是
-- 掃描器(@asset-ingest@)從檔案本身算出來的事實,不是人給的意見。「拒絕改」
-- 因此不是一個執行期檢查,而是__型別上表達不出來__ ——檔案換了就是換了一筆
-- asset,要走 'Aapms.Store.Create.addSection' \/ 'Aapms.Store.Create.deleteNode'。
--
-- 每一欄的外層 'Maybe' 是「這次動不動它」,內層 'Maybe' 是「要設成什麼」:
-- @apName = Nothing@ 不動、@apName = Just Nothing@ 清空、
-- @apName = Just (Just n)@ 設成 @n@。兩層合在一起才表達得出「清空」,少一層就
-- 只能把「不動」與「清空」混為一談。
data AssetPatch = AssetPatch
  { apName :: Maybe (Maybe LogicalName)
  , apLicense :: Maybe (Maybe Ref)
  , apAuthor :: Maybe (Maybe Text)
  , apTags :: Maybe [Text]
  -- ^ @tags@ 住在 'Aapms.Core.Meta.Meta' 而不是 asset 專屬表,但它是人給欄位,
  -- 所以與另外三欄一起走這條路徑;@Just []@ = 清空
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 輸入:整份新檔(graph-core/F008)

-- | 一份新的主題檔(檔案層主體)。
--
-- 沒有 @revision@ \/ @created@ \/ @updated@ 欄位:新檔的 revision 恆為 1,兩個
-- 日期恆為今天,由本層填 —— 讓呼叫端指定它們等於開一個偽造歷史的後門。
data NewEntity = NewEntity
  { neType :: TypeKey
  -- ^ 主體型別鍵,如 @character@;決定檔案落在註冊表的哪個 @dir@
  , neTitle :: Text
  , neSummary :: Text
  , neBody :: Text
  , neTags :: [Text]
  , neAliases :: [Text]
  , neStatus :: Status
  , neTimeline :: Maybe Timeline
  , neLinks :: [Link]
  , neSource :: Source
  , nePath :: Maybe FilePath
  -- ^ Vault 相對路徑;@Nothing@ = 依註冊表 @dir@ + 標題推導(撞名遞增)。
  -- 明確給了卻已經有檔案時回 'FileAlreadyExists' ——那是指定,
  -- 不是推導,不該悄悄換掉
  }
  deriving stock (Show, Eq)

-- | 一份新的 Level 檔。__一併建出根 Node__:Level 檔沒有根 Node 就解析不出
-- @root@,建一個空殼等於建一份壞檔。
data NewLevel = NewLevel
  { nlTitle :: Text
  , nlSummary :: Text
  , nlBody :: Text
  , nlStatus :: Status
  , nlSource :: Source
  , nlRootTitle :: Text
  , nlRootKind :: NodeKind
  , nlPath :: Maybe FilePath
  -- ^ @Nothing@ = @levels\/\<標題\>.md@
  }
  deriving stock (Show, Eq)

-- | 一份新的 @pack.md@(檔案層)。
--
-- @pckArchive = Nothing@ 表示散檔目錄,此時各 asset 的 @entry@ 是相對
-- 'npDir' 的路徑(design.md 契約 A)。
data NewPack = NewPack
  { npDir :: FilePath
  -- ^ Vault 相對目錄;檔案落在 @\<npDir\>\/pack.md@。由呼叫端給,不查註冊表
  , npTitle :: Text
  , npSummary :: Text
  , npBody :: Text
  , npTags :: [Text]
  , npStatus :: Status
  , npSource :: Source
  , npVendor :: Maybe Text
  , npArchive :: Maybe FilePath
  , npSha256 :: Maybe Sha256
  , npLicense :: Maybe Ref
  , npAuthor :: Maybe Author
  , npSourceUrl :: Maybe Text
  , npAiDisclosure :: AiDisclosure
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 建立與刪除的結果(graph-core/F008)

-- | 新節要落在哪裡(契約 E,2026-08-25 裁決)。
--
-- 用__封閉 sum__ 而不是 @Maybe Id@:落點種類日後若要再長(例如「插在某個兄弟
-- 之前」),編譯器會列出所有待處理處 ——與 'Aapms.Core.AnyNode.AnyNode' \/
-- 'Aapms.Md.Render.NewSectionPayload' \/ 'DeleteMode' 同一個模式。
data SectionPlacement
  = -- | 追加在檔尾('Aapms.Md.Render.appendSection')
    AtEnd
  | -- | 插在指定父節點的子樹之後,成為它的最後一個子節點
    -- ('Aapms.Md.Render.insertSection')。__只有 @LevelDoc@ 用得到__:另外三種
    -- 文件的節是平的
    UnderParent Id
  deriving stock (Show, Eq)

-- | 新產生的節點。
--
-- @crId@ 是呼叫端唯一拿不到其他來源的資訊 —— 少了它,@service@ 與 CLI 只能重讀
-- 檔案猜「最後一節就是剛剛那個」。
data CreateResult = CreateResult
  { crId :: Id
  , crPath :: FilePath
  -- ^ Vault 相對路徑
  , crRevision :: Revision
  -- ^ 寫入後檔案層主體的 revision(新檔為 @Revision 1@)
  , crIssues :: [IndexIssue]
  }
  deriving stock (Show, Eq)

-- | 被指向時要擋下來,還是照刪並回報斷點。
data DeleteMode = DeleteSafe | DeleteForce
  deriving stock (Show, Eq)

data DeleteResult = DeleteResult
  { drPath :: FilePath
  , drRemovedIds :: [Id]
  -- ^ 刪整份檔案或整棵子樹時不只一個,依文件順序
  , drBrokenLinks :: [(Id, Link)]
  -- ^ 'DeleteForce' 打斷的關聯(來源節點, 那一筆關聯)
  , drIssues :: [IndexIssue]
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 全文檢索的路由(P-002-search;原住 "Aapms.Store.Tokenize")

-- | 一次查詢要走哪張(或哪兩張)FTS 表。
--
-- __為什麼住型別層__:effects 層的 @Aapms.Store.Effect.Index.ftsMatch@ 把它當
-- 參數,而 effects 只准 import types 與 effects(rules\/boundary.md「四層」)。
-- "Aapms.Store.Tokenize"(pure)原樣 re-export 它與 'usesTrigram' \/ 'usesCjk',
-- 既有呼叫端逐字不變。
data SearchRoute
  = -- | 只查 @fts_tri@:查詢字串不含中日韓字元
    TrigramOnly
  | -- | 只查 @fts_cjk@:含中日韓字元,且整串長度不到三個字元
    -- (trigram 對三字元以下的查詢必定空結果,不值得多一次子查詢)
    CjkOnly
  | -- | 兩張都查,結果以分數合併去重:含中日韓字元且長度三個字元以上
    BothIndexes
  deriving stock (Show, Eq)

-- | 這條路由要不要查 @fts_tri@。
usesTrigram :: SearchRoute -> Bool
usesTrigram TrigramOnly = True
usesTrigram CjkOnly = False
usesTrigram BothIndexes = True

-- | 這條路由要不要查 @fts_cjk@。
usesCjk :: SearchRoute -> Bool
usesCjk TrigramOnly = False
usesCjk CjkOnly = True
usesCjk BothIndexes = True

--------------------------------------------------------------------------------
-- 索引狀態與記憶體 vault(P-001-index-rebuild)

-- | 一個檔的指紋:mtime 與 size。索引拿它判斷「這個檔要不要重新索引」。
data FileStat = FileStat
  { fsMtime :: Int64
  , fsSize :: Int64
  }
  deriving stock (Show, Eq)

-- | 索引裡的一個節點,連同它的擁有者(檔案層主體為 'Nothing')。
data IndexedNode = IndexedNode
  { inNode :: AnyNode
  , inOwner :: Maybe Id
  }
  deriving stock (Show, Eq)

-- | 一份 @.md@ 在索引裡的全部記錄。整檔一起進退(P-001 的決定)。
data FileIndex = FileIndex
  { fiPath :: FilePath
  , fiKind :: DocKind
  , fiStat :: FileStat
  , fiReference :: Bool
  , fiNodes :: [IndexedNode]
  }
  deriving stock (Show, Eq)

-- | 索引的完整狀態:每個檔一組記錄。純解譯器跑在它上面。
newtype IndexState = IndexState (Map FilePath FileIndex)
  deriving stock (Show, Eq)

-- | 記憶體裡的 vault:路徑 → (指紋, 全文)。@VaultFs@ 的純解譯器跑在它上面。
type VaultFiles = Map FilePath (FileStat, Text)

-- | 空索引。
emptyIndex :: IndexState
emptyIndex = IndexState Map.empty

-- | 記憶體 vault 裡的路徑,已排序('Map' 的鍵序就是字母序遞增)。
vaultPaths :: VaultFiles -> [FilePath]
vaultPaths = Map.keys

-- | 記憶體 vault 裡某路徑的指紋與內容。
--
-- 只在 @p in 'vaultPaths' vf@ 時有意義;不在裡面時回一個中性值而不是拋例外
-- ——觀察點不該是部分函數。
fileAt :: VaultFiles -> FilePath -> (FileStat, Text)
fileAt vf p = Map.findWithDefault (FileStat 0 0, T.empty) p vf

-- | 兩份 vault 同路徑內容不同時指紋也不同。
--
-- 只看兩邊都有的路徑:只出現在一邊的路徑沒有「同路徑」可比。
statsDistinguish :: VaultFiles -> VaultFiles -> Bool
statsDistinguish a b =
  and
    [ st1 /= st2
    | (p, (st1, t1)) <- Map.toList a
    , (st2, t2) <- maybe [] pure (Map.lookup p b)
    , t1 /= t2
    ]

-- | 索引裡有記錄的路徑,已排序。
indexedPaths :: IndexState -> [FilePath]
indexedPaths (IndexState m) = Map.keys m

-- | 索引裡全部節點,路徑遞增、檔內依文件順序。
indexedNodes :: IndexState -> [AnyNode]
indexedNodes (IndexState m) = [inNode n | fi <- Map.elems m, n <- fiNodes fi]

-- | 索引裡全部節點的 id。
indexedIds :: IndexState -> [Id]
indexedIds = map (metaId . anyMeta) . indexedNodes

-- | 索引裡已命名 asset 的邏輯名稱。
assetNames :: IndexState -> [LogicalName]
assetNames ix = [nm | NAsset a <- indexedNodes ix, nm <- maybe [] pure (astName a)]

-- | 'MetaWarningsFound' 點到的節點 id。
warnedIds :: [IndexIssue] -> [Id]
warnedIds is = [i | MetaWarningsFound _ i _ <- is]

--------------------------------------------------------------------------------
-- 搜尋的觀察點(P-002-search)

-- | 命中的 (vault, id)。
hitKey :: SearchHit -> (VaultId, Id)
hitKey h = (shVault h, metaId (shMeta h))

-- | 節點的 (vault, id)。
nodeKey :: (VaultId, AnyNode) -> (VaultId, Id)
nodeKey (v, n) = (v, metaId (anyMeta n))


-- | 記憶體索引集合裡的 vault id。
keysOf :: Map VaultId IndexState -> [VaultId]
keysOf = Map.keys

-- | 拿掉分頁(offset 0、limit 大於任何樣本總數)。
wide :: SearchQuery -> SearchQuery
wide q = withFilter (\nf -> nf {nfOffset = 0, nfLimit = wideLimit}) q

-- | 'wide' 用的「比任何樣本都大」的上限。分頁在純層是 @take@ \/ @drop@,
-- 給一個大但有限的值就夠;寫成 @maxBound@ 會讓任何「offset + limit」的
-- 算式溢位。
wideLimit :: Int
wideLimit = 1000000

-- | 設 offset j、limit k。
page :: Int -> Int -> SearchQuery -> SearchQuery
page j k q = withFilter (\nf -> nf {nfOffset = j, nfLimit = k}) q

-- | 換掉 'nfTypes'。
withTypes :: [TypeKey] -> SearchQuery -> SearchQuery
withTypes ts q = withFilter (\nf -> nf {nfTypes = ts}) q

-- | 換掉 'nfTags'。
withTags :: [Text] -> SearchQuery -> SearchQuery
withTags tags q = withFilter (\nf -> nf {nfTags = tags}) q

-- | 只改 'sqFilter' 的存取子輔助(本模組私有)。
withFilter :: (NodeFilter -> NodeFilter) -> SearchQuery -> SearchQuery
withFilter f q = q {sqFilter = f (sqFilter q)}

--------------------------------------------------------------------------------
-- 寫入請求與結果(P-003-node-write)

-- | 十一種寫入請求收成一個 sum type(P-003 的決定):三個殼對同一個型別編解碼,
-- 每種要動既有節點的都帶 expected 'Revision'。
data WriteOp
  = CreateTopic NewEntity
  | CreateLevel NewLevel
  | CreatePack NewPack [NewSection]
  | AddSection Id SectionPlacement NewSection
  | DeleteNode Id Revision DeleteMode
  | WriteMeta Id Revision MetaOverride
  | WriteAssetFields Id Revision AssetPatch
  | WriteBody Id Revision Text
  | AddLink Id Revision Link
  | RemoveLink Id Revision Link
  | UpsertLicense License
  deriving stock (Show, Eq)

-- | 一次成功寫入的結果:建檔、改寫、刪除三種形狀。
data WriteOutcome
  = Created CreateResult
  | Written WriteResult
  | Deleted DeleteResult
  deriving stock (Show, Eq)

-- | 純解譯器跑完一段寫入程式之後的三件事:結果、最終檔案表、最終索引。
data WriteRun a = WriteRun
  { runResult :: a
  , runFiles :: VaultFiles
  , runIndex :: IndexState
  }
  deriving stock (Show, Eq)

-- | @pack.md@ 的七個 pack 專屬欄位(P-003 LAW-20 的往返單位),逐欄對應
-- 'Aapms.Core.Pack.Pack' 的 @pckVendor@ 到 @pckAiDisclosure@。
data PackFields = PackFields
  { pfVendor :: Maybe Text
  , pfArchive :: Maybe FilePath
  , pfSha256 :: Maybe Sha256
  , pfLicense :: Maybe Ref
  , pfAuthor :: Maybe Author
  , pfSourceUrl :: Maybe Text
  , pfAiDisclosure :: AiDisclosure
  }
  deriving stock (Show, Eq)

-- | 請求要動的既有節點(建檔類為 'Nothing')。
opTarget :: WriteOp -> Maybe Id
opTarget = \case
  CreateTopic _ -> Nothing
  CreateLevel _ -> Nothing
  CreatePack _ _ -> Nothing
  AddSection i _ _ -> Just i
  DeleteNode i _ _ -> Just i
  WriteMeta i _ _ -> Just i
  WriteAssetFields i _ _ -> Just i
  WriteBody i _ _ -> Just i
  AddLink i _ _ -> Just i
  RemoveLink i _ _ -> Just i
  UpsertLicense l -> Just (metaId (licMeta l))

-- | 請求帶的 expected revision。
--
-- 逐字照建構子:帶 'Revision' 的請求回它,'UpsertLicense' 回傳入 'License'
-- 自己的 'metaRevision'(P-003 的決定),建檔與增節沒有 expected revision。
opRevision :: WriteOp -> Maybe Revision
opRevision = \case
  CreateTopic _ -> Nothing
  CreateLevel _ -> Nothing
  CreatePack _ _ -> Nothing
  AddSection {} -> Nothing
  DeleteNode _ r _ -> Just r
  WriteMeta _ r _ -> Just r
  WriteAssetFields _ r _ -> Just r
  WriteBody _ r _ -> Just r
  AddLink _ r _ -> Just r
  RemoveLink _ r _ -> Just r
  UpsertLicense l -> Just (metaRevision (licMeta l))

-- | 是不是會插入新節的請求(增節、建檔)。
--
-- 'UpsertLicense' __也算__:同 id 的節不存在時它會在 @licenses.md@ 檔尾追加一節,
-- 而追加會把插入點前一段的行尾補齊('Aapms.Md.Render' 的 @blankTail@)。
-- LAW-3 拿這個判定排除「會挪動別節位元組」的請求,漏掉它就漏掉一種挪動。
isInsertOp :: WriteOp -> Bool
isInsertOp = \case
  CreateTopic _ -> True
  CreateLevel _ -> True
  CreatePack _ _ -> True
  AddSection {} -> True
  UpsertLicense _ -> True
  _ -> False

-- | 是不是會刪掉節的請求(刪節,含 DeleteForce 連子樹一起刪)。
isDeleteOp :: WriteOp -> Bool
isDeleteOp = \case
  DeleteNode {} -> True
  _ -> False

-- | 這個請求要配幾個新 id。
--
-- 建檔類要一個(新檔的檔案層主體);'CreateLevel' 要__兩個__ ——Level 檔沒有根
-- Node 就解析不出 @root@,而根 Node 也是一個節點,它的 id 一樣要經過碰撞查詢
-- (ADR-014:唯一性由建構保證,不靠雜湊碰運氣)。改既有檔的請求不配號。
idsNeeded :: WriteOp -> Int
idsNeeded = \case
  CreateTopic _ -> 1
  CreateLevel _ -> 2
  CreatePack _ _ -> 1
  _ -> 0

-- | 結果的新 revision。
--
-- 'Deleted' 沒有新 revision('DeleteResult' 沒有這個欄位——被刪的節點不再有
-- 版本),回 @'Revision' 0@ 當中性值。
outcomeRevision :: WriteOutcome -> Revision
outcomeRevision = \case
  Created cr -> crRevision cr
  Written wr -> wrRevision wr
  Deleted _ -> Revision 0

-- | 結果落地的檔。
outcomePath :: WriteOutcome -> FilePath
outcomePath = \case
  Created cr -> crPath cr
  Written wr -> wrPath wr
  Deleted dr -> drPath dr

-- | 結果的節點 id(建檔為新檔主體)。
outcomeId :: WriteOutcome -> Id
outcomeId = \case
  Created cr -> crId cr
  Written wr -> wrId wr
  Deleted dr -> fromMaybe neutralId (listToMaybe (drRemovedIds dr))

-- | 'outcomeId' 對「一個 id 都沒刪掉的 'DeleteResult'」的中性值。
--
-- 寫入路徑產生的 'DeleteResult' 恆有至少一個消失的 id,所以這個值不會被觀察到;
-- 它存在只是為了讓觀察點是全函數(不拋例外)。
neutralId :: Id
neutralId = newId PEnt "" (UTCTime (fromGregorian 1970 1 1) 0) 0

-- | 刪除結果消失的 id。
removedIds :: WriteOutcome -> [Id]
removedIds = \case
  Deleted dr -> drRemovedIds dr
  _ -> []

-- | 刪除結果列出的斷點。
brokenLinks :: WriteOutcome -> [(Id, Link)]
brokenLinks = \case
  Deleted dr -> drBrokenLinks dr
  _ -> []

-- | 索引裡節點所在檔。
locatedFile :: IndexState -> Id -> Maybe FilePath
locatedFile (IndexState m) i =
  listToMaybe
    [ fiPath fi
    | fi <- Map.elems m
    , any ((== i) . metaId . anyMeta . inNode) (fiNodes fi)
    ]

-- | pack 七個專屬欄位。
packFields :: Pack -> PackFields
packFields p =
  PackFields
    { pfVendor = pckVendor p
    , pfArchive = pckArchive p
    , pfSha256 = pckSha256 p
    , pfLicense = pckLicense p
    , pfAuthor = pckAuthor p
    , pfSourceUrl = pckSourceUrl p
    , pfAiDisclosure = pckAiDisclosure p
    }

-- | 請求裡的同七欄。
newPackFields :: NewPack -> PackFields
newPackFields np =
  PackFields
    { pfVendor = npVendor np
    , pfArchive = npArchive np
    , pfSha256 = npSha256 np
    , pfLicense = npLicense np
    , pfAuthor = npAuthor np
    , pfSourceUrl = npSourceUrl np
    , pfAiDisclosure = npAiDisclosure np
    }

-- | 三態補丁套在舊值上:@Nothing@ 不動、@Just v@ 設成 @v@。
patchedName :: AssetPatch -> Maybe LogicalName -> Maybe LogicalName
patchedName patch old = fromMaybe old (apName patch)

-- | 索引記錄的每檔指紋,路徑遞增。
fileStatsOf :: IndexState -> [(FilePath, FileStat)]
fileStatsOf (IndexState m) = [(fiPath fi, fiStat fi) | fi <- Map.elems m]

-- | 去掉 revision 與 updated 兩行。
--
-- frontmatter 與節的 @```meta@ 區塊都適用:判準是「這一行去掉前導空白之後以
-- @revision:@ 或 @updated:@ 起頭」。行尾一律正規化成 @\\n@ ——比較兩份文字時
-- 兩邊都經過同一次正規化。
stripStamps :: Text -> Text
stripStamps = T.unlines . filter (not . isStamp) . T.lines
  where
    isStamp l =
      let s = T.stripStart l
       in "revision:" `T.isPrefixOf` s || "updated:" `T.isPrefixOf` s
