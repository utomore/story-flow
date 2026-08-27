-- | __唯一的 API 契約__。server(service-and-interfaces/F003)、@cli --remote@ 與 OpenAPI 文件
-- 三者都由這一份型別產生。
--
-- 這正是 ADR-006 選 servant 的理由:同一個型別同時產生 server、client 與文件,
-- __三邊無法悄悄長歪__。加一條路由要改的是這個檔案,而 server 少實作一個 handler
-- 或 client 少一個呼叫函式都是編譯錯誤,不是執行期才發現的落差。
--
-- 這個套件__只有型別__:它的 @build-depends@ 沒有 @servant-server@、
-- @servant-client@ 與 @warp@。型別若住在 server 裡,CLI 就得依賴 server,連帶把
-- 整套 HTTP 伺服器拖進一個預設根本不開伺服器的執行檔。
--
-- 兩個約定貫穿整份 API:
--
-- * __@revision@ 是必填的 query parameter__('QueryParam'' ''[Required]'),
--   不是選配。ADR-006 明列樂觀鎖在兩種模式下都要生效,而遠端模式恰恰是多客戶端
--   並發真的會發生的那一種。「先讀再寫」由客戶端自己補,server 不提供逃生口
-- * __@DELETE \/entities\/:id\/links@ 以 query parameter 帶 @kind@ 與 @target@__,
--   不是 request body:DELETE 帶 body 在中介軟體與 client 函式庫之間的支援度不一致,
--   而這兩個值都很短
module Aapms.Api
  ( -- * 契約
    AapmsAPI
  , aapmsAPI

    -- ** 子 API
  , VaultAPI
  , EntityAPI
  , LinkAPI
  , LevelAPI
  , NodeAPI
  , MiscAPI
  , ConflictAPI
  , WorkshopAPI

    -- * 請求 body 的小包裝
  , NewVaultReq (..)
  , BodyReq (..)
  , ContextReq (..)
  , CheckReq (..)
  , WorkshopStartReq (..)
  , WorkshopStepReq (..)
  , WorkshopStepResp (..)
  , WorkshopCommitResp (..)

    -- * OpenAPI
  , aapmsOpenApi
  , deriveOperationId
  ) where

import Control.Lens ((&), (.~), (?~), (%~))
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Char (toUpper)
import Data.OpenApi
  ( NamedSchema (..)
  , OpenApi
  , OpenApiType (OpenApiObject)
  , ToSchema (..)
  , declareSchemaRef
  , delete
  , description
  , get
  , info
  , license
  , operationId
  , patch
  , paths
  , post
  , properties
  , put
  , required
  , title
  , type_
  , version
  )
import Data.OpenApi.Operation (applyTagsFor)
import qualified Data.HashMap.Strict.InsOrd as IOM
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
-- @Servant.API@ 也匯出一個 @Link@(它的 safe-link 型別),與 core 的關聯型別撞名。
-- 隱藏它而不是把 core 的那個 qualified:這份檔案講的 @Link@ 從頭到尾都是關聯,
-- 而 safe link 在這裡一次都沒用到。
import Servant.API hiding (Link)
import Servant.OpenApi (subOperations, toOpenApi)
import Aapms.Api.Instances ()
import Aapms.Conflict.Json ()
import Aapms.Conflict.Types
  ( ConflictOpts
  , ConflictReport
  , ContextHit
  , Draft
  , defaultConflictOpts
  )
import Aapms.Core.Id (Id, Ref)
import Aapms.Core.Link (Link, LinkKind)
import Aapms.Core.Meta (Meta, Status)
import Aapms.Core.Registry (EntityTypeSpec)
import Aapms.Service
  ( DeleteReport
  , EntityPatch
  , EntityView
  , IndexReport
  , LevelView
  , LinkReport
  , NewEntityReq
  , NewFragmentReq
  , NewLevelReq
  , NewNodeReq
  , SearchHit
  , VaultView
  )
import Aapms.Workshop (Session)

-- 請求 body 的小包裝 -------------------------------------------------------------

