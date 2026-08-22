-- | @storyflow-service@ 的門面:__所有業務操作的唯一定義處__(ADR-006)。
--
-- CLI(service-and-interfaces/F002)、servant server(service-and-interfaces/F003)、未來的 MCP adapter 全部是這一層
-- 的薄包裝。這一層存在的價值不是「多一層」,而是__讓三種介面的行為由型別強制
-- 一致__——邏輯只有一份,不可能悄悄長歪。
--
-- 與 @store@ 的分工,用一句話講完:@store@ 做的是__落地操作__,這裡做的是
-- __業務操作__。差距具體是四件事:
--
-- * 型別註冊表的驗證有人呼叫了('StoryFlow.Core.Registry.checkEntity' 在
--   @store@ 那一層是沒人用的純函式)
-- * @Connection@ \/ @Vault@ \/ 註冊表收進 'Env',呼叫端不必自己張羅
-- * 錯誤講的是業務語彙('ServiceError'),不是檔案與索引的語彙
-- * 「建一個 Entity 並同時檢查它的關聯目標存在」這種組合操作有了歸屬
--
-- 典型用法:
--
-- @
-- Right (env, issues) <- 'openEnv' Nothing =<< getCurrentDirectory
-- Right view <- 'runService' env ('getEntity' i)
-- 'closeEnv' env
-- @
--
-- 明確__不做__的:conflict(P4)、workshop(P5)、LLM、跨 Vault 的讀寫。
module StoryFlow.Service
  ( -- * 重新匯出
    module StoryFlow.Service.Error
  , module StoryFlow.Service.Monad
  , module StoryFlow.Service.Types

    -- ** 沿用 @store@ 的定義(不重造)
  , EntityFilter (..)
  , emptyFilter
  , IndexIssue (..)
  , issueHasError
  , renderIndexIssue
  , VaultConfig (..)
  , LlmSection (..)

    -- * Vault
  , createVault
  , listVaults
  , vaultInfo
  , vaultConfig
  , vaultRoot
  , reindex
  , refreshIndex

    -- * 型別註冊表
  , listEntityTypes

    -- * Entity
  , createEntity
  , addFragment
  , getEntity
  , listEntities
  , searchEntity
  , aliasIndex
  , updateEntity
  , setEntityBody
  , deleteEntity

    -- * Link
  , addLink
  , removeLink
  , linksOf
  , linkGraph

    -- * Level / Node
  , createLevel
  , getLevel
  , listLevels
  , deleteLevel
  , addNode
  , removeNode
  ) where

import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, getCurrentTime, utctDay)
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Graph (LinkGraph)
import StoryFlow.Core.Id (Id, Ref (..), localRef)
import StoryFlow.Core.Link (Link (..), LinkKind)
import StoryFlow.Core.Meta (Meta (..))
import StoryFlow.Core.Registry
  ( EntityTypeSpec
  , EntityWarning (MissingRequiredField)
  , checkEntity
  , listTypes
  , lookupDir
  , lookupType
  )
import StoryFlow.Core.Tree (buildTree)
import StoryFlow.Md (applyOverride, overrideOf, renderMdWarning)
import StoryFlow.Service.Error
import StoryFlow.Service.Json ()
import StoryFlow.Service.Monad
import StoryFlow.Service.Types
import StoryFlow.Store hiding
  ( addFragment
  , addNode
  , deleteEntity
  , deleteLevel
  , listEntities
  , listLevels
  , removeNode
  , vaultRoot
  )
import qualified StoryFlow.Store as S
import StoryFlow.Store.Edit (Located (..), locate, locateNode)

-- Vault ------------------------------------------------------------------------

