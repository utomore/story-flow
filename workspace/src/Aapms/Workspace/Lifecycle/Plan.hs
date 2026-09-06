{-# LANGUAGE DataKinds #-}

-- | vault 與專案生命週期的__純規劃__(P-005-vault-lifecycle)。
--
-- 擁有的事實(唯一真相來源):前置檢查的__順序__(名稱 → 已佔用 → 目錄狀態)、
-- 舊 marker 的探測範圍(第一層、固定順序、不遞迴)、撞號的判準、marker 投影成
-- 中樞一列的規則,以及十個生命週期操作各自的路徑。
--
-- 整條是 "Aapms.Workspace.Effect.HubFile" \/ "Aapms.Workspace.Effect.VaultDir" \/
-- "Aapms.Workspace.Effect.Markers" \/ "Aapms.Store.Effect.Clock" 四個效果的程式,
-- __本模組一行 IO 都沒有__;真解譯器與進入點住 "Aapms.Workspace.Lifecycle"。
--
-- __明確不做__:不刪 @library\/@ 與任何 @.md@;不反向修 marker(syncHub 的方向
-- 只有 marker → 中樞);不自動刪舊系統的 marker(只報告)。
module Aapms.Workspace.Lifecycle.Plan
  ( -- * 前置檢查與投影
    checkInit
  , legacyMarkers
  , collisionOf
  , entryOf
  , syncEntry

    -- * 專案
  , lookupProject
  , allocateProjectId

    -- * 純的整條
  , applyLifecycle
  ) where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Effectful (Eff, (:>))

import Aapms.Core.Id (Id, IdPrefix (PPrj), newId, renderId)
import Aapms.Store.Effect.Clock (Clock, now)
import Aapms.Store.Types (VaultMarker (..))
import Aapms.Workspace.Effect.HubFile
  ( HubFile
  , ensureCacheDir
  , hubExists
  , hubPath
  , purgeHubFiles
  , writeHub
  )
import Aapms.Workspace.Effect.Markers (Markers, canonicalPath, dirExists, readMarkerAt)
import Aapms.Workspace.Effect.VaultDir
  ( VaultDir
  , initMarker
  , listEntries
  , markerDirExists
  , removeIndexDb
  , removeMarkerDir
  )
import Aapms.Workspace.Hub (removeProject, removeVault, renderHub, upsertProject, upsertVault)
import Aapms.Workspace.Resolve (lookupSelector, refOfEntry)
import Aapms.Workspace.Types
  ( AdoptNotice (..)
  , DeleteIndex (..)
  , Hub
  , HubLocation (hlPath)
  , InitMode (..)
  , LifecycleOp (..)
  , LifecycleOutcome (..)
  , ProjectEntry (..)
  , PurgeReport (..)
  , PurgeScope (..)
  , SetupReport (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , VaultRef (vrMarker)
  , WorkspaceError (..)
  , hubProjects
  , hubVaults
  , mkHub
  )
import System.FilePath ((</>))

-- | 前置檢查依序:名稱去空白非空 → @.aapms@ 未被佔用 → 'Aapms.Workspace.Types.FreshVault'
-- 要空、'Aapms.Workspace.Types.AdoptExisting' 要存在;通過回去空白後的名稱。
--
-- 三個 'Bool' \/ @['FilePath']@ 參數依序是:@.aapms@ 被佔用了嗎、目錄存在嗎、
-- 目錄第一層有什麼。
-- __GAP-1__:三個「目錄狀態」的錯誤建構子都捧著那個 vault 根目錄
-- ('Aapms.Workspace.Types.VaultAlreadyInitialized' \/
-- 'Aapms.Workspace.Types.VaultDirNotEmpty' \/ 'Aapms.Workspace.Types.VaultDirMissing'),
-- 但本簽名收不到它——五個參數是名稱、模式、佔用、存在、第一層的__名字__
-- (@vwEntries@ 給的是裸名,見 'legacyMarkers' 要另外收 @dir@ 才拼得出絕對路徑)。
-- LAW-3 要求整條的結果__逐值等於__本函式的錯誤,所以這裡不能回一個「之後由
-- 'applyLifecycle' 補上路徑」的半成品;暫以空路徑佔位,等簽名補上 @FilePath@。
checkInit :: Text -> InitMode -> FilePath -> Bool -> Bool -> [FilePath] -> Either WorkspaceError Text
checkInit name mode d occupied exists entries
  | T.null stripped = Left (InvalidName name)
  | occupied = Left (VaultAlreadyInitialized d)
  | otherwise = case mode of
      FreshVault
        | exists && not (null entries) -> Left (VaultDirNotEmpty d)
        | otherwise -> Right stripped
      AdoptExisting
        | exists -> Right stripped
        | otherwise -> Left (VaultDirMissing d)
  where
    stripped = T.strip name

-- | 目錄第一層裡的 @.assetdb@ \/ @.storyflow@,固定順序,不遞迴。
--
-- 順序由本函式決定(先 @.assetdb@ 後 @.storyflow@),__不隨目錄第一層的順序
-- 變動__;回傳的是以 @dir@ 為前綴的絕對路徑,@entries@ 收的是裸名。
legacyMarkers :: FilePath -> [FilePath] -> [FilePath]
legacyMarkers dir entries = [dir </> n | n <- [".assetdb", ".storyflow"], n `elem` entries]

-- | 新 marker 的 id 撞到中樞既有列(路徑不同)就是
-- 'Aapms.Workspace.Types.VaultIdCollision' 三個值。
--
-- __路徑相同不算撞號__:那是同一個 vault 被重新 init,以 id 為鍵 upsert 回去
-- 就對了(ADR-017 決策二)。
collisionOf :: Hub -> VaultMarker -> FilePath -> Maybe WorkspaceError
collisionOf hub m dir =
  fmap
    (\e -> VaultIdCollision (veId e) (vePath e) dir)
    (find (\e -> veId e == vmId m && vePath e /= dir) (hubVaults hub))

-- | marker 投影成中樞的一列。
entryOf :: VaultMarker -> FilePath -> VaultEntry
entryOf m dir =
  VaultEntry {veId = vmId m, veName = vmName m, veKind = vmKind m, vePath = dir}

-- | 只以 marker 修 @name@ 與 @kind@,@id@ 與 @path@ 不動。
syncEntry :: VaultEntry -> VaultMarker -> VaultEntry
syncEntry e m = e {veName = vmName m, veKind = vmKind m}

-- | 專案 selector:先 id 再 name,逐字,撞名
-- 'Aapms.Workspace.Types.ProjectSelectorAmbiguous'。
--
-- 規則與 'Aapms.Workspace.Resolve.lookupSelector' __同一套__,節點型別換成專案:
-- 兩階段、逐字精確比對(不去空白、不忽略大小寫、不做前綴比對),id 階段有命中
-- 時 name 階段完全不參與。
lookupProject :: Hub -> Text -> Either WorkspaceError ProjectEntry
lookupProject hub s = case byId of
  [e] -> Right e
  es@(_ : _ : _) -> Left (ProjectSelectorAmbiguous s es)
  [] -> case byName of
    [e] -> Right e
    es@(_ : _ : _) -> Left (ProjectSelectorAmbiguous s es)
    [] -> Left (ProjectSelectorNotFound s)
  where
    entries = hubProjects hub
    byId = filter ((== s) . renderId . peId) entries
    byName = filter ((== s) . peName) entries

-- | @prj-@ 短 id,撞既有就 salt 遞增,純函數。
--
-- (自 "Aapms.Workspace.Projects" 搬進純層,行為逐字不變;該模組原地 re-export。)
allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id
allocateProjectId existing nm t = go 0
  where
    taken = map peId existing
    go salt =
      let cand = newId PPrj nm t salt
      in if cand `elem` taken then go (salt + 1) else cand

-- | 純的整條:依請求走前置檢查 → 建 marker → 撞號比對 → 舊 marker 探測 →
-- 'Hub' 值上加減 → 渲染 → 原子寫回等路徑。
applyLifecycle
  :: (HubFile :> es, VaultDir :> es, Markers :> es, Clock :> es)
  => Hub
  -> LifecycleOp
  -> Eff es (Either WorkspaceError LifecycleOutcome)
applyLifecycle hub = \case
  SetupHub -> do
    loc <- hubPath
    existed <- hubExists
    written <-
      if existed
        then pure (Right False)
        else fmap (fmap (const True)) (writeHub (renderHub emptyHub))
    case written of
      Left err -> pure (Left err)
      Right hubCreated -> do
        cacheCreated <- ensureCacheDir
        pure
          ( Right
              emptyOutcome
                { outcomeSetup = Just (SetupReport (hlPath loc) hubCreated cacheCreated)
                }
          )
  InitVault dir kind name mode -> do
    d <- canonicalPath dir
    occupied <- markerDirExists d
    exists <- dirExists d
    entries <- listEntries d
    case checkInit name mode d occupied exists entries of
      Left err -> pure (Left err)
      Right nm -> do
        t <- now
        created <- initMarker d kind nm t
        case created of
          Left err -> do
            removeMarkerDir d
            pure (Left (VaultInitFailed d err))
          Right m -> case collisionOf hub m d of
            Just err -> do
              removeMarkerDir d
              pure (Left err)
            Nothing -> do
              let entry = entryOf m d
                  hub' = upsertVault entry hub
              saved <- writeHub (renderHub hub')
              pure $ case saved of
                Left err -> Left err
                Right () ->
                  Right
                    emptyOutcome
                      { outcomeHub = Just hub'
                      , outcomeEntry = Just entry
                      , outcomeNotice = Just (AdoptNotice (legacyMarkers d entries))
                      }
  AddVault dir -> do
    d <- canonicalPath dir
    markerR <- readMarkerAt d
    case markerR of
      Left err -> pure (Left (MarkerUnreadable d err))
      Right m -> do
        let entry = entryOf m d
            hub' = upsertVault entry hub
        saved <- writeHub (renderHub hub')
        pure $ case saved of
          Left err -> Left err
          Right () ->
            Right emptyOutcome {outcomeHub = Just hub', outcomeEntry = Just entry}
  ForgetVault sel di -> case lookupSelector hub sel of
    Left err -> pure (Left err)
    Right entry -> do
      let hub' = removeVault (veId entry) hub
      saved <- writeHub (renderHub hub')
      case saved of
        Left err -> pure (Left err)
        Right () -> do
          case di of
            KeepIndex -> pure ()
            DeleteIndex -> () <$ removeIndexDb (vePath entry)
          pure
            ( Right
                emptyOutcome {outcomeHub = Just hub', outcomeEntry = Just entry}
            )
  CheckVaults -> do
    results <- mapM refOfEntry (hubVaults hub)
    pure (Right emptyOutcome {outcomeIssues = [i | Left i <- results]})
  SyncHub -> do
    results <- mapM (\e -> (,) e <$> refOfEntry e) (hubVaults hub)
    let issues = [i | (_, Left i) <- results]
        fixes =
          [ syncEntry e m
          | (e, Right ref) <- results
          , let m = vrMarker ref
          , vmName m /= veName e || vmKind m /= veKind e
          ]
    if null fixes
      then pure (Right emptyOutcome {outcomeIssues = issues})
      else do
        let hub' = foldl' (flip upsertVault) hub fixes
        saved <- writeHub (renderHub hub')
        pure $ case saved of
          Left err -> Left err
          Right () ->
            Right emptyOutcome {outcomeHub = Just hub', outcomeIssues = issues}
  Purge scope -> do
    (hubRemoved, thumbs) <- purgeHubFiles
    indexes <- case scope of
      PurgeHubOnly -> pure []
      PurgeAllVaults -> dropIndexes (hubVaults hub)
    pure
      ( Right
          emptyOutcome {outcomePurge = Just (PurgeReport hubRemoved thumbs indexes)}
      )
  RegisterProject dir name
    | T.null (T.strip name) -> pure (Left (InvalidName name))
    | otherwise -> do
        let nm = T.strip name
        d <- canonicalPath dir
        exists <- dirExists d
        if not exists
          then pure (Left (ProjectPathMissing nm d))
          else case find ((== d) . pePath) (hubProjects hub) of
            Just e0 -> pure (Left (ProjectAlreadyRegistered (peId e0) (pePath e0)))
            Nothing -> do
              t <- now
              let entry =
                    ProjectEntry
                      { peId = allocateProjectId (hubProjects hub) nm t
                      , peName = nm
                      , pePath = d
                      }
                  hub' = upsertProject entry hub
              saved <- writeHub (renderHub hub')
              pure $ case saved of
                Left err -> Left err
                Right () ->
                  Right emptyOutcome {outcomeHub = Just hub', outcomeProject = Just entry}
  ForgetProject sel -> case lookupProject hub sel of
    Left err -> pure (Left err)
    Right entry -> do
      let hub' = removeProject (peId entry) hub
      saved <- writeHub (renderHub hub')
      pure $ case saved of
        Left err -> Left err
        Right () ->
          Right emptyOutcome {outcomeHub = Just hub', outcomeProject = Just entry}

--------------------------------------------------------------------------------
-- 私有

-- | 私有:每個欄位都空的結果。九種請求各自只填自己那幾格,其餘留白——
-- 'Aapms.Workspace.Types.outcomeHub' 只在__真的寫回中樞__時才是 @Just@
-- (LAW-18:有新 'Hub' 就要能從最終的中樞文字解析回來)。
emptyOutcome :: LifecycleOutcome
emptyOutcome =
  LifecycleOutcome
    { outcomeHub = Nothing
    , outcomeEntry = Nothing
    , outcomeNotice = Nothing
    , outcomeProject = Nothing
    , outcomeIssues = []
    , outcomeSetup = Nothing
    , outcomePurge = Nothing
    }

-- | 私有:全新中樞的空值。@setup@ 寫出去的就是它('Aapms.Workspace.Hub.renderHub'
-- 對空底稿的結果),四段都空。
emptyHub :: Hub
emptyHub = mkHub [] [] Nothing (ToolsConfig Nothing) ""

-- | 私有:逐一刪除中樞每一列的 @index.db@,回__真的被刪掉__的那些路徑(保序;
-- 呼叫前就不存在的不列入)。
dropIndexes :: VaultDir :> es => [VaultEntry] -> Eff es [FilePath]
dropIndexes [] = pure []
dropIndexes (e : es) = do
  gone <- removeIndexDb (vePath e)
  rest <- dropIndexes es
  pure (if gone then indexDbIn (vePath e) : rest else rest)

-- | 私有:一個 vault 根目錄底下的 @index.db@(同 graph-core 的 @indexDbPath@;
-- 那個函式住 shell,純層自己拼同一條路徑)。
indexDbIn :: FilePath -> FilePath
indexDbIn root = root </> ".aapms" </> "index.db"
