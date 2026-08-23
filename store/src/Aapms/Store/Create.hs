-- | 建檔、增節、刪除。
--
-- 「改既有實體」在 "Aapms.Store.Write",「Level 樹編輯」在
-- "Aapms.Store.Node";共用的紀律在 "Aapms.Store.Edit"。
--
-- == 檔案放哪裡
--
-- 目錄是__宣告式__的:'Aapms.Core.Registry.lookupDir' 查型別註冊表,
-- 查不到就回 'RegistryDirUnknown' 而不是默默丟進 Vault 根目錄。否則
-- 「新增一個型別不必改程式」這條垂直切片會在「檔案該放哪」這一步破掉。
-- Level 檔的目錄硬編為 @levels\/@ ——@level@ 是保留鍵,不可能出現在註冊表裡。
--
-- 檔名__保留中文原字元__:Vault 是給人看的 git repo,@characters\/琳達.md@
-- 比雜湊好一百倍。只替換檔案系統不接受的字元。
--
-- == 刪除策略
--
-- __不自動清掉指向被刪目標的關聯__:那要改其他檔案,而多檔寫入沒有交易保證
-- ——改到一半失敗會留下不一致,比留幾筆孤兒關聯糟得多。孤兒關聯是可查詢、
-- 可修復的狀態;半套的刪除不是。'DeleteSafe' 因此先擋下來讓作者自己決定。
module Aapms.Store.Create
  ( -- * 輸入
    NewEntity (..)
  , NewFragment (..)
  , NewLevel (..)
  , NewNode (..)

    -- * 結果
  , CreateResult (..)
  , DeleteMode (..)
  , DeleteResult (..)

    -- * 建立
  , createEntityFile
  , createLevelFile
  , addFragment

    -- * 刪除
  , deleteEntity
  , deleteLevel

    -- * 檔名(供 "Aapms.Store.Node" 與測試使用)
  , sanitizeFileName
  , preambleOf
  , freshPath
  , guardReferences
  , dropFile
  ) where

import Control.Monad (forM)
import Data.Char (isControl)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, getCurrentTime, utctDay)
import Database.SQLite.Simple
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (PEnt, PLvl, PNod), localRef, renderId)
import Aapms.Core.Level (Level (..), Node (..), NodeKind)
import Aapms.Core.Link (Link (..))
import Aapms.Core.Meta
import Aapms.Core.Registry (TypeRegistry, emptyRegistry, lookupDir)
import Aapms.Md
import Aapms.Store.Edit
import Aapms.Store.Error (StoreError (..), renderStoreError, trySqlite)
import Aapms.Store.Index (unindexFile)
import Aapms.Store.Query (linksTo)
import Aapms.Store.Vault (Vault (..), vaultAbsPath)
import Aapms.Store.Write (allocateId)
import System.Directory (doesFileExist, removeFile)
import System.FilePath (splitExtension)

-- 輸入 ------------------------------------------------------------------------

-- | 一份新的主題檔(檔案層主體)。
data NewEntity = NewEntity
  { neType :: Text
  -- ^ 主體型別鍵,如 @character@
  , neTitle :: Text
  , neSummary :: Text
  , neBody :: Text
  , neTags :: [Text]
  , neAliases :: [Text]
  , neStatus :: Status
  , neTimeline :: Timeline
  , neLinks :: [Link]
  , neSource :: Source
  , nePath :: Maybe FilePath
  -- ^ Vault 相對路徑;@Nothing@ = 依註冊表推導
  }
  deriving stock (Show, Eq)

-- | 往既有檔案加一個片段。
--
-- 只填__與檔案層不同__的欄位,其餘留 @Nothing@ 讓繼承生效(entity-graph-core/F003 的繼承
-- 規則)。但 @summary@ 不繼承,所以 'nfSummary' 一定要給值——缺了會產生
-- 'MissingSummary' 警告,一併帶在 'crWarnings' 裡回來。
data NewFragment = NewFragment
  { nfTitle :: Text
  , nfSummary :: Text
  , nfBody :: Text
  , nfType :: Maybe Text
  , nfTags :: [Text]
  , nfAliases :: [Text]
  , nfStatus :: Maybe Status
  , nfTimeline :: Maybe Timeline
  , nfLinks :: [Link]
  , nfSource :: Maybe Source
  }
  deriving stock (Show, Eq)