-- | 建立 Vault 骨架,並登記進全域註冊表。
--
-- __登記是這裡做而不是 @store@ 的 'initVault' 做__:ADR-008 的
-- 「@--vault \<名稱\>@ 查全域註冊表」如果沒有人負責寫進那份註冊表,規則就永遠
-- 命不中。而登記涉及「哪一份註冊表」這個由環境決定的問題,那是業務層的事。
createVault :: FilePath -> Text -> IO (Either ServiceError VaultView)
createVault root name = do
  regFile <- vaultsFile
  initVault root name >>= \case
    Left e -> pure (Left (StoreFailed e))
    Right v ->
      registerVaultIn regFile (vaultName v) (S.vaultRoot v) >>= \case
        Left e -> pure (Left (StoreFailed e))
        Right () -> pure (Right (VaultView (vaultName v) (S.vaultRoot v) (Just 0)))

-- | 全域註冊表裡的全部 Vault。
--
-- __不逐一開索引數 Entity__:開索引會觸發該 Vault 的過時掃描,列個清單不該
-- 付這個代價。因此 'vvEntityCount' 是 'Nothing'。
listVaults :: IO (Either ServiceError [VaultView])
listVaults = do
  regFile <- vaultsFile
  loadVaultRegistryFrom regFile >>= \case
    Left e -> pure (Left (StoreFailed e))
    Right reg -> pure (Right [VaultView n p Nothing | (n, p) <- M.toList reg])

vaultInfo :: ServiceM VaultView
vaultInfo = do
  Env v conn _ <- ask
  metas <- liftIO (S.listEntities conn emptyFilter)
  pure (VaultView (vaultName v) (S.vaultRoot v) (Just (length metas)))

-- | 這個 Vault 的 @.storyflow\/config.toml@ 內容。
--
-- __只開內嵌出口__:不進 @StoryFlowAPI@、不進 CLI 的指令樹。理由與 'linkGraph' /
-- 'aliasIndex' 同一條——Vault 設定不是作者用指令查的東西,是__子系統之間的讀取__;
-- 作者要看設定就直接打開那個檔案,而序列化整份設定送給外部客戶端只會多一個
-- 得跟著維護的 DTO。
--
-- 存在的理由是硬性的:@[llm]@ 那張表('cfgLlm')住在 @storyflow-store@,而
-- @storyflow-llm@ 的 @build-depends@ 逐字擋著 @storyflow-store@ ——與
-- @storyflow-conflict@ 完全相同的界線。那個套件拿得到 Vault 設定的唯一合法途徑
-- 就是經 'ServiceM'。
--
-- __不解讀 @[llm]@__:這裡原樣交出 'LlmSection' 捧著的 TOML 表。設定的形狀
-- (@base_url@ / @model@ / …)由 @storyflow-llm@ 定義並解析,service 這一層
-- 認得的只有「有沒有那張表」。
vaultConfig :: ServiceM VaultConfig
vaultConfig = asks (vaultCfg . envVault)

-- | 這個 Vault 的根目錄(含 @.storyflow\/@ 的那一層)。
--
-- __只開內嵌出口__:與 'vaultConfig' 同一條理由。存在的理由是硬性的:
-- @storyflow-workshop@ 的 session 快照要寫 @\<root\>\/.storyflow\/workshops\/@,
-- 而它與 @storyflow-llm@ 同樣不准依賴 @storyflow-store@,拿不到 'S.vaultRoot'。
--
-- __不沿用 'vaultInfo'__:它為了 'vvEntityCount' 會 'S.listEntities' 全表掃描,
-- 而快照每一 step 就要寫一次,不值得每次都付一次全表掃描的代價。
vaultRoot :: ServiceM FilePath
vaultRoot = asks (S.vaultRoot . envVault)

-- | 全量重建索引。ADR-002 的「刪掉 index.db 也回得來」就是這一條。
reindex :: ServiceM IndexReport
reindex = do
  Env v conn _ <- ask
  liftStore (rebuildIndex conn v) >>= indexReport v

-- | 只補過時的檔案。作者用編輯器改完檔案後的日常路徑。
refreshIndex :: ServiceM IndexReport
refreshIndex = do
  Env v conn _ <- ask
  liftStore (refreshStale conn v) >>= indexReport v

indexReport :: Vault -> [IndexIssue] -> ServiceM IndexReport
indexReport v issues = do
  files <- liftIO (vaultMarkdownFiles v)
  pure (IndexReport (length files) (map renderIndexIssue issues))

