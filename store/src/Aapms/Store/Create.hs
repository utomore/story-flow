-- | 建檔、增節、刪除,以及寫入路徑的輸入 DTO(graph-core\/F008)。
--
-- 「改寫既有節點」在 "Aapms.Store.Write",「Level 樹的純推導」在
-- "Aapms.Store.Node";共用的紀律在 "Aapms.Store.Edit";失敗原因在
-- "Aapms.Store.Error"。
--
-- __一個新節的形狀不是本模組定義的__:'NewSection' 家族住在 "Aapms.Md.Render"
-- (design.md 契約 D),本模組只 re-export ——序列化規則只有一份,它的輸入形狀
-- 自然也只該有一份。
--
-- == 檔案放哪裡
--
-- 目錄是__宣告式__的:'Aapms.Core.Registry.lookupDir' 查型別註冊表,查不到就回
-- 'Aapms.Store.Error.RegistryDirUnknown' 而不是默默丟進 vault 根目錄。否則
-- 「新增一種型別不必改程式」這條垂直切片會在「檔案該放哪」這一步破掉。Level 檔的
-- 目錄硬編為 @levels\/@ ——@level@ 是保留鍵,不可能出現在註冊表裡。pack.md 的目錄
-- 由呼叫端給('npDir'):一個 pack 的目錄同時是它散檔的根,只有 @asset-ingest@
-- 知道那是哪裡。
--
-- 檔名__保留中文原字元__:vault 是給人看的 git repo,@characters\/琳達.md@ 比雜湊
-- 好一百倍。只替換檔案系統不接受的字元。
--
-- == 配號與時間
--
-- 'createTopicFile' \/ 'createLevelFile' \/ 'createPackFile' \/ 'addSection' 內部都會
-- 呼叫 'Aapms.Store.Write.allocateId',而它自 2026-08-25(G8 裁決)起__把時間收成
-- 明碼參數__。這四個函式的__對外簽名不變__:它們自己呼叫
-- 'Data.Time.getCurrentTime' 取當下時間再傳進去,不把 'Data.Time.UTCTime' 一路往上
-- 加到契約 E 的簽名裡。可控時間源是 'Aapms.Store.Write.allocateId' 一個人的事,
-- 建檔路徑不需要那個能力。
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

    -- * 輸入:一個新的節(定義在 "Aapms.Md.Render",本模組只 re-export)
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
  , SectionPlacement (..)
  , createTopicFile
  , createLevelFile
  , createPackFile
  , addSection

    -- * 刪除
  , deleteNode

    -- * 檔名
  , sanitizeFileName
  ) where

import Control.Monad (foldM)
import Data.Char (isControl, isSpace)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime, utctDay)
import Aapms.Core.Asset (Sha256)
import Aapms.Core.Id (Id, IdPrefix (..), Ref, localRef, renderId)
import Aapms.Core.Level (NodeKind)
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Meta (..), Revision (..), Source, Status, Timeline, TypeKey (..), bumpRevision)
import Aapms.Core.Pack (AiDisclosure, Author)
import Aapms.Core.Registry (TypeRegistry, lookupDir)
import Aapms.Md.Document (DocKind (..), Document, sectionIds)
import Aapms.Md.Error (MdError)
import Aapms.Md.Inherit (emptyOverride)
import Aapms.Md.Render
  ( NewAsset (..)
  , NewLicense (..)
  , NewNode (..)
  , NewSection (..)
  , NewSectionPayload (..)
  , appendSection
  , insertSection
  , newDocument
  , removeSection
  , updateFrontmatter
  )
import Aapms.Store.Edit
  ( Located (..)
  , WriteResult (..)
  , checkRevision
  , commit
  , currentMetaAt
  , dropFile
  , locate
  , orMd
  , readDocument
  , vaultAbsPath
  )
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..))
import Aapms.Store.Node (headingDepthFor, isRootNode, subtreeIds, validateLevelDoc)
import Aapms.Store.Query (linksTo)
import Aapms.Store.Schema (IndexIssue)
import Aapms.Store.Write (allocateId)
import System.Directory (doesFileExist)

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
  -- 明確給了卻已經有檔案時回 'Aapms.Store.Error.FileAlreadyExists' ——那是指定,
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

