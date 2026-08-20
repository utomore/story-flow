{-# OPTIONS_GHC -Wno-orphans #-}

-- | URL 片段的編解碼與 OpenAPI schema,__集中在這一個模組__。
--
-- 與 "StoryFlow.Core.Json" 同一個理由的孤兒實例:capture 段、query parameter
-- 與 OpenAPI 文件講的必須是同一套規則,而規則只該有一份。
--
-- 兩組實例各自的紀律:
--
-- * 'FromHttpApiData' \/ 'ToHttpApiData' __直接委派給 core 的 @parse@ \/ @render@__。
--   URL 裡的 @ent-7f3a@ 與 JSON 裡的 @"ent-7f3a"@ 若能長得不一樣,Agent 就得學兩套寫法
-- * 'ToSchema' 必須與 'Data.Aeson.ToJSON' __逐欄對齊__。兩者分開手寫是 OpenAPI 文件
--   說謊最常見的來源,所以有一條測試(service-and-interfaces/F003 T3)拿樣本值的 JSON 鍵集合去比對
--   schema 的 @properties@ 鍵集合
--
-- 扁平化的三種實體('Entity' \/ 'Level' \/ 'Node')__重用 'Meta' 的 schema__ 再補上
-- 專屬欄位,理由與 @core@ 的 @metaPairs@ 相同:那十四欄若在這裡再抄一次,漏掉一欄
-- 不會有人發現。
module StoryFlow.Api.Instances () where

import Control.Lens ((&), (.~), (?~), (^.))
import Data.Aeson (Value (String))
import qualified Data.HashMap.Strict.InsOrd as IOM
import Data.OpenApi
  ( Definitions
  , NamedSchema (..)
  , OpenApiType (..)
  , Referenced
  , Schema
  , ToParamSchema (..)
  , ToSchema (..)
  , declareSchemaRef
  , description
  , enum_
  , example
  , properties
  , required
  , type_
  )
import Data.OpenApi.Declare (Declare)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day)
import Servant.API (FromHttpApiData (..), ToHttpApiData (..))
import StoryFlow.Conflict.Types
  ( ConflictOpts
  , ContextHit
  , Draft
  , GraphEvidence
  , HitLayer
  )
import StoryFlow.Core.Entity (Entity)
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef, renderId, renderRef)
import StoryFlow.Core.Level (Level, Node, NodeKind, allNodeKinds, parseNodeKind, renderNodeKind)
import StoryFlow.Core.Link (Link, LinkKind, coreLinkKinds, parseLinkKind, renderLinkKind)
import StoryFlow.Core.Meta
  ( Meta
  , Source
  , Status
  , Timeline
  , parseSource
  , parseStatus
  , renderSource
  , renderStatus
  )
import StoryFlow.Core.Registry (EntityTypeSpec, FieldSpec)
import StoryFlow.Core.Tree (NodeTree)
import StoryFlow.Service
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

-- HttpApiData ------------------------------------------------------------------

-- | core 的 @parse@ 回的錯誤型別各不相同,而 servant 要的是 'Text'。
-- 一律換成寫給人看的一句話——400 的 body 是使用者會讀到的東西。
viaCore :: (Text -> Either e a) -> Text -> Text -> Either Text a
viaCore f msg t = either (const (Left msg)) Right (f t)

instance FromHttpApiData Id where
  parseUrlPiece = viaCore (fmap snd . parseId) "id 的格式應為 <prefix>-<十六進位>,如 ent-7f3a"

instance ToHttpApiData Id where
  toUrlPiece = renderId

instance FromHttpApiData Ref where
  parseUrlPiece = viaCore parseRef "參照的格式應為 <id> 或 <vault>:<id>"

instance ToHttpApiData Ref where
  toUrlPiece = renderRef

instance FromHttpApiData Status where
  parseUrlPiece = viaCore parseStatus "status 只能是 draft / canon / deprecated"

instance ToHttpApiData Status where
  toUrlPiece = renderStatus

instance FromHttpApiData Source where
  parseUrlPiece = viaCore parseSource "source 只能是 human、agent:<名稱> 或 workshop:<型別>"

instance ToHttpApiData Source where
  toUrlPiece = renderSource

-- | 'parseLinkKind' 是__全函式__:任何字串都是合法的關聯(ADR-005),
-- 所以這個實例永遠回 'Right'。這不是疏漏,是規格。
instance FromHttpApiData LinkKind where
  parseUrlPiece = Right . parseLinkKind