-- | @POST \/vaults@ 的 body。
--
-- 不重用 service 的型別是因為 service 那一層的 'Aapms.Service.createVault'
-- 吃的是兩個裸參數,沒有對應的請求型別——而 JSON body 需要一個有名字的物件。
data NewVaultReq = NewVaultReq
  { nvRoot :: FilePath
  , nvName :: Text
  }
  deriving stock (Show, Eq)

instance ToJSON NewVaultReq where
  toJSON NewVaultReq {..} = object ["root" .= nvRoot, "name" .= nvName]

instance FromJSON NewVaultReq where
  parseJSON = withObject "NewVaultReq" $ \o -> NewVaultReq <$> o .: "root" <*> o .: "name"

instance ToSchema NewVaultReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    pure . NamedSchema (Just "NewVaultReq") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "建立 Vault 骨架並登記進全域註冊表"
        & properties .~ IOM.fromList [("root", txt), ("name", txt)]
        & required .~ ["root", "name"]

-- | @PUT \/entities\/:id\/body@ 的 body。
--
-- 裸字串當 request body 在 OpenAPI 裡表達得出來,但 Agent 幾乎一定會誤送成
-- @{"body": "…"}@ ——那就直接讓它是對的。
newtype BodyReq = BodyReq {brBody :: Text}
  deriving stock (Show, Eq)

instance ToJSON BodyReq where
  toJSON (BodyReq b) = object ["body" .= b]

instance FromJSON BodyReq where
  parseJSON = withObject "BodyReq" $ \o -> BodyReq <$> o .: "body"

instance ToSchema BodyReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    pure . NamedSchema (Just "BodyReq") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "換掉整段正文"
        & properties .~ IOM.fromList [("body", txt)]
        & required .~ ["body"]

-- | @POST \/conflict\/context@ 的 body。
--
-- @opts@ __缺席時退回 'defaultConflictOpts'__ ——與 @Conflict.Json@ 的
-- @FromJSON ConflictOpts@ 逐欄退預設是同一個待客之道:客戶端只想調 @top_n@ 時,
-- 不必把整個 @opts@ 物件寫齊,連 @opts@ 這個鍵都可以不出現。
data ContextReq = ContextReq
  { crqDraft :: Draft
  , crqOpts :: ConflictOpts
  }
  deriving stock (Show, Eq)

instance ToJSON ContextReq where
  toJSON ContextReq {..} = object ["draft" .= crqDraft, "opts" .= crqOpts]

instance FromJSON ContextReq where
  parseJSON = withObject "ContextReq" $ \o ->
    ContextReq <$> o .: "draft" <*> o .:? "opts" .!= defaultConflictOpts

-- | schema 與 'NewVaultReq' \/ 'BodyReq' 放在同一處(而不是
-- "Aapms.Api.Instances"):那個模組是本模組的__上游__,而 'ContextReq' 定義在
-- 這裡——實例寫過去會造成模組環。其餘五個衝突偵測型別的 'ToSchema' 是孤兒實例,
-- 照約定集中在 "Aapms.Api.Instances"。
instance ToSchema ContextReq where
  declareNamedSchema _ = do
    dS <- declareSchemaRef (Proxy :: Proxy Draft)
    oS <- declareSchemaRef (Proxy :: Proxy ConflictOpts)
    pure . NamedSchema (Just "ContextReq") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "只跑前兩層的 context 查詢;opts 缺席時退回保守的預設值"
        & properties .~ IOM.fromList [("draft", dS), ("opts", oS)]
        & required .~ ["draft"]

-- | @POST \/conflict\/check@ 的 body。
--
-- @opts@ 與 @no_llm@ __都可以缺席__:與 'ContextReq' 同一個待客之道。@no_llm@
-- 缺席時退回 'False' ——遠端模式的 @--no-llm@ 靠它過去。
data CheckReq = CheckReq
  { ckDraft :: Draft
  , ckOpts :: ConflictOpts
  , ckNoLlm :: Bool
  }
  deriving stock (Show, Eq)