-- 型別註冊表 --------------------------------------------------------------------

-- | 註冊表裡的全部型別,依 key 排序(排序由 'listTypes' 保證,輸出因此穩定)。
listEntityTypes :: ServiceM [EntityTypeSpec]
listEntityTypes = asks (listTypes . envTypes)

-- Entity 讀取 ------------------------------------------------------------------

getEntity :: Id -> ServiceM EntityView
getEntity i = do
  conn <- asks envConn
  liftIO (lookupEntity conn i) >>= \case
    Nothing -> throwError (StoreFailed (EntityNotFound i))
    Just e -> entityView i e []

listEntities :: EntityFilter -> ServiceM [Meta]
listEntities f = do
  conn <- asks envConn
  liftIO (S.listEntities conn f)

-- | FTS5 檢索。中文的兩字詞由 @store@ 那一層改走 @LIKE@,這裡不重複那個判斷。
--
-- 相關度原樣攤進 'SearchHit' __不做任何加工__:分數的語意由 @store@ 定義
-- ('StoryFlow.Store.Query.normalizeBm25'),這一層再壓一次只會讓兩處各有一份
-- 規則。
searchEntity :: Text -> EntityFilter -> ServiceM [SearchHit]
searchEntity q f = do
  conn <- asks envConn
  hits <- liftIO (searchEntities conn q f)
  pure [SearchHit m s sc | (m, s, sc) <- hits]

-- | 片段 id → 它的 @metaTitle@ 與 @metaAliases@。
--
-- 給衝突偵測第 2 層(conflict-detection/F003)做「既有名稱有沒有出現在草稿裡」的
-- 反向比對用。呼叫端傳 @'emptyFilter' { efStatus = Just Canon }@ 取比對基準。
--
-- __標題排第一__:它是最常被寫進草稿的名稱,而呼叫端的關鍵詞順序直接決定
-- 檢索順序。
--
-- __空字串名稱一律濾掉__:@metaAliases@ 允許使用者寫空項,而
-- @Data.Text.isInfixOf ""@ 對任何草稿都成立——留著會讓每個片段都變成關鍵詞命中。
--
-- 建在 'listEntities' 之上,__不新增 @store@ 查詢__:@ORDER BY e.id@ 已經保證
-- 輸出順序確定,而「只傳字串比較省」的論據只對 REST 成立——這個出口
-- __只開內嵌__:不接 CLI、不接 REST。
aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]
aliasIndex f = do
  metas <- listEntities f
  pure [(metaId m, names m) | m <- metas]
  where
    names m = nub (filter (not . T.null . T.strip) (metaTitle m : metaAliases m))

-- | 組出 'EntityView':路徑與錨點是__索引才知道__的事,型別警告是
-- 註冊表才知道的事,兩者都不在 'Entity' 裡。
entityView :: Id -> Entity -> [Text] -> ServiceM EntityView
entityView i e extra = do
  conn <- asks envConn
  Located p a <- liftStore (locate conn i)
  reg <- asks envTypes
  pure (EntityView e p a (extra ++ map renderEntityWarning (checkEntity reg e)))

-- Entity 寫入 ------------------------------------------------------------------

-- | 建一份新的主題檔。
--
-- 驗證發生在__寫檔之前__:用請求資料組一個佔位 id 的 'Entity' 跑
-- 'checkEntity',過了才呼叫 @store@。這樣 'ValidationFailed' 時一個位元組都
-- 沒寫,與樂觀鎖的 @StaleRevision@ 語意一致。
createEntity :: NewEntityReq -> ServiceM EntityView
createEntity req@NewEntityReq {..} = do
  Env v conn reg <- ask
  requireKnownType nerType
  today <- liftIO currentDay
  validateForWrite Nothing (Entity (newMeta v today) nerBody)
  r <- liftStore (createEntityFile conn v reg (toNewEntity req))
  createdEntity r
  where
    newMeta v today =
      Meta
        { metaId = placeholderId
        , metaVault = vaultName v
        , metaType = nerType
        , metaTitle = nerTitle
        , metaSummary = nerSummary
        , metaTags = nerTags
        , metaStatus = nerStatus
        , metaTimeline = nerTimeline
        , metaAliases = nerAliases
        , metaLinks = nerLinks
        , metaSource = nerSource
        , metaRevision = 1
        , metaCreated = today
        , metaUpdated = today
        }

