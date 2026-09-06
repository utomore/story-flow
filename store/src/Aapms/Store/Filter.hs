-- | 結構條件的純判定(P-002-search)。
--
-- 與 SQL 側的 @WHERE@ 子句是同一組規則的兩個實作:prefix、type、status、
-- tags 全部命中、owner('inOwner')、license、只要已命名、reference
-- ('fiReference')預設不列。吃節點所在的檔與索引節點,因為 owner 與
-- reference 都不是 'Aapms.Core.AnyNode.AnyNode' 自己知道的事(P-002 REV-1)。
module Aapms.Store.Filter
  ( passesFilter
  ) where

import Data.Maybe (isJust)

import Aapms.Core.AnyNode (AnyNode (..), anyMeta, prefixOf)
import Aapms.Core.Asset (Asset (..), LogicalName)
import Aapms.Core.Id (Ref)
import Aapms.Core.Meta (Meta (..), Status (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Store.Types (FileIndex (..), IndexedNode (..), NodeFilter (..))

-- | 這個索引節點在它所在的檔裡過不過得了結構條件。
--
-- 逐條對照 "Aapms.Store.Query" 的 @whereOfIn@(同一組規則的 SQL 實作):
--
-- * @nfPrefixes@ ↔ @n.prefix IN (…)@:@n.prefix@ 是寫入端由節點種類填的
--   ('Aapms.Store.Row.Sql.nodeFields' 的 @IdPrefix@ 參數),所以這裡用
--   'prefixOf' 而不是從 id 字串反推。
-- * @nfStatus = []@ ↔ @n.status \<\> 'missing'@(契約 F:全部但排除 Missing);
--   非空時是 @IN (…)@。
-- * @nfTags@ ↔ 每個標籤一句 @EXISTS@:要__全部__命中。
-- * @nfOwner@ ↔ @n.owner = ?@,也就是 'inOwner'。
-- * @nfLicense@ ↔ @a.license = ? OR p.license = ?@:只有 asset 與 pack 有
--   license 欄,其餘節點兩邊都是 NULL,恆不命中。
-- * @nfNamedOnly@ ↔ @a.name IS NOT NULL@:只有 asset 有邏輯名稱。
-- * @nfIncludeReference = False@ ↔ 排除 reference 的 pack 本身與 owner 指向
--   它的節點;在記憶體模型裡整份 pack 檔一起進退,所以判準是該檔的
--   'fiReference'。
passesFilter :: NodeFilter -> FileIndex -> IndexedNode -> Bool
passesFilter NodeFilter {..} fi n =
  prefixOk
    && typeOk
    && statusOk
    && tagsOk
    && ownerOk
    && licenseOk
    && namedOk
    && referenceOk
  where
    node = inNode n
    m = anyMeta node

    prefixOk = null nfPrefixes || prefixOf node `elem` nfPrefixes
    typeOk = null nfTypes || metaType m `elem` nfTypes
    statusOk
      | null nfStatus = metaStatus m /= Missing
      | otherwise = metaStatus m `elem` nfStatus
    tagsOk = all (`elem` metaTags m) nfTags
    ownerOk = maybe True (\o -> inOwner n == Just o) nfOwner
    licenseOk = maybe True (\r -> licenseRef == Just r) nfLicense
    namedOk = not nfNamedOnly || isJust logicalName
    referenceOk = nfIncludeReference || not (fiReference fi)

    licenseRef :: Maybe Ref
    licenseRef = case node of
      NAsset a -> astLicense a
      NPack p -> pckLicense p
      _ -> Nothing

    logicalName :: Maybe LogicalName
    logicalName = case node of
      NAsset a -> astName a
      _ -> Nothing