instance ToJSON CheckReq where
  toJSON CheckReq {..} =
    object ["draft" .= ckDraft, "opts" .= ckOpts, "no_llm" .= ckNoLlm]

instance FromJSON CheckReq where
  parseJSON = withObject "CheckReq" $ \o ->
    CheckReq
      <$> o .: "draft"
      <*> o .:? "opts" .!= defaultConflictOpts
      <*> o .:? "no_llm" .!= False

-- | 與 'ContextReq' 同一處、同一種寫法。
instance ToSchema CheckReq where
  declareNamedSchema _ = do
    dS <- declareSchemaRef (Proxy :: Proxy Draft)
    oS <- declareSchemaRef (Proxy :: Proxy ConflictOpts)
    blS <- declareSchemaRef (Proxy :: Proxy Bool)
    pure . NamedSchema (Just "CheckReq") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "三層合流的衝突報告查詢;opts 與 no_llm 缺席時分別退回保守的預設值與 false"
        & properties .~ IOM.fromList [("draft", dS), ("opts", oS), ("no_llm", blS)]
        & required .~ ["draft"]

-- | @POST \/workshop@ 的 body(llm-workshop-mcp/F004)。
--
-- @constraints@ __缺席時退回 @[]@__ ——與 'ContextReq' \/ 'CheckReq' 同一個待客
-- 之道:硬約束是選配的,不必為了不用它而寫一個空陣列。
data WorkshopStartReq = WorkshopStartReq
  { wsrType :: Text
  , wsrConstraints :: [Id]
  }
  deriving stock (Show, Eq)

instance ToJSON WorkshopStartReq where
  toJSON WorkshopStartReq {..} = object ["type" .= wsrType, "constraints" .= wsrConstraints]

instance FromJSON WorkshopStartReq where
  parseJSON = withObject "WorkshopStartReq" $ \o ->
    WorkshopStartReq <$> o .: "type" <*> o .:? "constraints" .!= []

-- | schema 與 'ContextReq' \/ 'CheckReq' 同一處、同一種寫法——見它們上面那則
-- 註解:這幾個 wrapper 型別定義在這裡,實例只能寫在這裡,不能挪去
-- "Aapms.Api.Instances"(那個模組是這裡的上游)。
instance ToSchema WorkshopStartReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    ids <- declareSchemaRef (Proxy :: Proxy [Id])
    pure . NamedSchema (Just "WorkshopStartReq") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "開一個新工作坊,依型別的階段清單逐階段對話;constraints 缺席時退回 []"
        & properties .~ IOM.fromList [("type", txt), ("constraints", ids)]
        & required .~ ["type"]

-- | @POST \/workshop\/:id\/step@ 的 body。
newtype WorkshopStepReq = WorkshopStepReq {wsiInput :: Text}
  deriving stock (Show, Eq)

instance ToJSON WorkshopStepReq where
  toJSON (WorkshopStepReq i) = object ["input" .= i]

instance FromJSON WorkshopStepReq where
  parseJSON = withObject "WorkshopStepReq" $ \o -> WorkshopStepReq <$> o .: "input"

instance ToSchema WorkshopStepReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    pure . NamedSchema (Just "WorkshopStepReq") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "這一輪要對模型說的話"
        & properties .~ IOM.fromList [("input", txt)]
        & required .~ ["input"]

-- | @POST \/workshop\/:id\/step@ 的回應。
--
-- 'wssReply' 是給人看的那段模型回覆,不進 'Session' 本體(見 @design.md@「階段
-- 定案的來源」段)——REST \/ CLI 的 @--json@ 都需要把兩者一起交出去。
data WorkshopStepResp = WorkshopStepResp
  { wssSession :: Session
  , wssReply :: Text
  }
  deriving stock (Show, Eq)

instance ToJSON WorkshopStepResp where
  toJSON WorkshopStepResp {..} = object ["session" .= wssSession, "reply" .= wssReply]

instance FromJSON WorkshopStepResp where
  parseJSON = withObject "WorkshopStepResp" $ \o ->
    WorkshopStepResp <$> o .: "session" <*> o .: "reply"

