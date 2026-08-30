-- | vault 的建立、納管、撤除、體檢與清理(design.md「內部模組劃分」的 Lifecycle)。
--
-- 擁有的事實(唯一真相來源):__撤除的分層界線__——什麼能刪、什麼絕不刪。
-- ADR-017 決策五的三條硬性約束在本模組被實體化:
--
-- 1. __任何情況下不碰 @library\/@、不碰任何 @.md@__。它們是真相,不是衍生物。
-- 2. @vault forget@ 預設__只動中樞__;vault 目錄原封不動,搬到另一台機器
--    @vault add@ 就能繼續用。
-- 3. 中樞的寫入只__追加一列或刪整列__;既有列的相對順序、使用者寫的註解與空白行
--    原樣保留——這靠 'Aapms.Workspace.Hub.saveHub' 以 @hubSourceText@ 為底稿收斂
--    差異達成,本模組只對 'Aapms.Workspace.Types.Hub' 值做純增刪。
--
-- __vault 的身分不屬於本模組__:@id@ \/ @kind@ \/ @name@ \/ @refs@ 屬各 vault 的
-- marker。新 id 由 graph-core 的 @Aapms.Store.Marker.initVaultAt@ 產生,既有 marker
-- 的重讀一律經 'Aapms.Workspace.Discovery'(本模組不自己呼叫 @readMarker@)。
--
-- __明確不做__(契約卡):不解析 vault 內的任何 Markdown、不開索引、不重建索引;
-- 不刪除舊的 @.assetdb\/@ 或 @.storyflow\/@(只報告);不做 @vault info@ 的統計
-- (那要索引,屬 @service@ 組合)。另外兩條由「明確不做」推出來的硬界線:本模組
-- __不執行任何外部程式__(那是 F006),也__不自己寫任何檔案文字__——落地只經
-- 'Aapms.Workspace.Hub.saveHub'(中樞)與 @initVaultAt@(marker + 空索引)。
module Aapms.Workspace.Lifecycle
  ( -- * 中樞的建立
    setupHub

    -- * vault 的建立與納管
  , initVault
  , initVaultWith
  , addVault

    -- * 撤除
  , forgetVault
  , purge

    -- * 體檢與回寫
  , checkVaults
  , syncHub
  ) where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, initVaultAtWith, markerDir, readMarker)
import Aapms.Store.Schema (VaultKind)
import Aapms.Workspace.Discovery (lookupSelector, readVaultRef, readVaultRefAt)
import Aapms.Workspace.Hub (hubVaults, removeVault, saveHub, upsertVault)
import Aapms.Workspace.Location (configPath, thumbCacheDir)
import Aapms.Workspace.Types
  ( AdoptNotice (..)
  , DeleteIndex (..)
  , Hub
  , HubLocation (..)
  , InitMode (..)
  , PurgeReport (..)
  , PurgeScope (..)
  , ScopeIssue
  , SetupReport (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , VaultRef (vrMarker)
  , WorkspaceError (..)
  , mkHub
  )
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  , removePathForcibly
  )
import System.FilePath ((</>))

-- 中樞的建立 -------------------------------------------------------------------

-- | 建立中樞目錄骨架:@\<hlPath\>\/config.toml@ 與 @\<hlPath\>\/cache\/thumbs\/@。
-- __冪等__:同一個位置跑第二次不會改變任何位元組。
--
-- * @config.toml@ 不存在 → 寫出一份空中樞(經 'Aapms.Workspace.Hub.saveHub',
--   中樞的檔案格式只有 @Hub@ 知道),
--   @'Aapms.Workspace.Types.spHubCreated' == True@
-- * @config.toml@ 已存在 → __完全不碰、不解析__(壞掉的檔案也不動),
--   @spHubCreated == False@;本函式因此不會回 @HubUnreadable@ \/ @HubMalformed@
-- * @cache\/thumbs\/@ 同理,由 @'Aapms.Workspace.Types.spCacheCreated'@ 區分
--
-- @'Aapms.Workspace.Types.spHubPath'@ 是__中樞根目錄__(等於
-- @'Aapms.Workspace.Types.hlPath'@),不是 @config.toml@ 的路徑——契約 A 已規定
-- @hlPath@ 指向目錄。
--
-- 落地失敗(目錄建不出來、檔案寫不進去)一律回
-- @Left ('Aapms.Workspace.Types.HubWriteFailed' 失敗的那個路徑 原因)@。
setupHub :: HubLocation -> IO (Either WorkspaceError SetupReport)
setupHub loc = do
  let fp = configPath loc
      td = thumbCacheDir loc
      hp = hlPath loc
  hubExisted <- doesFileExist fp
  cacheExisted <- doesDirectoryExist td
  result <-
    chainE
      [ if hubExisted
          then pure (Right ())
          else do
            mkR <- tryIO hp (createDirectoryIfMissing True hp)
            case mkR of
              Left e -> pure (Left e)
              Right () -> saveHub loc (mkHub [] [] Nothing (ToolsConfig Nothing) "")
      , if cacheExisted
          then pure (Right ())
          else tryIO td (createDirectoryIfMissing True td)
      ]
  pure $
    fmap
      (const (SetupReport hp (not hubExisted) (not cacheExisted)))
      result