-- 輸入:一個新的節(re-export)-----------------------------------------------------

-- NewSection / NewSectionPayload / NewAsset / NewLicense / NewNode 定義在
-- Aapms.Md.Render(design.md 契約 D 就把它們寫在 md 那一節;graph-core/F004 的
-- G2 重跑已經落地)。本模組只 re-export,呼叫端因此不必知道一個新節的形狀是誰
-- 定的 —— 它是 md 的序列化輸入,store 只是把它轉交出去。
--
-- nsId 由呼叫端先以 allocateId 配好再傳進來:md 那一層不知道怎麼配 id,而配號
-- 需要索引在場(ADR-014)。

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

-- | 新節要落在哪裡(契約 E,2026-08-25 裁決)。
--
-- 用__封閉 sum__ 而不是 @Maybe Id@:落點種類日後若要再長(例如「插在某個兄弟
-- 之前」),編譯器會列出所有待處理處 ——與 'Aapms.Core.AnyNode.AnyNode' \/
-- 'Aapms.Md.Render.NewSectionPayload' \/ 'DeleteMode' 同一個模式。
data SectionPlacement
  = -- | 追加在檔尾('Aapms.Md.Render.appendSection')
    AtEnd
  | -- | 插在指定父節點的子樹之後,成為它的最後一個子節點
    -- ('Aapms.Md.Render.insertSection')。__只有 @LevelDoc@ 用得到__:另外三種
    -- 文件的節是平的
    UnderParent Id
  deriving stock (Show, Eq)

-- | 建一份新的主題檔。
--
-- 落點依註冊表的 @dir@('Aapms.Core.Registry.lookupDir');查不到回
-- 'Aapms.Store.Error.RegistryDirUnknown'。註冊表由呼叫端傳入而不是取自
-- 'Aapms.Store.Marker.vhRegistry' ——契約 E 的簽名如此,而且建檔是唯一「用哪一份
-- 註冊表決定落點」有可能與索引時不同的場合(@service@ 可能先做過型別遷移)。
--
-- 新檔一律用 'Aapms.Md.Document.LF';Windows 上的 git 由 @core.autocrlf@ 處理,
-- 工具不介入。
createTopicFile
  :: VaultHandle
  -> TypeRegistry
  -> NewEntity
  -> IO (Either StoreError CreateResult)
createTopicFile vh reg NewEntity {..} = case lookupDir reg neType of
  Nothing -> pure (Left (RegistryDirUnknown neType))
  Just dir -> do
    t <- getCurrentTime
    let today = utctDay t
    idR <- allocateId vh PEnt neTitle t
    case idR of
      Left e -> pure (Left e)
      Right newId' -> do
        pathR <- resolvePath vh dir neTitle newId' nePath
        case pathR of
          Left e -> pure (Left e)
          Right relPath -> do
            let meta =
                  Meta
                    { metaId = newId'
                    , metaVault = vmId (vhMarker vh)
                    , metaType = neType
                    , metaTitle = neTitle
                    , metaSummary = neSummary
                    , metaTags = neTags
                    , metaStatus = neStatus
                    , metaTimeline = neTimeline
                    , metaAliases = neAliases
                    , metaLinks = neLinks
                    , metaSource = neSource
                    , metaRevision = Revision 1
                    , metaCreated = today
                    , metaUpdated = today
                    }
                doc = newDocument TopicDoc meta neBody
            result <- commit vh relPath doc newId' (Revision 1)
            pure (fmap toCreateResult result)