instance ToSchema WorkshopStepResp where
  declareNamedSchema _ = do
    sS <- declareSchemaRef (Proxy :: Proxy Session)
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    pure . NamedSchema (Just "WorkshopStepResp") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "這一輪的 session 快照與模型給人看的回覆"
        & properties .~ IOM.fromList [("session", sS), ("reply", txt)]
        & required .~ ["session", "reply"]

-- | @POST \/workshop\/:id\/commit@ 的回應。
data WorkshopCommitResp = WorkshopCommitResp
  { wcrSession :: Session
  , wcrEntities :: [EntityView]
  }
  deriving stock (Show, Eq)

instance ToJSON WorkshopCommitResp where
  toJSON WorkshopCommitResp {..} = object ["session" .= wcrSession, "entities" .= wcrEntities]

instance FromJSON WorkshopCommitResp where
  parseJSON = withObject "WorkshopCommitResp" $ \o ->
    WorkshopCommitResp <$> o .: "session" <*> o .: "entities"

instance ToSchema WorkshopCommitResp where
  declareNamedSchema _ = do
    sS <- declareSchemaRef (Proxy :: Proxy Session)
    esS <- declareSchemaRef (Proxy :: Proxy [EntityView])
    pure . NamedSchema (Just "WorkshopCommitResp") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "定案後的 session 快照與這次寫進圖譜的片段"
        & properties .~ IOM.fromList [("session", sS), ("entities", esS)]
        & required .~ ["session", "entities"]

-- 共用的 query parameter --------------------------------------------------------

-- | 樂觀鎖的 expected revision。__必填__,見模組註解。
type Revision = QueryParam' '[Required, Strict] "revision" Int

-- | 'Aapms.Store.Query.EntityFilter' 的四個欄位。清單與檢索路由共用。
--
-- 吃一個型別參數而不是寫成獨立的 @:>@ 鏈:@:>@ 是右結合的,一條沒有終點的鏈
-- 放在 @Filter :> Get …@ 的左邊會變成 @(a :> b) :> c@,而 servant 沒有那個形狀的
-- 實例。帶參數的版本展開後仍是一條平的鏈。
type Filter a =
  QueryParam "type" Text
    :> QueryParam "status" Status
    :> QueryParam "tag" Text
    :> QueryParam "limit" Int
    :> a

type Force = QueryParam "force" Bool

-- 子 API -----------------------------------------------------------------------

-- | @GET \/vaults@ 與 @POST \/vaults@ __在沒有目前 Vault 的情況下也要能跑__
-- ——它們對應 service-and-interfaces/F001 不需要 @Env@ 的那兩個函式。server 的 @Env@ 因此是延遲
-- 取得的,不是啟動時就必須成功。
type VaultAPI =
  "vaults" :> Summary "列出全域註冊表裡的全部 Vault" :> Get '[JSON] [VaultView]
    :<|> "vaults"
      :> Summary "建立 Vault 骨架並登記進全域註冊表"
      :> ReqBody '[JSON] NewVaultReq
      :> Post '[JSON] VaultView
    :<|> "vault" :> Summary "目前 Vault 的名稱、路徑與 Entity 數" :> Get '[JSON] VaultView
    :<|> "vault"
      :> "index"
      :> "rebuild"
      :> Summary "全量重建索引(刪掉 index.db 也回得來)"
      :> Post '[JSON] IndexReport
    :<|> "vault"
      :> "index"
      :> "refresh"
      :> Summary "只補過時的檔案"
      :> Post '[JSON] IndexReport