instance ToHttpApiData LinkKind where
  toUrlPiece = renderLinkKind

instance FromHttpApiData NodeKind where
  parseUrlPiece =
    viaCore parseNodeKind ("kind 只能是:" <> T.intercalate " / " (map renderNodeKind allNodeKinds))

instance ToHttpApiData NodeKind where
  toUrlPiece = renderNodeKind

-- schema 小工具 -----------------------------------------------------------------

-- | 純量型別的 schema。"StoryFlow.Core.Json" 的第一條約定是這些型別編成
-- __字串__而不是物件,schema 因此也是字串。
strSchema :: Text -> Schema
strSchema desc = mempty & type_ ?~ OpenApiString & description ?~ desc

-- | 附 @enum@ 的字串 schema:文件說得出合法值,Agent 才不必試。
enumSchema :: Text -> [Text] -> Schema
enumSchema desc vals = strSchema desc & enum_ ?~ map String vals

objSchema :: Text -> [(Text, Referenced Schema)] -> [Text] -> Schema
objSchema desc props req =
  mempty
    & type_ ?~ OpenApiObject
    & description ?~ desc
    & properties .~ IOM.fromList props
    & required .~ req

named :: Text -> Schema -> NamedSchema
named n = NamedSchema (Just n)

-- ToParamSchema ----------------------------------------------------------------

instance ToParamSchema Id where
  toParamSchema _ = mempty & type_ ?~ OpenApiString & example ?~ String "ent-7f3a"

instance ToParamSchema Ref where
  toParamSchema _ = mempty & type_ ?~ OpenApiString & example ?~ String "ent-7f3a"

instance ToParamSchema Status where
  toParamSchema _ = mempty & type_ ?~ OpenApiString & enum_ ?~ map String ["draft", "canon", "deprecated"]

instance ToParamSchema LinkKind where
  toParamSchema _ =
    mempty
      & type_ ?~ OpenApiString
      & description ?~ "核心關聯之一,或任何自訂字串(ADR-005:自訂關聯合法)"
      & example ?~ String "partOf"

instance ToParamSchema NodeKind where
  toParamSchema _ =
    mempty & type_ ?~ OpenApiString & enum_ ?~ map (String . renderNodeKind) allNodeKinds

-- ToSchema:core 的純量型別 -------------------------------------------------------

instance ToSchema Id where
  declareNamedSchema _ =
    pure (named "Id" (strSchema "<prefix>-<十六進位>,prefix 為 ent/lvl/nod/vlt"))

instance ToSchema Ref where
  declareNamedSchema _ = pure (named "Ref" (strSchema "<id> 或 <vault>:<id>"))

instance ToSchema Status where
  declareNamedSchema _ =
    pure (named "Status" (enumSchema "只有 canon 參與衝突偵測的比對基準" ["draft", "canon", "deprecated"]))

instance ToSchema Source where
  declareNamedSchema _ =
    pure (named "Source" (strSchema "human / agent:<名稱> / workshop:<型別>"))

instance ToSchema LinkKind where
  declareNamedSchema _ =
    pure . named "LinkKind" . strSchema $
      "核心關聯:" <> T.intercalate " / " (map renderLinkKind coreLinkKinds) <> ";其餘一律為自訂關聯"

instance ToSchema NodeKind where
  declareNamedSchema _ =
    pure (named "NodeKind" (enumSchema "Node 的種類" (map renderNodeKind allNodeKinds)))

-- | 兩欄皆缺時整個 @timeline@ 鍵不出現,所以兩欄都不是 required。
instance ToSchema Timeline where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    int <- declareSchemaRef (Proxy :: Proxy Int)
    pure . named "Timeline" $
      objSchema "故事內時間點。label 可模糊,order 供排序" [("label", txt), ("order", int)] []

-- ToSchema:結構型別 --------------------------------------------------------------

-- | 'Meta' 的十四個欄位,鍵名與 @core@ 的 @metaPairs@ 逐欄對齊。
instance ToSchema Meta where
  declareNamedSchema _ = named "Meta" <$> metaSchema