-- | 一份新檔的落點:呼叫端明確給了路徑就照給的用(已存在則 'FileAlreadyExists');
-- 否則依 'sanitizeFileName' 從標題推導,撞名就在檔名主幹後面加 @-2@、@-3@……
resolvePath :: VaultHandle -> FilePath -> Text -> Id -> Maybe FilePath -> IO (Either StoreError FilePath)
resolvePath vh _ _ _ (Just p) = do
  exists <- doesFileExist (vaultAbsPath vh p)
  pure $ if exists then Left (FileAlreadyExists p) else Right p
resolvePath vh dir title fallbackId Nothing = do
  let base = sanitizeFileName title (renderId fallbackId)
  findFreePath vh dir base (0 :: Int)

findFreePath :: VaultHandle -> FilePath -> Text -> Int -> IO (Either StoreError FilePath)
findFreePath vh dir base n = do
  let name = if n == 0 then base <> ".md" else base <> "-" <> T.pack (show (n + 1)) <> ".md"
      rel = dir <> "/" <> T.unpack name
  exists <- doesFileExist (vaultAbsPath vh rel)
  if exists then findFreePath vh dir base (n + 1) else pure (Right rel)

toCreateResult :: WriteResult -> CreateResult
toCreateResult wr = CreateResult (wrId wr) (wrPath wr) (wrRevision wr) (wrIssues wr)

-- | 建一份新的 Level 檔,連同它的根 Node。
--
-- 目錄固定 @levels\/@:@level@ 是保留型別鍵,不可能在註冊表裡宣告 @dir@。根 Node
-- 用 @##@,留一級給 @#@ 當作者想寫的檔案大標。
createLevelFile
  :: VaultHandle
  -> TypeRegistry
  -> NewLevel
  -> IO (Either StoreError CreateResult)
createLevelFile vh _reg NewLevel {..} = do
  t <- getCurrentTime
  let today = utctDay t
  lvlIdR <- allocateId vh PLvl nlTitle t
  case lvlIdR of
    Left e -> pure (Left e)
    Right lvlId -> do
      pathR <- resolvePath vh "levels" nlTitle lvlId nlPath
      case pathR of
        Left e -> pure (Left e)
        Right relPath -> do
          rootIdR <- allocateId vh PNod nlRootTitle t
          case rootIdR of
            Left e -> pure (Left e)
            Right rootId -> do
              let meta =
                    Meta
                      { metaId = lvlId
                      , metaVault = vmId (vhMarker vh)
                      , metaType = TypeKey "level"
                      , metaTitle = nlTitle
                      , metaSummary = nlSummary
                      , metaTags = []
                      , metaStatus = nlStatus
                      , metaTimeline = Nothing
                      , metaAliases = []
                      , metaLinks = []
                      , metaSource = nlSource
                      , metaRevision = Revision 1
                      , metaCreated = today
                      , metaUpdated = today
                      }
                  doc0 = newDocument LevelDoc meta nlBody
                  rootSection =
                    NewSection
                      { nsId = rootId
                      , nsLevel = 2
                      , nsTitle = nlRootTitle
                      , nsBody = ""
                      , nsPayload = NSNode emptyOverride (NewNode nlRootKind)
                      }
              case orMd relPath (appendSection rootSection doc0) of
                Left e -> pure (Left e)
                Right doc1 -> do
                  result <- commit vh relPath doc1 lvlId (Revision 1)
                  pure (fmap toCreateResult result)

-- | 在 'npDir' 寫出一份 @pack.md@,節的順序與給定順序__相同__。
--
-- 第三個參數是 @[NewSection]@ 而不是 @[NewAsset]@(2026-08-25 已回寫契約 E):
-- G1 之後 'NewAsset' 只剩 asset 專屬七欄,組不出節的標題與節層 meta。
-- 每一節的 'nsPayload' 必須是 'NSAsset',否則回
-- 'Aapms.Store.Error.BadSectionPayload' ——@pack.md@ 的節只能是 asset。
--
-- 與 'addSection' 走同一條序列化路徑,「順序相同」因此是結構上的結果,不是另外
-- 維護的一條規則。
createPackFile
  :: VaultHandle
  -> NewPack
  -> [NewSection]
  -> IO (Either StoreError CreateResult)