-- | 往既有主題檔加一個片段。
--
-- __樂觀鎖的 revision 由這一層自己讀__:'addFragment' 在操作清單裡沒有
-- @expected@ 參數,因為加一個片段不會覆蓋任何既有內容。並發保護仍然在——
-- @store@ 會重讀檔案比對 revision,兩個同時進來的請求第二個會拿到
-- @StaleRevision@ 而不是靜默覆蓋。
addFragment :: Id -> NewFragmentReq -> ServiceM EntityView
addFragment i req = do
  Env v conn _ <- ask
  main <- getEntity i
  today <- liftIO currentDay
  let mainMeta = entMeta (evEntity main)
  validateForWrite Nothing (Entity (fragmentMeta mainMeta today req) (nfrBody req))
  r <- liftStore (S.addFragment conn v i (metaRevision mainMeta) (toNewFragment req))
  createdEntity r

-- | 修改 Meta(必要時連標題一起)。
--
-- @expected@ 是必填而不是 @Maybe Int@:ADR-006 明列「樂觀鎖在兩種模式下都
-- 必須生效」,給一個「不帶就跳過檢查」的逃生口,CLI 一定會用它,然後遠端模式
-- 的並發保護就只剩一半。呼叫端的作法是__先讀再寫__,不是繞過。
updateEntity :: Id -> Int -> EntityPatch -> ServiceM EntityView
updateEntity i expected p = do
  Env v conn _ <- ask
  cur <- getEntity i
  let e = evEntity cur
      merged = retitle (applyOverride (patchOverride p (overrideOf (entMeta e))) (entMeta e))
  validateForWrite (Just i) e {entMeta = merged}
  _ <- liftStore (writeEntityPatch conn v i expected (epTitle p) (patchOverride p))
  getEntity i
  where
    retitle m = maybe m (\t -> m {metaTitle = t}) (epTitle p)

-- | 換掉正文。正文才是片段真正的內容,所以它一樣走樂觀鎖、一樣遞增 revision。
setEntityBody :: Id -> Int -> Text -> ServiceM EntityView
setEntityBody i expected body = do
  Env v conn _ <- ask
  _ <- liftStore (writeEntityBody conn v i expected body)
  getEntity i

-- | 刪除。@force@ 為 'False' 時被指向就擋下來(@store@ 的 'DeleteSafe')。
deleteEntity :: Id -> Int -> Bool -> ServiceM DeleteReport
deleteEntity i expected force = do
  Env v conn _ <- ask
  deleteReport <$> liftStore (S.deleteEntity conn v i expected (deleteMode force))

-- | 建立成功後__重讀一次__再組 View。
--
-- 不拿請求資料回填:繼承規則、id 配置、檔案路徑推導都發生在 @store@ 裡,
-- 用請求資料組出來的 View 會與檔案裡真正的內容有落差。
createdEntity :: CreateResult -> ServiceM EntityView
createdEntity (CreateResult i _ ws) = do
  conn <- asks envConn
  liftIO (lookupEntity conn i) >>= \case
    Nothing -> throwError (StoreFailed (EntityNotFound i))
    Just e -> entityView i e (map renderMdWarning ws)

-- 驗證 -------------------------------------------------------------------------

-- | 型別警告__依種類分流__(service-and-interfaces/F001 的驗證策略表):
--
-- * @MissingRequiredField@ → 拒絕寫入。@required = true@ 是作者自己在 TOML 裡
--   設的,擋下來是執行作者的意思,不是工具越權
-- * @LinkNotAllowed@ → 警告照寫。ADR-005 明說自訂關聯合法
-- * @UnknownEntityType@ → 警告照寫。擋下來等於逼作者先寫 TOML 才能記一句設定
validateForWrite :: Maybe Id -> Entity -> ServiceM ()
validateForWrite mi e = do
  reg <- asks envTypes
  let missing = [w | w@(MissingRequiredField _ _) <- checkEntity reg e]
  unless (null missing) (throwError (ValidationFailed mi missing))