-- | 一份新的 Level 檔。__一併建出根 Node__:Level 檔沒有根 Node 就解析不出
-- @root@,建一個空殼等於建一份壞檔。
data NewLevel = NewLevel
  { nlTitle :: Text
  , nlSummary :: Text
  , nlBody :: Text
  , nlRootTitle :: Text
  , nlRootKind :: NodeKind
  , nlStatus :: Status
  }
  deriving stock (Show, Eq)

-- | 一個新的 Node。層級與插入位置由父節點決定,不由呼叫端指定(ADR-009)。
data NewNode = NewNode
  { nnTitle :: Text
  , nnKind :: NodeKind
  , nnSummary :: Text
  , nnBody :: Text
  , nnLinks :: [Link]
  }
  deriving stock (Show, Eq)

-- 結果 ------------------------------------------------------------------------

-- | 新產生的實體。
--
-- 與 entity-graph-core/F005 規格書的差異:'addFragment' 與
-- 'Aapms.Store.Node.addNode' 原本回 @WriteResult@,改成回本型別
-- (見實作備註)——新片段 \/ 新 Node 的 id 是呼叫端唯一拿不到其他來源的資訊,
-- 少了它 service 與 CLI 只能重讀檔案猜「最後一節就是剛剛那個」。
data CreateResult = CreateResult
  { crId :: Id
  , crPath :: FilePath
  , crWarnings :: [MdWarning]
  }
  deriving stock (Show, Eq)

-- | 被指向時要擋下來,還是照刪並回報斷點。
data DeleteMode = DeleteSafe | DeleteForce
  deriving stock (Show, Eq)

data DeleteResult = DeleteResult
  { drPath :: FilePath
  , drRemovedIds :: [Id]
  -- ^ 刪整份檔案時可能不只一個
  , drBrokenLinks :: [(Id, Link)]
  -- ^ 'DeleteForce' 打斷的關聯
  }
  deriving stock (Show, Eq)

-- 建立主題檔 --------------------------------------------------------------------

-- | 建一份新的 Entity 檔。
--
-- __先檢查檔案不存在再寫__:'Aapms.Store.Atomic.atomicWriteText' 是覆蓋
-- 語意,不擋既有檔案。撞名時加 @-2@ \/ @-3@ 遞增;呼叫端明確給了 'nePath'
-- 卻已經有檔案時回 'FileAlreadyExists' ——那是指定,不是推導,不該悄悄換掉。
--
-- 新檔一律用 'LF'。Windows 上的 git 由 @core.autocrlf@ 處理,工具不介入。
createEntityFile
  :: Connection -> Vault -> TypeRegistry -> NewEntity -> IO (Either StoreError CreateResult)
createEntityFile conn v reg NewEntity {..} = do
  now <- getCurrentTime
  allocateId conn PEnt (neTitle <> neSummary) now >>? \i ->
    targetPath v reg neType neTitle nePath i >>? \rel -> do
      let meta = newMeta i (utctDay now) neType
          doc = (mkDocument LF meta (preambleOf neBody False)) {docPath = rel}
      writeNewFile conn v rel doc i
  where
    newMeta i today ty =
      Meta
        { metaId = i
        , metaVault = vaultName v
        , metaType = ty
        , metaTitle = neTitle
        , metaSummary = neSummary
        , metaTags = neTags
        , metaStatus = neStatus
        , metaTimeline = neTimeline
        , metaAliases = neAliases
        , metaLinks = neLinks
        , metaSource = neSource
        , metaRevision = 1
        , metaCreated = today
        , metaUpdated = today
        }

