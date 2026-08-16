-- | func-0005 T11:刪除。
--
-- 範例 Vault 的關聯本來就交織:@ent-7f3b@ 與 @ent-7f3c@ 都 @partOf@ 指向主體
-- @ent-7f3a@,而 @lvl-3a01@ 的 Node @involves@ 指向 @ent-7f3a@ 與 @ent-c41d@。
-- 「安全刪除擋得住」因此不必另外編情境,拿真實的資料測就是了。
module StoryFlow.Store.DeleteSpec (spec) where

import qualified Data.Text as T
import Database.SQLite.Simple
import StoryFlow.Core.Id (renderId)
import StoryFlow.Core.Link (Link (..), LinkKind (..))
import StoryFlow.Store.Create
import StoryFlow.Store.Error (StoreError (..))
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Index (rebuildIndex)
import StoryFlow.Store.Query (lookupEntity)
import StoryFlow.Store.Vault (vaultAbsPath)
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = do
  describe "T11 deleteEntity(片段)" $ do
    it "沒有人指向時直接刪掉那一節,主體 revision +1" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< deleteEntity conn v frag 1 DeleteSafe
        drPath r `shouldBe` linda
        drRemovedIds r `shouldBe` [frag]
        drBrokenLinks r `shouldBe` []

        txt <- readVaultFile v linda
        txt `shouldSatisfy` (not . T.isInfixOf "外貌")
        txt `shouldSatisfy` T.isInfixOf "與塔主的過節"
        txt `shouldSatisfy` T.isInfixOf "revision: 4"

        lookupEntity conn frag `shouldReturn` Nothing
        scalarInt conn "SELECT count(*) FROM entities WHERE file_path = ?" (Only linda)
          `shouldReturn` 2

    it "被指向時 DeleteSafe 回 ReferencedBy,檔案位元組完全未變" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v lore
        -- ent-c41e supersedes ent-91cc;先讓別人指向 ent-c41e
        r <- deleteEntity conn v (idOf "ent-c41d") 1 DeleteSafe
        case r of
          Left (ReferencedBy i srcs) -> do
            i `shouldBe` idOf "ent-c41d"
            map (renderId . fst) srcs `shouldContain` ["ent-7f3c"]
          other -> expectationFailure ("預期 ReferencedBy,得到 " <> show other)
        readVaultFile v lore `shouldReturn` original

    it "DeleteForce 照刪,並回報被打斷的關聯" $
      withSampleIndex $ \v conn -> do
        r <- orDie =<< deleteEntity conn v (idOf "ent-c41d") 1 DeleteForce
        map (renderId . fst) (drBrokenLinks r) `shouldContain` ["ent-7f3c"]
        map linkKind (map snd (drBrokenLinks r)) `shouldContain` [OccursIn]
        doesFileExist (vaultAbsPath v lore) `shouldReturn` False

    it "以過期的 revision 刪除時回 StaleRevision,檔案位元組完全未變" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- deleteEntity conn v frag 99 DeleteSafe
        r `shouldBe` Left (StaleRevision frag 99 1)
        readVaultFile v linda `shouldReturn` original

    it "刪不存在的 id 回 EntityNotFound" $
      withSampleIndex $ \v conn -> do
        let ghost = idOf "ent-0000"
        r <- deleteEntity conn v ghost 1 DeleteSafe
        r `shouldBe` Left (EntityNotFound ghost)

  describe "T11 deleteEntity(檔案層主體)" $ do
    it "刪主體時整份檔案與索引記錄一起消失" $
      withSampleIndex $ \v conn -> do
        -- 先把指向琳達的關聯清掉才刪得動;這裡直接走 DeleteForce
        r <- orDie =<< deleteEntity conn v main_ 3 DeleteForce
        drPath r `shouldBe` linda
        map renderId (drRemovedIds r) `shouldBe` ["ent-7f3a", "ent-7f3b", "ent-7f3c"]

        doesFileExist (vaultAbsPath v linda) `shouldReturn` False
        scalarInt conn "SELECT count(*) FROM entities WHERE file_path = ?" (Only linda)
          `shouldReturn` 0
        scalarInt conn "SELECT count(*) FROM files WHERE path = ?" (Only linda)
          `shouldReturn` 0
        -- 檔內片段的關聯也跟著級聯消失
        scalarInt conn "SELECT count(*) FROM links WHERE file_path = ?" (Only linda)
          `shouldReturn` 0

    it "任何一個片段被指向就整份拒絕(DeleteSafe 逐一檢查)" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v linda
        r <- deleteEntity conn v main_ 3 DeleteSafe
        case r of
          Left (ReferencedBy i _) -> i `shouldBe` main_
          other -> expectationFailure ("預期 ReferencedBy,得到 " <> show other)
        readVaultFile v linda `shouldReturn` original

    it "沒有人指向的檔案 DeleteSafe 刪得動" $
      withSampleIndex $ \v conn -> do
        -- 走廊沒有任何人指向它
        r <- orDie =<< deleteLevel conn v (idOf "lvl-3a02") 1 DeleteSafe
        drPath r `shouldBe` "levels/走廊.md"
        map renderId (drRemovedIds r) `shouldBe` ["lvl-3a02", "nod-0100", "nod-0101"]
        doesFileExist (vaultAbsPath v "levels/走廊.md") `shouldReturn` False

  describe "T11 deleteLevel" $ do
    it "對 Node 的 id 呼叫 deleteLevel 回 NotAFileMain" $
      withSampleIndex $ \v conn -> do
        let n = idOf "nod-0002"
        r <- deleteLevel conn v n 1 DeleteSafe
        r `shouldBe` Left (NotAFileMain n)

    it "Level 也走樂觀鎖" $
      withSampleIndex $ \v conn -> do
        original <- readVaultFile v "levels/走廊.md"
        r <- deleteLevel conn v (idOf "lvl-3a02") 9 DeleteSafe
        r `shouldBe` Left (StaleRevision (idOf "lvl-3a02") 9 1)
        readVaultFile v "levels/走廊.md" `shouldReturn` original

    it "刪掉之後 rebuildIndex 仍然乾淨(索引與檔案一致)" $
      withSampleIndex $ \v conn -> do
        _ <- orDie =<< deleteLevel conn v (idOf "lvl-3a02") 1 DeleteSafe
        countRows conn "levels" `shouldReturn` 1
        countRows conn "nodes" `shouldReturn` 4
        _ <- orDie =<< rebuildIndex conn v
        countRows conn "levels" `shouldReturn` 1
        countRows conn "nodes" `shouldReturn` 4
  where
    linda = "characters/琳達.md"
    lore = "lore/埃提亞崩塌.md"
    main_ = idOf "ent-7f3a"
    frag = idOf "ent-7f3b"