createPackFile vh NewPack {..} sections = case find (not . isAssetPayload . nsPayload) sections of
  Just bad -> pure (Left (BadSectionPayload (nsId bad) PackDoc))
  Nothing -> do
    t <- getCurrentTime
    let today = utctDay t
        relPath = npDir <> "/pack.md"
    pckIdR <- allocateId vh PPck npTitle t
    case pckIdR of
      Left e -> pure (Left e)
      Right pckId -> do
        let meta =
              Meta
                { metaId = pckId
                , metaVault = vmId (vhMarker vh)
                , metaType = TypeKey "asset-pack"
                , metaTitle = npTitle
                , metaSummary = npSummary
                , metaTags = npTags
                , metaStatus = npStatus
                , metaTimeline = Nothing
                , metaAliases = []
                , metaLinks = []
                , metaSource = npSource
                , metaRevision = Revision 1
                , metaCreated = today
                , metaUpdated = today
                }
            doc0 = newDocument PackDoc meta npBody
        case orMd relPath (foldM (flip appendSection) doc0 sections) of
          Left e -> pure (Left e)
          Right doc1 -> do
            result <- commit vh relPath doc1 pckId (Revision 1)
            pure (fmap toCreateResult result)
  where
    isAssetPayload (NSAsset _ _) = True
    isAssetPayload _ = False

-- | 往既有檔案加一個節:片段 \/ asset \/ license \/ node,依
-- 'Aapms.Md.Render.nsPayload' 分派。
--
-- 第二個參數是__檔案層主體__的 id(用來定位檔案);傳節的 id 回
-- 'Aapms.Store.Error.BadSectionPayload'。@licenses.md@ 的檔案層是容器不是節點
-- ('Aapms.Md.Parse.toLicenses' 只回 @[License]@),所以那一種文件以檔案裡任一
-- 既有 license 節的 id 定位。
--
-- 第三個參數是__落點__('SectionPlacement',2026-08-25 裁決):
--
-- * 'AtEnd' —— 追加在檔尾,'Aapms.Md.Render.appendSection';
--   __不動前面任何一節的位元組__(ADR-010)
-- * @'UnderParent' p@ —— 插在父節點 @p@ 的子樹之後,
--   'Aapms.Md.Render.insertSection';此時 @nsLevel@ __由本層以__
--   'Aapms.Store.Node.headingDepthFor' __推導__(= @secLevel p + 1@),
--   __不看呼叫端給的值__ ——呼叫端自己算標題層級等於讓父子關係有兩個真相來源。
--   @p@ 不在檔案裡回 'Aapms.Store.Error.SectionMissing',推導出來超過六級回
--   'Aapms.Store.Error.NodeDepthExceeded',兩者都在寫檔之前,檔案位元組不變
--
-- payload 與目標檔案的 'Aapms.Md.Document.DocKind' 必須相容
-- (@TopicDoc@↔@NSFragment@、@PackDoc@↔@NSAsset@、@LicenseDoc@↔@NSLicense@、
-- @LevelDoc@↔@NSNode@),不符回 'Aapms.Store.Error.BadSectionPayload' 且不寫檔。
-- @LevelDoc@ 額外在寫檔前跑 'Aapms.Store.Node.validateLevelDoc'。
--
-- 檔案層主體的 revision 走完會 +1:這是樂觀鎖的另一半,不遞增的話兩個並發的
-- 'addSection' 拿同一個 revision 都會通過。
addSection
  :: VaultHandle
  -> Id
  -> SectionPlacement
  -> NewSection
  -> IO (Either StoreError CreateResult)
