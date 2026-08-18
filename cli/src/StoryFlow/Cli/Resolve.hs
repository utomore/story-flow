-- | 'Selector' → 'Id',以及「先讀再寫」的那個先讀。
--
-- 使用者記得住的是「琳達」,不是 @ent-7f3a@,所以每個吃實體的位置都接受標題。
-- 標題比對是__精確比對,不做模糊比對__:猜錯然後改到別的片段,比找不到糟得多。
--
-- 多筆命中時不挑一個,而是列出全部候選讓使用者改用 id 重下——Node 的標題重複率
-- 特別高(「出場人物」會出現在每個場景),這條規則在那裡最常派上用場。
--
-- __全部走 'Backend'__:同一段定址邏輯在內嵌與遠端都成立,差別只在底下那幾個
-- 查詢是本機呼叫還是 HTTP GET。這是驗收標準 4 在定址路徑上的實作——遠端模式
-- 用標題找到的東西、找不到時的訊息、多筆命中時的候選清單,與內嵌模式逐字相同。
module StoryFlow.Cli.Resolve
  ( resolveEntity
  , resolveLevel
  , resolveNode
  , currentRevision
  , levelRevision
  ) where

import Control.Monad.Trans.Except (catchE)
import StoryFlow.Cli.Backend
import StoryFlow.Cli.Error
import StoryFlow.Cli.Options (Selector (..))
import StoryFlow.Core.Id (Id, IdPrefix (..), idPrefix, renderId)
import StoryFlow.Core.Level (Node (..))
import StoryFlow.Core.Meta (Meta (..))
import StoryFlow.Core.Tree (preorder)
import StoryFlow.Service (emptyFilter, evRevision, lvId, lvRevision, lvTree)

resolveEntity :: Backend -> Selector -> M Id
resolveEntity b = byTitle SubEntity (listEntitiesB b emptyFilter)

resolveLevel :: Backend -> Selector -> M Id
resolveLevel b = byTitle SubLevel (listLevelsB b emptyFilter)

-- | 節點定址,回的是 __(Level id, Node id)__。
--
-- Level 是一起回的而不是另外問:service 的 @addNode@ \/ @removeNode@ 都要 Level
-- 的 id 與 __Level 主體__的 revision(樂觀鎖鎖的是整份檔案),而指令列上只有
-- 節點。既然為了找節點本來就要走過每一棵樹,順手把它所屬的 Level 帶回來。
resolveNode :: Backend -> Selector -> M (Id, Id)
resolveNode b sel = do
  metas <- listLevelsB b emptyFilter
  pairs <- concat <$> traverse nodesOfLevel metas
  case sel of
    SelById i -> case [p | p@(_, n) <- pairs, metaId (nodMeta n) == i] of
      ((l, n) : _) -> pure (l, metaId (nodMeta n))
      [] -> throw (CliResolve (NotFound SubNode (renderId i)))
    SelByTitle t -> case [p | p@(_, n) <- pairs, metaTitle (nodMeta n) == t] of
      [(l, n)] -> pure (l, metaId (nodMeta n))
      [] -> throw (CliResolve (NotFound SubNode t))
      xs -> throw (CliResolve (Ambiguous SubNode t [nodMeta n | (_, n) <- xs]))
  where
    -- 某一份 Level 的標題階層被作者改壞時跳過它,而不是讓整個定址失敗:
    -- 一份壞掉的 Level 不該讓另一份 Level 上的節點也碰不到。
    nodesOfLevel m =
      (do v <- getLevelB b (metaId m); pure [(lvId v, n) | n <- preorder (lvTree v)])
        `catchE` \_ -> pure []

-- | id 直接用;標題以清單做精確比對。
byTitle :: Subject -> M [Meta] -> Selector -> M Id
byTitle _ _ (SelById i) = pure i
byTitle s list (SelByTitle t) = do
  metas <- list
  case filter ((== t) . metaTitle) metas of
    [m] -> pure (metaId m)
    [] -> throw (CliResolve (NotFound s t))
    xs -> throw (CliResolve (Ambiguous s t xs))

-- | 沒給 @--revision@ 時先讀一次拿當前值。
--
-- 人用起來是「改一欄就改一欄」,不必先查數字;腳本與 AI Agent 要真樂觀鎖時帶
-- @--revision@ ——它們手上本來就有上一次讀到的值。
--
-- __遠端模式一樣走這條__,只是那個「先讀」變成一次 HTTP GET(func-0008 第四節)。
-- 兩次呼叫之間的窗口在遠端模式確實比內嵌模式大,而那正是 @--revision@ 存在的
-- 理由:真的在乎並發的呼叫端自己帶。
currentRevision :: Backend -> Id -> M Int
currentRevision b i = case idPrefix i of
  PLvl -> lvRevision <$> getLevelB b i
  _ -> evRevision <$> getEntityB b i

-- | Node 的操作鎖的是 __Level 主體__的 revision(func-0005 的 @addNode@ \/
-- @removeNode@ 就是這麼定的),不是節點自己的。
levelRevision :: Backend -> Id -> Maybe Int -> M Int
levelRevision b lvl = maybe (lvRevision <$> getLevelB b lvl) pure
