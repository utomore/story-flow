-- | T3:原子寫入。
--
-- 「覆蓋既有檔案成功」是本檔最重要的一條:Windows 的 rename 在目標已存在時
-- 不見得會覆寫,func-0004 明確要求驗證這個行為而不是相信它。
module StoryFlow.Store.AtomicSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Store.Atomic (atomicWriteText)
import StoryFlow.Store.Error (StoreError (..))
import StoryFlow.Store.Fixtures (withTempVault)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "T3 atomicWriteText" $ do
  it "寫入後內容正確、UTF-8 且不加 BOM" $
    withTempVault $ \dir -> do
      let fp = dir </> "琳達.md"
          txt = "# 琳達\n埃提亞的第七織手\n"
      atomicWriteText fp txt `shouldReturn` Right ()
      bytes <- BS.readFile fp
      bytes `shouldBe` TE.encodeUtf8 txt
      BS.take 3 bytes `shouldNotBe` BS.pack [0xEF, 0xBB, 0xBF]

  it "覆蓋既有檔案成功(Windows 的關鍵驗證)" $
    withTempVault $ \dir -> do
      let fp = dir </> "琳達.md"
      atomicWriteText fp "第一版" `shouldReturn` Right ()
      atomicWriteText fp "第二版" `shouldReturn` Right ()
      readText fp `shouldReturn` "第二版"

  it "寫入後目錄下沒有殘留的暫存檔" $
    withTempVault $ \dir -> do
      let fp = dir </> "琳達.md"
      forM_ [1 :: Int .. 3] $ \i ->
        atomicWriteText fp ("第 " <> T.pack (show i) <> " 版")
      leftovers dir `shouldReturn` []

  it "寫入失敗時回 FileWriteFailed(父目錄不存在)" $
    withTempVault $ \dir -> do
      let fp = dir </> "不存在的目錄" </> "琳達.md"
      r <- atomicWriteText fp "內容"
      case r of
        Left (FileWriteFailed p _) -> p `shouldBe` fp
        other -> expectationFailure ("預期 FileWriteFailed,得到 " <> show other)

  -- 「目標路徑寫不進去」在跨平台上唯一一致的造法:目標是一個既有目錄。
  -- rename 蓋不過去,於是可以同時驗證「回 FileWriteFailed」「原有的東西沒被動到」
  -- 「暫存檔有清掉」三件事。
  it "目標是既有目錄時回 FileWriteFailed,原內容不變且不留暫存檔" $
    withTempVault $ \dir -> do
      let target = dir </> "已存在的目錄"
      createDirectoryIfMissing True target
      BS.writeFile (target </> "裡面的檔案") (TE.encodeUtf8 "原有內容")
      r <- atomicWriteText target "想蓋掉目錄的內容"
      case r of
        Left (FileWriteFailed p _) -> p `shouldBe` target
        other -> expectationFailure ("預期 FileWriteFailed,得到 " <> show other)
      doesDirectoryExist target `shouldReturn` True
      readText (target </> "裡面的檔案") `shouldReturn` "原有內容"
      leftovers dir `shouldReturn` []

readText :: FilePath -> IO Text
readText fp = TE.decodeUtf8 <$> BS.readFile fp

-- | 目錄下所有名字帶 @.tmp@ 的殘留物。
leftovers :: FilePath -> IO [FilePath]
leftovers dir = filter (".tmp" `isInfixOf`) <$> listDirectory dir