addSection vh targetId placement sec = do
  locR <- locate vh targetId
  case locR of
    Left e -> pure (Left e)
    Right loc
      | not (payloadMatchesDocKind (nsPayload sec) (locKind loc)) ->
          pure (Left (BadSectionPayload (nsId sec) (locKind loc)))
      | locKind loc /= LicenseDoc, locAnchor loc /= Nothing ->
          -- 第二個參數必須是檔案層主體的 id;傳節的 id 回 BadSectionPayload。
          -- licenses.md 是唯一的例外(容器不是節點,以任一既有 license 節定位)。
          pure (Left (BadSectionPayload (nsId sec) (locKind loc)))
      | otherwise -> do
          docR <- readDocument vh (locPath loc)
          case docR of
            Left e -> pure (Left e)
            Right doc -> case placement of
              AtEnd -> proceedAdd vh loc doc targetId sec appendSection
              UnderParent p -> case headingDepthFor (locPath loc) doc p of
                Left e -> pure (Left e)
                Right depth -> proceedAdd vh loc doc targetId (sec {nsLevel = depth}) (insertSection p)

payloadMatchesDocKind :: NewSectionPayload -> DocKind -> Bool
payloadMatchesDocKind (NSFragment _) TopicDoc = True
payloadMatchesDocKind (NSAsset _ _) PackDoc = True
payloadMatchesDocKind (NSLicense _ _) LicenseDoc = True
payloadMatchesDocKind (NSNode _ _) LevelDoc = True
payloadMatchesDocKind _ _ = False

-- | 'addSection' 兩種落點共用的後半段:視情況把檔案層主體的 revision +1、
-- (@LevelDoc@)重新驗證整棵樹,最後落地。
proceedAdd
  :: VaultHandle
  -> Located
  -> Document
  -> Id
  -> NewSection
  -> (NewSection -> Document -> Either MdError Document)
  -> IO (Either StoreError CreateResult)
proceedAdd vh loc doc targetId sec insertFn =
  case orMd (locPath loc) (insertFn sec doc) of
    Left e -> pure (Left e)
    Right doc1 -> do
      today <- utctDay <$> getCurrentTime
      -- licenses.md 的檔案層是容器,不是索引裡的節點,沒有可比對的 revision
      -- 可 bump;另外三種文件的檔案層主體本來就是 targetId 本身。
      revE <-
        if locKind loc == LicenseDoc
          then pure (Right Nothing)
          else pure (Just <$> currentMetaAt (locPath loc) (locKind loc) targetId (locAnchor loc) doc)
      case revE of
        Left e -> pure (Left e)
        Right curMetaM -> do
          let bumpedM = bumpRevision today <$> curMetaM
              newRev = maybe (Revision 1) metaRevision bumpedM
              doc2E = case bumpedM of
                Nothing -> Right doc1
                Just bumped -> orMd (locPath loc) (updateFrontmatter (const bumped) doc1)
          case doc2E of
            Left e -> pure (Left e)
            Right doc2 ->
              case locKind loc of
                LevelDoc -> case validateLevelDoc (locPath loc) doc2 of
                  Left e -> pure (Left e)
                  Right () -> finishAdd vh loc doc2 sec newRev
                _ -> finishAdd vh loc doc2 sec newRev

finishAdd :: VaultHandle -> Located -> Document -> NewSection -> Revision -> IO (Either StoreError CreateResult)
finishAdd vh loc doc2 sec newRev = do
  result <- commit vh (locPath loc) doc2 (nsId sec) newRev
  pure (fmap (\wr -> CreateResult (nsId sec) (wrPath wr) newRev (wrIssues wr)) result)

-- 刪除 ------------------------------------------------------------------------