-- | 抽出來讓 'Entity' \/ 'Level' \/ 'Node' 扁平化時重用。
metaSchema :: Declare (Definitions Schema) Schema
metaSchema = do
  txt <- declareSchemaRef (Proxy :: Proxy Text)
  txts <- declareSchemaRef (Proxy :: Proxy [Text])
  int <- declareSchemaRef (Proxy :: Proxy Int)
  day <- declareSchemaRef (Proxy :: Proxy Day)
  idS <- declareSchemaRef (Proxy :: Proxy Id)
  stS <- declareSchemaRef (Proxy :: Proxy Status)
  srS <- declareSchemaRef (Proxy :: Proxy Source)
  tlS <- declareSchemaRef (Proxy :: Proxy Timeline)
  lkS <- declareSchemaRef (Proxy :: Proxy [Link])
  pure $
    objSchema
      "Entity / Level / Node 共用的統一 Meta"
      [ ("id", idS)
      , ("vault", txt)
      , ("type", txt)
      , ("title", txt)
      , ("summary", txt)
      , ("tags", txts)
      , ("status", stS)
      , ("aliases", txts)
      , ("links", lkS)
      , ("source", srS)
      , ("revision", int)
      , ("created", day)
      , ("updated", day)
      , ("timeline", tlS)
      ]
      ["id", "vault", "type", "title", "summary", "status", "source", "revision", "created", "updated"]

instance ToSchema Link where
  declareNamedSchema _ = do
    kS <- declareSchemaRef (Proxy :: Proxy LinkKind)
    rS <- declareSchemaRef (Proxy :: Proxy Ref)
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    pure . named "Link" $
      objSchema
        "有方向性的關聯,存在來源端"
        [("kind", kS), ("target", rS), ("note", txt)]
        ["kind", "target"]

-- | 在 'Meta' 的 schema 上補專屬欄位。
--
-- 'Entity' \/ 'Level' \/ 'Node' 在 JSON 裡是__扁平__的(與 Markdown frontmatter
-- 的形狀一致),schema 因此也要攤平,不能只塞一個 @meta@ 子物件。
extend :: Text -> Text -> [(Text, Referenced Schema)] -> [Text] -> Schema -> NamedSchema
extend n desc props req base =
  named n $
    base
      & description ?~ desc
      & properties .~ (base ^. properties <> IOM.fromList props)
      & required .~ (base ^. required <> req)

instance ToSchema Entity where
  declareNamedSchema _ = do
    base <- metaSchema
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    pure (extend "Entity" "Meta 攤平 + body(正文 Markdown)" [("body", txt)] ["body"] base)

instance ToSchema Level where
  declareNamedSchema _ = do
    base <- metaSchema
    idS <- declareSchemaRef (Proxy :: Proxy Id)
    pure (extend "Level" "Meta 攤平 + root(根 Node 的 id)" [("root", idS)] ["root"] base)

instance ToSchema Node where
  declareNamedSchema _ = do
    base <- metaSchema
    idS <- declareSchemaRef (Proxy :: Proxy Id)
    int <- declareSchemaRef (Proxy :: Proxy Int)
    kS <- declareSchemaRef (Proxy :: Proxy NodeKind)
    refs <- declareSchemaRef (Proxy :: Proxy [Ref])
    pure $
      extend
        "Node"
        "Meta 攤平 + 樹的結構欄位。parent 缺席即為根節點"
        [("level", idS), ("parent", idS), ("order", int), ("kind", kS), ("entities", refs)]
        ["level", "order", "kind", "entities"]
        base

-- | 遞迴 schema:@children@ 指回 @NodeTree@ 自己。
--
-- __必須走 'declareSchemaRef' 而不是內嵌 schema__ ——內嵌會讓宣告無限展開直到堆疊
-- 爆掉。@openapi3@ 靠具名 schema 的 @$ref@ 打斷這個環,而具名的前提是這個實例回的
-- 'NamedSchema' 帶著名字(所以這裡不能用匿名的 @NamedSchema Nothing@)。
instance ToSchema NodeTree where
  declareNamedSchema _ = do
    nS <- declareSchemaRef (Proxy :: Proxy Node)
    kids <- declareSchemaRef (Proxy :: Proxy [NodeTree])
    pure . named "NodeTree" $
      objSchema
        "場景樹的一個節點與它的子樹"
        [("node", nS), ("children", kids)]
        ["node", "children"]

-- ToSchema:型別註冊表 ------------------------------------------------------------

instance ToSchema FieldSpec where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    bl <- declareSchemaRef (Proxy :: Proxy Bool)
    pure . named "FieldSpec" $
      objSchema
        "型別宣告裡的一個欄位提示"
        [("name", txt), ("required", bl), ("hint", txt)]
        ["name", "required", "hint"]

