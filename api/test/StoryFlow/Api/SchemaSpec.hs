-- | T3:'ToSchema' 的欄位名與 'Data.Aeson.ToJSON' 一致。
--
-- __這是整個 API 套件最重要的一條測試__。@ToJSON@ 與 @ToSchema@ 分開手寫是
-- OpenAPI 文件說謊最常見的來源:改了一邊、忘了另一邊,文件照樣產得出來、照樣
-- 看起來很專業,而照著它寫的 Agent 會拿到 400。
--
-- 作法是拿樣本值兩邊各跑一次,比對__鍵集合相等__。樣本刻意把選配欄位填滿
-- ("StoryFlow.Api.Fixtures"),否則 @Maybe@ 欄位「沒值就整個鍵不出現」的約定會讓
-- 兩邊看似不一致。
module StoryFlow.Api.SchemaSpec (spec) where

import Control.Lens ((^.))
import Data.Aeson (ToJSON, Value (..), toJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.HashMap.Strict.InsOrd as IOM
import Data.List (sort)
import Data.OpenApi (ToSchema, properties, toSchema)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Api ()
import StoryFlow.Api.Fixtures
import StoryFlow.Core.Entity (Entity)
import StoryFlow.Core.Id (Id, Ref)
import StoryFlow.Core.Level (Level, Node)
import StoryFlow.Core.Link (Link)
import StoryFlow.Core.Meta (Meta, Timeline)
import StoryFlow.Core.Registry (EntityTypeSpec, FieldSpec)
import StoryFlow.Core.Tree (NodeTree)
import StoryFlow.Service
import Test.Hspec

spec :: Spec
spec = describe "ToSchema 與 ToJSON 逐欄對齊" $ do
  describe "core 的結構型別" $ do
    it "Meta" $ aligns (Proxy :: Proxy Meta) sampleMeta
    it "Entity(Meta 攤平 + body)" $ aligns (Proxy :: Proxy Entity) sampleEntity
    it "Level(Meta 攤平 + root)" $ aligns (Proxy :: Proxy Level) sampleLevel
    it "Node(Meta 攤平 + 結構欄位)" $ aligns (Proxy :: Proxy Node) sampleNode
    it "Link" $ aligns (Proxy :: Proxy Link) sampleLink
    it "Timeline" $ aligns (Proxy :: Proxy Timeline) sampleTimeline
    it "NodeTree" $ aligns (Proxy :: Proxy NodeTree) sampleTree

  describe "型別註冊表" $ do
    it "FieldSpec" $ aligns (Proxy :: Proxy FieldSpec) sampleFieldSpec
    it "EntityTypeSpec" $ aligns (Proxy :: Proxy EntityTypeSpec) sampleTypeSpec

  describe "service 的 View" $ do
    it "EntityView" $ aligns (Proxy :: Proxy EntityView) sampleEntityView
    it "LevelView" $ aligns (Proxy :: Proxy LevelView) sampleLevelView
    it "VaultView" $ aligns (Proxy :: Proxy VaultView) sampleVaultView
    it "SearchHit" $ aligns (Proxy :: Proxy SearchHit) sampleSearchHit
    it "LinkReport" $ aligns (Proxy :: Proxy LinkReport) sampleLinkReport
    it "IndexReport" $ aligns (Proxy :: Proxy IndexReport) sampleIndexReport
    it "DeleteReport" $ aligns (Proxy :: Proxy DeleteReport) sampleDeleteReport

  describe "service 的請求型別" $ do
    it "NewEntityReq" $ aligns (Proxy :: Proxy NewEntityReq) sampleNewEntityReq
    it "NewFragmentReq" $ aligns (Proxy :: Proxy NewFragmentReq) sampleNewFragmentReq
    it "NewLevelReq" $ aligns (Proxy :: Proxy NewLevelReq) sampleNewLevelReq
    it "NewNodeReq" $ aligns (Proxy :: Proxy NewNodeReq) sampleNewNodeReq
    it "EntityPatch" $ aligns (Proxy :: Proxy EntityPatch) sampleEntityPatch

  describe "純量型別是字串,不是物件" $
    it "Id / Ref 的 schema 沒有 properties" $ do
      schemaKeys (Proxy :: Proxy Id) `shouldBe` []
      schemaKeys (Proxy :: Proxy Ref) `shouldBe` []

  describe "遞迴 schema" $
    it "NodeTree 產得出有限的 schema(children 走 $ref,不無限展開)" $ do
      -- 真正的證明是這一行跑得完:內嵌 schema 的話 declareNamedSchema 會一路
      -- 展開到堆疊爆掉,連 length 都拿不到。
      length (show (toSchema (Proxy :: Proxy NodeTree))) `shouldSatisfy` (> 0)
      schemaKeys (Proxy :: Proxy NodeTree) `shouldBe` ["children", "node"]

-- | 樣本值的 JSON 鍵集合 == 該型別 schema 的 @properties@ 鍵集合。
aligns :: (ToJSON a, ToSchema a) => Proxy a -> a -> Expectation
aligns p x = case toJSON x of
  Object o ->
    let jsonKeys = sort (map K.toText (KM.keys o))
        schKeys = schemaKeys p
     in if jsonKeys == schKeys
          then pure ()
          else
            expectationFailure . T.unpack $
              "JSON 有而 schema 沒有:"
                <> render (diff jsonKeys schKeys)
                <> ";schema 有而 JSON 沒有:"
                <> render (diff schKeys jsonKeys)
  other -> expectationFailure ("樣本的 toJSON 不是物件:" <> show other)
  where
    diff a b = [k | k <- a, k `notElem` b]
    render [] = "(無)"
    render ks = T.intercalate ", " ks

schemaKeys :: (ToSchema a) => Proxy a -> [Text]
schemaKeys p = sort (IOM.keys (toSchema p ^. properties))
