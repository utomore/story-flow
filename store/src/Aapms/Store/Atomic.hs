-- | 原子寫入:寫同目錄暫存檔 → 關檔 → rename 覆蓋。
--
-- 「先寫檔、再更新索引」(ADR-002)的前半段。中途失敗時原檔__完好無損__,
-- 不會出現半寫的檔案——Markdown 是唯一的真相來源,半個檔案等於資料遺失。
--
-- 三個實作上的堅持:
--
-- * 暫存檔與目標檔__同一個目錄__。跨檔案系統的 rename 不是原子操作,
--   寫進系統暫存目錄再搬過來就失去了整個保證
-- * 以二進位 handle 寫 UTF-8 位元組:__不加 BOM__,也不讓 Windows 把 @\\n@
--   悄悄換成 @\\r\\n@(行尾風格由 "Aapms.Md.Document" 決定,不是由平台決定)
-- * 失敗時清掉暫存檔,不在作者的 Vault 裡留垃圾
--
-- 殘留競態:重讀檔案(樂觀鎖比對)與 rename 之間有極短窗口,兩個行程剛好在此
-- 交錯仍可能互相覆蓋。這是 entity-graph-core/F004 明確接受的殘留風險(S1 不做作業系統層
-- 檔案鎖):單機、單人 + AI Agent,窗口是毫秒級,損失可由 git 復原。
module Aapms.Store.Atomic
  ( atomicWriteText
  , readTextFile
  ) where

import Control.Exception (IOException, bracketOnError, try)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Store.Error (StoreError (..))
import System.Directory (removeFile, renamePath)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (Handle, hClose, hFlush, openBinaryTempFile)

-- | 讀檔的對應方向:一律當 UTF-8,不看本機 locale。
--
-- Vault 裡的 @.md@ 是跨機器、進 git 的資產,編碼不能取決於誰的機器在讀。
readTextFile :: FilePath -> IO (Either StoreError Text)
readTextFile fp = do
  raw <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
  pure $ case raw of
    Left e -> Left (FileReadFailed fp (T.pack (show e)))
    Right bytes -> case TE.decodeUtf8' bytes of
      Left e -> Left (FileReadFailed fp ("檔案不是合法的 UTF-8:" <> T.pack (show e)))
      Right t -> Right t

atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())
atomicWriteText target txt = do
  r <- try go :: IO (Either IOException ())
  pure $ case r of
    Left e -> Left (FileWriteFailed target (T.pack (show e)))
    Right () -> Right ()
  where
    go =
      bracketOnError
        -- 暫存檔名由 openBinaryTempFile 產生:同目錄、原子建立、跨平台唯一。
        -- entity-graph-core/F004 原本寫的是 <target>.tmp-<pid>,但 base 在 Windows 上沒有
        -- 取 pid 的介面,而 openBinaryTempFile 連「同時兩個行程」都涵蓋。
        (openBinaryTempFile (takeDirectory target) (takeFileName target <> ".tmp"))
        discard
        $ \(tmp, h) -> do
          BS.hPut h (TE.encodeUtf8 txt)
          hFlush h
          hClose h
          renamePath tmp target

    discard :: (FilePath, Handle) -> IO ()
    discard (tmp, h) = do
      ignoring (hClose h)
      ignoring (removeFile tmp)

    ignoring :: IO () -> IO ()
    ignoring act = do
      _ <- try act :: IO (Either IOException ())
      pure ()