instance ToSchema EntityTypeSpec where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    txts <- declareSchemaRef (Proxy :: Proxy [Text])
    fs <- declareSchemaRef (Proxy :: Proxy [FieldSpec])
    ks <- declareSchemaRef (Proxy :: Proxy [LinkKind])
    pure . named "EntityTypeSpec" $
      objSchema
        "型別註冊表的一筆宣告(types/registry/*.toml)"
        [ ("key", txt)
        , ("name", txt)
        , ("fields", fs)
        , ("allowed_links", ks)
        , ("stages", txts)
        , ("dir", txt)
        , ("owner_type", txt)
        ]
        ["key", "name", "fields", "allowed_links", "stages"]

-- ToSchema:service 的 View 與請求 --------------------------------------------------

instance ToSchema EntityView where
  declareNamedSchema _ = do
    eS <- declareSchemaRef (Proxy :: Proxy Entity)
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    txts <- declareSchemaRef (Proxy :: Proxy [Text])
    pure . named "EntityView" $
      objSchema
        "一個 Entity 加上索引才知道的事:路徑、錨點、警告"
        [("entity", eS), ("path", txt), ("anchor", txt), ("warnings", txts)]
        ["entity", "path", "warnings"]

instance ToSchema LevelView where
  declareNamedSchema _ = do
    lS <- declareSchemaRef (Proxy :: Proxy Level)
    tS <- declareSchemaRef (Proxy :: Proxy NodeTree)
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    pure . named "LevelView" $
      objSchema
        "Level 與它的樹。回樹而不是扁平清單:合法性已由 buildTree 驗過"
        [("level", lS), ("tree", tS), ("path", txt)]
        ["level", "tree", "path"]

instance ToSchema VaultView where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    int <- declareSchemaRef (Proxy :: Proxy Int)
    pure . named "VaultView" $
      objSchema
        "entity_count 在 GET /vaults 不會有值:列個清單不該把每個 Vault 的索引都打開"
        [("name", txt), ("root", txt), ("entity_count", int)]
        ["name", "root"]

-- | @score@ 在 @properties@ 但不在 @required@:它是選配的。
--
-- 中文兩字詞走的是 @LIKE@ 路徑,那條查詢沒有相關度可言,'shScore' 因此是
-- 'Nothing',而 @Maybe@ 沒值時整個鍵不出現(service-and-interfaces/F001 的編碼
-- 約定)。把它列進 @required@ 會讓 OpenAPI 說謊。
instance ToSchema SearchHit where
  declareNamedSchema _ = do
    mS <- declareSchemaRef (Proxy :: Proxy Meta)
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    dbl <- declareSchemaRef (Proxy :: Proxy Double)
    pure . named "SearchHit" $
      objSchema
        "檢索命中:Meta + 命中片段 + 相關度(0–1,只有 FTS5 路徑給得出來)"
        [("meta", mS), ("snippet", txt), ("score", dbl)]
        ["meta", "snippet"]

-- | @(Id, Link)@ 這個配對在 schema 裡需要一個名字。
--
-- 它不出現在任何簽名裡,只是 'LinkReport' 與 'DeleteReport' 的元素型別——
-- 兩者的 aeson 實例把它編成 @{"source": …, "link": …}@ 物件而不是二元陣列
-- ("StoryFlow.Service.Json" 的第三條約定:Agent 讀得懂鍵名,讀不懂位置)。
data SourcedLink

instance ToSchema SourcedLink where
  declareNamedSchema _ = do
    idS <- declareSchemaRef (Proxy :: Proxy Id)
    lS <- declareSchemaRef (Proxy :: Proxy Link)
    pure . named "SourcedLink" $
      objSchema "(來源 id, 那一筆關聯)" [("source", idS), ("link", lS)] ["source", "link"]

instance ToSchema LinkReport where
  declareNamedSchema _ = do
    ls <- declareSchemaRef (Proxy :: Proxy [Link])
    sls <- declareSchemaRef (Proxy :: Proxy [SourcedLink])
    pure . named "LinkReport" $
      objSchema
        "正向與反向一次給。反向查詢只有索引做得到:關聯只存在來源端"
        [("outgoing", ls), ("incoming", sls)]
        ["outgoing", "incoming"]

