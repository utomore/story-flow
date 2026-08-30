-- | 執行環境與 'ServiceM'(design.md「內部模組劃分」的 Monad;契約 A)。
--
-- 擁有的事實(唯一真相來源):__一次執行期間的資源生命週期__——中樞快照、型別
-- 註冊表、selector、起點目錄、vault handle 快取,以及保護它們的那把__全域一把__
-- 互斥鎖。
--
-- == 'Env' 為什麼是不透明型別
--
-- 'Env' 的建構子與欄位__不匯出__(與 @aapms-workspace@ 的 'Hub' 同一個道理):
-- 中樞快照、註冊表、註冊表來源三者之間有「同一次 'openEnv' 載入」的不變量,允許
-- 外部逐欄拼裝就是允許拼出不一致的執行環境;而 handle 快取與鎖是可變狀態,直接
-- 露出欄位等於把「誰負責拿鎖」這件事交給呼叫端記得。建構走 'openEnv',讀取走
-- 下面那組 @ask*@,handle 走 'handleFor'。
--
-- design.md 契約 A 把 'Env' 寫成沒有欄位的 @data Env@,而同一份文件裡每一個
-- __要露欄位__的型別('NodeView' \/ 'VaultView' \/ 'DoctorView' …)都逐欄列了
-- 出來——這個寫法差異就是「不透明」的意思。
--
-- == 鎖在 'runService' 上
--
-- 三件事都靠這一把鎖(design.md 契約 A):@sqlite-simple@ 的 @Connection@ 不保證
-- 多執行緒安全而 warp 是多執行緒的;handle 快取本身是可變狀態;「先寫檔、再更新
-- 索引」這條紀律在__請求之間__也要是原子的。因此鎖不在 'handleFor'、不在各操作,
-- 而在 'runService' ——一次 'runService' 就是一個臨界區。
--
-- 代價已知且是刻意的:兩個 'runService' 恒不重疊,__巢狀呼叫 'runService' 會
-- 死結__。契約沒有任何一條需要巢狀(每條資料流管線裡 'Env' 只被建立一次,操作
-- 也只跑一次 'runService'),所以不為它付執行期偵測的成本。
--
-- __明確不做__(契約卡):不實作任何業務操作(F002 起);不做業務驗證(F004);
-- 不決定 HTTP 狀態碼(@shell@)。本模組也__不__自己解讀 selector ——那是
-- @aapms-workspace@ 的裁決,'Env' 只是原樣捧著。
module Aapms.Service.Monad
  ( -- * 契約 A:執行環境
    Env
  , ServiceM
  , openEnv
  , runService
  , closeEnv
  , withEnv

    -- * 'Env' 內容的存取(模組間公開介面:Scope \/ Machine \/ Read \/ Write → Monad)
  , askHubLocation
  , askHub
  , reloadHub
  , askRegistry
  , askNaming
  , askRegistrySource
  , askSelector
  , askCwd

    -- * handle 快取(模組間公開介面:Scope → Monad)
  , handleFor
  , indexIssuesFor

    -- * 錯誤(模組間公開介面:全部模組 → Monad)
  , throwService
  , liftStore
  , liftWorkspace

    -- * 收尾(模組間公開介面:Scope 與 F002 起的全部模組 → Monad)
  , finallyService
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (finally)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Aapms.Core.Id (VaultId)
import Aapms.Core.Naming (NamingVocab)
import Aapms.Core.Registry (TypeRegistry)
import Aapms.Store.Error (StoreError)
import Aapms.Store.Marker (VaultHandle, VaultMarker (vmId), closeVault, openVault)
import Aapms.Store.Schema (IndexIssue)
import Aapms.Types.Loader (RegistrySource, loadRegistry, locateRegistry)
import Aapms.Workspace.Hub (loadHub)
import Aapms.Workspace.Location (hubLocation)
import Aapms.Workspace.Types (Hub, HubLocation, VaultRef (vrMarker, vrPath), WorkspaceError)

import Aapms.Service.Types (ServiceError (..))

-- | 一次執行期間的全部資源:中樞快照 + 型別註冊表 + selector + 起點目錄 +
-- handle 快取 + 全域鎖(design.md 契約 A)。
--
-- __建構子與欄位不匯出__,理由見模組說明。
data Env = Env
  { envHubLocation :: HubLocation
  -- ^ 中樞根目錄與「這個位置怎麼決定的」;'Aapms.Workspace.Location.hubLocation'
  -- 在 'openEnv' 解析一次,之後不再變。@doctor@ 的 @dvHubPath@ \/ @dvHubSource@
  -- 兩欄的來源。
  , envHubRef :: IORef Hub
  -- ^ 中樞快照。__可變__:'Aapms.Workspace.Hub.saveHub' 之後必須重新載入
  -- (design.md 模組間公開介面 Machine → @aapms-workspace@ 那一列),因為 'Hub'
  -- 是不可變值,寫回檔案不會改到手上這一份。
  , envRegistry :: TypeRegistry
  -- ^ 型別註冊表。'openEnv' 載入一次,__不可變__:型別宣告在一次執行期間不會變。
  , envNaming :: NamingVocab
  -- ^ 命名文法詞彙表。與 'envRegistry' 是 'Aapms.Types.Loader.loadRegistry'
  -- __同一次呼叫__的兩個回傳值,拆開存會允許兩者來自不同次載入。
  , envRegistrySource :: RegistrySource
  -- ^ 註冊表是從三層定位的哪一層找到的;@doctor@ 的 @dvRegistry@ 欄的來源。
  , envSelector :: Maybe Text
  -- ^ @--vault@ 的原始字串,__本層不解讀__(design.md「明確不做 › 參數解析」);
  -- 原樣交給 @aapms-workspace@ 的三個裁決函式。
  , envCwd :: FilePath
  -- ^ 向上探測的起點,絕對路徑;'Aapms.Workspace.Scope.resolveWrite' 的第三參數。
  , envHandles :: IORef (Map VaultId VaultHandle)
  -- ^ handle 快取。鍵是 marker 的 'VaultId'(__不是路徑__:ADR-017 說 vault 的
  -- 身分就是 marker 裡的 id)。'openEnv' 之後為空,'closeEnv' 一次全關。
  , envIndexIssues :: IORef (Map VaultId [IndexIssue])
  -- ^ 每個 vault __第一次__被 'handleFor' 開啟時,
  -- 'Aapms.Store.Marker.openVault' 一併回的 'IndexIssue' 清單。存起來是因為
  -- 'handleFor' 的第二次呼叫走快取、不會再產生這份清單,而 @vaultInfo@ 的
  -- @viIssues@ 欄(F002)要得到它。
  , envLock :: MVar ()
  -- ^ __全域一把__互斥鎖(不是每個 vault 一把,design.md 不可逆決定第二列)。
  -- 'runService' 全程持有。
  }

-- | 業務操作的執行 monad(design.md 契約 A)。
--
-- @ReaderT 'Env' + ExceptT 'ServiceError'@(design.md「使用的技術」):業務操作是
-- __組合__的,手工串 @Either@ 會讓每個函式的主體被 @case@ 淹沒。
--
-- 匯出的是型別本身,__不是建構子__:能執行它的只有 'runService',而 'runService'
-- 是唯一拿鎖的地方。露出建構子等於露出一條繞過鎖的路。
--
-- __實例只有這四個,不得再加__(LAW-25 以原始碼文字靜態守住):類別方法__不進匯出
-- 清單__,所以多 derive 一個實例就是多一條沒有登記在 design.md 介面表上的對外
-- API——任何 import 本模組的模組都會自動拿到它的方法。需要攔截短路的能力時,走
-- 'finallyService' 這個__範圍受控的組合子__,而不是 @MonadError@ 實例。
newtype ServiceM a = ServiceM (ReaderT Env (ExceptT ServiceError IO) a)
  deriving newtype (Functor, Applicative, Monad, MonadIO)

-- | 私有:取出目前的 'Env'。不匯出——存取一律經下面那組 @ask*@。
askEnv :: ServiceM Env
askEnv = ServiceM ask

-- | 建立執行環境:解析中樞位置 → 載入中樞 → 定位並載入型別註冊表。
--
-- 第一參數是 @--vault@ 的 selector(@Nothing@ = 沒給);第二參數是向上探測的
-- 起點,通常是行程的當前目錄。
--
-- __不開任何 vault 索引__(與 legacy 相反):索引在第一個真的需要它的操作上才由
-- 'handleFor' 開,開過就留在快取裡。
--
-- 中樞載不起來或註冊表載不起來時回 @Left@,__不退回一個空的 'Env'__
-- (system.md 全域錯誤策略第 3 條)。
openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError Env)
openEnv sel cwd = do
  loc <- hubLocation
  hubR <- loadHub loc
  case hubR of
    Left e -> pure (Left (WorkspaceFailed e))
    Right hub -> do
      locR <- locateRegistry
      case locR of
        Left e -> pure (Left (RegistryUnavailable e))
        Right (dir, src) -> do
          regR <- loadRegistry dir
          case regR of
            Left e -> pure (Left (RegistryLoadFailed e))
            Right (registry, naming) -> do
              hubRef <- newIORef hub
              handlesRef <- newIORef Map.empty
              issuesRef <- newIORef Map.empty
              lock <- newMVar ()
              pure $
                Right
                  Env
                    { envHubLocation = loc
                    , envHubRef = hubRef
                    , envRegistry = registry
                    , envNaming = naming
                    , envRegistrySource = src
                    , envSelector = sel
                    , envCwd = cwd
                    , envHandles = handlesRef
                    , envIndexIssues = issuesRef
                    , envLock = lock
                    }

