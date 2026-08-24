-- | 改寫既有節點,與短 id 的配號(graph-core\/F008)。
--
-- 「建檔 \/ 增節 \/ 刪除」在 "Aapms.Store.Create",「Level 樹的純推導」在
-- "Aapms.Store.Node";三者共用的那條紀律(讀 → 樂觀鎖 → 純函式編輯 → 寫檔 →
-- 索引)在 "Aapms.Store.Edit",本模組不重寫一遍。
--
-- 檔案層主體與節走__同一組介面__:差別只在 'Aapms.Store.Edit.locAnchor' 是不是
-- 'Nothing',而那件事由 'Aapms.Store.Edit.locate' 回答,不必呼叫端指定。節改的是
-- 該節的 @```meta@ 區塊(只有那一段被重新序列化,ADR-010),主體改的是
-- frontmatter。
--
-- __本模組不做業務判斷__(契約卡「明確不做」):名稱是否全域唯一由 @service@
-- 在呼叫之前以 'Aapms.Store.Query.lookupByName' 查過;本模組只負責把值寫下去。
module Aapms.Store.Write
  ( -- * asset 的人給欄位
    AssetPatch (..)

    -- * Meta
  , writeMeta
  , writeAssetFields

    -- * 正文
  , writeBody

    -- * 關聯
  , addLink
  , removeLink

    -- * 授權
  , upsertLicense

    -- * ID
  , allocateId
  ) where

import Data.Text (Text)
import Aapms.Core.Asset (LogicalName)
import Aapms.Core.Id (Id, IdPrefix, Ref)
import Aapms.Core.License (License)
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Revision)
import Aapms.Md.Inherit (MetaOverride)
import Aapms.Store.Edit (StoreWriteError, WriteResult)
import Aapms.Store.Marker (VaultHandle)

-- asset 的人給欄位 ---------------------------------------------------------------

-- | 'Aapms.Store.Write.writeAssetFields' 能改的__全部__欄位。
--
-- @sha256@ \/ @entry@ \/ @ext@ \/ @meta@ __不在這裡,而且是刻意的__:那四欄是
-- 掃描器(@asset-ingest@)從檔案本身算出來的事實,不是人給的意見。「拒絕改」
-- 因此不是一個執行期檢查,而是__型別上表達不出來__ ——檔案換了就是換了一筆
-- asset,要走 'Aapms.Store.Create.addSection' \/ 'Aapms.Store.Create.deleteNode'。
--
-- 每一欄的外層 'Maybe' 是「這次動不動它」,內層 'Maybe' 是「要設成什麼」:
-- @apName = Nothing@ 不動、@apName = Just Nothing@ 清空、
-- @apName = Just (Just n)@ 設成 @n@。兩層合在一起才表達得出「清空」,少一層就
-- 只能把「不動」與「清空」混為一談。
data AssetPatch = AssetPatch
  { apName :: Maybe (Maybe LogicalName)
  , apLicense :: Maybe (Maybe Ref)
  , apAuthor :: Maybe (Maybe Text)
  , apTags :: Maybe [Text]
  -- ^ @tags@ 住在 'Aapms.Core.Meta.Meta' 而不是 asset 專屬表,但它是人給欄位,
  -- 所以與另外三欄一起走這條路徑;@Just []@ = 清空
  }
  deriving stock (Show, Eq)

-- Meta ------------------------------------------------------------------------

-- | 修改既有節點的 'Aapms.Core.Meta.Meta'。節與檔案層主體都支援。
--
-- 第三個參數是呼叫端手上那份資料的 revision;與檔案裡的實際值不符就
-- 'Aapms.Store.Edit.RevisionMismatch',__一個位元組都不寫__。
--
-- 修改函式吃 'MetaOverride' 而不是 'Meta':節的 meta 區塊本來就是「只寫與檔案層
-- 不同的欄位」,寫成完整的 'Meta' 會讓每次修改都把繼承來的欄位全部釘死在節上。
-- @id@ 與 @title@ 'MetaOverride' 表達不了,因此改不動。
--
-- 目標是 pack.md 的 asset 節或 licenses.md 的 license 節時,該節的專屬欄位
-- (@sha256@ \/ @entry@ \/ 八個授權維度……)__必須原樣保留__ ——它們與
-- 'MetaOverride' 住在同一個 @```meta@ 區塊裡,重新序列化時漏掉就是資料遺失。
writeMeta
  :: VaultHandle
  -> Id
  -> Revision
  -> (MetaOverride -> MetaOverride)
  -> IO (Either StoreWriteError WriteResult)
