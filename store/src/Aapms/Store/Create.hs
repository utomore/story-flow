-- | 建檔、增節、刪除,以及寫入路徑的全部輸入 DTO(graph-core\/F008)。
--
-- 「改寫既有節點」在 "Aapms.Store.Write",「Level 樹的純推導」在
-- "Aapms.Store.Node";共用的紀律在 "Aapms.Store.Edit"。
--
-- == 檔案放哪裡
--
-- 目錄是__宣告式__的:'Aapms.Core.Registry.lookupDir' 查型別註冊表,查不到就回
-- 'Aapms.Store.Edit.RegistryDirUnknown' 而不是默默丟進 vault 根目錄。否則
-- 「新增一種型別不必改程式」這條垂直切片會在「檔案該放哪」這一步破掉。Level 檔的
-- 目錄硬編為 @levels\/@ ——@level@ 是保留鍵,不可能出現在註冊表裡。pack.md 的目錄
-- 由呼叫端給('npDir'):一個 pack 的目錄同時是它散檔的根,只有 @asset-ingest@
-- 知道那是哪裡。
--
-- 檔名__保留中文原字元__:vault 是給人看的 git repo,@characters\/琳達.md@ 比雜湊
-- 好一百倍。只替換檔案系統不接受的字元。
--
-- == 刪除策略
--
-- __不自動清掉指向被刪目標的關聯__:那要改其他檔案,而多檔寫入沒有交易保證 ——
-- 改到一半失敗會留下不一致,比留幾筆孤兒關聯糟得多。孤兒關聯是可查詢、可修復的
-- 狀態;半套的刪除不是。'DeleteSafe' 因此先擋下來讓作者自己決定。
module Aapms.Store.Create
  ( -- * 輸入:整份新檔
    NewEntity (..)
  , NewLevel (..)
  , NewPack (..)

    -- * 輸入:一個新的節
  , NewSection (..)
  , NewSectionPayload (..)
  , NewAsset (..)
  , NewLicense (..)
  , NewNode (..)

    -- * 結果
  , CreateResult (..)
  , DeleteMode (..)
  , DeleteResult (..)

    -- * 建立
  , createTopicFile
  , createLevelFile
  , createPackFile
  , addSection

    -- * 刪除
  , deleteNode

    -- * 檔名
  , sanitizeFileName
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Aapms.Core.Asset (LogicalName, Sha256)
import Aapms.Core.Id (Id, Ref)
import Aapms.Core.Level (NodeKind)
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Revision, Source, Status, Timeline, TypeKey)
import Aapms.Core.Pack (AiDisclosure, Author)
import Aapms.Core.Registry (TypeRegistry)
import Aapms.Md.Inherit (MetaOverride)
import Aapms.Store.Edit (StoreWriteError)
import Aapms.Store.Marker (VaultHandle)
import Aapms.Store.Schema (IndexIssue)

-- 輸入:整份新檔 -----------------------------------------------------------------

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
  -- 明確給了卻已經有檔案時回 'Aapms.Store.Edit.FileAlreadyExists' ——那是指定,
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

-- 輸入:一個新的節 ---------------------------------------------------------------