-- | 建一份新的 Level 檔,連同它的根 Node。
--
-- 目錄固定 @levels\/@:@level@ 是保留型別鍵,不可能在註冊表裡宣告 @dir@。
-- 根 Node 用 @##@(二級標題),與 system.md 的範例一致——留一級給
-- @#@ 當作者想寫的檔案大標。
createLevelFile :: Connection -> Vault -> NewLevel -> IO (Either StoreError CreateResult)
createLevelFile conn v NewLevel {..} = do
  now <- getCurrentTime
  allocateId conn PLvl (nlTitle <> nlSummary) now >>? \lvlId ->
    allocateId conn PNod (nlTitle <> nlRootTitle) now >>? \rootId ->
      targetPath v emptyRegistry "level" nlTitle Nothing lvlId >>? \rel -> do
        let meta = levelMeta lvlId (utctDay now)
            doc0 = (mkDocument LF meta (preambleOf nlBody True)) {docPath = rel}
            root =
              mkSection
                LF
                2
                rootId
                nlRootTitle
                (Just (emptyOverride {moKind = Just nlRootKind}))
                (renderLineEnding LF)
        orMd rel (insertSection Nothing root doc0) ?>> \doc ->
          writeNewFile conn v rel doc lvlId
  where
    levelMeta i today =
      Meta
        { metaId = i
        , metaVault = vaultName v
        , metaType = "level"
        , metaTitle = nlTitle
        , metaSummary = nlSummary
        , metaTags = []
        , metaStatus = nlStatus
        , metaTimeline = emptyTimeline
        , metaAliases = []
        , metaLinks = []
        , metaSource = Human
        , metaRevision = 1
        , metaCreated = today
        , metaUpdated = today
        }

-- | 寫一份全新的檔案:先自己解析回來驗證,再落地。
--
-- 驗證是純函式、不花 IO,__沒有理由先寫壞檔再說__。順帶把解析警告
-- (缺 @summary@ 之類)撈出來還給呼叫端——它們是本層唯一看得到的地方。
writeNewFile
  :: Connection -> Vault -> FilePath -> Document -> Id -> IO (Either StoreError CreateResult)
writeNewFile conn v rel doc i =
  selfCheck rel doc ?>> \ws -> do
    ensureDir v rel
    commit conn v rel doc 1 >>? \_ -> pure (Right (CreateResult i rel ws))

-- | 產出的文字必須自己解析得回來。解析不回來就是序列化寫壞了,不是資料的問題。
selfCheck :: FilePath -> Document -> Either StoreError [MdWarning]
selfCheck rel doc = do
  reparsed <- readBack
  kind <- orMds (documentKind reparsed)
  case kind of
    DocEntity -> snd <$> entityFileOf rel reparsed
    DocLevel -> snd <$> levelFileOf rel reparsed
  where
    readBack = orMds (parseDocument rel (renderDocument doc))
    orMds = either (Left . ParseFailed rel) Right

-- 增節 ------------------------------------------------------------------------

