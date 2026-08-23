-- | 內容雜湊。
--
-- SHA-256 是整個系統的內容識別基礎:
--
-- * @blobs@ 表以它為主鍵,同一份內容跨素材包只算一次縮圖
-- * 重構的刪除閘門只認它 —— 檔名與大小相同不構成「同一份內容」的證明
-- * 專案素材與來源不一致時,靠它分辨「被改過」與「來源更新了」
module AssetDB.Ingest.Hash
  ( Sha256
  , unSha256
  , sha256Bytes
  , sha256File
  , crc32Hex
  ) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Crypto.Hash qualified as Hash
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Numeric (showHex)

-- | 十六進位小寫的 SHA-256。存進資料庫的就是這個形式 ——
-- 人看得懂、SQL 比得動、複製貼上不會壞。
newtype Sha256 = Sha256 Text
  deriving newtype (Eq, Ord)

instance Show Sha256 where
  show (Sha256 t) = T.unpack t

unSha256 :: Sha256 -> Text
unSha256 (Sha256 t) = t

sha256Bytes :: ByteString -> Sha256
sha256Bytes = fromDigest . Hash.hash

-- | 串流讀取,不把整個檔案載入記憶體。
--
-- 素材庫裡有 1 GB 的參考資料壓縮檔;整檔載入會在掃描大型壓縮檔時
-- 把記憶體吃光。'hashlazy' 配合 'BL.readFile' 以區塊處理。
sha256File :: FilePath -> IO Sha256
sha256File path = fromDigest . hashlazy <$> BL.readFile path

-- | @crypton@ 的 'Show' instance 就是小寫十六進位,不需要繞道
-- @memory@ 的 @convertToBase@ —— 那條路還會撞上 @memory@ 版本不一致的問題。
fromDigest :: Digest SHA256 -> Sha256
fromDigest = Sha256 . T.pack . show

-- | CRC32 轉成固定八位的十六進位。
--
-- ZIP 的 central directory 免費附贈 CRC32,可當作 SHA-256 之前的廉價前濾:
-- CRC 不同就一定不是同一份內容,不必真的解壓比對。
crc32Hex :: Word32 -> Text
crc32Hex w = T.justifyRight 8 '0' (T.pack (showHex w ""))