-- | 在一個 'Env' 上跑一段業務操作,__全程持有 'envLock'__。
--
-- 兩個並發的 'runService' 因此恒不交錯:handle 快取的讀寫、SQLite 連線的使用、
-- 以及「先寫檔、再更新索引」這一整段,在請求之間都是原子的。
--
-- __不__關閉任何 handle:handle 的生命週期屬 'Env',由 'closeEnv' 收。
runService :: Env -> ServiceM a -> IO (Either ServiceError a)
runService env (ServiceM action) =
  withMVar (envLock env) (\_ -> runExceptT (runReaderT action env))

-- | 關閉這個 'Env' 開過的__全部__ vault handle 並清空快取。
--
-- 冪等:對同一個 'Env' 呼叫第二次是 no-op。Windows 上 @index.db@ 只要還有連線
-- 沒關就刪不掉,而 'withEnv' 的例外路徑與呼叫端的顯式 'closeEnv' 都可能走到,
-- 不冪等就會變成「第二次呼叫對已關的連線再關一次」。
closeEnv :: Env -> IO ()
closeEnv env = do
  handles <- readIORef (envHandles env)
  mapM_ closeVault (Map.elems handles)
  writeIORef (envHandles env) Map.empty
  writeIORef (envIndexIssues env) Map.empty