-- | 往既有檔案的__檔尾__加一個片段。
--
-- @Id@ 是__檔案層主體__的 id(用來定位檔案),@Int@ 是主體的 revision。
-- 主體的 revision 走完會 +1:這是樂觀鎖的另一半,不遞增的話兩個並發的
-- 'addFragment' 拿同一個 revision 都會通過。
--
-- 片段一律是二級標題:system.md 的規則是「第一個帶 @{#id}@ 的標題才
-- 開始分節」,Entity 檔的節之間沒有階層。
addFragment
  :: Connection -> Vault -> Id -> Int -> NewFragment -> IO (Either StoreError CreateResult)
addFragment conn v i expected NewFragment {..} =
  locate conn i >>? \(Located rel anchor) -> case anchor of
    Just _ -> pure (Left (NotAFileMain i))
    Nothing ->
      readDocument v rel >>? \doc ->
        entityFileOf rel doc ?>> \(ef, _) ->
          checkRevision i expected (metaRevision (entMeta (efMain ef))) ?>> \() -> do
            now <- getCurrentTime
            allocateId conn PEnt (nfTitle <> nfSummary) now >>? \newId ->
              build rel doc newId (utctDay now) ?>> \doc' ->
                selfCheck rel doc' ?>> \ws ->
                  commit conn v rel doc' (expected + 1) >>? \_ ->
                    pure (Right (CreateResult newId rel ws))
  where
    build rel doc newId today = do
      let le = docEnding doc
          sec =
            mkSection
              le
              2
              newId
              nfTitle
              (Just override)
              (sectionBodyRaw le nfBody)
      doc' <- orMd rel (insertSection (lastSectionOf doc) sec doc)
      orMd rel (updateFrontmatter (bumpRevision today) doc')

    override =
      emptyOverride
        { moType = nfType
        , moSummary = Just nfSummary
        , moTags = nonEmpty nfTags
        , moStatus = nfStatus
        , moTimeline = nfTimeline
        , moAliases = nonEmpty nfAliases
        , moLinks = nonEmpty nfLinks
        , moSource = nfSource
        , -- 片段的 revision 不繼承(未寫時為 1),但明寫出來讓樂觀鎖的起點
          -- 在檔案裡看得見
          moRevision = Just 1
        }

    nonEmpty xs = if null xs then Nothing else Just xs

-- | 檔尾最後一節;檔案還沒有任何節時 @Nothing@(插在最前面)。
lastSectionOf :: Document -> Maybe Id
lastSectionOf doc = case sectionIds doc of
  [] -> Nothing
  is -> Just (last is)

-- 刪除 ------------------------------------------------------------------------

-- | 刪一個 Entity。
--
-- 片段(@section_anchor@ 非 @NULL@)刪的是那一節;__檔案層主體刪的是整份
-- 檔案__,連同檔內所有片段。因此 'DeleteSafe' 對每一個片段也做被引用檢查:
-- 任何一個被指向就整份拒絕。
--
-- @Int@ 是被刪目標的 revision:刪除也走樂觀鎖,否則「作者剛改完、Agent 拿舊
-- 資料刪掉」會靜默生效。
deleteEntity
  :: Connection -> Vault -> Id -> Int -> DeleteMode -> IO (Either StoreError DeleteResult)
deleteEntity conn v i expected mode =
  locate conn i >>? \(Located rel anchor) ->
    readDocument v rel >>? \doc ->
      entityFileOf rel doc ?>> \(ef, _) -> case anchor of
        Just _ -> case [e | e <- efFragments ef, metaId (entMeta e) == i] of
          [] -> pure (Left (ParseFailed rel [mdError rel 1 (UnknownSectionId i)]))
          (e : _) ->
            checkRevision i expected (metaRevision (entMeta e)) ?>> \() ->
              guardReferences conn mode i [i] >>? \broken -> do
                today <- utctDay <$> getCurrentTime
                cutSection rel doc i today ?>> \doc' ->
                  commit conn v rel doc' (expected + 1) >>? \_ ->
                    pure (Right (DeleteResult rel [i] broken))
        Nothing ->
          checkRevision i expected (metaRevision (entMeta (efMain ef))) ?>> \() ->
            let ids = i : [metaId (entMeta e) | e <- efFragments ef]
             in guardReferences conn mode i ids >>? \broken ->
                  dropFile conn v rel >>? \() ->
                    pure (Right (DeleteResult rel ids broken))

-- | 刪一份 Level 檔,連同它全部的 Node。
--
-- @Id@ 必須是 Level 本身;傳 Node 的 id 回 'NotAFileMain' ——想刪一個 Node
-- 請用 'Aapms.Store.Node.removeNode'。
deleteLevel
  :: Connection -> Vault -> Id -> Int -> DeleteMode -> IO (Either StoreError DeleteResult)
deleteLevel conn v i expected mode =
  locateNode conn i >>? \(Located rel anchor) -> case anchor of
    Just _ -> pure (Left (NotAFileMain i))
    Nothing ->
      readDocument v rel >>? \doc ->
        levelFileOf rel doc ?>> \(lf, _) ->
          checkRevision i expected (metaRevision (lvlMeta (lfLevel lf))) ?>> \() ->
            let ids = i : [metaId (nodMeta n) | n <- lfNodes lf]
             in guardReferences conn mode i ids >>? \broken ->
                  dropFile conn v rel >>? \() ->
                    pure (Right (DeleteResult rel ids broken))

-- | 刪掉一節,並把檔案層主體的 revision 遞增。
cutSection :: FilePath -> Document -> Id -> Day -> Either StoreError Document
cutSection rel doc i today = do
  doc' <- orMd rel (removeSection i doc)
  orMd rel (updateFrontmatter (bumpRevision today) doc')

-- | 被引用檢查。
--
-- 'DeleteSafe' 且有人指向時回 'ReferencedBy' 並__不刪__;'DeleteForce' 照刪,
-- 把被打斷的關聯回報出來。@reportAs@ 是錯誤訊息裡要顯示的那個 id
-- (刪整份檔案時是主體,個別片段的來源列在清單裡)。
guardReferences
  :: Connection -> DeleteMode -> Id -> [Id] -> IO (Either StoreError [(Id, Link)])
guardReferences conn mode reportAs ids = do
  found <- concat <$> forM ids (linksTo conn . localRef)
  pure $ case mode of
    DeleteSafe | not (null found) -> Left (ReferencedBy reportAs found)
    _ -> Right found

-- | 刪檔 → 清索引。順序與寫入時一致:檔案是真相,索引跟著走。
dropFile :: Connection -> Vault -> FilePath -> IO (Either StoreError ())
dropFile conn v rel = do
  removed <- tryRemove (vaultAbsPath v rel)
  case removed of
    Left e -> pure (Left e)
    Right () ->
      trySqlite (withTransaction conn (unindexFile conn rel)) >>= \case
        Left e -> pure (Left (IndexUpdateFailed rel (renderStoreError e)))
        Right () -> pure (Right ())

tryRemove :: FilePath -> IO (Either StoreError ())
tryRemove fp = do
  ok <- doesFileExist fp
  if not ok
    then pure (Right ()) -- 檔案已經不在,目的達成
    else Right <$> removeFile fp

-- 路徑與檔名 --------------------------------------------------------------------

-- | 決定新檔案的 Vault 相對路徑。
--
-- 呼叫端明確給了路徑就用它(已存在則 'FileAlreadyExists');否則依註冊表推導
-- 目錄、由標題產生檔名,撞名時遞增。@level@ 走硬編的 @levels\/@。
targetPath
  :: Vault -> TypeRegistry -> Text -> Text -> Maybe FilePath -> Id -> IO (Either StoreError FilePath)
targetPath v reg ty title given i = case given of
  Just p -> do
    taken <- doesFileExist (vaultAbsPath v p)
    pure (if taken then Left (FileAlreadyExists p) else Right p)
  Nothing -> case dirOf of
    Nothing -> pure (Left (RegistryDirUnknown ty))
    Just d -> Right <$> freshPath v (T.unpack d <> "/" <> T.unpack name <> ".md")
  where
    dirOf
      | ty == "level" = Just "levels"
      | otherwise = lookupDir ty reg
    name = sanitizeFileName title (renderId i)

-- | 檔名淨化。
--
-- __保留中文原字元__:Vault 是給人看的 git repo。只把檔案系統不接受的
-- @\<\>:\"\/\\|?*@ 與控制字元換成 @-@,去掉頭尾空白與句點(Windows 不接受
-- 以句點結尾的檔名),全空時退回傳入的替代字串。
sanitizeFileName :: Text -> Text -> Text
sanitizeFileName title fallback
  | T.null cleaned = fallback
  | otherwise = cleaned
  where
    replaced = T.map swap title
    swap c
      | c `elem` ("<>:\"/\\|?*" :: String) = '-'
      | isControl c = '-'
      | otherwise = c
    cleaned = T.dropAround (`elem` (" .\t" :: String)) replaced

-- | 還沒有人用的路徑。撞名就 @-2@ \/ @-3@ 遞增。
--
-- 檢查與寫入之間仍有毫秒級窗口,與 entity-graph-core/F004 已接受的競態同一種,不另外加鎖。
freshPath :: Vault -> FilePath -> IO FilePath
freshPath v rel = do
  taken <- doesFileExist (vaultAbsPath v rel)
  if not taken then pure rel else go (2 :: Int)
  where
    (base, ext) = splitExtension rel
    go n = do
      let cand = base <> "-" <> show n <> ext
      taken <- doesFileExist (vaultAbsPath v cand)
      if taken then go (n + 1) else pure cand

-- | 'mkDocument' 的 body 參數:去掉尾端空白後補一個行尾;後面還要接節時再多
-- 補一個空行,免得正文與第一個標題貼在一起。
preambleOf :: Text -> Bool -> Text
preambleOf b hasSections
  | T.null s = ""
  | hasSections = s <> "\n\n"
  | otherwise = s <> "\n"
  where
    s = T.stripEnd b

