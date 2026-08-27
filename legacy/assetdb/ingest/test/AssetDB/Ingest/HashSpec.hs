module AssetDB.Ingest.HashSpec (spec) where

import AssetDB.Ingest.Hash
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "sha256Bytes" $ do
    it "空輸入的標準值" $
      -- NIST 的已知向量。自己算出來的「看起來對」不算驗證。
      unSha256 (sha256Bytes "")
        `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    it "abc 的標準值" $
      unSha256 (sha256Bytes "abc")
        `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    it "輸出是 64 個小寫十六進位字元" $ do
      let h = unSha256 (sha256Bytes "任意內容")
      T.length h `shouldBe` 64
      T.all (`elem` ("0123456789abcdef" :: String)) h `shouldBe` True

    it "二進位內容不會被文字編碼弄壞" $ do
      -- 素材是 PNG 與 HEIC,不是文字。任何一處誤用文字編碼都會靜默改變雜湊。
      let png = BC.pack "\137PNG\r\n\26\n" <> BS.pack [0, 255, 128, 1]
      unSha256 (sha256Bytes png) `shouldNotBe` unSha256 (sha256Bytes "")

  describe "sha256File" $
    it "與 sha256Bytes 一致 —— 串流路徑不能算出不同答案" $
      withSystemTempDirectory "assetdb-hash" $ \dir -> do
        let p = dir </> "sample.bin"
            content = BS.concat (replicate 5000 (BC.pack "abcdefghij"))
        BS.writeFile p content
        fromFile <- sha256File p
        unSha256 fromFile `shouldBe` unSha256 (sha256Bytes content)

  describe "crc32Hex" $ do
    it "補零到八位" $ do
      crc32Hex 0 `shouldBe` "00000000"
      crc32Hex 255 `shouldBe` "000000ff"

    it "最大值" $
      crc32Hex 0xFFFFFFFF `shouldBe` "ffffffff"
