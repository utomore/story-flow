-- | T5:單檔索引是整檔替換,而且包在一個 transaction 裡。
module Aapms.Store.IndexSpec (spec) where

import Data.Text (Text)
import Database.SQLite.Simple
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Fixtures
import Aapms.Store.Index
import Test.Hspec

spec :: Spec
spec = describe "T5 indexFile" $ do
  it "一份含 2 個片段的 Entity 檔進索引後是 1 主體 + 2 片段" $
    withVaultIndex $ \v conn -> do
      writeVaultFile v linda lindaMd
      orDie =<< indexFile conn v linda

      countRows conn "entities" `shouldReturn` 3
      textsOf conn "SELECT id FROM entities ORDER BY id" ()
        `shouldReturn` ["ent-7f3a", "ent-7f3b", "ent-7f3c"]
      -- 主體沒有 section_anchor:它的 meta 在 frontmatter,不屬於任何一節
      textsOf conn "SELECT id FROM entities WHERE section_anchor IS NULL" ()
        `shouldReturn` ["ent-7f3a"]

  it "aliases / tags / links 依繼承規則進表" $
    withVaultIndex $ \v conn -> do
      writeVaultFile v linda lindaMd
      orDie =<< indexFile conn v linda

      -- aliases 不繼承:只有主體有
      textsOf conn "SELECT alias FROM entity_aliases" ()
        `shouldReturn` ["小琳", "第七織手"]
      textsOf conn "SELECT entity_id FROM entity_aliases" ()
        `shouldReturn` ["ent-7f3a", "ent-7f3a"]
      -- tags 是檔案層與節層的聯集,這份檔案的檔案層沒有 tags
      countRows conn "entity_tags" `shouldReturn` 3
      -- links 也不繼承:1 + 3 筆,全部掛在片段身上
      countRows conn "links" `shouldReturn` 4
      textsOf conn "SELECT kind FROM links WHERE src = 'ent-7f3c'" ()
        `shouldReturn` ["contradicts", "occursIn", "partOf"]
      -- 備註原樣保留
      textsOf conn "SELECT note FROM links WHERE kind = 'contradicts'" ()
        `shouldReturn` ["對雙親死因的敘述不一致"]

  it "FTS 查得到剛索引進去的內容" $
    withVaultIndex $ \v conn -> do
      writeVaultFile v linda lindaMd
      orDie =<< indexFile conn v linda
      hits <-
        textsOf
          conn
          -- MATCH 的左邊只能是 FTS 表本身的名字,別名不行
          "SELECT m.entity_id FROM entities_fts JOIN fts_map m ON m.rowid = entities_fts.rowid\
          \ WHERE entities_fts MATCH ?"
          (Only ("埃提亞" :: Text))
      hits `shouldContain` ["ent-7f3a"]

  it "同一份檔案改成只剩 1 個片段後重新索引,舊記錄全部消失" $
    withVaultIndex $ \v conn -> do
      writeVaultFile v linda lindaMd
      orDie =<< indexFile conn v linda
      writeVaultFile v linda lindaOneFragmentMd
      orDie =<< indexFile conn v linda

      countRows conn "entities" `shouldReturn` 2
      textsOf conn "SELECT id FROM entities ORDER BY id" ()
        `shouldReturn` ["ent-7f3a", "ent-7f3b"]
      -- 不留孤兒:aliases / tags / links / FTS 一起走
      countRows conn "entity_tags" `shouldReturn` 1
      countRows conn "links" `shouldReturn` 1
      countRows conn "fts_map" `shouldReturn` 2
      countRows conn "entities_fts" `shouldReturn` 2
      countRows conn "files" `shouldReturn` 1

  it "Level 檔的 levels / nodes / node_entities 正確" $
    withVaultIndex $ \v conn -> do
      writeVaultFile v classroom classroomMd
      orDie =<< indexFile conn v classroom

      countRows conn "levels" `shouldReturn` 1
      textsOf conn "SELECT root FROM levels" () `shouldReturn` ["nod-0001"]
      textsOf conn "SELECT id FROM nodes ORDER BY id" ()
        `shouldReturn` ["nod-0001", "nod-0002", "nod-0003", "nod-0004"]
      -- 標題階層即樹:parent 與 order 由層級與文件順序推導
      textsOf conn "SELECT parent_id FROM nodes WHERE id = 'nod-0004'" ()
        `shouldReturn` ["nod-0002"]
      scalarInt conn "SELECT order_idx FROM nodes WHERE id = 'nod-0003'" ()
        `shouldReturn` 2
      -- Node 指向的 Entity 由 involves / references 推導
      countRows conn "node_entities" `shouldReturn` 3
      textsOf conn "SELECT entity_id FROM node_entities WHERE node_id = 'nod-0002'" ()
        `shouldReturn` ["ent-7f3a", "ent-8b20"]

  it "unindexFile 之後這份檔案的記錄一筆不剩" $
    withVaultIndex $ \v conn -> do
      writeVaultFile v linda lindaMd
      orDie =<< indexFile conn v linda
      unindexFile conn linda
      mapM_
        (\t -> countRows conn t `shouldReturn` 0)
        ["files", "entities", "entity_aliases", "entity_tags", "links", "fts_map", "entities_fts"]

  -- 索引中途拋錯時 transaction 必須整批回滾,不能留下「舊記錄刪了、新記錄沒進去」
  -- 的半殘索引。這裡用「另一份檔案的第二個片段與既有 id 相撞」造出中途失敗。
  it "寫入中途失敗時整批回滾,索引維持原狀" $
    withVaultIndex $ \v conn -> do
      writeVaultFile v dao daoMd
      orDie =<< indexFile conn v dao
      writeVaultFile v clash duplicateIdMd
      r <- indexFile conn v clash
      case r of
        Left (SqliteError _) -> pure ()
        other -> expectationFailure ("預期 SqliteError,得到 " <> show other)

      textsOf conn "SELECT path FROM files" () `shouldReturn` ["items/織紋刀.md"]
      countRows conn "entities" `shouldReturn` 2
      textsOf conn "SELECT file_path FROM entities WHERE id = 'ent-1001'" ()
        `shouldReturn` ["items/織紋刀.md"]
  where
    linda = "characters/琳達.md"
    dao = "items/織紋刀.md"
    clash = "items/撞號.md"
    classroom = "levels/教室.md"
