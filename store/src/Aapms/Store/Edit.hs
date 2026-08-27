-- | 所有寫入路徑共用的那一條紀律(graph-core\/F008)。內部模組,不對外承諾介面。
--
-- 契約 E 的寫入組有十二條;順序不能調換,也不能各寫一份:
--
-- @
-- 讀檔 → parseDocument → 樂觀鎖比對 → 純函式編輯 → atomicWriteText → indexFile
--                             ↑ 不符 = RevisionMismatch(一個位元組都不寫)
--                                                        ↑ 失敗 = IndexUpdateFailed(檔案已落地)
-- @
--
-- == ADR-022(寫鎖預算)在本模組的落地形狀
--
-- 上面那條線裡,__所有__檔案 IO、Markdown 解析與序列化都發生在任何 SQLite
-- 呼叫之外;'commit' 把「已經算好的 'Document'」交出去之後才碰索引,而碰索引
-- 的唯一入口是 'Aapms.Store.Index.indexFile'(它自己在交易外完成讀檔與解析)。
-- 因此本 feature 的四個模組__不得出現 @withTransaction@__,也不得在任何
-- SQLite 呼叫之間插入檔案 IO ——這是可稽核的結構約束,不是需要判斷的規則。
--
-- == 錯誤型別
--
-- 本模組__不定義錯誤型別__:寫入路徑的十五個失敗原因是
-- 'Aapms.Store.Error.StoreError' 的建構子(design.md 契約 G ——
-- @StoreError@ 是 @aapms-store@ 的唯一錯誤型別,由各 feature 擴充,不得另立
-- 平行型別再橋接)。
--
-- == 為什麼重讀檔案而不信任索引裡的 revision
--
-- 作者可能剛用編輯器改過,索引還沒 refresh。拿過時的 revision 去比對,樂觀鎖
-- 就形同虛設(ADR-002:檔案是真相)。索引只用來__定位__(哪個檔、哪一節)。
--
-- 殘留競態見 "Aapms.Store.Atomic":重讀與 rename 之間的毫秒級窗口是 F005 明確
-- 接受的風險,本 feature 沿用同一個結論。
module Aapms.Store.Edit
  ( -- * 結果
    WriteResult (..)

    -- * 短路組合
  , (>>?)
  , (?>>)

    -- * 定位
  , Located (..)
  , locate

    -- * 讀與解析(交易之外)
  , readDocument
  , orMd

    -- * 樂觀鎖
  , checkRevision

    -- * 落地
  , commit
  , dropFile
  , ensureDir
  , vaultAbsPath

    -- * 切片
  , sectionBodyRaw

    -- * 共用:讀出目標目前的 Meta / Asset(供 Write / Create 使用)
  , currentMetaAt
  , currentAssetAt
  ) where

import Control.Exception (IOException, try)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), query)
import System.Directory (createDirectoryIfMissing, removeFile)
import System.FilePath (takeDirectory, (</>))
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, parseId, renderId)
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..), Revision)
import Aapms.Core.Pack (Pack (..))
import Aapms.Md.Document (DocKind (..), Document, LineEnding, renderLineEnding)
import Aapms.Md.Error (MdError)
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Md.Render (renderDocument)
import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Error (StoreError (..), renderStoreError, trySqlite)
import Aapms.Store.Index (indexFile, unindexFile)
import Aapms.Store.Marker (VaultHandle (..))
import Aapms.Store.Schema (IndexIssue)

-- 結果 ------------------------------------------------------------------------

-- | 一次成功寫入的結果。
--
-- @wrIssues@ 是寫入後 'Aapms.Store.Index.indexFile' 對__該檔__回報的問題
-- (@checkMeta@ 警告等);它不是失敗,是附帶回報,由 @service@ 決定怎麼辦。
data WriteResult = WriteResult
  { wrId :: Id
  , wrPath :: FilePath
  -- ^ Vault 相對路徑,與索引裡存的形式一致
  , wrRevision :: Revision
  -- ^ 寫入後的新 revision(= 傳入的 expected + 1)
  , wrIssues :: [IndexIssue]
  }
  deriving stock (Show, Eq)

-- 短路組合 ---------------------------------------------------------------------

-- | @Either@ 短路的 IO 鏈。每個寫入路徑都是五到七個「失敗就回 'Left'」的步驟。
(>>?)
  :: IO (Either StoreError a)
  -> (a -> IO (Either StoreError b))
  -> IO (Either StoreError b)
ioa >>? f = ioa >>= either (pure . Left) f

infixl 1 >>?

