-- | graph-core\/E001:"Aapms.Store.Walk" 的 'vaultMarkdownFiles' \/ 'statOf'——原樣
-- 從 "Aapms.Store.Index" 搬過來的兩個函式,簽名與行為不得改變。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/enhancements\/E001-store-internal-module-boundary.md@)
--
-- @
-- REG-3  vaultMarkdownFiles:略過 . 開頭目錄與非 .md 檔,回排序後的相對路徑,行為與搬移前相同 -> prop_REG3
-- REG-4  statOf:現存檔案的 size 分量 = 實際位元組數;同一未變動檔案重複讀取結果相同        -> prop_REG4_size / prop_REG4_stable
-- EX-3  vault 目錄含 .aapms\/config.toml、.git\/HEAD、foo.txt、bar.md -> ["bar.md"]        -> test_EX3(= 搬移前 IndexSpec STEP-3)
-- EX-4  完全空的 vault 目錄 -> []                                                          -> test_EX4
-- EX-5  不存在的檔案路徑 -> statOf 回 Left,不拋例外                                        -> test_EX5
-- @
--
-- __禁止讀實作__:本檔只 import "Aapms.Store.Walk" 的骨架簽名,不讀
-- "Aapms.Store.Index" 現有的函式本體;REG-3\/REG-4 的產生器範圍刻意只涵蓋 spec 與既有
-- EX-3\/EX-4 example 已經寫明的邊界(根層檔案 + 整個 . 開頭子目錄略過),不假設是否遞迴
-- 進非 . 開頭的巢狀子目錄——spec 沒寫,不腦補。
module Aapms.Store.WalkSpec (spec) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import Data.List (nubBy, sort)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Store.Fixtures (withTempVault)
import Aapms.Store.Walk (statOf, vaultMarkdownFiles)

spec :: Spec
spec = describe "graph-core/E001 Aapms.Store.Walk" $ do
  describe "REG-3 / EX-3 / EX-4: vaultMarkdownFiles" $ do
    it "EX-3: 略過 . 開頭目錄與非 .md 檔,只回排序後的 .md 相對路徑(= 搬移前 IndexSpec STEP-3)" $
      withTempVault $ \dir -> do
        createDirectoryIfMissing True (dir </> ".aapms")
        createDirectoryIfMissing True (dir </> ".git")
        writeFile (dir </> ".aapms" </> "config.toml") "id = \"vlt-1\"\n"
        writeFile (dir </> ".git" </> "HEAD") "ref: refs/heads/main\n"
        writeFile (dir </> "foo.txt") "not markdown"
        writeFile (dir </> "bar.md") "---\n---\n"
        files <- vaultMarkdownFiles dir
        files `shouldBe` ["bar.md"]

    it "EX-4: 完全空的 vault 目錄回 []" $
      withTempVault $ \dir -> do
        files <- vaultMarkdownFiles dir
        files `shouldBe` []

    it "REG-3: 任意根層檔案與 . 開頭子目錄組合,回傳值 = 排序後、根層 .md 檔名的集合" $
      hedgehog $ do
        entries <- forAll genEntries
        result <- evalIO $ withTempVault $ \dir -> do
          materialize dir entries
          vaultMarkdownFiles dir
        let expected =
              sort
                [ T.unpack (filenameOf base "md")
                | Entry Nothing base ext <- entries
                , ext == "md"
                ]
        sort result === expected

  describe "REG-4 / EX-5: statOf" $ do
    it "EX-5: 不存在的路徑回 Left 的 StoreError,不拋例外" $
      withTempVault $ \dir -> do
        outcome <- try (statOf (dir </> "never-existed.md"))
        case outcome of
          Left ex -> expectationFailure ("statOf 對不存在的路徑拋出例外:" <> show (ex :: SomeException))
          Right (Left _) -> pure ()
          Right (Right v) -> expectationFailure ("預期 Left,得到 Right " <> show v)

    it "REG-4: 現存檔案 statOf 結果的第二個分量(size)= 檔案的實際位元組數" $
      hedgehog $ do
        content <- forAll (Gen.bytes (Range.linear 0 200))
        outcome <- evalIO $ withTempVault $ \dir -> do
          let fp = dir </> "sized.bin"
          BS.writeFile fp content
          statOf fp
        case outcome of
          Left err -> annotateShow err >> failure
          Right (_mtime, size) -> size === fromIntegral (BS.length content)

    it "EX-6: 內容恰為 5 個位元組的檔,statOf 回 Right (m, 5)——第二個分量是 5" $
      withTempVault $ \dir -> do
        let fp = dir </> "five-bytes.bin"
        BS.writeFile fp (BS.replicate 5 0)
        outcome <- statOf fp
        case outcome of
          Left err -> expectationFailure ("statOf 對存在的檔案回 Left:" <> show err)
          Right (_mtime, size) -> size `shouldBe` 5

    it "REG-4: 同一個未變動的檔案重複 statOf 兩次,結果相同" $
      hedgehog $ do
        content <- forAll (Gen.bytes (Range.linear 0 100))
        (r1, r2) <- evalIO $ withTempVault $ \dir -> do
          let fp = dir </> "stable.bin"
          BS.writeFile fp content
          a <- statOf fp
          b <- statOf fp
          pure (a, b)
        r1 === r2

--------------------------------------------------------------------------------
-- REG-3 產生器與輔助

-- | 一個候選檔案:落在根目錄(@Nothing@)或某個 @.@ 開頭子目錄(@Just 目錄名@)。
data Entry = Entry
  { entryDotDir :: Maybe Text
  , entryBase :: Text
  , entryExt :: Text
  }
  deriving stock (Eq, Show)

genEntries :: Gen [Entry]
genEntries = nubBy sameSlot <$> Gen.list (Range.linear 0 12) genEntry
  where
    sameSlot a b = (entryDotDir a, entryBase a, entryExt a) == (entryDotDir b, entryBase b, entryExt b)

genEntry :: Gen Entry
genEntry =
  Entry
    <$> Gen.maybe (Gen.element [".aapms", ".git", ".hidden"])
    <*> Gen.text (Range.linear 1 8) Gen.alphaNum
    <*> Gen.element ["md", "txt", "markdown", ""]

filenameOf :: Text -> Text -> Text
filenameOf base "" = base
filenameOf base ext = base <> "." <> ext

materialize :: FilePath -> [Entry] -> IO ()
materialize dir = mapM_ writeEntry
  where
    writeEntry (Entry Nothing base ext) =
      writeFile (dir </> T.unpack (filenameOf base ext)) "x"
    writeEntry (Entry (Just d) base ext) = do
      let subdir = dir </> T.unpack d
      createDirectoryIfMissing True subdir
      writeFile (subdir </> T.unpack (filenameOf base ext)) "x"