-- vault 的建立與納管 -----------------------------------------------------------

-- | 在一個目錄上建立 vault 並登錄進中樞(生命週期管線全段)。
--
-- 參數依序是:中樞位置、已載入的中樞、vault 根目錄(絕對或相對,內部正規化為
-- 絕對)、@kind@(__必填,不猜__;ADR-017 決策一)、名稱、
-- 'Aapms.Workspace.Types.InitMode'。
--
-- 前置檢查__依序__判定,任一條成立即回對應的 @Left@ 且__一個位元組都不寫__:
--
-- 1. 名稱去空白後為空 → 'Aapms.Workspace.Types.InvalidName'(帶__原始__字串)
-- 2. 目標目錄已有 @.aapms\/@ → 'Aapms.Workspace.Types.VaultAlreadyInitialized'
--    ——__兩種 'Aapms.Workspace.Types.InitMode' 都一樣__,且不覆寫該檔
-- 3. 'Aapms.Workspace.Types.FreshVault':目錄存在且非空 →
--    'Aapms.Workspace.Types.VaultDirNotEmpty';不存在時由本函式建立
-- 4. 'Aapms.Workspace.Types.AdoptExisting':目錄不存在 →
--    'Aapms.Workspace.Types.VaultDirMissing';存在時內容__一律不動__
--
-- 通過之後:@initVaultAt@(寫 marker + 建空索引)→ 新 id 與中樞既有的
-- @veId@ 比對,撞號回 'Aapms.Workspace.Types.VaultIdCollision' 並__把剛寫出的
-- @.aapms\/@ 回滾__(否則錯誤訊息要求的「重跑一次」會被
-- @VaultAlreadyInitialized@ 擋住)→ 掃 @.assetdb\/@ \/ @.storyflow\/@ 成
-- 'Aapms.Workspace.Types.AdoptNotice'(__只報告不刪除__)→ 對 'Hub' 值追加一列 →
-- 'Aapms.Workspace.Hub.saveHub' 原子寫回。
--
-- 回傳的 'Aapms.Workspace.Types.VaultEntry' 逐欄來自 marker(中樞是快取,marker
-- 是真相),@vePath@ 是正規化後的絕對路徑。
initVault
  :: HubLocation
  -> Hub
  -> FilePath
  -> VaultKind
  -> Text
  -> InitMode
  -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
initVault loc hub dir kind name mode = do
  t <- getCurrentTime
  initVaultWith loc hub dir kind name mode t

-- | 'initVault' 的__明碼時間版本__(workspace\/E001)。
--
-- 參數與 'initVault' __完全相同__,尾端多一個 @UTCTime@;新 vault 的 id 由這個
-- 時間決定,而不是由函式內部取樣。時間放最後,與
-- 'Aapms.Workspace.Projects.allocateProjectId'(2026-08-29 W4)及 graph-core 的
-- @Aapms.Store.Marker.initVaultAtWith@(E002)一致。
--
-- __為什麼它是公開的__:'initVault' 有一整條「新 id 撞到中樞既有 @veId@ 就回
-- 'Aapms.Workspace.Types.VaultIdCollision' 並回滾剛寫出的 @.aapms\/@」的分支,
-- 它的正確性只能靠__造出一次碰撞__來驗;時間藏在函式內部取樣時,呼叫端無法
-- 預先造出兩個相同的 id,那條分支就永遠沒有人驗得了(spec-gap G4)。理由與
-- 'Aapms.Workspace.Projects.allocateProjectId' 的 salt 重試迴圈完全相同。
--
-- 前置檢查、撞號處置、回滾與 'Aapms.Workspace.Types.AdoptNotice' 的語意
-- __一律與 'initVault' 相同__,差別只在時間的來源。
initVaultWith
  :: HubLocation
  -> Hub
  -> FilePath
  -> VaultKind
  -> Text
  -> InitMode
  -> UTCTime
  -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