-- | 型別必須是註冊表認得的。
--
-- 判斷用 'lookupDir' 而不是只用 'lookupType':檔案層主體的型別(@character@)
-- 本來就不在註冊表的 key 裡,是由片段宣告的 @owner_type@ 認領的。宣告得到目錄
-- 就代表註冊表認得它。
--
-- 「型別在註冊表裡、但沒宣告 @dir@」不在這裡擋——那是另一種錯,@store@ 的
-- 'RegistryDirUnknown' 訊息講得比 'UnknownType' 準確。
requireKnownType :: Text -> ServiceM ()
requireKnownType t = do
  reg <- asks envTypes
  case (lookupType t reg, lookupDir t reg) of
    (Nothing, Nothing) -> throwError (UnknownType t)
    _ -> pure ()

-- Link -------------------------------------------------------------------------

-- | 加一筆關聯。
--
-- 呼叫 @store@ 之前先確認目標__確實存在__ ——這是 service 才做得到的驗證:
-- @store@ 的單檔操作看不到別的檔案。指不到目標的關聯不會被引擎推論到,
-- 卻會在衝突偵測時安靜地少一條路徑。
addLink :: Id -> Int -> Link -> ServiceM EntityView
addLink i expected l = do
  Env v conn _ <- ask
  requireLocalRef (linkTarget l)
  requireTargetExists (linkTarget l)
  _ <- liftStore (addEntityLink conn v i expected l)
  getEntity i

removeLink :: Id -> Int -> LinkKind -> Ref -> ServiceM EntityView
removeLink i expected k target = do
  Env v conn _ <- ask
  requireLocalRef target
  _ <- liftStore (removeEntityLink conn v i expected k target)
  getEntity i

-- | 正向 + 反向一次給。反向查詢只有索引做得到:關聯只存在來源端(ADR-002)。
linksOf :: Id -> ServiceM LinkReport
linksOf i = do
  conn <- asks envConn
  out <- liftIO (linksFrom conn i)
  inc <- liftIO (linksTo conn (localRef i))
  pure (LinkReport out inc)

-- | 整張關聯圖。衝突偵測第 1 層(conflict-detection/F002 的 @graphHits@)吃的就是它。
--
-- __只開內嵌出口__:不進 @StoryFlowAPI@、不進 CLI 的指令樹。理由與 'aliasIndex'
-- 同一條——整張圖序列化送出去,對任何一個外部客戶端都不是它要的東西;需要它的
-- REST 路徑(@POST \/conflict\/context@)是在伺服器端自己呼叫這個函式。
--
-- 存在的理由是硬性的:@loadLinkGraph@ 住在 @storyflow-store@,而
-- @storyflow-conflict@ 的 @build-depends@ 逐字擋著 @storyflow-store@。
-- 那個套件拿得到整張圖的唯一合法途徑就是經 'ServiceM'。
--
-- __不過濾、不投影__:第 1 層的反向索引要看的是「有沒有__任何__關聯」
-- (conflict-detection/F002 的 @revIndex@ 刻意不依 'StoryFlow.Core.Link.LinkKind'
-- 過濾),這裡先砍一刀會讓那個判斷失準。
--
-- __不變量:指向本 Vault 的目標一律 @refVault = 'Nothing'@__。這不是本函式做的
-- 正規化,而是__索引寫入端__已經保證的事,呼叫端可以直接依賴:
--
-- * "StoryFlow.Store.Index" 的 @insertLinks@ 在寫進 @links@ 表之前套用
--   @localize@,把 @refVault == Just (vaultName v)@ 的目標改成 'Nothing';
--   @links@ 表的三個寫入點(Entity \/ Level \/ Node)全部經過它,沒有第四條路徑
-- * @StoryFlow.Store.Row@ 的 @linkFields@ 把它寫成表的不變量
-- * @StoryFlow.Store.Query@ 的 @linksTo@ __已經依賴__它(查本地 id 用的是
--   @WHERE dst = ? AND dst_vault IS NULL@),而 @loadLinkGraph@ 讀的是同一張表
--
-- 因此消費端__不該再掃一遍圖做第二次正規化__:同一條規則有兩份時,其中一份會先
-- 過期。這條不變量由 @StoryFlow.Service.LinkGraphSpec@ 釘住。
linkGraph :: ServiceM LinkGraph
linkGraph = asks envConn >>= liftIO . loadLinkGraph