type EntityAPI =
  "entities" :> Summary "列出 Entity" :> Filter (Get '[JSON] [Meta])
    :<|> "entities"
      :> Summary "建一份新的主題檔"
      :> ReqBody '[JSON] NewEntityReq
      :> Post '[JSON] EntityView
    :<|> "entities" :> Capture "id" Id :> Summary "讀一個 Entity" :> Get '[JSON] EntityView
    :<|> "entities"
      :> Capture "id" Id
      :> Summary "改 Meta 欄位。只改有給值的鍵"
      :> Revision
      :> ReqBody '[JSON] EntityPatch
      :> Patch '[JSON] EntityView
    :<|> "entities"
      :> Capture "id" Id
      :> "body"
      :> Summary "換掉正文"
      :> Revision
      :> ReqBody '[JSON] BodyReq
      :> Put '[JSON] EntityView
    :<|> "entities"
      :> Capture "id" Id
      :> Summary "刪除。被指向時需要 force=true"
      :> Revision
      :> Force
      :> Delete '[JSON] DeleteReport
    -- 唯一沒有 revision 的寫入端點。
    --
    -- service 的 addFragment 在操作清單裡就沒有 expected 參數:加一個片段不覆蓋
    -- 任何既有內容,所以它自己讀主體的 revision 再往下傳。並發保護仍然在——
    -- store 會重讀檔案比對,兩個同時進來的請求第二個拿到 stale_revision。
    --
    -- 這裡__不補一個假的 revision__:一個收下來卻不參與判斷的必填參數,會讓
    -- 客戶端以為自己拿到了樂觀鎖的保護,而它其實什麼也沒做。
    :<|> "entities"
      :> Capture "id" Id
      :> "fragments"
      :> Summary "往既有主題檔加一個片段(revision 由伺服器自己讀,不必帶)"
      :> ReqBody '[JSON] NewFragmentReq
      :> Post '[JSON] EntityView

type LinkAPI =
  "entities"
    :> Capture "id" Id
    :> "links"
    :> Summary "正向與反向的關聯一次列完"
    :> Get '[JSON] LinkReport
    :<|> "entities"
      :> Capture "id" Id
      :> "links"
      :> Summary "加一筆關聯。目標必須已經存在"
      :> Revision
      :> ReqBody '[JSON] Link
      :> Post '[JSON] EntityView
    :<|> "entities"
      :> Capture "id" Id
      :> "links"
      :> Summary "刪一筆關聯。kind 與 target 走 query parameter"
      :> Revision
      :> QueryParam' '[Required, Strict] "kind" LinkKind
      :> QueryParam' '[Required, Strict] "target" Ref
      :> Delete '[JSON] EntityView

type LevelAPI =
  "levels"
    :> Summary "列出 Level"
    :> QueryParam "status" Status
    :> QueryParam "limit" Int
    :> Get '[JSON] [Meta]
    :<|> "levels"
      :> Summary "建一份新的 Level 檔(連同根 Node)"
      :> ReqBody '[JSON] NewLevelReq
      :> Post '[JSON] LevelView
    :<|> "levels" :> Capture "id" Id :> Summary "讀出 Level 與它的場景樹" :> Get '[JSON] LevelView
    :<|> "levels"
      :> Capture "id" Id
      :> Summary "刪除整份 Level"
      :> Revision
      :> Force
      :> Delete '[JSON] DeleteReport

-- | Node 的兩條路由都吃 __Level 主體__的 revision,不是節點自己的
-- ——樂觀鎖鎖的是整份檔案,因為標題階層一動就會影響到別的節點。
--
-- 兩條路由的 capture __都叫 @id@__,雖然 @POST@ 拿到的是父節點、@DELETE@ 拿到的是
-- 要刪的節點。取不同的名字(@parentId@ \/ @id@)會讓 OpenAPI 產出兩個 URL 模板
-- 相同、只有參數名不同的 path item,而那是不少 codegen 工具會直接拒絕的形狀。
-- 語意差異寫在各自的 @Summary@ 裡。
type NodeAPI =
  "nodes"
    :> Capture "id" Id
    :> Summary "在這個節點(父節點)底下新增一個子節點"
    :> QueryParam' '[Required, Strict] "levelId" Id
    :> Revision
    :> ReqBody '[JSON] NewNodeReq
    :> Post '[JSON] LevelView
    :<|> "nodes"
      :> Capture "id" Id
      :> Summary "刪掉一個節點與它整棵子樹"
      :> QueryParam' '[Required, Strict] "levelId" Id
      :> Revision
      :> Force
      :> Delete '[JSON] LevelView

type MiscAPI =
  "types" :> Summary "型別註冊表裡的全部型別" :> Get '[JSON] [EntityTypeSpec]
    :<|> "search"
      :> Summary "FTS5 全文檢索。兩字以下的查詢由落地層改走 LIKE"
      :> QueryParam' '[Required, Strict] "q" Text
      :> Filter (Get '[JSON] [SearchHit])

-- | 衝突偵測的兩個出口:@context@(F004)與 @check@(F006)。
--
-- __兩條都唯讀,所以都沒有 @revision@__:整條路徑只讀不寫(@linkGraph@ \/
-- @getEntity@ \/ @aliasIndex@ \/ @searchEntity@ \/ @linksOf@ 五個讀取操作),
-- 樂觀鎖在這裡沒有意義,而收一個不參與判斷的必填參數就是說謊(同 @POST
-- \/entities\/{id}\/fragments@ 的理由)。方法都是 @POST@,因為草稿是一段長文字,
-- 塞不進 query parameter。
--
-- __整張關聯圖不會被序列化送出去__:@service@ 的 @linkGraph@ 只開內嵌出口,
-- 伺服器端是自己在 'Aapms.Service.ServiceM' 裡呼叫它。@check@ 這條路上,
-- 第 3 層要用的 'Aapms.Llm.Client.LlmClient' 同理不跨 HTTP:伺服器自己讀
-- 它綁定的那個 Vault 的 @[llm]@ 設定並建 client。
type ConflictAPI =
  "conflict"
    :> "context"
    :> Summary "只跑前兩層,把相關片段連內容一起撈出來(不做矛盾判斷)"
    :> ReqBody '[JSON] ContextReq
    :> Post '[JSON] [ContextHit]
    :<|> "conflict"
      :> "check"
      :> Summary "三層合流的衝突報告(第 3 層拿不到端點時退化成兩層,不讓指令失敗)"
      :> ReqBody '[JSON] CheckReq
      :> Post '[JSON] ConflictReport

-- | 工作坊的三個出口(llm-workshop-mcp/F004)。
--
-- __沒有一條帶 @revision@__:session 不是走樂觀鎖的資源(@design.md@「LlmConfig
-- 與 aapms-store 的佔位型別」段沒有提到樂觀鎖,'commitStage' 內部寫圖譜時的
-- 樂觀鎖屬於 @entity@\/@level@\/@node@ 那些既有端點的職責,不是 workshop 端點
-- 自己的)。
--
-- @Capture "id" Text@ 而不是 @Capture "id" Id@:session id(@Session@ 的
-- @wsId@)是 @design.md@ 明寫的 'Text',不是 core 的 @\<prefix\>-\<hex\>@ 格式,
-- 沿用 'Id' 的 'FromHttpApiData' 會擋掉合法的 session id。
type WorkshopAPI =
  "workshop"
    :> Summary "開一個新工作坊,依型別的階段清單逐階段對話"
    :> ReqBody '[JSON] WorkshopStartReq
    :> Post '[JSON] Session
    :<|> "workshop"
      :> Capture "id" Text
      :> "step"
      :> Summary "把這一輪的輸入送進目前階段,模型的回覆存回 session"
      :> ReqBody '[JSON] WorkshopStepReq
      :> Post '[JSON] WorkshopStepResp
    :<|> "workshop"
      :> Capture "id" Text
      :> "commit"
      :> Summary "把目前階段最後一次成功解析的草稿定案,寫進圖譜"
      :> Post '[JSON] WorkshopCommitResp

type AapmsAPI =
  VaultAPI
    :<|> EntityAPI
    :<|> LinkAPI
    :<|> LevelAPI
    :<|> NodeAPI
    :<|> MiscAPI
    :<|> ConflictAPI
    :<|> WorkshopAPI

aapmsAPI :: Proxy AapmsAPI
aapmsAPI = Proxy

-- OpenAPI ----------------------------------------------------------------------

-- | OpenAPI 3 文件,由 'aapmsAPI' 推導。
--
-- @aapms-serve --openapi@ 直接把它印出來,所以
-- @aapms-serve --openapi > openapi.json@ 是給 Agent 的一步驟交付。
aapmsOpenApi :: OpenApi
aapmsOpenApi =
  tagged (toOpenApi aapmsAPI)
    & info . title .~ "aapms API"
    & info . version .~ "0.1.0"
    & info . description ?~ "故事設定的片段圖譜與場景樹。所有業務操作的唯一契約(ADR-006)。"
    & info . license ?~ "BSD-3-Clause"
  where
    tagged =
      setOperationIds
        . applyTagsFor (subOperations (Proxy :: Proxy VaultAPI) aapmsAPI) ["vault"]
        . applyTagsFor (subOperations (Proxy :: Proxy EntityAPI) aapmsAPI) ["entity"]
        . applyTagsFor (subOperations (Proxy :: Proxy LinkAPI) aapmsAPI) ["link"]
        . applyTagsFor (subOperations (Proxy :: Proxy LevelAPI) aapmsAPI) ["level"]
        . applyTagsFor (subOperations (Proxy :: Proxy NodeAPI) aapmsAPI) ["node"]
        . applyTagsFor (subOperations (Proxy :: Proxy MiscAPI) aapmsAPI) ["misc"]
        . applyTagsFor (subOperations (Proxy :: Proxy ConflictAPI) aapmsAPI) ["conflict"]
        . applyTagsFor (subOperations (Proxy :: Proxy WorkshopAPI) aapmsAPI) ["workshop"]

-- | 幫 'aapmsOpenApi' 全部 28 個 operation 補上 @operationId@
-- (llm-workshop-mcp/F005)。@servant-openapi3@ 完全不設定這個欄位(查證結果 2),
-- 但 @aapms-mcp@ 的 tool 名字要「由 operationId 推導,不手維護對照表」——
-- 這一步讓那句話在 __編譯期__ 就成立:'AapmsAPI' 一改,這裡的 traverse 自動
-- 跟著算出新的 operationId,沒有人要手動同步一份表。
setOperationIds :: OpenApi -> OpenApi
setOperationIds doc = doc & paths %~ IOM.mapWithKey setForPath
  where
    setForPath path item =
      item
        & get %~ fmap (setId "get" path)
        & post %~ fmap (setId "post" path)
        & put %~ fmap (setId "put" path)
        & patch %~ fmap (setId "patch" path)
        & delete %~ fmap (setId "delete" path)
    setId verb path op = op & operationId ?~ deriveOperationId verb (T.pack path)

-- | 從 HTTP method(小寫)與 OpenAPI 路徑模板(如 @\"\/entities\/{id}\/links\"@)
-- 機械推導 operationId,不手寫任何一筆對照。規則:
--
--   1. 依 @\'\/\'@ 切成片段,去掉空字串
--   2. 片段形如 @\"{name}\"@ → @\"By\"@ <> 首字大寫(name)
--   3. 其餘片段 → 首字大寫(片段本身,全部已是純小寫英文單字)
--   4. method(小寫)接上全部轉換後片段依序串接
--
-- 例:@(\"post\", \"\/entities\/{id}\/links\")@ -> @\"postEntitiesByIdLinks\"@;
-- @(\"post\", \"\/vault\/index\/rebuild\")@ -> @\"postVaultIndexRebuild\"@。
deriveOperationId :: Text -> Text -> Text
deriveOperationId method path = T.concat (method : map convertSegment segments)
  where
    segments = filter (not . T.null) (T.splitOn "/" path)
    convertSegment seg = case T.stripPrefix "{" seg >>= T.stripSuffix "}" of
      Just name -> "By" <> capitalize name
      Nothing -> capitalize seg
    capitalize t = case T.uncons t of
      Nothing -> t
      Just (c, rest) -> T.cons (toUpper c) rest