writeMeta = undefined

-- | 改 asset 的人給欄位。目標不是 asset 時回 'Aapms.Store.Edit.NotAnAsset'。
--
-- 只動 'AssetPatch' 指定的欄位;@sha256@ \/ @entry@ \/ @ext@ \/ @meta@ 與正文
-- 一律不變(見 'AssetPatch' 的說明)。
writeAssetFields
  :: VaultHandle
  -> Id
  -> Revision
  -> AssetPatch
  -> IO (Either StoreWriteError WriteResult)
writeAssetFields = undefined

-- 正文 ------------------------------------------------------------------------

-- | 換掉正文:節換該節的正文切片,檔案層主體換 frontmatter 之後的 preamble。
--
-- 兩條路徑都會遞增 revision ——正文才是節真正的內容,改了它卻不動 revision,
-- 樂觀鎖就對「內容被改過」視而不見。
writeBody
  :: VaultHandle
  -> Id
  -> Revision
  -> Text
  -> IO (Either StoreWriteError WriteResult)
writeBody = undefined

-- 關聯 ------------------------------------------------------------------------

-- | 加一筆關聯。
--
-- 關聯__只存在來源端__(ADR-002),所以這是單邊、單檔操作:目標端的檔案一個
-- 位元組都不會被碰到。反向查詢由索引負責。
addLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreWriteError WriteResult)
addLink = undefined

-- | 刪一筆關聯,以整筆 'Link' 比對(@kind@ + @target@ + @note@ 皆相同才算命中);
-- 同一筆出現多次時全部刪掉。
--
-- __一筆都沒命中時回 'Aapms.Store.Edit.LinkNotFound' 而不是靜默成功__:呼叫端
-- 以為刪掉了、實際上關聯還在,是最難查的那種錯,而且此時檔案__不會被寫__。
--
-- 比對的是__檔案裡寫的那個 'Aapms.Core.Id.Ref'__:作者寫
-- @vlt-a0c4e1f8:ent-7f3a@ 時要以同樣的形式來刪。
removeLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreWriteError WriteResult)
removeLink = undefined

-- 授權 ------------------------------------------------------------------------

-- | 把一種授權寫進該 vault 的 @licenses.md@:同 id 的節已存在就整節改寫,
-- 不存在就追加一節。
--
-- 吃完整的 'License' 而不是覆寫函式:授權的八個維度是一組互相牽動的宣告
-- (可商用但要求署名、可改作但不可轉售……),逐欄 patch 會讓「這份授權到底
-- 允許什麼」散落在多次呼叫裡。'Aapms.Core.License.licFullText' 不寫進節層
-- (@licenses.md@ 的節不重複貼授權全文,'Aapms.Md.Parse.toLicenses' 解出來
-- 恆為 'Nothing')。
--
-- 樂觀鎖的 expected revision 取自傳入的 'License' 自己的
-- 'Aapms.Core.Meta.metaRevision' ——契約 E 的簽名沒有獨立的 revision 參數,而
-- 完整的 'License' 本來就帶著它。節不存在(新增)時不比對。
upsertLicense :: VaultHandle -> License -> IO (Either StoreWriteError WriteResult)
upsertLicense = undefined

-- ID ---------------------------------------------------------------------------

-- | 產生一個索引裡還沒有人用的 ID(ADR-014)。
--
-- 'Aapms.Core.Id.newId' 是純函式,唯一性只有持有索引的這一層做得到:撞了就
-- @salt + 1@ 重算,直到不撞。時間由本函式取(@core@ 零 IO,時間必須由呼叫端
-- 提供,而這裡就是那個呼叫端)。
--
-- 簽名沒有失敗通道(契約 E 標明 @IO Id@),所以碰撞查詢本身出錯時視同「查不到」
-- 並回傳當前候選:配號是純粹的計算,索引壞掉這件事會在後續的
-- 'Aapms.Store.Edit.commit' 以 'Aapms.Store.Edit.IndexUpdateFailed' 現形,不必
-- 在這裡多一條路徑(F008 待確認假設 A3)。
allocateId :: VaultHandle -> IdPrefix -> Text -> IO Id
allocateId = undefined