-- | 跨 Vault 的定址只存不解析(service-and-interfaces/F001 第四節)。
--
-- 關聯寫得進檔案、也查得出來(@links@ 表有 @dst_vault@ 欄位),但這一層的讀寫
-- 一律只碰本 Vault:跨 Vault 讀取要開第二個索引連線,連帶帶出連線快取、
-- 生命週期、目標索引過時要不要一起補等一整批問題,而 P2 完全不需要它。
requireLocalRef :: Ref -> ServiceM ()
requireLocalRef r = do
  v <- asks envVault
  case refVault r of
    Just n | n /= vaultName v -> throwError (CrossVaultUnsupported r)
    _ -> pure ()

-- | Entity / Level / Node 三種都算數:@convergesTo@ 指向的是 Node,
-- 只查 @entities@ 表會把合法的合流標註判成懸空。
requireTargetExists :: Ref -> ServiceM ()
requireTargetExists r = do
  conn <- asks envConn
  liftIO (lookupEntity conn (refId r)) >>= \case
    Just _ -> pure ()
    Nothing ->
      liftIO (locateNode conn (refId r)) >>= \case
        Right _ -> pure ()
        Left _ -> throwError (DanglingLinkTarget r)

-- Level / Node -----------------------------------------------------------------

-- | 建一份新的 Level 檔,連同它的根 Node(空殼 Level 解析不出 @root@)。
createLevel :: NewLevelReq -> ServiceM LevelView
createLevel req = do
  Env v conn _ <- ask
  r <- liftStore (createLevelFile conn v (toNewLevel req))
  getLevel (crId r)

-- | 讀出 Level 與它的樹。
--
-- 樹壞掉時回 'LevelTreeInvalid' 而不是崩潰:@store@ 的寫入路徑在寫檔前就驗過
-- 樹,但作者隨時可以直接編輯 Level 檔把標題層級改壞——那是合法的使用方式
-- (檔案才是真相),工具要講得出哪裡壞了。
getLevel :: Id -> ServiceM LevelView
getLevel i = do
  conn <- asks envConn
  liftIO (lookupLevel conn i) >>= \case
    Nothing -> throwError (StoreFailed (EntityNotFound i))
    Just (lvl, nodes) -> case buildTree lvl nodes of
      Left es -> throwError (LevelTreeInvalid i es)
      Right t -> do
        Located p _ <- liftStore (locateNode conn i)
        pure (LevelView lvl t p)

listLevels :: EntityFilter -> ServiceM [Meta]
listLevels f = do
  conn <- asks envConn
  liftIO (S.listLevels conn f)

deleteLevel :: Id -> Int -> Bool -> ServiceM DeleteReport
deleteLevel i expected force = do
  Env v conn _ <- ask
  deleteReport <$> liftStore (S.deleteLevel conn v i expected (deleteMode force))

-- | 在父 Node 底下新增一個子節點。
--
-- 三個 Id\/Int 參數的分工:__第一個是 Level__、第二個是父 Node、@expected@ 是
-- __Level 主體__的 revision(樂觀鎖鎖的是整份檔案,因為標題階層一動就會影響到
-- 別的節點)。
--
-- Level 是獨立參數而不是從父 Node 反推:索引沒有「由 Node 反查 Level」的查詢,
-- 而回傳的 'LevelView' 需要它。呼叫端本來就拿得到——@expected@ 就是它的
-- revision。
addNode :: Id -> Id -> Int -> NewNodeReq -> ServiceM LevelView
addNode lvlId parent expected req = do
  Env v conn _ <- ask
  _ <- liftStore (S.addNode conn v parent expected (toNewNode req))
  getLevel lvlId