initVaultWith loc hub dir kind name mode t
  | T.null (T.strip name) = pure (Left (InvalidName name))
  | otherwise = do
      dir' <- canonicalizePath dir
      occupied <- pathExists (markerDir dir')
      if occupied
        then pure (Left (VaultAlreadyInitialized dir'))
        else do
          modeCheck <- case mode of
            FreshVault -> do
              exists <- doesDirectoryExist dir'
              if not exists
                then pure (Right ())
                else do
                  contents <- listDirectory dir'
                  pure $
                    if null contents
                      then Right ()
                      else Left (VaultDirNotEmpty dir')
            AdoptExisting -> do
              exists <- doesDirectoryExist dir'
              pure $ if exists then Right () else Left (VaultDirMissing dir')
          case modeCheck of
            Left e -> pure (Left e)
            Right () -> do
              initR <- initVaultAtWith dir' kind (T.strip name) t
              case initR of
                Left err -> do
                  removePathForcibly (markerDir dir')
                  pure (Left (VaultInitFailed dir' err))
                Right m -> case find ((== vmId m) . veId) (hubVaults hub) of
                  Just existing -> do
                    removePathForcibly (markerDir dir')
                    pure (Left (VaultIdCollision (vmId m) (vePath existing) dir'))
                  Nothing -> do
                    let legacyCandidates = [dir' </> n | n <- [".assetdb", ".storyflow"]]
                    legacyMarkers <- filterM doesDirectoryExist legacyCandidates
                    let entry = VaultEntry (vmId m) (vmName m) (vmKind m) dir'
                        hub' = upsertVault entry hub
                    saveR <- saveHub loc hub'
                    pure $ case saveR of
                      Left e -> Left e
                      Right () -> Right (hub', entry, AdoptNotice legacyMarkers)

-- | 把一個__已經是 vault__ 的目錄納管進中樞(該目錄必須已有 @.aapms\/@)。
--
-- 身分一律重讀 marker 取得(經 'Aapms.Workspace.Discovery.readVaultRefAt'):
-- marker 讀不到是__硬失敗__ 'Aapms.Workspace.Types.MarkerUnreadable',捧著
-- graph-core 的原件、這一層不翻譯。
--
-- 中樞的更新是 @upsertVault@ 的語意:__以 marker 的 id 為鍵__,已有那一列就
-- 就地覆寫(vault 搬家只改 @vePath@,ADR-017 決策二),沒有才追加。因此對同一個
-- vault 重複 @vault add@ 是安全的,不會長出第二列。
--
-- __不建立、不修改 vault 目錄下的任何東西__。
addVault
  :: HubLocation
  -> Hub
  -> FilePath
  -> IO (Either WorkspaceError (Hub, VaultEntry))
addVault loc hub dir = do
  dir' <- canonicalizePath dir
  refR <- readVaultRefAt hub dir'
  case refR of
    Left e -> pure (Left e)
    Right ref -> do
      let m = vrMarker ref
          entry = VaultEntry (vmId m) (vmName m) (vmKind m) dir'
          hub' = upsertVault entry hub
      saveR <- saveHub loc hub'
      pure $ case saveR of
        Left e -> Left e
        Right () -> Right (hub', entry)

-- 撤除 -------------------------------------------------------------------------

-- | 把一個 vault 從中樞移除。第三參數的比對規則__同
-- 'Aapms.Workspace.Discovery.lookupSelector'__(先比 @veId@ 再比 @veName@,逐字
-- 精確比對;撞名回 'Aapms.Workspace.Types.VaultSelectorAmbiguous')。
--
-- 預設__只動中樞__:刪掉那一列、'Aapms.Workspace.Hub.saveHub' 寫回,vault 目錄
-- 原封不動(搬到另一台機器 @vault add@ 就能繼續用)。
-- 'Aapms.Workspace.Types.DeleteIndex' 時才__多刪一個檔__:
-- @\<vePath\>\/.aapms\/index.db@。
--
-- @config.toml@、@library\/@ 與任何 @.md@ __任何情況都不碰__(ADR-017 決策五)。
--
-- 回傳的 'Aapms.Workspace.Types.VaultEntry' 是被移除的那一列(中樞裡原本的值)。
forgetVault
  :: HubLocation
  -> Hub
  -> Text
  -> DeleteIndex
  -> IO (Either WorkspaceError (Hub, VaultEntry))
forgetVault loc hub sel di =
  case lookupSelector hub sel of
    Left e -> pure (Left e)
    Right entry -> do
      identityR <- case di of
        KeepIndex -> pure (Right ())
        DeleteIndex -> verifyDeleteTarget entry
      case identityR of
        Left err -> pure (Left err)
        Right () -> do
          let hub' = removeVault (veId entry) hub
          saveR <- saveHub loc hub'
          case saveR of
            Left err -> pure (Left err)
            Right () -> do
              deleteR <- case di of
                KeepIndex -> pure (Right ())
                DeleteIndex -> removeFileIfExists (indexDbPath (vePath entry))
              pure $ case deleteR of
                Left err -> Left err
                Right () -> Right (hub', entry)

-- | 清理中樞與(可選)各 vault 的索引。
--
-- * 'Aapms.Workspace.Types.PurgeHubOnly'(預設):刪中樞的 @config.toml@ 與整棵
--   @cache\/thumbs\/@;中樞目錄下__其他檔案不動__
-- * 'Aapms.Workspace.Types.PurgeAllVaults':另刪每個已註冊 vault 的
--   @.aapms\/index.db@,路徑逐一列進
--   'Aapms.Workspace.Types.prVaultIndexesRemoved'
--
-- __任何 'Aapms.Workspace.Types.PurgeScope' 下都不刪除任何 @library\/@ 下的檔案
-- 與任何 @.md@__,也不刪 vault 的 @.aapms\/config.toml@——索引是衍生物,重建即
-- 可;marker 與素材不是。
--
-- 冪等:已經清乾淨之後再跑一次回 @Right@,三個欄位分別是 @False@ \/ @0@ \/ @[]@。
-- 刪不掉時回 @Left ('Aapms.Workspace.Types.HubWriteFailed' 那個路徑 原因)@。
purge
  :: HubLocation
  -> Hub
  -> PurgeScope
  -> IO (Either WorkspaceError PurgeReport)
purge loc hub scope = do
  let fp = configPath loc
      td = thumbCacheDir loc
  driftCheck <- case scope of
    PurgeHubOnly -> pure (Right ())
    PurgeAllVaults -> verifyAllDeleteTargets (hubVaults hub)
  case driftCheck of
    Left e -> pure (Left e)
    Right () -> do
      hubExisted <- doesFileExist fp
      hubR <- removeFileIfExists fp
      case hubR of
        Left e -> pure (Left e)
        Right () -> do
          thumbCount <- countFiles td
          thumbR <- removeTreeForcibly td
          case thumbR of
            Left e -> pure (Left e)
            Right () -> do
              indexesR <- case scope of
                PurgeHubOnly -> pure (Right [])
                PurgeAllVaults -> removeExistingIndexes (hubVaults hub)
              pure $ case indexesR of
                Left e -> Left e
                Right indexes -> Right (PurgeReport hubExisted thumbCount indexes)

-- 體檢與回寫 -------------------------------------------------------------------

-- | 純體檢:對中樞每一列重讀 marker,回傳修不掉與修得掉之外的降級紀錄。
--
-- __不寫任何檔案__,__沒有失敗通道__:路徑不見 \/ marker 壞 \/ id 漂移都是一則
-- 'Aapms.Workspace.Types.ScopeIssue',其餘照跑。順序同
-- 'Aapms.Workspace.Hub.hubVaults'。
--
-- __不展開 @refs@__(那是 F003 的 Scope 擁有的規則),所以本函式永遠不產生
-- 'Aapms.Workspace.Types.RefVaultNotRegistered'。@veName@ \/ @veKind@ 的漂移
-- __不是__ 'Aapms.Workspace.Types.ScopeIssue' 的任何一個建構子,它由 'syncHub'
-- 直接修掉。
checkVaults :: Hub -> IO [ScopeIssue]
checkVaults hub = do
  results <- mapM (\e -> readVaultRef e (vePath e)) (hubVaults hub)
  pure [issue | Left issue <- results]

-- | 把__修得掉__的漂移(@veName@ \/ @veKind@ 與 marker 不符)回寫中樞;修不掉的
-- (路徑不見、marker 壞、id 漂移)原樣回傳。
--
-- 回傳的 @['Aapms.Workspace.Types.ScopeIssue']@ 與對同一個 'Hub' 呼叫
-- 'checkVaults' 的結果__逐項相同__——'syncHub' 修的東西根本不在
-- 'Aapms.Workspace.Types.ScopeIssue' 的值域裡。
--
-- __marker 是真相,中樞是快取__:回寫的方向只有「marker → 中樞」,本函式
-- __不會__把中樞的值寫進 marker,也不動 @veId@ 與 @vePath@。沒有任何一列需要
-- 修正時__不寫檔案__。
syncHub :: HubLocation -> Hub -> IO (Either WorkspaceError (Hub, [ScopeIssue]))
syncHub loc hub = do
  results <- mapM (\e -> (,) e <$> readVaultRef e (vePath e)) (hubVaults hub)
  let issues = [issue | (_, Left issue) <- results]
      fixes =
        [ e {veName = vmName m, veKind = vmKind m}
        | (e, Right ref) <- results
        , let m = vrMarker ref
        , vmName m /= veName e || vmKind m /= veKind e
        ]
  if null fixes
    then pure (Right (hub, issues))
    else do
      let hub' = foldr upsertVault hub fixes
      saveR <- saveHub loc hub'
      pure $ case saveR of
        Left e -> Left e
        Right () -> Right (hub', issues)

-- 私有 helper ------------------------------------------------------------------

-- | 路徑存在,不論是目錄還是普通檔案。
pathExists :: FilePath -> IO Bool
pathExists fp = do
  isFile <- doesFileExist fp
  if isFile then pure True else doesDirectoryExist fp

-- | 把可能拋出 'IOException' 的動作包成 'HubWriteFailed'(T11:讓七個函式對同一種
-- 落地失敗給出同一個建構子)。
tryIO :: FilePath -> IO a -> IO (Either WorkspaceError a)
tryIO fp act = do
  r <- try act
  pure $ case r of
    Left e -> Left (HubWriteFailed fp (T.pack (show (e :: IOException))))
    Right v -> Right v

-- | 依序執行一串會失敗的動作,遇到第一個 'Left' 就停。
chainE :: [IO (Either WorkspaceError ())] -> IO (Either WorkspaceError ())
chainE [] = pure (Right ())
chainE (a : as) = do
  r <- a
  case r of
    Left e -> pure (Left e)
    Right () -> chainE as

-- | 存在才刪(檔案),不存在就跳過、不報錯;刪除本身的 IO 失敗包成 'HubWriteFailed'。
removeFileIfExists :: FilePath -> IO (Either WorkspaceError ())
removeFileIfExists fp = do
  exists <- doesFileExist fp
  if exists then tryIO fp (removeFile fp) else pure (Right ())

-- | 遞迴刪除整棵樹;@directory@ 的 'removePathForcibly' 本身對不存在的路徑就是
-- 「什麼都不做」,這裡只補上 IO 失敗轉換成 'HubWriteFailed'。
removeTreeForcibly :: FilePath -> IO (Either WorkspaceError ())
removeTreeForcibly fp = tryIO fp (removePathForcibly fp)

-- | 遞迴數某個目錄樹底下的檔案總數(不含目錄本身);目錄不存在回 0。
countFiles :: FilePath -> IO Int
countFiles dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure 0
    else do
      names <- listDirectory dir
      counts <- mapM countEntry names
      pure (sum counts)
  where
    countEntry name = do
      let p = dir </> name
      isDir <- doesDirectoryExist p
      if isDir then countFiles p else pure 1

-- | 刪索引前的身分驗證(W4 裁決 B):讀不到就通過(照刪);讀得到但 id 與中樞
-- 那一列不符就拒絕。
verifyDeleteTarget :: VaultEntry -> IO (Either WorkspaceError ())
verifyDeleteTarget e = do
  mr <- readMarker (vePath e)
  pure $ case mr of
    Left _ -> Right ()
    Right m
      | vmId m == veId e -> Right ()
      | otherwise -> Left (DeleteTargetIdDrift (veId e) (vePath e) (vmId m))

-- | 對整批 vault 逐一驗身分,全部通過才回 'Right'——'purge' 的
-- @'PurgeAllVaults'@ 靠它做到「全有或全無」:此刻還沒有任何刪除發生。
verifyAllDeleteTargets :: [VaultEntry] -> IO (Either WorkspaceError ())
verifyAllDeleteTargets = chainE . map verifyDeleteTarget

-- | 逐一刪除實際存在的 @index.db@,回傳真的被刪掉的路徑(保序;呼叫前就不存在
-- 的不列入)。
removeExistingIndexes :: [VaultEntry] -> IO (Either WorkspaceError [FilePath])
removeExistingIndexes [] = pure (Right [])
removeExistingIndexes (e : es) = do
  let p = indexDbPath (vePath e)
  exists <- doesFileExist p
  if not exists
    then removeExistingIndexes es
    else do
      r <- tryIO p (removeFile p)
      case r of
        Left err -> pure (Left err)
        Right () -> fmap (fmap (p :)) (removeExistingIndexes es)
