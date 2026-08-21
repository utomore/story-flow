-- | 引數解析:字串 → 'Command'。
--
-- 這個模組__不做任何業務判斷__,也不碰 IO。它的產物是一個純資料的
-- 'Command','StoryFlow.Cli' 再拿它去呼叫 @service@。這條界線讓「引數怎麼寫」
-- 能被單元測試釘死,不必開 Vault。
--
-- 指令形狀是__名詞在前、動詞在後__(@git remote add@ \/ @docker image ls@ 的
-- 形狀):同一個名詞的操作聚在一起,@--help@ 才讀得下去。
--
-- @--type@ 的合法值__不寫死在列舉裡__(垂直切片 1:新增型別不改程式)。照收
-- 字串,由 service 的 @UnknownType@ 負責擋;@--help@ 只提示去哪裡查——optparse
-- 的說明文字是在有 'StoryFlow.Service.Monad.Env' 之前就要組出來的,那時拿不到
-- 註冊表。
module StoryFlow.Cli.Options
  ( -- * 型別
    GlobalOpts (..)
  , Command (..)
  , Selector (..)
  , BodySource (..)

    -- * 解析
  , parseCli
  , mkSelector

    -- * 供測試與 'StoryFlow.Cli' 共用
  , parseLinkSpec
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import StoryFlow.Conflict.Types (ConflictOpts (..), defaultConflictOpts)
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Core.Level (NodeKind, allNodeKinds, parseNodeKind, renderNodeKind)
import StoryFlow.Core.Link (Link (..), LinkKind, coreLinkKinds, parseLinkKind, renderLinkKind)
import StoryFlow.Core.Meta
  ( Source (Human)
  , Status (Draft)
  , Timeline (..)
  , isEmptyTimeline
  , parseSource
  , parseStatus
  )
import StoryFlow.Service
  ( EntityFilter (..)
  , EntityPatch (..)
  , NewEntityReq (..)
  , NewFragmentReq (..)
  , NewLevelReq (..)
  , NewNodeReq (..)
  )

-- 型別 -------------------------------------------------------------------------

-- | 名詞之前就要給的選項。
data GlobalOpts = GlobalOpts
  { goVault :: Maybe Text
  -- ^ 原樣傳給 'StoryFlow.Service.Monad.openEnv';ADR-008 的解析規則不在 CLI 重寫
  , goJson :: Bool
  , goRemote :: Maybe Text
  -- ^ 遠端伺服器的 base url。給了就改走 HTTP,__與 'goVault' 不能併用__
  -- (伺服器已經綁定了它自己的 Vault)
  }
  deriving stock (Show, Eq)

-- | 使用者打的是 id 還是標題,解析後才知道。
data Selector
  = SelById Id
  | SelByTitle Text
  deriving stock (Show, Eq)

-- | 正文的三種來源:直接給、讀檔、讀 stdin。
--
-- 它不能在解析階段就變成 'Text' ——讀檔與讀 stdin 是 IO,而 'parseCli' 是純的。
-- 這也是 'EntityNew' \/ 'EntityAdd' 帶著它、而不是把正文塞進請求型別的原因。
data BodySource
  = BodyLiteral Text
  | BodyFile FilePath
  | BodyStdin
  deriving stock (Show, Eq)

data Command
  = VaultInit FilePath Text
  | VaultList
  | VaultInfo
  | IndexRebuild
  | IndexRefresh
  | TypeList
  | EntityNew NewEntityReq BodySource
  | EntityAdd Selector NewFragmentReq BodySource
  | EntityShow Selector
  | EntityList EntityFilter
  | EntitySearch Text EntityFilter
  | EntitySet Selector (Maybe Int) EntityPatch
  | EntitySetBody Selector (Maybe Int) BodySource
  | EntityRm Selector (Maybe Int) Bool
  | LinkAdd Selector (Maybe Int) Link
  | LinkRm Selector (Maybe Int) LinkKind Ref
  | LinkList Selector
  | LevelNew NewLevelReq
  | LevelShow Selector
  | LevelList EntityFilter
  | LevelRm Selector (Maybe Int) Bool
  | NodeAdd Selector (Maybe Int) NewNodeReq
  | NodeRm Selector (Maybe Int) Bool
  | -- | @context --for \<檔案|-\>@:草稿來源、已引用的片段、三層共用的選項。
    --
    -- 草稿是 'BodySource' 而不是 'Text',理由與 'EntitySetBody' 相同——讀檔與讀
    -- stdin 是 IO,而 'parseCli' 是純的。
    Context BodySource [Id] ConflictOpts
  | -- | @conflict check --draft \<檔案|-\>@:草稿來源、已引用的片段、五欄選項、
    -- @--no-llm@(conflict-detection/F006)。
    --
    -- @Bool@ 是 @--no-llm@,不是 'ConflictOpts' 的欄位——它是「這一次要不要跑」
    -- 的執行決定,不是三層共用的選項(見 F006 對應的 Level 2 契約)。
    ConflictCheck BodySource [Id] ConflictOpts Bool
  deriving stock (Show, Eq)

-- 進入點 -----------------------------------------------------------------------

parseCli :: [String] -> ParserResult (GlobalOpts, Command)
parseCli = execParserPure defaultPrefs pinfo

pinfo :: ParserInfo (GlobalOpts, Command)
pinfo =
  info
    (helper <*> ((,) <$> globalP <*> commandP))
    ( fullDesc
        <> header "story-flow —— 故事設定的片段圖譜與場景樹"
        <> progDesc "以片段為最小單位管理故事設定;每個子指令都支援 --json"
    )

globalP :: Parser GlobalOpts
globalP =
  GlobalOpts
    <$> optional
      ( txtOption
          ( long "vault"
              <> metavar "<名稱>"
              <> help "指定 Vault 名稱;不給時從目前目錄向上搜尋 .storyflow/"
          )
      )
    <*> switch
      ( long "json"
          <> help "輸出統一信封 {\"ok\":true,\"data\":…} / {\"ok\":false,\"error\":{…}}"
      )
    <*> optional
      ( txtOption
          ( long "remote"
              <> metavar "<網址>"
              <> help "改走遠端伺服器,如 http://127.0.0.1:8787;不能與 --vault 併用"
          )
      )

commandP :: Parser Command
commandP =
  hsubparser
    ( grp "vault" vaultP "Vault 的建立、清單與資訊"
        <> grp "index" indexP "索引重建與補齊"
        <> grp "type" typeP "型別註冊表"
        <> grp "entity" entityP "Entity 片段的增刪查改"
        <> cmd "search" searchP "全文檢索"
        <> grp "link" linkP "關聯的增刪查"
        <> grp "level" levelP "Level 場景樹"
        <> grp "node" nodeP "Level 裡的 Node"
        <> cmd "context" contextP "撈出與一段草稿相關的既有片段(只跑前兩層,不做矛盾判斷)"
        <> grp "conflict" conflictP "三層合流的衝突報告"
    )

-- | 名詞層:再包一層動詞的 @hsubparser@。
grp :: String -> Parser Command -> String -> Mod CommandFields Command
grp name p d = command name (info (helper <*> p) (progDesc d))

cmd :: String -> Parser Command -> String -> Mod CommandFields Command
cmd = grp

-- 各名詞 -----------------------------------------------------------------------

vaultP :: Parser Command
vaultP =
  hsubparser
    ( cmd "init" vaultInitP "建立 Vault 骨架並登記進全域註冊表"
        <> cmd "list" (pure VaultList) "列出全域註冊表裡的 Vault"
        <> cmd "info" (pure VaultInfo) "目前 Vault 的名稱、路徑與 Entity 數"
    )

vaultInitP :: Parser Command
vaultInitP =
  VaultInit
    <$> argument str (metavar "[目錄]" <> value "." <> help "Vault 根目錄,預設為目前目錄")
    <*> txtOption (long "name" <> metavar "<名稱>" <> help "Vault 名稱,--vault 用它來定址")

indexP :: Parser Command
indexP =
  hsubparser
    ( cmd "rebuild" (pure IndexRebuild) "全量重建索引(刪掉 index.db 也回得來)"
        <> cmd "refresh" (pure IndexRefresh) "只補過時的檔案"
    )

typeP :: Parser Command
typeP = hsubparser (cmd "list" (pure TypeList) "列出型別註冊表裡的全部型別")

entityP :: Parser Command
entityP =
  hsubparser
    ( cmd "new" entityNewP "建一份新的主題檔"
        <> cmd "add" entityAddP "往既有主題檔加一個片段"
        <> cmd "show" (EntityShow <$> selectorArg "<實體>") "印出一個 Entity 的欄位與正文"
        <> cmd "list" (EntityList <$> filterP) "列出 Entity"
        <> cmd "set" entitySetP "改 Meta 欄位"
        <> cmd "set-body" entitySetBodyP "換掉正文"
        <> cmd "rm" (EntityRm <$> selectorArg "<實體>" <*> revisionP <*> forceP) "刪除"
    )

entityNewP :: Parser Command
entityNewP =
  EntityNew
    <$> ( NewEntityReq
            <$> typeOptReq
            <*> titleOpt
            <*> summaryOpt
            <*> pure "" -- 正文由 BodySource 在 runCli 裡讀進來
            <*> many (txtOption (long "tag" <> metavar "<標籤>" <> help "可重複"))
            <*> many (txtOption (long "alias" <> metavar "<別名>" <> help "可重複"))
            <*> statusOpt
            <*> timelineP
            <*> many linkOpt
            <*> sourceOpt
        )
    <*> bodyP

entityAddP :: Parser Command
entityAddP =
  EntityAdd
    <$> selectorArg "<主體>"
    <*> ( NewFragmentReq
            <$> titleOpt
            <*> summaryOpt
            <*> pure ""
            <*> optional typeOpt
            <*> many (txtOption (long "tag" <> metavar "<標籤>" <> help "可重複"))
            <*> many (txtOption (long "alias" <> metavar "<別名>" <> help "可重複"))
            <*> optional statusOptRaw
            <*> maybeTimelineP
            <*> many linkOpt
            <*> optional sourceOptRaw
        )
    <*> bodyP

entitySetP :: Parser Command
entitySetP =
  EntitySet
    <$> selectorArg "<實體>"
    <*> revisionP
    <*> ( EntityPatch
            <$> optional (txtOption (long "title" <> metavar "<標題>"))
            <*> optional (txtOption (long "summary" <> metavar "<一句話總結>"))
            <*> optionalList (txtOption (long "tag" <> metavar "<標籤>" <> help "可重複;給了就整組取代"))
            <*> optional statusOptRaw
            <*> maybeTimelineP
            <*> optionalList (txtOption (long "alias" <> metavar "<別名>" <> help "可重複;給了就整組取代"))
            <*> optional sourceOptRaw
        )

entitySetBodyP :: Parser Command
entitySetBodyP =
  EntitySetBody
    <$> selectorArg "<實體>"
    <*> revisionP
    <*> bodyReqP

searchP :: Parser Command
searchP =
  EntitySearch
    <$> argument str (metavar "<關鍵詞>" <> help "FTS5 檢索;兩字以下的詞由 store 改走 LIKE")
    <*> filterP

linkP :: Parser Command
linkP =
  hsubparser
    ( cmd "add" linkAddP "加一筆關聯"
        <> cmd "rm" linkRmP "刪一筆關聯"
        <> cmd "list" (LinkList <$> selectorArg "<實體>") "正向與反向的關聯一次列完"
    )

linkAddP :: Parser Command
linkAddP =
  LinkAdd
    <$> selectorArg "<來源>"
    <*> revisionP
    <*> ( Link
            <$> kindOpt
            <*> targetOpt
            <*> optional (txtOption (long "note" <> metavar "<說明>" <> help "這條關聯的註記"))
        )

linkRmP :: Parser Command
linkRmP =
  LinkRm
    <$> selectorArg "<來源>"
    <*> revisionP
    <*> kindOpt
    <*> targetOpt

levelP :: Parser Command
levelP =
  hsubparser
    ( cmd "new" levelNewP "建一份新的 Level 檔(連同根 Node)"
        <> cmd "show" (LevelShow <$> selectorArg "<Level>") "印出場景樹"
        <> cmd "list" (LevelList <$> filterP) "列出 Level"
        <> cmd "rm" (LevelRm <$> selectorArg "<Level>" <*> revisionP <*> forceP) "刪除整份 Level"
    )

levelNewP :: Parser Command
levelNewP =
  LevelNew
    <$> ( NewLevelReq
            <$> titleOpt
            <*> summaryOpt
            <*> bodyTextOpt
            <*> txtOption (long "root-title" <> metavar "<標題>" <> help "根 Node 的標題")
            <*> nodeKindOpt "root-kind"
            <*> statusOpt
        )

nodeP :: Parser Command
nodeP =
  hsubparser
    ( cmd "add" nodeAddP "在父節點底下新增一個子節點"
        <> cmd "rm" (NodeRm <$> selectorArg "<節點>" <*> revisionP <*> forceP) "刪掉一個節點與它整棵子樹"
    )

nodeAddP :: Parser Command
nodeAddP =
  NodeAdd
    <$> selectorArg "<父節點>"
    <*> revisionP
    <*> ( NewNodeReq
            <$> titleOpt
            <*> nodeKindOpt "kind"
            <*> summaryOpt
            <*> bodyTextOpt
            <*> many linkOpt
        )

-- | @context@ 是__頂層名詞__(與 @search@ 同一種形狀),不是
-- @story-flow conflict context@ ——它是給外部 Agent 用的日常入口,而 @conflict@
-- 那個名詞底下放的是「做判斷」的那一組,目前只有 @check@ 一個動詞
-- (conflict-detection/F006)。
contextP :: Parser Command
contextP = Context <$> forP <*> many refOpt <*> contextOptsP

-- | @conflict@ 名詞群:目前只有 @check@。
conflictP :: Parser Command
conflictP = hsubparser (cmd "check" checkP "三層合流的衝突報告(第 3 層拿不到端點時退化成兩層)")

-- | @conflict check --draft \<檔案|-\>@:與 @context@ 同一種形狀,但草稿旗標是
-- @--draft@ 不是 @--for@(契約卡逐字寫的就是 @--draft@),而且五欄選項全開、
-- 多一個 @--no-llm@。
checkP :: Parser Command
checkP = ConflictCheck <$> draftP <*> many refOpt <*> checkOptsP <*> noLlmP

-- | @--draft@ __必填__,沒有預設:草稿要從哪裡來,猜不得。
--
-- @-@ 解成 'BodyStdin',其餘一律當檔案路徑——與 'forP' \/ @entity set-body@ 的
-- @-@ 同一條規則。
draftP :: Parser BodySource
draftP =
  toSource
    <$> strOption
      ( long "draft"
          <> metavar "<檔案|->"
          <> help "草稿的來源檔案(UTF-8);寫 - 就從 stdin 讀"
      )
  where
    toSource :: FilePath -> BodySource
    toSource "-" = BodyStdin
    toSource p = BodyFile p

noLlmP :: Parser Bool
noLlmP = switch (long "no-llm" <> help "這一次不跑第 3 層(語意判斷),報告退化成兩層")

-- | @--for@ __必填__,沒有預設:草稿要從哪裡來,猜不得。
--
-- @-@ 解成 'BodyStdin',其餘一律當檔案路徑——與 @entity set-body@ 的 @-@ 同一條
-- 規則,連 UTF-8 強制解碼與「讀不到檔」的錯誤訊息都沿用 'StoryFlow.Cli' 的
-- @readBody@。
forP :: Parser BodySource
forP =
  toSource
    <$> strOption
      ( long "for"
          <> metavar "<檔案|->"
          <> help "草稿的來源檔案(UTF-8);寫 - 就從 stdin 讀"
      )
  where
    toSource :: FilePath -> BodySource
    toSource "-" = BodyStdin
    toSource p = BodyFile p

-- | 草稿已經引用了哪些片段。__可重複,順序保留__。
--
-- 契約卡的 CLI 形式只寫了 @--for@,但第 1 層完全靠這個清單起步——沒有它,
-- @story-flow context@ 這條路的第 1 層永遠不會有輸出(見 F004 待確認假設 A1)。
refOpt :: Parser Id
refOpt =
  option
    (eitherReader (readWith (fmap snd . parseId) "id 的格式應為 <prefix>-<十六進位>,如 ent-7f3a"))
    ( long "ref"
        <> metavar "<id>"
        <> help "草稿已引用的片段 id,可重複;第 1 層由它起步"
    )

-- | @context@ 的三個數值旗標對應 'ConflictOpts' 的三欄,行為與拆分前的
-- @conflictOptsP@ 一字不變。
--
-- @coExpandBody@ / @coJudgeN@ __不開旗標__:兩者都是第 3 層(LLM)控制 token
-- 成本的手段,而 @context@ 根本不跑第 3 層,給它們沒有作用的旗標只會讓人以為
-- 有作用(@--judge-n@ / @--expand-body@ 由 F006 加在 @conflict check@ 上)。
contextOptsP :: Parser ConflictOpts
contextOptsP =
  ConflictOpts
    <$> topNOpt
    <*> pure (coJudgeN defaultConflictOpts)
    <*> pure (coExpandBody defaultConflictOpts)
    <*> timelineWindowOpt
    <*> graphDepthOpt

-- | @conflict check@ 的五欄選項:全部可調
-- (conflict-detection/F006 契約卡驗收標準 6)。
checkOptsP :: Parser ConflictOpts
checkOptsP =
  ConflictOpts
    <$> topNOpt
    <*> intOpt "judge-n" (coJudgeN defaultConflictOpts) "第 3 層的候選預算"
    <*> switch (long "expand-body" <> help "第 3 層展開 body 而非只送 summary")
    <*> timelineWindowOpt
    <*> graphDepthOpt

topNOpt :: Parser Int
topNOpt = intOpt "top-n" (coTopN defaultConflictOpts) "第 2 層的候選上限"

timelineWindowOpt :: Parser (Maybe Int)
timelineWindowOpt =
  optional
    ( option
        auto
        ( long "timeline-window"
            <> metavar "<n>"
            <> help "只保留 timeline order 與草稿引用片段相距 n 以內的候選;不給就不做時序過濾"
        )
    )

graphDepthOpt :: Parser Int
graphDepthOpt = intOpt "graph-depth" (coGraphDepth defaultConflictOpts) "第 1 層順 supersedes 反向遍歷的深度"

intOpt :: String -> Int -> String -> Parser Int
intOpt l d h = option auto (long l <> metavar "<n>" <> value d <> help (h <> ",預設 " <> show d))

-- 共用選項 ---------------------------------------------------------------------

txtOption :: Mod OptionFields Text -> Parser Text
txtOption = option str

titleOpt :: Parser Text
titleOpt = txtOption (long "title" <> metavar "<標題>" <> help "人類可讀的標題")

summaryOpt :: Parser Text
summaryOpt =
  txtOption (long "summary" <> metavar "<一句話總結>" <> help "衝突偵測與 AI 撈 context 時優先用它")
    <|> pure ""

-- | 只有字面正文的欄位(@level new@ \/ @node add@,規格沒有給它們 @--body-file@)。
bodyTextOpt :: Parser Text
bodyTextOpt = txtOption (long "body" <> metavar "<正文>") <|> pure ""

-- | 選配的正文來源;都沒給就是空正文。
bodyP :: Parser BodySource
bodyP = bodyLiteralOpt <|> bodyFileOpt <|> pure (BodyLiteral "")

-- | 必填的正文來源(@entity set-body@):三選一,少一個都不行。
bodyReqP :: Parser BodySource
bodyReqP = bodyLiteralOpt <|> bodyFileOpt <|> bodyStdinArg

bodyLiteralOpt :: Parser BodySource
bodyLiteralOpt = BodyLiteral <$> txtOption (long "body" <> metavar "<正文>" <> help "正文內容")

bodyFileOpt :: Parser BodySource
bodyFileOpt =
  BodyFile <$> strOption (long "body-file" <> metavar "<檔案>" <> help "從檔案讀取正文(UTF-8)")

bodyStdinArg :: Parser BodySource
bodyStdinArg = argument reader (metavar "-" <> help "從 stdin 讀取正文")
  where
    reader = eitherReader $ \case
      "-" -> Right BodyStdin
      _ -> Left "正文來源請用 --body / --body-file,或用 - 從 stdin 讀"

-- | @--type@ 照收字串。合法值來自型別註冊表,由 service 的 @UnknownType@ 擋。
typeOpt :: Parser Text
typeOpt =
  txtOption
    ( long "type"
        <> metavar "<型別>"
        <> help "型別註冊表裡的鍵;以 story-flow type list 查看可用型別"
    )

typeOptReq :: Parser Text
typeOptReq = typeOpt

statusOptRaw :: Parser Status
statusOptRaw =
  option
    (eitherReader (readWith parseStatus "狀態只能是 draft / canon / deprecated"))
    (long "status" <> metavar "<狀態>" <> help "draft | canon | deprecated")

statusOpt :: Parser Status
statusOpt = statusOptRaw <|> pure Draft

sourceOptRaw :: Parser Source
sourceOptRaw =
  option
    (eitherReader (readWith parseSource "來源只能是 human、agent:<名稱> 或 workshop:<型別>"))
    (long "source" <> metavar "<來源>" <> help "human | agent:<名稱> | workshop:<型別>")

sourceOpt :: Parser Source
sourceOpt = sourceOptRaw <|> pure Human

-- | @--kind@ __沒有驗證步驟__:'parseLinkKind' 是全函式,任何字串都是合法的關聯
-- (ADR-005)。CLI 能做的只有事後提示,那在 'StoryFlow.Cli' 裡。
kindOpt :: Parser LinkKind
kindOpt =
  parseLinkKind
    <$> txtOption
      ( long "kind"
          <> metavar "<關聯>"
          <> help ("核心關聯:" <> unwords (map (T.unpack . renderLinkKind) coreLinkKinds) <> ";其餘字串一律存為自訂關聯")
      )

targetOpt :: Parser Ref
targetOpt =
  option
    (eitherReader (readWith parseRef "目標格式應為 <id> 或 <vault>:<id>"))
    (long "target" <> metavar "<目標>" <> help "關聯指向的 id")

nodeKindOpt :: String -> Parser NodeKind
nodeKindOpt l =
  option
    (eitherReader (readWith parseNodeKind kindsHelp))
    (long l <> metavar "<kind>" <> help kindsHelp)
  where
    kindsHelp = "Node 種類:" <> unwords (map (T.unpack . renderNodeKind) allNodeKinds)

linkOpt :: Parser Link
linkOpt =
  option
    (eitherReader (parseLinkSpec . T.pack))
    ( long "link"
        <> metavar "<關聯>:<目標>[:<說明>]"
        <> help "可重複。只切前兩個冒號,其餘算進說明"
    )

revisionP :: Parser (Maybe Int)
revisionP =
  optional
    ( option
        auto
        ( long "revision"
            <> metavar "<n>"
            <> help "樂觀鎖的 expected revision;不給時 CLI 先讀一次取當前值"
        )
    )

forceP :: Parser Bool
forceP = switch (long "force" <> help "被別的實體指向時仍強制刪除")

timelineP :: Parser Timeline
timelineP =
  Timeline
    <$> optional (txtOption (long "timeline" <> metavar "<時間點>" <> help "故事內時間點,可模糊"))
    <*> optional (option auto (long "order" <> metavar "<n>" <> help "供排序的整數"))

-- | 兩個欄位都沒給時是 'Nothing' ——patch 的語意是「沒給就不動」,
-- 填一個空的 'Timeline' 進去會把原本的時間點抹掉。
maybeTimelineP :: Parser (Maybe Timeline)
maybeTimelineP = nonEmpty <$> timelineP
  where
    nonEmpty t = if isEmptyTimeline t then Nothing else Just t

-- | 可重複的選項在 patch 裡的語意:一次都沒給是 'Nothing'(不動),
-- 給了就是整組取代。
optionalList :: Parser a -> Parser (Maybe [a])
optionalList p = nonEmpty <$> many p
  where
    nonEmpty [] = Nothing
    nonEmpty xs = Just xs

filterP :: Parser EntityFilter
filterP =
  EntityFilter
    <$> optional typeOpt
    <*> optional statusOptRaw
    <*> optional (txtOption (long "tag" <> metavar "<標籤>"))
    <*> optional (option auto (long "limit" <> metavar "<n>" <> help "最多回幾筆"))

-- 讀取器 -----------------------------------------------------------------------

-- | core 的 @parse*@ 回的錯誤型別各不相同,而 optparse 要的是 'String'。
-- 一律換成寫給人看的一句話,比 @show@ 出建構子名有用。
readWith :: (Text -> Either e a) -> String -> String -> Either String a
readWith f msg s = either (const (Left msg)) Right (f (T.pack s))

-- | @\<kind\>:\<target\>[:\<note\>]@。
--
-- @entity new@ 常常要一次掛好幾條 @partOf@,所以有這個緊湊格式。
-- __只切前兩個冒號__:說明文字裡本來就會有冒號。代價是跨 Vault 的
-- @\<vault\>:\<id\>@ 目標在這個格式裡表達不了(會被讀成說明),而跨 Vault 的
-- 讀寫本來就還沒支援(service 的 @CrossVaultUnsupported@)。
parseLinkSpec :: Text -> Either String Link
parseLinkSpec raw = case T.splitOn ":" raw of
  (k : tgt : rest)
    | not (T.null k)
    , not (T.null tgt) ->
        case parseRef tgt of
          Right r -> Right (Link (parseLinkKind k) r (note rest))
          Left _ -> Left ("關聯目標「" <> T.unpack tgt <> "」不是合法的 id")
  _ -> Left "--link 的格式是 <關聯>:<目標>[:<說明>]"
  where
    note [] = Nothing
    note xs = Just (T.intercalate ":" xs)

-- | 引數符合 @\<prefix\>-\<hex\>@ 就當 id,否則當標題。
--
-- 使用者記得住的是「琳達」,不是 @ent-7f3a@。真正的比對在
-- "StoryFlow.Cli.Resolve" ——那裡才有索引可查。
mkSelector :: Text -> Selector
mkSelector t = case parseId t of
  Right (_, i) -> SelById i
  Left _ -> SelByTitle t

selectorArg :: String -> Parser Selector
selectorArg mv =
  mkSelector <$> argument str (metavar mv <> help "id 或標題;標題多筆命中時會列出候選")
