{-# LANGUAGE CPP #-}

-- | 終端機輸出的位元組層設定。
module AssetDB.Console (setupConsole) where

#ifdef mingw32_HOST_OS
import Control.Exception (SomeException, try)
import System.Win32.Console (setConsoleCP, setConsoleOutputCP)
#endif
import System.IO

-- | 讓 stdout\/stderr 以 UTF-8 輸出,**而且讓終端機以 UTF-8 解讀**。
--
-- 只設 'hSetEncoding' 是不夠的,而且原本那段註解把結論下反了。
-- 'hSetEncoding' 做的事情是「把 Haskell 的 Char 編成 UTF-8 位元組」;
-- 它沒有、也不能告訴 Windows 主控台要用 UTF-8 去**解讀**那些位元組。
--
-- 在 Windows 上,寫進 console handle 的位元組由 console output code page
-- 決定怎麼顯示。這台機器實測 @getConsoleOutputCP() == 950@(Big5),於是:
--
-- @
-- 「資」 U+8CC7
--   程式寫出 UTF-8:      E8 B3 87
--   conhost 以 Big5 解讀: (E8 B3) -> 「鞈」, 87 對不上 -> 「?」
--   螢幕上:               鞈?
-- @
--
-- 三位元組的中文字被當成一個半 Big5 字,所以亂碼永遠是「怪中文字 + 問號」
-- 交替出現。連 @──@(U+2500,同樣三位元組)都會被切碎。
--
-- 產生位元組與解讀位元組是兩件事,兩件都要設。
setupConsole :: IO ()
setupConsole = do
#ifdef mingw32_HOST_OS
  -- 沒有主控台時(輸出被導向管線、或當成服務跑)這兩個呼叫會失敗。
  -- 那是正常情況,不該讓程式死掉 —— 而且那種情況下 code page 本來就無關,
  -- 位元組會原封不動進到檔案或管線裡。
  _ <- try @SomeException (setConsoleOutputCP 65001)
  _ <- try @SomeException (setConsoleCP 65001)
  pure ()
#endif
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetBuffering stdout LineBuffering