instance ToSchema IndexReport where
  declareNamedSchema _ = do
    int <- declareSchemaRef (Proxy :: Proxy Int)
    txts <- declareSchemaRef (Proxy :: Proxy [Text])
    pure . named "IndexReport" $
      objSchema "索引重建的結果" [("files", int), ("issues", txts)] ["files", "issues"]

instance ToSchema DeleteReport where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    ids <- declareSchemaRef (Proxy :: Proxy [Id])
    sls <- declareSchemaRef (Proxy :: Proxy [SourcedLink])
    pure . named "DeleteReport" $
      objSchema
        "removed 在刪整份檔案時不只一個;broken_links 是強制刪除打斷的關聯"
        [("path", txt), ("removed", ids), ("broken_links", sls)]
        ["path", "removed", "broken_links"]

instance ToSchema NewEntityReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    txts <- declareSchemaRef (Proxy :: Proxy [Text])
    stS <- declareSchemaRef (Proxy :: Proxy Status)
    tlS <- declareSchemaRef (Proxy :: Proxy Timeline)
    lkS <- declareSchemaRef (Proxy :: Proxy [Link])
    srS <- declareSchemaRef (Proxy :: Proxy Source)
    pure . named "NewEntityReq" $
      objSchema
        "建一份新的主題檔。type 必須是型別註冊表認得的鍵(GET /types 查得到)"
        [ ("type", txt)
        , ("title", txt)
        , ("summary", txt)
        , ("body", txt)
        , ("tags", txts)
        , ("aliases", txts)
        , ("status", stS)
        , ("timeline", tlS)
        , ("links", lkS)
        , ("source", srS)
        ]
        ["type", "title"]

instance ToSchema NewFragmentReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    txts <- declareSchemaRef (Proxy :: Proxy [Text])
    stS <- declareSchemaRef (Proxy :: Proxy Status)
    tlS <- declareSchemaRef (Proxy :: Proxy Timeline)
    lkS <- declareSchemaRef (Proxy :: Proxy [Link])
    srS <- declareSchemaRef (Proxy :: Proxy Source)
    pure . named "NewFragmentReq" $
      objSchema
        "只填與檔案層不同的欄位,其餘留空讓繼承生效;summary 不繼承,所以它不是選配的"
        [ ("title", txt)
        , ("summary", txt)
        , ("body", txt)
        , ("type", txt)
        , ("tags", txts)
        , ("aliases", txts)
        , ("status", stS)
        , ("timeline", tlS)
        , ("links", lkS)
        , ("source", srS)
        ]
        ["title"]

instance ToSchema NewLevelReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    kS <- declareSchemaRef (Proxy :: Proxy NodeKind)
    stS <- declareSchemaRef (Proxy :: Proxy Status)
    pure . named "NewLevelReq" $
      objSchema
        "建 Level 一定連根 Node 一起建:空殼 Level 解析不出 root"
        [ ("title", txt)
        , ("summary", txt)
        , ("body", txt)
        , ("root_title", txt)
        , ("root_kind", kS)
        , ("status", stS)
        ]
        ["title", "root_title", "root_kind"]

instance ToSchema NewNodeReq where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    kS <- declareSchemaRef (Proxy :: Proxy NodeKind)
    lkS <- declareSchemaRef (Proxy :: Proxy [Link])
    pure . named "NewNodeReq" $
      objSchema
        "掛在某個父 Node 底下的新節點"
        [("title", txt), ("kind", kS), ("summary", txt), ("body", txt), ("links", lkS)]
        ["title", "kind"]

-- ToSchema:衝突偵測(conflict-detection/F004) ---------------------------------------

-- | @refs@ 在 @properties@ 但不在 @required@:'Draft' 的 @FromJSON@ 對它
-- @.!= []@,@drRefs@ 為空清單是合法輸入(那代表只能跑第 2 層)。
instance ToSchema Draft where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    ids <- declareSchemaRef (Proxy :: Proxy [Id])
    pure . named "Draft" $
      objSchema
        "待檢查的草稿:文字 + 呼叫端已經知道它引用了哪些片段"
        [("text", txt), ("refs", ids)]
        ["text"]

