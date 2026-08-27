-- | graph-core\/F006 T6:'rebuildIndex' 兩次結果相同、內容問題不中斷整批。
module Aapms.Store.RebuildSpec (spec) where

import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id, renderId)
import Aapms.Core.Meta (metaId)
import Aapms.Store.Fixtures
import Aapms.Store.Index (rebuildIndex)
import Aapms.Store.Marker (VaultHandle, vhRoot)
import Aapms.Store.Query (childrenOf, emptyNodeFilter, linksFrom, listNodes)
import Aapms.Store.Schema (IndexIssue (..))
import Test.Hspec

spec :: Spec
spec = describe "graph-core/F006 rebuildIndex" $ do
  it "T6: story vault 與 asset vault 各跑兩次 rebuildIndex,listNodes/linksFrom/childrenOf 結果相同" $ do
    withStoryVault (assertRebuildIdempotent (idOf "ent-00000001"))
    withAssetVault (assertRebuildIdempotent (idOf "pck-00000001"))

  it "T6: fixture 混入一個解析失敗的檔案,rebuildIndex 仍把其餘檔案正確索引且回傳含該筆 IndexIssue" $
    withStoryVault $ \vh -> do
      writeFiles (vhRoot vh) [("characters/broken.md", "---\nid: [nope\n---\n")]
      issues <- orDie =<< rebuildIndex vh
      any isParseFailed issues `shouldBe` True
      -- 其餘檔案(主題檔的主體 + 兩個片段、Level 的兩個 Node)仍正常索引
      metas <- listNodes vh emptyNodeFilter
      length metas `shouldSatisfy` (>= 5)
  where
    isParseFailed (ParseFailed _ _) = True
    isParseFailed _ = False

assertRebuildIdempotent :: Id -> VaultHandle -> IO ()
assertRebuildIdempotent ownerId vh = do
  _ <- orDie =<< rebuildIndex vh
  snap1 <- snapshot vh ownerId
  _ <- orDie =<< rebuildIndex vh
  snap2 <- snapshot vh ownerId
  snap1 `shouldBe` snap2

-- | 拍下 listNodes / linksFrom / childrenOf 的快照,供兩次 rebuild 比對。
snapshot :: VaultHandle -> Id -> IO ([Text], [Text], [Text])
snapshot vh ownerId = do
  metas <- listNodes vh emptyNodeFilter
  links <- linksFrom vh ownerId
  kids <- childrenOf vh ownerId
  pure
    ( sort (map (renderId . metaId) metas)
    , sort (map show' links)
    , sort (map (renderId . metaId) kids)
    )
  where
    show' = T.pack . show