-- | 刪一個節點。目標是什麼決定刪掉多少:
--
-- * 檔案層主體(主題檔 \/ Level 檔 \/ pack.md 的 @pck-@)→ __整份檔案__,
--   連同檔內全部節
-- * 主題檔的片段 \/ pack.md 的 asset \/ licenses.md 的 license → 該一節
-- * Level 檔的 Node → 該節__與它整棵子樹__('Aapms.Store.Node.subtreeIds');
--   根 Node 回 'Aapms.Store.Error.CannotDeleteRootNode',請改刪整份 Level 檔
--
-- 第三個參數是被刪目標的 revision:刪除也走樂觀鎖,否則「作者剛改完、Agent 拿
-- 舊資料刪掉」會靜默生效。
--
-- 'DeleteSafe' 對__每一個__要消失的 id 做被引用檢查,任何一個被指向就整份拒絕
-- ('Aapms.Store.Error.ReferencedBy',且檔案未動);'DeleteForce' 照刪並把被打斷的
-- 關聯放進 'drBrokenLinks'。
deleteNode
  :: VaultHandle
  -> Id
  -> Revision
  -> DeleteMode
  -> IO (Either StoreError DeleteResult)
deleteNode vh i expected mode = do
  locR <- locate vh i
  case locR of
    Left e -> pure (Left e)
    Right loc -> do
      docR <- readDocument vh (locPath loc)
      case docR of
        Left e -> pure (Left e)
        Right doc -> do
          let rootCheckE =
                if locKind loc == LevelDoc
                  then isRootNode (locPath loc) doc i
                  else Right False
          case rootCheckE of
            Left e -> pure (Left e)
            Right True -> pure (Left (CannotDeleteRootNode i))
            Right False ->
              case currentMetaAt (locPath loc) (locKind loc) i (locAnchor loc) doc of
                Left e -> pure (Left e)
                Right curMeta -> case checkRevision i expected (metaRevision curMeta) of
                  Left e -> pure (Left e)
                  Right () -> do
                    let victims = case locAnchor loc of
                          Nothing -> i : sectionIds doc
                          Just _ -> subtreeIds doc i
                    refs <- gatherReferrers vh victims
                    case mode of
                      DeleteSafe | not (null refs) -> pure (Left (ReferencedBy i refs))
                      _ -> performDelete vh loc doc i victims refs

gatherReferrers :: VaultHandle -> [Id] -> IO [(Id, Link)]
gatherReferrers vh victims = do
  results <- mapM (linksTo vh . localRef) victims
  pure [(metaId m, l) | rs <- results, (m, l) <- rs]

performDelete :: VaultHandle -> Located -> Document -> Id -> [Id] -> [(Id, Link)] -> IO (Either StoreError DeleteResult)
performDelete vh loc doc i victims refs = case locAnchor loc of
  Nothing -> do
    result <- dropFile vh (locPath loc)
    pure (fmap (const (DeleteResult (locPath loc) victims refs [])) result)
  Just _ -> case orMd (locPath loc) (foldM (flip removeSection) doc victims) of
    Left e -> pure (Left e)
    Right doc1 -> do
      -- commit 的 Revision 參數只用來組回傳的 WriteResult;'DeleteResult' 沒有
      -- revision 欄位,這裡寫哪個值都不影響任何可觀察行為
      result <- commit vh (locPath loc) doc1 i (Revision 1)
      pure (fmap (\wr -> DeleteResult (locPath loc) victims refs (wrIssues wr)) result)

-- 檔名 ------------------------------------------------------------------------

-- | 檔名淨化:標題 → 檔名主幹。
--
-- __保留中文原字元__(vault 是給人看的 git repo)。只把檔案系統不接受的
-- @\<\>:\"\/\\|?*@ 與控制字元換成 @-@,去掉頭尾空白與句點(Windows 不接受以句點
-- 結尾的檔名);全部被清掉時退回第二個參數(慣例上是該節點的短 id)。
sanitizeFileName :: Text -> Text -> Text
sanitizeFileName t fb =
  let replaced = T.map replaceChar t
      trimmed = T.dropWhileEnd trimChar (T.dropWhile trimChar replaced)
   in if T.null trimmed then fb else trimmed
  where
    trimChar c = isSpace c || c == '.'
    replaceChar c
      | c `elem` ("<>:\"/\\|?*" :: String) = '-'
      | isControl c = '-'
      | otherwise = c
