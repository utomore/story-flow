-- | func-0005 T15:九個新建構子都有非空的繁中訊息,而且說得出下一步。
--
-- 「不含原始 @show@ 痕跡」是本檔真正在守的那條:錯誤訊息會直接被 CLI 與 API
-- 印給作者與 AI Agent 看,漏出一個 @Left@ 或建構子名稱就等於把內部型別當成
-- 使用者介面。
module StoryFlow.Store.ErrorSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, localRef, parseId)
import StoryFlow.Core.Link (Link (..), LinkKind (..))
import StoryFlow.Core.Tree (TreeError (..))
import StoryFlow.Store.Error
import Test.Hspec

i1, i2 :: Id
i1 = idOf "ent-7f3a"
i2 = idOf "ent-7f3b"

-- | func-0005 新增的九個建構子。
newErrors :: [(String, StoreError)]
newErrors =
  [ ("ReferencedBy", ReferencedBy i1 [(i2, Link PartOf (localRef i1) Nothing)])
  , ("NotAFileMain", NotAFileMain i2)
  , ("NotAFragment", NotAFragment i1)
  , ("NodeDepthExceeded", NodeDepthExceeded (idOf "nod-0004") 7)
  , ("CannotRemoveRootNode", CannotRemoveRootNode (idOf "nod-0001"))
  , ("LinkNotFound", LinkNotFound i1 Contradicts (localRef i2))
  , ("FileAlreadyExists", FileAlreadyExists "characters/琳達.md")
  , ("TreeInvalid", TreeInvalid "levels/教室.md" [NoRoot, DuplicateNodeId (idOf "nod-0001")])
  , ("RegistryDirUnknown", RegistryDirUnknown "sketch")
  ]

spec :: Spec
spec = do
  describe "T15 九個新建構子的訊息" $ do
    mapM_
      ( \(name, e) -> it (name <> " 的訊息非空、是繁中、且不含原始 show 痕跡") $ do
          let msg = renderStoreError e
          msg `shouldNotBe` ""
          T.length msg `shouldSatisfy` (> 10)
          msg `shouldSatisfy` hasHan
          mapM_ (\bad -> msg `shouldSatisfy` (not . T.isInfixOf bad)) showTraces
      )
      newErrors

    it "每一則都說得出下一步該做什麼" $
      mapM_
        (\(name, e) -> (name, actionable (renderStoreError e)) `shouldBe` (name, True))
        newErrors

    it "ReferencedBy 列出是誰指向它" $
      renderStoreError (ReferencedBy i1 [(i2, Link PartOf (localRef i1) Nothing)])
        `shouldSatisfy` T.isInfixOf "ent-7f3b"

    it "TreeInvalid 說明檔案沒有被改到,並逐條列出樹的問題" $ do
      let msg = renderStoreError (TreeInvalid "levels/教室.md" [NoRoot])
      msg `shouldSatisfy` T.isInfixOf "沒有被改到"
      msg `shouldSatisfy` T.isInfixOf "根 Node"

    it "NodeDepthExceeded 講得出是第幾級" $
      renderStoreError (NodeDepthExceeded (idOf "nod-0004") 7)
        `shouldSatisfy` T.isInfixOf "7"

    it "LinkNotFound 講得出關聯種類與目標" $ do
      let msg = renderStoreError (LinkNotFound i1 Contradicts (localRef i2))
      msg `shouldSatisfy` T.isInfixOf "contradicts"
      msg `shouldSatisfy` T.isInfixOf "ent-7f3b"

-- | 原始 @show@ 會漏出來的痕跡。
showTraces :: [Text]
showTraces =
  ["Left", "Right", "Just ", "Nothing", "StoreError", "TreeError", "fromList", "Id \""]

-- | 訊息裡有沒有「下一步」。既有訊息全部是這個風格(如 'IndexUpdateFailed'
-- 直接叫人跑 @story-flow index rebuild@)。
actionable :: Text -> Bool
actionable msg = any (`T.isInfixOf` msg) ["請", "改用", "可以", "才"]

hasHan :: Text -> Bool
hasHan = T.any (\c -> c >= '\x4e00' && c <= '\x9fff')

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)
