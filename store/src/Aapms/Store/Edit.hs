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
-- 'WriteResult' 與 'Located' 的宣告住 "Aapms.Store.Types"(型別層),寫入路徑上
-- 不碰 IO 的那幾個函式('checkRevision' \/ 'orMd' \/ 'sectionBodyRaw' \/
-- 'currentMetaAt' \/ 'currentAssetAt')住 "Aapms.Store.Editing"(純);本模組原樣
-- re-export,匯出清單與呼叫端逐字不變,自己只剩 IO。
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
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), query)
import System.Directory (createDirectoryIfMissing, removeFile)
import System.FilePath (takeDirectory, (</>))
import Aapms.Core.Id (Id, parseId, renderId)
import Aapms.Core.Meta (Revision)
import Aapms.Md.Document (DocKind (..), Document)
import Aapms.Md.Parse (parseDocument)
import Aapms.Md.Render (renderDocument)
import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Editing
  ( checkRevision
  , currentAssetAt
  , currentMetaAt
  , orMd
  , sectionBodyRaw
  )
import Aapms.Store.Error (StoreError (..), renderStoreError, trySqlite)
import Aapms.Store.Index (indexFile, unindexFile)
import Aapms.Store.Marker (VaultHandle (..))
import Aapms.Store.Types (Located (..), WriteResult (..))

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

