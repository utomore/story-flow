-- | Level 樹在寫入路徑上的純推導(graph-core\/F008)。內部模組。
--
-- ADR-009「標題階層即樹」在這裡__反過來用__:作者不寫 @parent@ 與 @order@,
-- 所以工具也不寫 —— 新節的標題層級由父節點的層級推導,@parent@ \/ @order@ 交給
-- 'Aapms.Md.Parse.toLevel' 從標題階層算回來。
--
-- __樹的驗證放在寫檔之前__:對編輯後的 'Document' 先 'Aapms.Md.Parse.toLevel' +
-- 'Aapms.Core.Tree.buildTree',通過才落地。純函式驗證不花 IO,沒有理由先寫壞檔
-- 再說 —— 先寫再驗的話,樹壞掉時檔案已經出去了,只剩「資料已寫入但不合法」這種
-- 最難善後的處境。
--
-- 本模組__全部是純函式__:它是 ADR-022 的一部分——凡是要在寫入路徑上算的東西,
-- 都在碰索引之前算完。
--
-- 明確__不做__ @moveNode@ \/ @reorderNode@:標題階層即樹,作者直接改檔案的標題
-- 層級就是移動,工具層先不介入。
module Aapms.Store.Node
  ( -- * 層級
    headingDepthFor

    -- * 子樹
  , subtreeAfter
  , subtreeIds
  , isRootNode

    -- * 驗證
  , validateLevelDoc
  ) where

import Aapms.Core.Id (Id)
import Aapms.Core.Tree (buildTree)
import Aapms.Md.Document (Document (..), Section (..), sectionById)
import Aapms.Md.Parse (toLevel)
import Aapms.Store.Error (StoreError (..))

-- 層級 ------------------------------------------------------------------------

-- | 在指定父節點底下新增一個子節點時,新節該用第幾級標題(父節點層級 + 1)。
--
-- 父節點不在文件裡回 'Aapms.Store.Error.SectionMissing';算出來超過六級回
-- 'Aapms.Store.Error.NodeDepthExceeded' —— Markdown 只有六級標題,再深就沒有
-- 合法的表示法。
headingDepthFor :: FilePath -> Document -> Id -> Either StoreError Int
headingDepthFor path doc pid = case sectionById pid doc of
  Nothing -> Left (SectionMissing path pid)
  Just p ->
    let depth = secLevel p + 1
     in if depth > 6
          then Left (NodeDepthExceeded pid depth)
          else Right depth

-- 子樹 ------------------------------------------------------------------------

-- | 某一節之後、屬於它子樹的所有節(不含它自己)。節不存在時是空清單。
subtreeAfter :: Document -> Id -> [Section]
subtreeAfter doc i = case break ((== i) . secId) (docSections doc) of
  (_, s : rest) -> takeWhile ((> secLevel s) . secLevel) rest
  (_, []) -> []

-- | 某一節與它整棵子樹的 id,依文件順序;節本身排在最前面。
--
-- 刪一個 Node 就是刪它整棵子樹:留下孤兒節點會讓下一次
-- 'Aapms.Core.Tree.buildTree' 直接失敗,整份 Level 檔進不了索引。
subtreeIds :: Document -> Id -> [Id]
subtreeIds doc i = i : map secId (subtreeAfter doc i)

-- | 這個 id 是不是該 Level 檔的根 Node(frontmatter 的 @root@ \/ 第一個節)。
--
-- 根 Node 刪不得:刪了整份 Level 檔就解析不出 @root@。
--
-- 三種結果,一個都不能少(2026-08-25 GAP-9 裁決,見 F008 的 LAW-24):
--
-- * @id@ 在 @doc@ 裡且就是該 Level 檔的根 → @'Right' 'True'@
-- * @id@ 在 @doc@ 裡但不是根 → @'Right' 'False'@
-- * @id@ __不在__ @doc@ 裡 → @'Left' ('Aapms.Store.Error.SectionMissing' path id)@
--
-- 最後一種__不是__ @'Right' 'False'@:與同模組的 'headingDepthFor' 對稱(父節點不在
-- 文件裡時它回 'Aapms.Store.Error.SectionMissing')。「查無此節」與「這個節不是根」
-- 是兩件不同的事,合一會讓呼叫端分不出來 ——'Aapms.Store.Create.deleteNode' 會把
-- 一個根本不存在的 id 當成「可以刪的非根節點」繼續往下走,錯誤就往下游飄。
isRootNode :: FilePath -> Document -> Id -> Either StoreError Bool
isRootNode path doc i = case sectionById i doc of
  Nothing -> Left (SectionMissing path i)
  Just _ -> case docSections doc of
    (root : _) -> Right (secId root == i)
    [] -> Left (SectionMissing path i)

-- 驗證 ------------------------------------------------------------------------

-- | 編輯後的 Level 檔仍然合法嗎。__在寫檔之前__呼叫。
--
-- 解析失敗回 'Aapms.Store.Error.MdWriteFailed',樹不合法回
-- 'Aapms.Store.Error.TreeInvalidOnWrite'。
validateLevelDoc :: FilePath -> Document -> Either StoreError ()
validateLevelDoc path doc = case toLevel doc of
  Left e -> Left (MdWriteFailed path e)
  Right (lvl, nodes) -> case buildTree lvl nodes of
    Left errs -> Left (TreeInvalidOnWrite path errs)
    Right _tree -> Right ()