-- | 'openEnv' 與 'closeEnv' 的成對包裝:'openEnv' 成功才跑第三參數,結束時
-- (含例外路徑)必定 'closeEnv'。
--
-- 'openEnv' 失敗時第三參數__不被呼叫__,直接把 @Left@ 傳出去。
withEnv :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)
withEnv sel cwd f = do
  envR <- openEnv sel cwd
  case envR of
    Left e -> pure (Left e)
    Right env -> Right <$> (f env `finally` closeEnv env)

-- | 中樞根目錄與它的來源。一次執行期間不變。
askHubLocation :: ServiceM HubLocation
askHubLocation = envHubLocation <$> askEnv

-- | 目前的中樞快照。
askHub :: ServiceM Hub
askHub = do
  env <- askEnv
  liftIO (readIORef (envHubRef env))

-- | 從磁碟重新載入中樞、換掉快照,並回傳新的那一份。
--
-- 寫中樞的操作(@vault init@ \/ @add@ \/ @forget@ \/ @project register@ \/
-- @forget@,F002)之後必須呼叫,否則同一個 'Env' 的後續 'askHub' 看到的是舊值。
--
-- 載入失敗時以 'WorkspaceFailed' 短路——中樞剛被自己寫過卻讀不回來,是硬錯誤。
reloadHub :: ServiceM Hub
reloadHub = do
  env <- askEnv
  hubR <- liftIO (loadHub (envHubLocation env))
  case hubR of
    Left e -> throwService (WorkspaceFailed e)
    Right hub -> do
      liftIO (writeIORef (envHubRef env) hub)
      pure hub

-- | 型別註冊表。
askRegistry :: ServiceM TypeRegistry
askRegistry = envRegistry <$> askEnv

-- | 命名文法詞彙表(與 'askRegistry' 來自同一次載入)。
askNaming :: ServiceM NamingVocab
askNaming = envNaming <$> askEnv

-- | 註冊表是從三層定位的哪一層找到的。
askRegistrySource :: ServiceM RegistrySource
askRegistrySource = envRegistrySource <$> askEnv