-- | __四欄全部選配__:'StoryFlow.Conflict.Json' 的 @FromJSON ConflictOpts@ 逐欄退回
-- @defaultConflictOpts@,客戶端只想調 @top_n@ 時不必寫齊四欄。
instance ToSchema ConflictOpts where
  declareNamedSchema _ = do
    int <- declareSchemaRef (Proxy :: Proxy Int)
    bl <- declareSchemaRef (Proxy :: Proxy Bool)
    pure . named "ConflictOpts" $
      objSchema
        "三層共用的選項。缺席的欄位一律退回保守的預設值(top_n=20 / graph_depth=2)"
        [ ("top_n", int)
        , ("expand_body", bl)
        , ("timeline_window", int)
        , ("graph_depth", int)
        ]
        []

instance ToSchema GraphEvidence where
  declareNamedSchema _ = do
    idS <- declareSchemaRef (Proxy :: Proxy Id)
    kS <- declareSchemaRef (Proxy :: Proxy LinkKind)
    rS <- declareSchemaRef (Proxy :: Proxy Ref)
    pure . named "GraphEvidence" $
      objSchema
        "第 1 層的證據:造成命中的那一條關聯。to 是 Ref 而非 Id,跨 Vault 的命中才表達得出來"
        [("from", idS), ("kind", kS), ("to", rS)]
        ["from", "kind", "to"]

-- | 'HitLayer' 是__和積型別__,schema 因此宣告成__聯集物件__:六個鍵都在
-- @properties@ 裡,而 @required@ __只有 @layer@__ ——一個樣本值只走得到一個建構子,
-- 把 @from@ 或 @score@ 列進 @required@ 會讓另外兩個建構子的 JSON 變成不合法。
--
-- 這也是 @StoryFlow.Api.SchemaSpec@ 對它用 @alignsSubset@(子集)而不是既有
-- @aligns@(相等)的原因:相等對和積型別必然不成立,而放寬既有那條斷言等於
-- 把整組型別的保護一起拆掉。
instance ToSchema HitLayer where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    idS <- declareSchemaRef (Proxy :: Proxy Id)
    kS <- declareSchemaRef (Proxy :: Proxy LinkKind)
    rS <- declareSchemaRef (Proxy :: Proxy Ref)
    dbl <- declareSchemaRef (Proxy :: Proxy Double)
    -- @GraphEvidence@ 登記進 @components.schemas@,但__沒有人 @$ref@ 它__:
    -- 它在 wire 上是攤平的(@layer@ + 它的三欄),不是巢狀物件。之所以仍然要有
    -- 這個具名 schema,是因為那三欄的型別本身帶著契約——@to@ 是 'Ref' 而不是
    -- 'Id',跨 Vault 的命中才表達得出來(F001)——而攤平之後,讀 OpenAPI 的 Agent
    -- 只看得到 @HitLayer@ 那個聯集物件的鍵,看不出這三欄是一組。
    _ <- declareSchemaRef (Proxy :: Proxy GraphEvidence)
    pure . named "HitLayer" $
      objSchema
        "命中層級,以 layer 標籤區分的和:\
        \graph 帶 from/kind/to(第 1 層是事實)、\
        \retrieval 帶 score(FTS5 相關度)、\
        \judge 帶 confidence(第 3 層是判斷)。除 layer 外的鍵依 layer 而定"
        [ ("layer", txt)
        , ("from", idS)
        , ("kind", kS)
        , ("to", rS)
        , ("score", dbl)
        , ("confidence", dbl)
        ]
        ["layer"]

instance ToSchema ContextHit where
  declareNamedSchema _ = do
    mS <- declareSchemaRef (Proxy :: Proxy Meta)
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    lS <- declareSchemaRef (Proxy :: Proxy HitLayer)
    pure . named "ContextHit" $
      objSchema
        "撈出來的素材:直接帶 Meta 與命中片段,外部 Agent 不必再往返一次"
        [("meta", mS), ("snippet", txt), ("via", lS)]
        ["meta", "snippet", "via"]

instance ToSchema EntityPatch where
  declareNamedSchema _ = do
    txt <- declareSchemaRef (Proxy :: Proxy Text)
    txts <- declareSchemaRef (Proxy :: Proxy [Text])
    stS <- declareSchemaRef (Proxy :: Proxy Status)
    tlS <- declareSchemaRef (Proxy :: Proxy Timeline)
    srS <- declareSchemaRef (Proxy :: Proxy Source)
    pure . named "EntityPatch" $
      objSchema
        "只改有給值的欄位。沒給的鍵不會被填成空值"
        [ ("title", txt)
        , ("summary", txt)
        , ("tags", txts)
        , ("status", stS)
        , ("timeline", tlS)
        , ("aliases", txts)
        , ("source", srS)
        ]
        []