-- | 一個新的節,四種文件共用(契約 D,2026-08-24 的 G1 裁決)。
--
-- @nsId@ 由呼叫端先以 'Aapms.Store.Write.allocateId' 配好再傳進來 —— md 那一層
-- 不知道怎麼配 id,而配號需要索引在場(ADR-014)。
data NewSection = NewSection
  { nsId :: Id
  , nsLevel :: Int
  -- ^ 標題層級(@##@ = 2)。主題檔的片段恆為 2;Level 檔的節由
  -- 'Aapms.Store.Node.headingDepthFor' 由父節點推導
  , nsTitle :: Text
  , nsBody :: Text
  , nsPayload :: NewSectionPayload
  }
  deriving stock (Show, Eq)

-- | 節的專屬欄位,__對節點種類做 sum__(G1 定案)。
--
-- 'MetaOverride' 只涵蓋 'Aapms.Core.Meta.Meta' 的欄位,沒有 asset 的
-- @sha256@ \/ @entry@ \/ @ext@ \/ @meta@ \/ @license@ \/ @author@,也沒有
-- license 的八個授權維度 —— 少了這條管道就寫不出能通過
-- 'Aapms.Md.Parse.toPack' \/ 'Aapms.Md.Parse.toLicenses' 驗證的完整新節。
--
-- __不採__「把 asset \/ license 欄位塞進 'MetaOverride'」:那個型別是 md 與
-- store 共用的節層繼承 DTO,污染它會動到 ADR-010 位元組保留所依賴的繼承規則。
-- 做成封閉 sum 的好處與契約 A 的 'Aapms.Core.AnyNode.AnyNode' 相同:新增節點
-- 種類時編譯器會列出所有待處理處,而 'addSection' 維持單一入口。
data NewSectionPayload
  = -- | 主題檔的片段
    NSFragment MetaOverride
  | -- | @pack.md@ 的一筆 asset
    NSAsset MetaOverride NewAsset
  | -- | @licenses.md@ 的一種授權
    NSLicense MetaOverride NewLicense
  | -- | Level 檔的一個節點
    NSNode MetaOverride NewNode
  deriving stock (Show, Eq)

-- | asset 的專屬欄位(與 'Aapms.Core.Asset.Asset' 逐欄對應,扣掉 'Aapms.Core.Meta.Meta'
-- 與正文)。
--
-- @sha256@ \/ @entry@ 是必填而非 'Maybe':'Aapms.Core.Asset.Asset' 的對應欄位就
-- 不是 'Maybe',寫不出這兩欄的節解析回來一定失敗。它們由 @asset-ingest@ 算好,
-- 本子系統不算雜湊(契約卡「明確不做」)。
data NewAsset = NewAsset
  { naName :: Maybe LogicalName
  , naSha256 :: Sha256
  , naEntry :: Text
  , naExt :: Maybe Text
  , naKindMeta :: Value
  -- ^ kind 專屬 JSON(@image@ 的寬高、@audio@ 的長度……),不開新欄位
  , naLicense :: Maybe Ref
  , naAuthor :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | 授權的八個維度(與 'Aapms.Core.License.License' 對應,扣掉
-- 'Aapms.Core.Meta.Meta' 與 @full_text@)。
--
-- @full_text@ 不在這裡:@licenses.md@ 的節不重複貼授權全文
-- ('Aapms.Md.Parse.toLicenses' 解出來恆為 'Nothing')。
-- @commercial@ 與 @attribution_required@ 是 'Bool' 而非 'Maybe' 'Bool':
-- 它們缺漏是錯誤(design.md 契約卡),其餘六項缺漏為 'Nothing'。
data NewLicense = NewLicense
  { nlcCommercial :: Bool
  , nlcAttributionRequired :: Bool
  , nlcCreditText :: Maybe Text
  , nlcModificationAllowed :: Maybe Bool
  , nlcRedistributionAllowed :: Maybe Bool
  , nlcResaleAllowed :: Maybe Bool
  , nlcNftAllowed :: Maybe Bool
  , nlcSourceUrl :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | Level 檔的一個節點的專屬欄位。
--
-- 只有 @kind@ 一欄:@parent@ 與 @order@ 由標題階層推導(ADR-009),
-- 'Aapms.Core.Level.nodEntities' 由 @involves@ \/ @references@ 兩種關聯推導
-- ('Aapms.Md.Parse.toLevel'),兩者都不該由呼叫端重複指定 —— 指定了就會有兩個
-- 真相來源。
newtype NewNode = NewNode
  { nnKind :: NodeKind
  }
  deriving stock (Show, Eq)

-- 結果 ------------------------------------------------------------------------

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

-- 建立 ------------------------------------------------------------------------

-- | 建一份新的主題檔。
--
-- 落點依註冊表的 @dir@('Aapms.Core.Registry.lookupDir');查不到回
-- 'Aapms.Store.Edit.RegistryDirUnknown'。註冊表由呼叫端傳入而不是取自
-- 'Aapms.Store.Marker.vhRegistry' ——契約 E 的簽名如此,而且建檔是唯一「用哪一份
-- 註冊表決定落點」有可能與索引時不同的場合(@service@ 可能先做過型別遷移)。
--
-- 新檔一律用 'Aapms.Md.Document.LF';Windows 上的 git 由 @core.autocrlf@ 處理,
-- 工具不介入。
createTopicFile
  :: VaultHandle
  -> TypeRegistry
  -> NewEntity
  -> IO (Either StoreWriteError CreateResult)
createTopicFile = undefined

-- | 建一份新的 Level 檔,連同它的根 Node。
--
-- 目錄固定 @levels\/@:@level@ 是保留型別鍵,不可能在註冊表裡宣告 @dir@。根 Node
-- 用 @##@,留一級給 @#@ 當作者想寫的檔案大標。
createLevelFile
  :: VaultHandle
  -> TypeRegistry
  -> NewLevel
  -> IO (Either StoreWriteError CreateResult)
createLevelFile = undefined

-- | 在 'npDir' 寫出一份 @pack.md@,節的順序與給定順序__相同__。
--
-- 第三個參數是 @[NewSection]@ 而不是契約 E 寫的 @[NewAsset]@(F008 待確認假設
-- A1):G1 之後 'NewAsset' 只剩 asset 專屬七欄,組不出節的標題與節層 meta。
-- 每一節的 'nsPayload' 必須是 'NSAsset',否則回
-- 'Aapms.Store.Edit.BadSectionPayload' ——@pack.md@ 的節只能是 asset。
--
-- 與 'addSection' 走同一條序列化路徑,「順序相同」因此是結構上的結果,不是另外
-- 維護的一條規則。
createPackFile
  :: VaultHandle
  -> NewPack
  -> [NewSection]
  -> IO (Either StoreWriteError CreateResult)
createPackFile = undefined

-- | 往既有檔案的__檔尾__追加一個節:片段 \/ asset \/ license \/ node,依
-- 'nsPayload' 分派。
--
-- 第二個參數是__檔案層主體__的 id(用來定位檔案);傳節的 id 回
-- 'Aapms.Store.Edit.BadSectionPayload'。@licenses.md@ 的檔案層是容器不是節點
-- ('Aapms.Md.Parse.toLicenses' 只回 @[License]@),所以那一種文件以檔案裡任一
-- 既有 license 節的 id 定位。
--
-- payload 與目標檔案的 'Aapms.Md.Document.DocKind' 必須相容
-- (@TopicDoc@↔@NSFragment@、@PackDoc@↔@NSAsset@、@LicenseDoc@↔@NSLicense@、
-- @LevelDoc@↔@NSNode@),不符回 'Aapms.Store.Edit.BadSectionPayload' 且不寫檔。
--
-- 追加__不動前面任何一節的位元組__(ADR-010;'Aapms.Md.Render.appendSection' 的
-- 保證)。@LevelDoc@ 額外在寫檔前跑 'Aapms.Store.Node.validateLevelDoc'。
--
-- 檔案層主體的 revision 走完會 +1:這是樂觀鎖的另一半,不遞增的話兩個並發的
-- 'addSection' 拿同一個 revision 都會通過。
addSection
  :: VaultHandle
  -> Id
  -> NewSection
  -> IO (Either StoreWriteError CreateResult)
addSection = undefined

-- 刪除 ------------------------------------------------------------------------

-- | 刪一個節點。目標是什麼決定刪掉多少:
--
-- * 檔案層主體(主題檔 \/ Level 檔 \/ pack.md 的 @pck-@)→ __整份檔案__,
--   連同檔內全部節
-- * 主題檔的片段 \/ pack.md 的 asset \/ licenses.md 的 license → 該一節
-- * Level 檔的 Node → 該節__與它整棵子樹__('Aapms.Store.Node.subtreeIds');
--   根 Node 回 'Aapms.Store.Edit.CannotDeleteRootNode',請改刪整份 Level 檔
--
-- 第三個參數是被刪目標的 revision:刪除也走樂觀鎖,否則「作者剛改完、Agent 拿
-- 舊資料刪掉」會靜默生效。
--
-- 'DeleteSafe' 對__每一個__要消失的 id 做被引用檢查,任何一個被指向就整份拒絕
-- ('Aapms.Store.Edit.ReferencedBy',且檔案未動);'DeleteForce' 照刪並把被打斷的
-- 關聯放進 'drBrokenLinks'。
deleteNode
  :: VaultHandle
  -> Id
  -> Revision
  -> DeleteMode
  -> IO (Either StoreWriteError DeleteResult)
deleteNode = undefined

-- 檔名 ------------------------------------------------------------------------

-- | 檔名淨化:標題 → 檔名主幹。
--
-- __保留中文原字元__(vault 是給人看的 git repo)。只把檔案系統不接受的
-- @\<\>:\"\/\\|?*@ 與控制字元換成 @-@,去掉頭尾空白與句點(Windows 不接受以句點
-- 結尾的檔名);全部被清掉時退回第二個參數(慣例上是該節點的短 id)。
sanitizeFileName :: Text -> Text -> Text
sanitizeFileName = undefined