-- | @--vault@ 的原始字串,未經解讀。
askSelector :: ServiceM (Maybe Text)
askSelector = envSelector <$> askEnv

-- | 向上探測的起點(絕對路徑)。
askCwd :: ServiceM FilePath
askCwd = envCwd <$> askEnv

-- | 取得一個 vault 的 handle:先查快取,沒有才開,開好放回快取。
--
-- __這是本套件唯一開 vault handle 的地方__(design.md 模組間公開介面
-- Scope → Monad 那一列)。多一個開法就多一條不會進快取、也不會被 'closeEnv'
-- 關掉的洩漏路徑。
--
-- 同一個 'VaultRef' 的第二次呼叫回__同一個__ handle,不再碰檔案系統。開啟失敗
-- 以 'StoreFailed' 短路。
handleFor :: VaultRef -> ServiceM VaultHandle
handleFor ref = do
  env <- askEnv
  let vid = vmId (vrMarker ref)
  cache <- liftIO (readIORef (envHandles env))
  case Map.lookup vid cache of
    Just h -> pure h
    Nothing -> do
      r <- liftIO (openVault (envRegistry env) (vrPath ref))
      case r of
        Left e -> throwService (StoreFailed e)
        Right (h, issues) -> do
          liftIO (modifyIORef' (envHandles env) (Map.insert vid h))
          liftIO (modifyIORef' (envIndexIssues env) (Map.insert vid issues))
          pure h

-- | 某個 vault __第一次__被 'handleFor' 開啟時一併回的 'IndexIssue' 清單。
--
-- 這個 vault 在本次執行期間還沒被開過時回空清單——「沒開過」與「開過但沒有問題」
-- 從這個出口看不出差別,而呼叫端(@vaultInfo@)本來就會先讓它被開起來。
indexIssuesFor :: VaultId -> ServiceM [IndexIssue]
indexIssuesFor vid = do
  env <- askEnv
  issues <- liftIO (readIORef (envIndexIssues env))
  pure (Map.findWithDefault [] vid issues)

-- | 以一個 'ServiceError' 短路目前的 'ServiceM'。
throwService :: ServiceError -> ServiceM a
throwService e = ServiceM (throwError e)

-- | 跑一個 graph-core 的 IO 動作,@Left@ 原樣包成 'StoreFailed' 後短路。
liftStore :: IO (Either StoreError a) -> ServiceM a
liftStore action = do
  r <- liftIO action
  either (throwService . StoreFailed) pure r

-- | 跑一個 @aapms-workspace@ 的 IO 動作,@Left@ 原樣包成 'WorkspaceFailed'
-- 後短路。
liftWorkspace :: IO (Either WorkspaceError a) -> ServiceM a
liftWorkspace action = do
  r <- liftIO action
  either (throwService . WorkspaceFailed) pure r

-- | 收尾組合子:@finallyService 動作 收尾@。
--
-- 跑第一個動作;無論它__正常結束__、以 'throwService' __短路__、還是拋出 IO
-- 例外,第二個動作都__恰好被執行一次__,然後第一個動作的結果__原樣__傳出——
-- 短路原樣再短路,例外原樣重拋。第二個動作的回傳值被丟棄。
--
-- 參數順序與語意對齊 'Control.Exception.finally'。
--
-- __為什麼是一個組合子,而不是給 'ServiceM' 一個 @MonadError@ 實例__:
-- 'Aapms.Service.Scope' 的三個 @with*@ 要保證
-- 'Aapms.Store.MultiVault.VaultSet' 在第一參數結束時(含短路路徑)被關掉,而那
-- 需要攔截短路的能力。derive 一個實例辦得到,但類別方法__不進匯出清單__:每一個
-- import 本模組的模組都會自動拿到 @catchError@ 與一條繞過 'throwService' 的
-- 拋出路徑,那是沒有登記在 design.md「模組間公開介面」表上的對外 API,也讓
-- 'ServiceM' 不再是不透明型別(本 feature 不可逆決定第一列)。本組合子把那個能力
-- __收斂成一個登記過的名字__:拆 'ServiceM' 的 newtype 這件事只發生在本模組內部。
finallyService :: ServiceM a -> ServiceM b -> ServiceM a
finallyService (ServiceM act) (ServiceM cleanup) = ServiceM $ do
  env <- ask
  result <-
    liftIO $
      runExceptT (runReaderT act env)
        `finally` runExceptT (runReaderT cleanup env)
  either throwError pure result
