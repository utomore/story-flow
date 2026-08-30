-- | T9:Vault 的建立、列出、資訊與索引維護。
--
-- 'createVault' 除了建骨架還要__登記進全域註冊表__ ——ADR-008 的
-- 「@--vault \<名稱\>@ 查全域註冊表」如果沒有人寫進那份註冊表,規則永遠命不中。
module Aapms.Service.VaultSpec (spec) where

import Data.List (sort)
import Aapms.Service
import Aapms.Service.Fixtures
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "Vault" $ do
  it "createVault 之後 listVaults 看得到它" $
    withVaultDir $ \dir -> do
      v <- orDieS =<< createVault dir "liftgame"
      vvName v `shouldBe` "liftgame"
      vvEntityCount v `shouldBe` Just 0
      vs <- orDieS =<< listVaults
      map vvName vs `shouldBe` ["liftgame"]

  it "listVaults 不為了數 Entity 而開索引" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      vs <- orDieS =<< listVaults
      map vvEntityCount vs `shouldBe` [Nothing]

  it "同一個名稱登記到另一個路徑會被擋下來" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      r <- createVault (dir </> "characters") "liftgame"
      fmap (const ()) r `shouldFailWith` "vault_config_invalid"

  it "同一個目錄再建一次回 VaultAlreadyExists" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      r <- createVault dir "liftgame"
      fmap (const ()) r `shouldFailWith` "vault_already_exists"

  it "vaultInfo 的名稱與根目錄相符,Entity 數跟著寫入走" $
    withServiceEnv $ \env -> do
      earlier <- runS env vaultInfo
      vvName earlier `shouldBe` "liftgame"
      vvEntityCount earlier `shouldBe` Just 0
      _ <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      later <- runS env vaultInfo
      vvEntityCount later `shouldBe` Just 1

  it "reindex 的檔案數等於 Vault 裡真正的 .md 數" $
    withServiceEnv $ \env -> do
      _ <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      _ <- runS env (createEntity (newEntity "item" "織紋刀" "第七織手的佩刀"))
      r <- runS env reindex
      irFiles r `shouldBe` 2
      irIssues r `shouldBe` []

  it "reindex 之後查詢結果不變(索引是衍生物)" $
    withServiceEnv $ \env -> do
      _ <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      earlier <- runS env (listEntities emptyFilter)
      _ <- runS env reindex
      later <- runS env (listEntities emptyFilter)
      later `shouldBe` earlier

  it "refreshIndex 在沒有外部改動時什麼問題都沒有" $
    withServiceEnv $ \env -> do
      _ <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      r <- runS env refreshIndex
      irIssues r `shouldBe` []

  it "createVault 建出 system.md 說的子目錄" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      entries <- listDirectory dir
      sort (filter (`elem` expectedDirs) entries) `shouldBe` sort expectedDirs
  where
    expectedDirs = ["characters", "dialogues", "items", "levels", "lore"]