-- | 純函式那一段接進同一條鏈。
(?>>)
  :: Either StoreError a
  -> (a -> IO (Either StoreError b))
  -> IO (Either StoreError b)
ea ?>> f = either (pure . Left) f ea

infixl 1 ?>>

-- 定位 ------------------------------------------------------------------------

-- | 索引裡的 @nodes.file_path@ \/ @nodes.section_anchor@ 與 @files.doc_kind@。
--
-- 索引在寫入路徑上__只做定位__:哪個檔、哪一節、那是哪一種文件。所有會被比對
-- 或寫回的值一律重讀檔案取得。
data Located = Located
  { locPath :: FilePath
  -- ^ Vault 相對路徑
  , locAnchor :: Maybe Id
  -- ^ @Nothing@ = 檔案層主體(meta 在 frontmatter,不在任何一節)
  , locKind :: DocKind
  }
  deriving stock (Show, Eq)

-- | 一張 @nodes@ 表裝所有節點,所以定位只要一次查詢。查不到回 'NodeNotFound'。
locate :: VaultHandle -> Id -> IO (Either StoreError Located)
locate vh i = do
  rowsR <-
    trySqlite
      ( query
          (vhConn vh)
          "SELECT n.file_path, n.section_anchor, f.doc_kind \
          \FROM nodes n JOIN files f ON f.path = n.file_path WHERE n.id = ?"
          (Only (renderId i))
      ) ::
      IO (Either StoreError [(Text, Maybe Text, Text)])
  pure $ case rowsR of
    Left e -> Left e
    Right [] -> Left (NodeNotFound i)
    Right ((fp, anchorText, kindText) : _) ->
      Right
        Located
          { locPath = T.unpack fp
          , locAnchor = anchorText >>= parseAnchorId
          , -- 索引裡的 doc_kind 一律由本套件自己寫入(見 "Aapms.Store.Row"
            -- 的 renderDocKind),認不得時不該發生;寬鬆地落到 'TopicDoc'
            -- 而不是讓查詢整個炸掉——索引是可重建的衍生物。
            locKind = maybe TopicDoc id (parseDocKindText kindText)
          }
  where
    parseAnchorId t = either (const Nothing) (Just . snd) (parseId t)

-- | 與 "Aapms.Store.Row" 的 @renderDocKind@ 互逆,本模組不 import 該內部模組
-- (依賴方向只到 'Aapms.Store.Error'),所以在此重寫同一組四個字面值。
parseDocKindText :: Text -> Maybe DocKind
parseDocKindText = \case
  "topic" -> Just TopicDoc
  "level" -> Just LevelDoc
  "pack" -> Just PackDoc
  "license" -> Just LicenseDoc
  _ -> Nothing

-- 讀與解析 ---------------------------------------------------------------------

-- | 重讀檔案並切塊。@rel@ 是 Vault 相對路徑,同時當作錯誤訊息的原點。
readDocument :: VaultHandle -> FilePath -> IO (Either StoreError Document)
readDocument vh rel = do
  txtR <- readTextFile (vaultAbsPath vh rel)
  pure (txtR >>= orMd rel . parseDocument)

-- | md 的編輯函式回的 'MdError' 包成 'StoreError'。
orMd :: FilePath -> Either MdError a -> Either StoreError a
orMd fp = either (Left . MdWriteFailed fp) Right

-- 樂觀鎖 -----------------------------------------------------------------------

-- | 節點 id、呼叫端手上的 revision、檔案裡的實際 revision。
--
-- 不符即 'RevisionMismatch',而呼叫端在這之後才會碰到 'commit' ——
-- __一個位元組都不會被寫出去__(system.md 全域錯誤處理策略第 6 條)。
checkRevision :: Id -> Revision -> Revision -> Either StoreError ()
checkRevision i expected actual
  | expected == actual = Right ()
  | otherwise = Left (RevisionMismatch i expected actual)

-- 落地 ------------------------------------------------------------------------

-- | 先寫檔、再更新索引(design.md 寫入管線;順序固定)。
--
-- 索引那一步失敗時檔案__已經寫成功__,所以回的是 'IndexUpdateFailed' 而不是
-- 檔案錯誤:呼叫端該說的是「資料已寫入,索引需重建」。
--
-- 進到本函式時 'Document' 必須__已經是最終內容__ ——序列化、樹驗證、繼承展開
-- 全部在此之前完成。這是 ADR-022 的結構約束:交易(索引那一段)只接受算好的值。
commit
  :: VaultHandle
  -> FilePath
  -- ^ Vault 相對路徑
  -> Document
  -> Id
  -- ^ 這次寫入的主體 id(回傳用)
  -> Revision
  -- ^ 寫入後的新 revision
  -> IO (Either StoreError WriteResult)