-- | 刪掉一個 Node __與它整棵子樹__。參數分工同 'addNode'。
removeNode :: Id -> Id -> Int -> Bool -> ServiceM LevelView
removeNode lvlId i expected force = do
  Env v conn _ <- ask
  _ <- liftStore (S.removeNode conn v i expected (deleteMode force))
  getLevel lvlId

-- 請求型別的轉換 ----------------------------------------------------------------

toNewEntity :: NewEntityReq -> NewEntity
toNewEntity NewEntityReq {..} =
  NewEntity
    { neType = nerType
    , neTitle = nerTitle
    , neSummary = nerSummary
    , neBody = nerBody
    , neTags = nerTags
    , neAliases = nerAliases
    , neStatus = nerStatus
    , neTimeline = nerTimeline
    , neLinks = nerLinks
    , neSource = nerSource
    , -- 路徑一律讓註冊表推導:業務層不提供「寫到任意路徑」的能力,
      -- 否則宣告式目錄(垂直切片 1)就有一個繞過的後門
      nePath = Nothing
    }

toNewFragment :: NewFragmentReq -> NewFragment
toNewFragment NewFragmentReq {..} =
  NewFragment
    { nfTitle = nfrTitle
    , nfSummary = nfrSummary
    , nfBody = nfrBody
    , nfType = nfrType
    , nfTags = nfrTags
    , nfAliases = nfrAliases
    , nfStatus = nfrStatus
    , nfTimeline = nfrTimeline
    , nfLinks = nfrLinks
    , nfSource = nfrSource
    }

toNewLevel :: NewLevelReq -> NewLevel
toNewLevel NewLevelReq {..} =
  NewLevel
    { nlTitle = nlrTitle
    , nlSummary = nlrSummary
    , nlBody = nlrBody
    , nlRootTitle = nlrRootTitle
    , nlRootKind = nlrRootKind
    , nlStatus = nlrStatus
    }

toNewNode :: NewNodeReq -> NewNode
toNewNode NewNodeReq {..} =
  NewNode
    { nnTitle = nnrTitle
    , nnKind = nnrKind
    , nnSummary = nnrSummary
    , nnBody = nnrBody
    , nnLinks = nnrLinks
    }

-- | 驗證用的片段 'Meta':逐欄比照 md 的繼承規則
-- ('StoryFlow.Md.Inherit.inheritMeta')——@tags@ 聯集、@summary@ 不繼承、
-- @revision@ 不繼承。這裡只是先把它算出來給 'checkEntity' 看,真正寫進檔案的
-- 那一份仍然由 md 產生。
fragmentMeta :: Meta -> Day -> NewFragmentReq -> Meta
fragmentMeta main today NewFragmentReq {..} =
  Meta
    { metaId = placeholderId
    , metaVault = metaVault main
    , metaType = fromMaybe (metaType main) nfrType
    , metaTitle = nfrTitle
    , metaSummary = nfrSummary
    , metaTags = nub (metaTags main ++ nfrTags)
    , metaStatus = fromMaybe (metaStatus main) nfrStatus
    , metaTimeline = fromMaybe (metaTimeline main) nfrTimeline
    , metaAliases = nfrAliases
    , metaLinks = nfrLinks
    , metaSource = fromMaybe (metaSource main) nfrSource
    , metaRevision = 1
    , metaCreated = today
    , metaUpdated = today
    }

deleteReport :: DeleteResult -> DeleteReport
deleteReport DeleteResult {..} = DeleteReport drPath drRemovedIds drBrokenLinks

-- | 介面層一律用 @Bool@ 表達「要不要強制」;@DeleteMode@ 是落地層的詞彙。
deleteMode :: Bool -> DeleteMode
deleteMode force = if force then DeleteForce else DeleteSafe

currentDay :: IO Day
currentDay = utctDay <$> getCurrentTime
