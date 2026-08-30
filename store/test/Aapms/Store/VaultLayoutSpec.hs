-- | graph-core\/B001:vault 目錄配置的守衛。
--
-- @system.md:439@ 對 asset vault 的目錄配置是明訂的:@library\/licenses.md@、
-- @library\/packs\/\<vendor\>\/\<pack-slug\>\/pack.md@、@library\/reference\/\<topic\>\/@、
-- @library\/studio\/@。在 B001 之前,__沒有任何測試在斷言這件事__,於是 F006 寫錯的
-- fixture 路徑一路被 F007 與 F009 照抄,三份 fixture 長出兩種寫法。
--
-- 本檔就是那個缺的斷言。判準是 'vaultLayoutViolations'(純函式,比對 fixture 的
-- 資料結構而非原始碼文字)。
--
-- __新增 vault fixture 時__:把新的檔案組加進下面的 'allVaultFixtures'。這是本方案
-- 唯一靠人記得的地方——判準本身是機械的,但「有哪些 fixture」得有人列。B001 的
-- 「修復方向」記了另一個零 opt-in 的替代方案(把驗證塞進 'writeFiles'),
-- 代價是違規會變成 setup 期例外而不是一條紅燈,當時未採用。
--
-- 對照表:
--
-- * LAW-1  每個 @licenses.md@ 的路徑恰好是 @library\/licenses.md@   -> test_LAW1
-- * LAW-2  每個 @pack.md@ 的路徑以 @library\/@ 起頭                  -> test_LAW2
-- * EX-1  'assetVaultFiles'(F006 的源頭)零違規                    -> test_EX1
-- * EX-2  'vaultBFiles'(F009 照抄的那份)零違規                    -> test_EX2
-- * EX-3  判準本身:對一份刻意寫錯的檔案組,逐條指出違規路徑        -> test_EX3
module Aapms.Store.VaultLayoutSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Aapms.Store.Fixtures (assetVaultFiles, storyVaultFiles, vaultLayoutViolations)
import Aapms.Store.MultiVaultSpec (vaultAFiles, vaultBFiles)
import Aapms.Store.SearchSpec (ftsVaultFiles)

-- | 測試套件裡每一份「一個 vault 的完整檔案組」。新增 fixture 要加進這裡。
allVaultFixtures :: [(String, [(FilePath, Text)])]
allVaultFixtures =
  [ ("Fixtures.storyVaultFiles", storyVaultFiles)
  , ("Fixtures.assetVaultFiles", assetVaultFiles)
  , ("MultiVaultSpec.vaultAFiles", vaultAFiles)
  , ("MultiVaultSpec.vaultBFiles", vaultBFiles)
  , ("SearchSpec.ftsVaultFiles", ftsVaultFiles)
  ]

-- | 刻意違規的檔案組,用來證明判準真的會抓(否則 LAW-1\/LAW-2 可能只是恆真)。
badFixture :: [(FilePath, Text)]
badFixture =
  [ ("licenses.md", "")
  , ("packs/some-vendor/pack.md", "")
  , ("library/licenses.md", "")
  , ("library/reference/topic/pack.md", "")
  , ("characters/linda.md", "")
  ]

spec :: Spec
spec = describe "graph-core/B001 vault 目錄配置(system.md:439)" $ do
  describe "LAW-1 / LAW-2: 每一份 fixture 的檔案組都符合主架構" $
    mapM_ oneFixture allVaultFixtures

  describe "EX-3: 判準本身抓得到違規" $
    it "對刻意寫錯的檔案組,逐條回出 licenses.md 與 pack.md 的違規路徑" $
      vaultLayoutViolations badFixture
        `shouldBe` ["licenses.md", "packs/some-vendor/pack.md"]
  where
    oneFixture (name, files) =
      it (name <> ":licenses.md 在 library/ 下、pack.md 以 library/ 起頭") $
        vaultLayoutViolations files `shouldBe` []
