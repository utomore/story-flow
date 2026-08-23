-- | graph-core\/F006 T7:@rm index.db@ 後 'Aapms.Store.Marker.openVault' +
-- 'rebuildIndex' 與刪除前等價(P0 契約測試精神,套件內版本——見 F006 待確認
-- 假設 A8)、'refreshStale' 只重讀改動過的檔、移除消失的檔案。
module Aapms.Store.StaleSpec (spec) where

import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), query)
import Aapms.Core.Id (renderId)
import Aapms.Core.Meta (metaId)
import Aapms.Store.Fixtures
import Aapms.Store.Index (rebuildIndex, refreshStale)
import Aapms.Store.Marker (VaultHandle, closeVault, indexDbPath, initVaultAt, openVault, vhConn, vhRoot)
import Aapms.Store.Schema (VaultKind (StoryVault))
import Aapms.Store.Query (emptyNodeFilter, linksFrom, listNodes)
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "graph-core/F006 過時偵測與 rm index.db 等價" $ do
  -- __不用 withStoryVault__:它收尾會自動 closeVault 一次,這條測試需要自己
  -- 提前 closeVault 才能刪掉 index.db(Windows 上開著的檔案刪不掉),兩者疊加
  -- 會對同一個連線 close 兩次(SQLite「bad parameter or other API misuse」)。
  it "T7: rm index.db 後 openVault + rebuildIndex 與刪除前的 listNodes/linksFrom 結果相同" $
    withTempVault $ \dir -> do
      _ <- orDie =<< initVaultAt dir StoryVault "story-fixture"
      writeFiles dir storyVaultFiles
      (vh, _issues1) <- orDie =<< openVault testRegistry dir
      _ <- orDie =<< rebuildIndex vh
      snapBefore <- snapshot vh
      let dbPath = indexDbPath (vhRoot vh)
      closeVault vh
      removeFile dbPath
      -- WAL 模式可能留下 -wal/-shm,一併清掉避免殘留影響重新開檔
      mapM_ removeIfExists [dbPath <> "-wal", dbPath <> "-shm"]
      (vh2, _issues2) <- orDie =<< openVault testRegistry dir
      _ <- orDie =<< rebuildIndex vh2
      snapAfter <- snapshot vh2
      snapAfter `shouldBe` snapBefore
      closeVault vh2

  it "T7: 只改一個檔案的 mtime/size,refreshStale 只重讀那一個,其餘檔案不受影響" $
    withStoryVault $ \vh -> do
      _ <- orDie =<< rebuildIndex vh
      beforeLevel <- summaryOf vh "lvl-00000001"
      let original = case lookup "characters/test-character.md" storyVaultFiles of
            Just t -> t
            Nothing -> error "fixture 缺少 characters/test-character.md"
          changed = T.replace "外貌片段" "改過的外貌片段" original
      writeFiles (vhRoot vh) [("characters/test-character.md", changed)]
      _ <- orDie =<< refreshStale vh
      afterFrag <- summaryOf vh "ent-00000002"
      afterFrag `shouldBe` Just "改過的外貌片段"
      -- 沒被動到的 Level 檔內容不變
      afterLevel <- summaryOf vh "lvl-00000001"
      afterLevel `shouldBe` beforeLevel

  it "T7: 索引後刪除磁碟上一個檔案,refreshStale 把該檔案的記錄移除" $
    withStoryVault $ \vh -> do
      _ <- orDie =<< rebuildIndex vh
      removeFile (vhRoot vh </> "levels" </> "test-classroom.md")
      _ <- orDie =<< refreshStale vh
      metas <- listNodes vh emptyNodeFilter
      any ((== idOf "lvl-00000001") . metaId) metas `shouldBe` False

--------------------------------------------------------------------------------

removeIfExists :: FilePath -> IO ()
removeIfExists fp = do
  exists <- doesFileExist fp
  if exists then removeFile fp else pure ()

snapshot :: VaultHandle -> IO ([String], [String])
snapshot vh = do
  metas <- listNodes vh emptyNodeFilter
  links1 <- linksFrom vh (idOf "ent-00000001")
  links3 <- linksFrom vh (idOf "ent-00000003")
  pure
    ( sort (map (T.unpack . renderId . metaId) metas)
    , sort (map show (links1 ++ links3))
    )

summaryOf :: VaultHandle -> Text -> IO (Maybe Text)
summaryOf vh nodeId = do
  rows <- query (vhConn vh) "SELECT summary FROM nodes WHERE id = ?" (Only nodeId) :: IO [Only Text]
  pure $ case rows of
    (Only s : _) -> Just s
    [] -> Nothing