commit vh rel doc wid newRev = do
  ensureDir vh rel
  writeR <- atomicWriteText (vaultAbsPath vh rel) (renderDocument doc)
  case writeR of
    Left e -> pure (Left e)
    Right () ->
      indexFile vh rel >>= \case
        Left e -> pure (Left (IndexUpdateFailed rel (renderStoreError e)))
        Right issues -> pure (Right (WriteResult wid rel newRev issues))

-- | 刪檔 → 清索引。順序與寫入時一致:檔案是真相,索引跟著走。
dropFile :: VaultHandle -> FilePath -> IO (Either StoreError ())
dropFile vh rel = do
  let absPath = vaultAbsPath vh rel
  removed <- try (removeFile absPath) :: IO (Either IOException ())
  case removed of
    Left e -> pure (Left (FileWriteFailed absPath ("刪除檔案失敗 —— " <> T.pack (show e))))
    Right () -> unindexFile vh rel

-- | 建出檔案所在的目錄。
--
-- 註冊表宣告的自訂 @dir@ 與呼叫端指定的路徑都可能還不存在,而
-- 'Aapms.Store.Atomic.atomicWriteText' 的暫存檔就開在目標目錄裡 ——
-- 目錄沒有,連暫存檔都建不起來。
ensureDir :: VaultHandle -> FilePath -> IO ()
ensureDir vh rel = createDirectoryIfMissing True (takeDirectory (vaultAbsPath vh rel))

-- | Vault 相對路徑 → 絕對路徑。
vaultAbsPath :: VaultHandle -> FilePath -> FilePath
vaultAbsPath vh rel = vhRoot vh </> rel

-- 切片 ------------------------------------------------------------------------

-- | 節的正文切片:@```meta@ 區塊(或標題行)之後隔一個空行,結尾補行尾。
--
-- 新節與改正文走同一個形狀,不然同一份檔案裡兩種節的排版會不一樣。
sectionBodyRaw :: LineEnding -> Text -> Text
sectionBodyRaw le t = nl <> T.strip t <> nl
  where
    nl = renderLineEnding le

-- 共用:讀出目標目前的 Meta / Asset ---------------------------------------------
--
-- 'Aapms.Store.Write' 與 'Aapms.Store.Create' 都需要「目標目前真正的 Meta」
-- 才能做樂觀鎖比對(不可逆決定 2:來源是重讀的檔案,不是索引)。四種文件的
-- 檔案層主體與節分別由 'toTopic' \/ 'toLevel' \/ 'toPack' \/ 'toLicenses' 解讀,
-- 派送邏輯集中在這裡,'Write' 與 'Create' 都不用各自重寫一份。

-- | @path@、目標所在文件的種類、目標 id、'Aapms.Store.Edit.locAnchor'(定位
-- 結果)→ 目標目前的 'Meta'。找不到回 'SectionMissing'。
currentMetaAt :: FilePath -> DocKind -> Id -> Maybe Id -> Document -> Either StoreError Meta
currentMetaAt path kind target anchor doc = case kind of
  TopicDoc -> do
    (mainE, frags) <- orMd path (toTopic doc)
    case anchor of
      Nothing -> Right (entMeta mainE)
      Just _ -> maybe (Left (SectionMissing path target)) (Right . entMeta) (find ((== target) . metaId . entMeta) frags)
  LevelDoc -> do
    (lvl, nodes) <- orMd path (toLevel doc)
    case anchor of
      Nothing -> Right (lvlMeta lvl)
      Just _ -> maybe (Left (SectionMissing path target)) (Right . nodMeta) (find ((== target) . metaId . nodMeta) nodes)
  PackDoc -> do
    (pck, assets) <- orMd path (toPack doc)
    case anchor of
      Nothing -> Right (pckMeta pck)
      Just _ -> maybe (Left (SectionMissing path target)) (Right . astMeta) (find ((== target) . metaId . astMeta) assets)
  LicenseDoc -> do
    lics <- orMd path (toLicenses doc)
    maybe (Left (SectionMissing path target)) (Right . licMeta) (find ((== target) . metaId . licMeta) lics)

-- | 同 'currentMetaAt',但回傳完整的 'Asset'(供 @writeAssetFields@ 保留唯讀
-- 欄位用)。目標必須落在 @pack.md@ 裡。
currentAssetAt :: FilePath -> Id -> Document -> Either StoreError Asset
currentAssetAt path target doc = do
  (_, assets) <- orMd path (toPack doc)
  maybe (Left (SectionMissing path target)) Right (find ((== target) . metaId . astMeta) assets)
