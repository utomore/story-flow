-- | graph-core\/F006 T2:'Aapms.Store.Row' 的欄位規則本身(不透過 Index\/Query
-- 走完整流程,直接對 @nodes@ + 附屬表寫入\/讀出)。
module Aapms.Store.RowSpec (spec) where

import Data.Text (Text)
import Data.Time (fromGregorian)
import Database.SQLite.Simple (Only (..), Query (..), execute, query, withTransaction)
import Aapms.Core.Id (IdPrefix (PEnt), VaultId (..))
import Aapms.Core.Link (Link (..), LinkKind (References))
import Aapms.Core.Meta
import Aapms.Md.Document (DocKind (..))
import Aapms.Store.Fixtures (idOf, orDie, refOf, testRegistry, withTempVault)
import Aapms.Store.Marker (closeVault, initVaultAt, openVault, vhConn)
import Aapms.Store.Schema (VaultKind (StoryVault))
import Aapms.Store.Row
import Test.Hspec

-- | 一個「什麼欄位都有值」的合成 Meta,涵蓋 tags/aliases/links/timeline。
sampleMeta :: Meta
sampleMeta =
  Meta
    { metaId = idOf "ent-00000042"
    , metaVault = VaultId "liftgame"
    , metaType = TypeKey "character"
    , metaTitle = "測試節點"
    , metaSummary = "row roundtrip 用的合成節點"
    , metaTags = ["tag-a", "tag-b"]
    , metaStatus = Canon
    , metaTimeline = Just (Timeline (Just "崩塌前") (Just 3))
    , metaAliases = ["alias-a", "alias-b"]
    , metaLinks = [Link References (refOf "ent-00000001") (Just "備註")]
    , metaSource = Agent "claude-code"
    , metaRevision = Revision 5
    , metaCreated = fromGregorian 2026 8 10
    , metaUpdated = fromGregorian 2026 8 16
    }

spec :: Spec
spec = describe "graph-core/F006 Row" $ do
  it "T2: nodeFields 寫入 nodes + 附屬表後,hydrateMeta 讀回的 Meta 與原值相等" $
    withTempVault $ \dir -> do
      _ <- orDie =<< initVaultAt dir StoryVault "row-roundtrip"
      (vh, _issues) <- orDie =<< openVault testRegistry dir
      let conn = vhConn vh
          m = sampleMeta
      withTransaction conn $ do
        -- nodes.file_path / links.file_path 都是 FK REFERENCES files(path),
        -- 先補一筆 files 列才能通過 foreign_keys 檢查。
        execute
          conn
          "INSERT INTO files(path, mtime, size, doc_kind) VALUES (?, ?, ?, ?)"
          ("characters/x.md" :: Text, 0 :: Int, 0 :: Int, "topic" :: Text)
        execute
          conn
          (insertSql "nodes" nodeColumnList)
          (nodeFields m PEnt "characters/x.md" Nothing Nothing)
        execute conn "INSERT INTO node_aliases(node_id, alias) VALUES (?, ?)" ("ent-00000042" :: Text, "alias-a" :: Text)
        execute conn "INSERT INTO node_aliases(node_id, alias) VALUES (?, ?)" ("ent-00000042" :: Text, "alias-b" :: Text)
        execute conn "INSERT INTO node_tags(node_id, tag) VALUES (?, ?)" ("ent-00000042" :: Text, "tag-a" :: Text)
        execute conn "INSERT INTO node_tags(node_id, tag) VALUES (?, ?)" ("ent-00000042" :: Text, "tag-b" :: Text)
        execute
          conn
          (insertSql "links" ["src", "dst_vault", "dst", "kind", "note", "file_path"])
          [ sText "ent-00000042"
          , sMaybeText Nothing
          , sText "ent-00000001"
          , sText "references"
          , sMaybeText (Just "備註")
          , sText "characters/x.md"
          ]
      rows <-
        query
          conn
          (Query ("SELECT " <> nodeColumns <> " FROM nodes WHERE id = ?"))
          (Only ("ent-00000042" :: Text)) ::
          IO [NodeRow]
      case rows of
        [row] -> do
          got <- hydrateMeta (VaultId "liftgame") conn row
          got `shouldBe` m
        other -> expectationFailure ("預期恰一筆 NodeRow,得到 " <> show (length other))
      closeVault vh

  it "T2: parseDocKind . renderDocKind 對四種 DocKind 是 identity" $ do
    mapM_
      (\k -> parseDocKind (renderDocKind k) `shouldBe` Just k)
      [TopicDoc, LevelDoc, PackDoc, LicenseDoc]
