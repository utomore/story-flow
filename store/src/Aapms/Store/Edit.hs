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
  ) where

import Data.Text (Text)
import Aapms.Core.Id (Id)
import Aapms.Core.Meta (Revision)
import Aapms.Md.Document (DocKind, Document, LineEnding)
import Aapms.Md.Error (MdError)
import Aapms.Store.Error (StoreError)
import Aapms.Store.Marker (VaultHandle)
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
(>>?) = undefined

infixl 1 >>?

-- | 純函式那一段接進同一條鏈。
(?>>)
  :: Either StoreError a
  -> (a -> IO (Either StoreError b))
  -> IO (Either StoreError b)
(?>>) = undefined

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
locate = undefined

-- 讀與解析 ---------------------------------------------------------------------

-- | 重讀檔案並切塊。@rel@ 是 Vault 相對路徑,同時當作錯誤訊息的原點。
readDocument :: VaultHandle -> FilePath -> IO (Either StoreError Document)
readDocument = undefined

-- | md 的編輯函式回的 'MdError' 包成 'StoreError'。
orMd :: FilePath -> Either MdError a -> Either StoreError a
orMd = undefined

-- 樂觀鎖 -----------------------------------------------------------------------

-- | 節點 id、呼叫端手上的 revision、檔案裡的實際 revision。
--
-- 不符即 'RevisionMismatch',而呼叫端在這之後才會碰到 'commit' ——
-- __一個位元組都不會被寫出去__(system.md 全域錯誤處理策略第 6 條)。
checkRevision :: Id -> Revision -> Revision -> Either StoreError ()
checkRevision = undefined

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
commit = undefined

-- | 刪檔 → 清索引。順序與寫入時一致:檔案是真相,索引跟著走。
dropFile :: VaultHandle -> FilePath -> IO (Either StoreError ())
dropFile = undefined

-- | 建出檔案所在的目錄。
--
-- 註冊表宣告的自訂 @dir@ 與呼叫端指定的路徑都可能還不存在,而
-- 'Aapms.Store.Atomic.atomicWriteText' 的暫存檔就開在目標目錄裡 ——
-- 目錄沒有,連暫存檔都建不起來。
ensureDir :: VaultHandle -> FilePath -> IO ()
ensureDir = undefined

-- | Vault 相對路徑 → 絕對路徑。
vaultAbsPath :: VaultHandle -> FilePath -> FilePath
vaultAbsPath = undefined

-- 切片 ------------------------------------------------------------------------

-- | 節的正文切片:@```meta@ 區塊(或標題行)之後隔一個空行,結尾補行尾。
--
-- 新節與改正文走同一個形狀,不然同一份檔案裡兩種節的排版會不一樣。
sectionBodyRaw :: LineEnding -> Text -> Text
sectionBodyRaw = undefined
