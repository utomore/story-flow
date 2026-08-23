-- | @story-flow@ 的進入點與子指令派送。
--
-- 這一層__不含任何業務判斷__。它只做四件事:解析引數、把引數轉成 service 的
-- 請求型別、呼叫後端、把結果 render 成文字或 JSON。任何「這樣做對不對」的判斷
-- 出現在這裡,就代表它應該在 @service@。
--
-- __內嵌與遠端在這個模組裡看不出差別__:'handle' 只認得 'Backend' 這個抽象與
-- "StoryFlow.Cli.Backend" 的那組操作,而渲染器只有一份。service-and-interfaces/F003 驗收標準 4
-- (兩種模式輸出完全相同)因此是結構上成立的,不是靠對照測試碰運氣——不過還是有
-- 一條對照測試守著(T15)。
--
-- 兩個設計選擇值得寫下來:
--
-- * 'runCli' 回 'ExitCode' 而不是自己 @exitWith@ ——測試才能在同一個行程裡跑完
--   整個指令,不必 @readProcess@
-- * 輸出走 'CliIO' 而不是直接寫 'stdout' \/ 'stderr' ——測試因此能把三個 handle
--   換成暫存檔,不必去動全域的標準輸出
module StoryFlow.Cli
  ( -- * 進入點
    runCli
  , runCliWith

    -- * 輸出去向
  , CliIO (..)
  , defaultCliIO
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (ToJSON (..), Value (..), fromJSON)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Options.Applicative (ParserResult (..), execCompletion, renderFailure)
import StoryFlow.Api (WorkshopStepResp (wssReply))
import StoryFlow.Cli.Backend
import StoryFlow.Cli.Doctor
import StoryFlow.Cli.Error
import StoryFlow.Cli.Options
import StoryFlow.Cli.Render
import StoryFlow.Cli.Resolve
import StoryFlow.Conflict.Json ()
import StoryFlow.Conflict.Types (Draft (..))
import StoryFlow.Core.Id (Id, renderId, renderRef)
import StoryFlow.Core.Link (Link (..), LinkKind, isCoreKind, renderLinkKind, suggestCoreKind)
import StoryFlow.Service
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.IO (Handle, hFlush, stderr, stdin, stdout)

-- 輸出去向 ---------------------------------------------------------------------

data CliIO = CliIO
  { cliOut :: Handle
  , cliErr :: Handle
  , cliIn :: Handle
  }

defaultCliIO :: CliIO
defaultCliIO = CliIO stdout stderr stdin

-- 進入點 -----------------------------------------------------------------------

runCli :: [String] -> IO ExitCode
runCli = runCliWith defaultCliIO

-- | 三種 optparse 結果各有一個出口。
--
-- __引數錯誤是 exit 2__,與業務錯誤的 exit 1 分開:腳本要能區分「我指令打錯了」
-- 與「工具告訴我這件事做不到」。@--help@ 走的是同一個 'Failure' 分支但
-- 'renderFailure' 回 'ExitSuccess',所以它印到 stdout 且 exit 0。
--
-- 引數錯誤__不走信封__:@--json@ 這個旗標本身可能就是打錯的那一個,
-- 這時候假裝解析成功地印一個 JSON 出來只會更難查。
runCliWith :: CliIO -> [String] -> IO ExitCode
runCliWith io args = case parseCli args of
  Success (g, c) -> dispatch io g c
  CompletionInvoked cr -> do
    msg <- execCompletion cr "story-flow"
    TIO.hPutStr (cliOut io) (T.pack msg)
    pure ExitSuccess
  Failure f -> case renderFailure f "story-flow" of
    (msg, ExitSuccess) -> TIO.hPutStrLn (cliOut io) (T.pack msg) >> pure ExitSuccess
    (msg, _) -> TIO.hPutStrLn (cliErr io) (T.pack msg) >> pure (ExitFailure 2)

-- 派送 -------------------------------------------------------------------------

-- | @vault init@ 與 @vault list@ 在內嵌模式不需要 'Env',所以它們不開後端就能跑;
-- 遠端模式則仍然要走 HTTP,因此它們吃的是 @Maybe Backend@。
dispatch :: CliIO -> GlobalOpts -> Command -> IO ExitCode
dispatch io g cmd = case cmd of
  VaultInit dir name | Nothing <- goRemote g -> direct (vaultCreated <$> createVaultB Nothing dir name)
  VaultList | Nothing <- goRemote g -> direct (listed <$> listVaultsB Nothing)
  -- G-E002:doctor 診斷的是這台機器,不走 Backend、不開索引;
  -- 退出碼不由 emit 決定——報告永遠印得出來,但註冊表找不到就是 1。
  Doctor
    | Just _ <- goRemote g -> emit io g (Left (CliUsage "doctor 診斷本機,不能與 --remote 併用"))
    | otherwise -> do
        cwd <- getCurrentDirectory
        r <- runDoctor (T.pack cliVersion) (goVault g) cwd
        _ <- emit io g (Right (plain (renderDoctor r) r))
        pure (if doctorPasses r then ExitSuccess else ExitFailure 1)
  _ -> withBackend g $ \case
    Left e -> emit io g (Left e)
    Right (b, issues) -> do
      mapM_ (warn io) issues
      emit io g =<< runM (handle io b cmd)
  where
    direct m = emit io g =<< runM m
    vaultCreated v = plain ("已建立 Vault " <> vvName v <> "(" <> T.pack (vvRoot v) <> ")") v
    listed vs = plain (renderVaults vs) vs

-- 指令 -------------------------------------------------------------------------

handle :: CliIO -> Backend -> Command -> M Out
handle io b = \case
  VaultInit dir name -> vaultCreated <$> createVaultB (Just b) dir name
  VaultList -> (\vs -> plain (renderVaults vs) vs) <$> listVaultsB (Just b)
  VaultInfo -> (\v -> plain (renderVaultInfo v) v) <$> vaultInfoB b
  IndexRebuild -> indexOut <$> reindexB b
  IndexRefresh -> indexOut <$> refreshIndexB b
  TypeList -> (\ts -> plain (renderTypes ts) ts) <$> listEntityTypesB b
  EntityNew req bs -> do
    body <- readBody io bs
    v <- createEntityB b req {nerBody = body}
    pure (viewOut (renderCreated "已建立" v) [] v)
  EntityAdd sel req bs -> do
    i <- resolveEntity b sel
    body <- readBody io bs
    v <- addFragmentB b i req {nfrBody = body}
    pure (viewOut (renderCreated "已新增片段" v) [] v)
  EntityShow sel -> do
    v <- getEntityB b =<< resolveEntity b sel
    pure (viewOut (renderEntity v) [] v)
  EntityList f -> (\ms -> plain (renderMetaTable ms) ms) <$> listEntitiesB b f
  EntitySearch q f -> (\hs -> plain (renderSearch hs) hs) <$> searchEntityB b q f
  EntitySet sel mrev p -> do
    (i, rev) <- entityTarget b sel mrev
    v <- updateEntityB b i rev p
    pure (viewOut (updated v) [] v)
  EntitySetBody sel mrev bs -> do
    (i, rev) <- entityTarget b sel mrev
    body <- readBody io bs
    v <- setEntityBodyB b i rev body
    pure (viewOut (updated v) [] v)
  EntityRm sel mrev force -> do
    (i, rev) <- entityTarget b sel mrev
    r <- deleteEntityB b i rev force
    pure (plain (renderDelete r) r)
  LinkAdd sel mrev l -> do
    (i, rev) <- entityTarget b sel mrev
    v <- addLinkB b i rev l
    let txt = "已加上關聯 " <> renderLinkKind (linkKind l) <> " → " <> renderRef (linkTarget l)
    pure (viewOut txt (kindHint (linkKind l)) v)
  LinkRm sel mrev k target -> do
    (i, rev) <- entityTarget b sel mrev
    v <- removeLinkB b i rev k target
    pure (viewOut ("已移除關聯 " <> renderLinkKind k <> " → " <> renderRef target) [] v)
  LinkList sel -> do
    r <- linksOfB b =<< resolveEntity b sel
    pure (plain (renderLinks r) r)
  LevelNew req -> do
    v <- createLevelB b req
    pure (plain ("已建立 Level " <> renderId (lvId v) <> "(" <> T.pack (lvPath v) <> ")") v)
  LevelShow sel -> do
    v <- getLevelB b =<< resolveLevel b sel
    pure (plain (renderLevelTree v) v)
  LevelList f -> (\ms -> plain (renderMetaTable ms) ms) <$> listLevelsB b f
  LevelRm sel mrev force -> do
    i <- resolveLevel b sel
    rev <- maybe (currentRevision b i) pure mrev
    r <- deleteLevelB b i rev force
    pure (plain (renderDelete r) r)
  NodeAdd sel mrev req -> do
    (lvl, parent) <- resolveNode b sel
    rev <- levelRevision b lvl mrev
    v <- addNodeB b lvl parent rev req
    pure (plain ("已新增節點於 " <> renderId parent <> "(Level " <> renderId (lvId v) <> ")") v)
  NodeRm sel mrev force -> do
    (lvl, node) <- resolveNode b sel
    rev <- levelRevision b lvl mrev
    v <- removeNodeB b lvl node rev force
    pure (plain ("已刪除節點 " <> renderId node <> " 與它的子樹") v)
  -- --for 走既有的 readBody:UTF-8 強制解碼與「讀不到檔」的訊息都與
  -- entity set-body 同一份。--ref 原樣進 drRefs,不在 CLI 這一層解析或驗證
  -- ——不存在的 id 由第 1 層在圖上查不到、第 2 層 catchError 吞掉。
  Context bs refs copts -> do
    txt <- readBody io bs
    hs <- gatherContextB b copts (Draft txt refs)
    pure (plain (renderContext hs) hs)
  -- --draft 走既有的 readBody(entity set-body / context --for 同一份);--no-llm
  -- 決定 acquireJudge 讀不讀 [llm] 設定,不是 ConflictOpts 的欄位(見
  -- StoryFlow.Cli.Options 的 F006 註解)。exit code 恆為 0:這是一份報告,不是
  -- 一個判定,命中是不是真的衝突由作者決定。
  ConflictCheck bs refs copts noLlm -> do
    txt <- readBody io bs
    report <- checkConflictB b noLlm copts (Draft txt refs)
    pure (plain (renderReport report) report)
  -- workshop start 把 session id 印出來(人類模式的一行文字裡含 wsId,--json
  -- 模式下 data 就是完整的 Session,data.id 自然帶著它)——否則使用者沒東西
  -- 餵給 workshop step。
  WorkshopStart ty cs -> do
    s <- startWorkshopB b ty cs
    pure (plain (renderWorkshopStarted s) s)
  -- step 的人類輸出就是 wssReply 本身(給人看的那段模型回覆),不另外包裝;
  -- --json 的 data 需要 session 與 reply 一起交出去,所以整個 WorkshopStepResp
  -- 進 outJson。
  WorkshopStep sid bs -> do
    input <- readBody io bs
    r <- stepWorkshopB b sid input
    pure (Out (wssReply r) [] (toJSON r))
  WorkshopCommit sid -> do
    r <- commitStageB b sid
    pure (plain (renderWorkshopCommit r) r)
  -- dispatch 在進 Backend 之前就攔下 Doctor;這一支只為了讓 pattern 完整
  Doctor -> throwError (CliUsage "doctor 不走 Backend")
  where
    vaultCreated v = plain ("已建立 Vault " <> vvName v <> "(" <> T.pack (vvRoot v) <> ")") v
    updated v = "已更新 " <> renderId (evId v) <> "(revision " <> tshow (evRevision v) <> ")"
    indexOut r = Out (renderIndexReport r) (irIssues r) (toJSON r)

-- | 樂觀鎖的 expected revision:給了 @--revision@ 就照用,沒給就__先讀一次__。
--
-- 人用起來是「改一欄就改一欄」,不必先查數字;腳本與 AI Agent 要真樂觀鎖時帶
-- @--revision@ ——它們手上本來就有上一次讀到的值。
entityTarget :: Backend -> Selector -> Maybe Int -> M (Id, Int)
entityTarget b sel mrev = do
  i <- resolveEntity b sel
  rev <- maybe (currentRevision b i) pure mrev
  pure (i, rev)

-- | 非核心關聯的提示。
--
-- __提示不是阻擋__:'StoryFlow.Core.Link.parseLinkKind' 是全函式,自訂關聯一律
-- 合法(ADR-005),而打錯字與刻意自訂在字串層面無法區分——擋下來會擋到合法用法。
kindHint :: LinkKind -> [Text]
kindHint k
  | isCoreKind k = []
  | otherwise = case suggestCoreKind (renderLinkKind k) of
      Nothing -> []
      Just s ->
        [ "「"
            <> renderLinkKind k
            <> "」不是核心關聯,你是不是要打「"
            <> renderLinkKind s
            <> "」?已照原樣存為自訂關聯"
        ]

-- 正文來源 ---------------------------------------------------------------------

-- | 一律以 UTF-8 解讀,不看系統預設編碼:Vault 的內容是繁中,而 Windows 的
-- 預設 code page 會在讀到第一個中文字時就丟 @InvalidArgument@。
readBody :: CliIO -> BodySource -> M Text
readBody _ (BodyLiteral t) = pure t
readBody _ (BodyFile p) = readUtf8 ("讀不到 " <> T.pack p) (BS.readFile p)
readBody io BodyStdin = readUtf8 "從 stdin 讀不到正文" (BS.hGetContents (cliIn io))

readUtf8 :: Text -> IO BS.ByteString -> M Text
readUtf8 what act =
  liftIO (try act) >>= \case
    Right bs -> pure (TE.decodeUtf8 bs)
    Left e -> throw (CliInput (what <> ":" <> T.pack (show (e :: IOException))))

-- 輸出 -------------------------------------------------------------------------

-- | 一個子指令的產物:人類模式的文字、要進 stderr 的警告、@--json@ 的 @data@。
--
-- 三者一起帶而不是分兩條路走完,是為了讓 'emit' 只有一份——兩種模式各寫一次
-- 派送,就會有子指令只在其中一種模式下被記得。
data Out = Out
  { outText :: Text
  , outWarnings :: [Text]
  , outJson :: Value
  }

plain :: (ToJSON a) => Text -> a -> Out
plain t a = Out t [] (toJSON a)

-- | 'EntityView' 的產物。
--
-- @extra@ 是 CLI 這一層才知道的提示(例如非核心關聯),它__同時__進 stderr
-- 與 @data.warnings@ ——規格說「@--json@ 模式下警告在 @data@ 的 @warnings@
-- 欄位裡」,而 View 自己的 @warnings@ 已經在 JSON 裡了。
viewOut :: Text -> [Text] -> EntityView -> Out
viewOut t extra v = Out t (evWarnings v ++ extra) (addWarnings extra (toJSON v))

addWarnings :: [Text] -> Value -> Value
addWarnings [] v = v
addWarnings ws (Object o) = Object (KM.insert "warnings" (toJSON (cur ++ ws)) o)
  where
    cur = case KM.lookup "warnings" o of
      Just x -> case fromJSON x of
        A.Success ts -> ts
        _ -> []
      Nothing -> [] :: [Text]
addWarnings _ v = v

-- | 兩種模式的唯一出口。
--
-- @--json@:成功與失敗都是__一個__ JSON 物件、都到 stdout。
-- 人類模式:結果到 stdout,警告與錯誤到 stderr——警告不該混進管線。
emit :: CliIO -> GlobalOpts -> Either CliError Out -> IO ExitCode
emit io g r
  | goJson g = case r of
      Right o -> jsonLine (cliOut io) (encodeEnvelope (Ok (outJson o))) >> pure ExitSuccess
      Left e -> jsonLine (cliOut io) (encodeEnvelope (errEnvelope e)) >> pure (failCode e)
  | otherwise = case r of
      Right o -> do
        mapM_ (warn io) (outWarnings o)
        unless (T.null (outText o)) (line (cliOut io) (outText o))
        pure ExitSuccess
      Left e -> do
        line (cliErr io) ("錯誤(" <> cliErrorCode e <> "):" <> cliErrorMessage e)
        pure (failCode e)
  where
    errEnvelope e = Err (cliErrorCode e) (cliErrorMessage e) :: Envelope Value

-- | 用法錯誤 exit 2,業務與傳輸失敗 exit 1。
failCode :: CliError -> ExitCode
failCode e = ExitFailure (if isUsageError e then 2 else 1)

warn :: CliIO -> Text -> IO ()
warn io t = line (cliErr io) ("警告:" <> t)

-- | 人類可讀的輸出走 handle 自己的編碼:Windows 主控台是 cp950 時,繁中要交給
-- 它的 codec 才顯示得出來。
line :: Handle -> Text -> IO ()
line = TIO.hPutStrLn

-- | @--json@ 的那一行__一律寫成 UTF-8 位元組__,繞過 handle 的 codec。
--
-- 理由是 Windows:輸出被導進管線或檔案時,GHC 用的是系統的 ANSI code page
-- (開發機是 cp950),於是 @story-flow --json entity show 琳達 | jq@ 拿到的
-- 就不是合法的 UTF-8 JSON。信封是給機器讀的,編碼不能跟著主控台的設定跑。
jsonLine :: Handle -> Text -> IO ()
jsonLine h t = do
  hFlush h
  BS.hPut h (TE.encodeUtf8 t <> "\n")
  hFlush h

tshow :: (Show a) => a -> Text
tshow = T.pack . show
