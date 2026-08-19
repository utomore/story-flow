-- | Level 樹的編輯:加一個 Node、刪一棵子樹。
--
-- ADR-009「標題階層即樹」在這裡__反過來用__:作者不寫 @parent@ 與 @order@,
-- 所以工具也不寫——新節的標題層級 = 父節點層級 + 1,插入位置 = 父節點子樹的
-- 最後一節之後,兩者都由標題推導。
--
-- __樹的驗證放在寫檔之前__:對編輯後的 'Document' 先 'parseLevelFile' +
-- 'buildTree',通過才落地。純函式驗證不花 IO,沒有理由先寫壞檔再說——先寫再
-- 驗的話,樹壞掉時檔案已經出去了,只剩「資料已寫入但不合法」這種最難善後的
-- 處境。
--
-- 明確__不做__ 'moveNode' \/ 'reorderNode':標題階層即樹,作者直接改檔案的
-- 標題層級就是移動,工具層先不介入(entity-graph-core/F005)。
module StoryFlow.Store.Node
  ( addNode
  , removeNode
  ) where

import Data.Time (getCurrentTime, utctDay)
import Database.SQLite.Simple
import StoryFlow.Core.Id (Id, IdPrefix (PNod))
import StoryFlow.Core.Level (Level (..))
import StoryFlow.Core.Meta (Meta (..), bumpRevision)
import StoryFlow.Core.Tree (buildTree)
import StoryFlow.Md
import StoryFlow.Store.Create
  ( CreateResult (..)
  , DeleteMode
  , NewNode (..)
  , guardReferences
  )
import StoryFlow.Store.Edit
import StoryFlow.Store.Error (StoreError (..))
import StoryFlow.Store.Vault (Vault)
import StoryFlow.Store.Write (allocateId)

-- | 在父 Node 底下新增一個子節點。
--
-- @Id@ 是__父 Node__,@Int@ 是 Level 主體的 revision(樂觀鎖鎖的是整份檔案,
-- 因為標題階層一動就會影響到別的節點)。
--
-- 插入位置是「父節點子樹的最後一節之後」,不是父節點自己之後——
-- 'StoryFlow.Md.Render.insertSection' 的「之後」指的是該節本身,所以子樹的
-- 尾端要自己算出來。
addNode
  :: Connection -> Vault -> Id -> Int -> NewNode -> IO (Either StoreError CreateResult)
addNode conn v parent expected NewNode {..} =
  locateNode conn parent >>? \(Located rel anchor) -> case anchor of
    Nothing -> pure (Left (NotAFragment parent))
    Just _ ->
      readDocument v rel >>? \doc ->
        levelFileOf rel doc ?>> \(lf, _) ->
          checkRevision (metaId (lvlMeta (lfLevel lf))) expected (metaRevision (lvlMeta (lfLevel lf)))
            ?>> \() ->
              parentSection rel doc parent ?>> \p ->
                depthOf parent (secLevel p + 1) ?>> \lvl -> do
                  now <- getCurrentTime
                  allocateId conn PNod (nnTitle <> nnSummary) now >>? \newId ->
                    build rel doc p lvl newId (utctDay now) ?>> \doc' ->
                      validateTree rel doc' ?>> \ws ->
                        commit conn v rel doc' (expected + 1) >>? \_ ->
                          pure (Right (CreateResult newId rel ws))
  where
    build rel doc p lvl newId today = do
      let le = docEnding doc
          sec =
            mkSection
              le
              lvl
              newId
              nnTitle
              (Just override)
              (sectionBodyRaw le nnBody)
      doc' <- orMd rel (insertSection (Just (subtreeEnd doc p)) sec doc)
      orMd rel (updateFrontmatter (bumpRevision today) doc')

    -- Node 的 meta 區塊不寫 revision:樂觀鎖鎖的是 Level 主體那一份,
    -- 每個 Node 各帶一個 revision 只會讓作者以為它有意義
    override =
      emptyOverride
        { moKind = Just nnKind
        , moSummary = if nnSummary == "" then Nothing else Just nnSummary
        , moLinks = if null nnLinks then Nothing else Just nnLinks
        }

-- | 刪掉一個 Node __與它整棵子樹__。
--
-- 根 Node 刪不得:刪了整份 Level 檔就解析不出 @root@,'CannotRemoveRootNode'
-- 請呼叫端改用 'StoryFlow.Store.Create.deleteLevel'。
--
-- 'DeleteSafe' 對子樹裡__每一個__ Node 做被引用檢查——@convergesTo@ 指向被刪
-- 節點的情況會在這裡被擋下來。
removeNode
  :: Connection -> Vault -> Id -> Int -> DeleteMode -> IO (Either StoreError WriteResult)
removeNode conn v i expected mode =
  locateNode conn i >>? \(Located rel anchor) -> case anchor of
    Nothing -> pure (Left (NotAFragment i))
    Just _ ->
      readDocument v rel >>? \doc ->
        levelFileOf rel doc ?>> \(lf, _) ->
          let lvlId = metaId (lvlMeta (lfLevel lf))
           in checkRevision lvlId expected (metaRevision (lvlMeta (lfLevel lf))) ?>> \() ->
                if lvlRoot (lfLevel lf) == i
                  then pure (Left (CannotRemoveRootNode i))
                  else
                    parentSection rel doc i ?>> \s ->
                      let victims = i : map secId (subtreeAfter doc s)
                       in guardReferences conn mode i victims >>? \_ -> do
                            today <- utctDay <$> getCurrentTime
                            cut rel doc victims today ?>> \doc' ->
                              validateTree rel doc' ?>> \_ ->
                                commit conn v rel doc' (expected + 1)
  where
    cut rel doc victims today = do
      doc' <- foldl (\acc x -> acc >>= orMd rel . removeSection x) (Right doc) victims
      orMd rel (updateFrontmatter (bumpRevision today) doc')

-- 樹的推導 ---------------------------------------------------------------------

-- | 目標節點在文件裡的那一節。
parentSection :: FilePath -> Document -> Id -> Either StoreError Section
parentSection rel doc i = case sectionById i doc of
  Just s -> Right s
  Nothing -> Left (ParseFailed rel [mdError rel 1 (UnknownSectionId i)])

-- | 某一節之後、屬於它子樹的所有節:往後掃到第一個 @secLevel <= 自己@ 為止。
subtreeAfter :: Document -> Section -> [Section]
subtreeAfter doc s =
  takeWhile ((> secLevel s) . secLevel) (drop 1 (dropWhile ((/= secId s) . secId) (docSections doc)))

-- | 子樹的最後一節;子樹是空的就是節點自己。'insertSection' 要的就是這一個。
subtreeEnd :: Document -> Section -> Id
subtreeEnd doc s = case subtreeAfter doc s of
  [] -> secId s
  xs -> secId (last xs)

-- | Markdown 只有六級標題(system.md 已載明此限制與繞道方式)。
depthOf :: Id -> Int -> Either StoreError Int
depthOf parent lvl
  | lvl > 6 = Left (NodeDepthExceeded parent lvl)
  | otherwise = Right lvl

-- | 編輯後的樹仍然合法嗎。__在寫檔之前__。
validateTree :: FilePath -> Document -> Either StoreError [MdWarning]
validateTree rel doc = do
  (lf, ws) <- levelFileOf rel doc
  case buildTree (lfLevel lf) (lfNodes lf) of
    Left es -> Left (TreeInvalid rel es)
    Right _ -> Right ws
