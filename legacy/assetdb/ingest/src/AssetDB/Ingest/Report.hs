-- | 掃描結果的人類可讀輸出。
module AssetDB.Ingest.Report
  ( renderReport
  , renderEvent
  , humanBytes
  ) where

import AssetDB.Ingest.Scan
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeFileName)

renderEvent :: ScanEvent -> Maybe Text
renderEvent = \case
  EvDiscovered a l ->
    Just ("找到 " <> tshow a <> " 個壓縮檔、" <> tshow l <> " 個散檔")
  EvArchiveStart p i n ->
    Just ("[" <> tshow i <> "/" <> tshow n <> "] " <> T.pack (takeFileName p))
  EvArchiveDone _ n -> Just ("      " <> tshow n <> " 個項目")
  EvArchiveSkipped _ -> Just "      跳過(雜湊未變)"
  EvArchiveFailed _ why -> Just ("      ✗ 整包讀不開,未索引 —— " <> why)
  EvLooseStart n -> Just ("散檔 " <> tshow n <> " 個")
  EvLooseDone _ -> Nothing
  EvProblem m -> Just ("  ⚠ " <> m)
  EvAborted why -> Just ("\n✗ 中止:" <> why)

renderReport :: ScanReport -> Text
renderReport ScanReport {..} =
  T.unlines $
    [ ""
    , heading
    ]
      <> abortNote
      <> [ "  壓縮檔      " <> tshow srArchives <> skipped
         , "  壓縮檔內項目 " <> tshow srEntries
         , "  散檔        " <> tshow srLooseFiles
         , "  雜湊資料量   " <> humanBytes srBytesHashed
         ]
      <> failed
      <> unread
      <> problems
  where
    heading = case srAborted of
      Nothing -> "掃描完成"
      Just _ -> "✗ 掃描中止(未跑完)"

    -- 中止時最需要回答的是「我現在該做什麼」。已寫入的部分留著,
    -- 而掃描是冪等的 —— 重跑會從缺的地方補齊,不會產生重複。
    abortNote = case srAborted of
      Nothing -> []
      Just why ->
        [ "  原因:" <> why
        , ""
        , "  以下數字是**中止前**完成的進度,不是全部。"
        , "  已完成的部分已經寫入資料庫;排除原因後重跑同一個指令即可補齊。"
        , ""
        ]

    skipped
      | srArchivesSkipped > 0 = "(另有 " <> tshow srArchivesSkipped <> " 個雜湊未變已跳過)"
      | otherwise = ""

    -- 整包讀不開與「個別項目讀不到」是兩件事,分開講。
    -- 這一項代表那些壓縮檔**一筆都沒有進索引**,不是少了幾筆。
    failed
      | srArchivesFailed == 0 = []
      | otherwise =
          [ ""
          , "  ✗ " <> tshow srArchivesFailed <> " 個壓縮檔整包讀不開,完全沒有進索引。"
          , "    原因見下方問題清單;這些素材包目前在資料庫裡不存在。"
          ]

    -- 沒有 SHA-256 的項目不能當刪除依據。這個數字不是零就代表
    -- 重構的刪除閘門會保留對不上的散檔 —— 必須顯眼。
    unread
      | srEntriesUnread == 0 = []
      | otherwise =
          [ ""
          , "  ⚠ " <> tshow srEntriesUnread <> " 個項目列得出來但讀不到內容,沒有 SHA-256。"
          , "    這些項目無法作為重構刪除閘門的依據。"
          ]

    problems
      | null srProblems = []
      | otherwise = "" : ("問題 " <> tshow (length srProblems) <> " 則:") : map ("  " <>) srProblems

humanBytes :: Integer -> Text
humanBytes n
  | n >= gib = fixed (fromIntegral n / fromIntegral gib) <> " GiB"
  | n >= mib = fixed (fromIntegral n / fromIntegral mib) <> " MiB"
  | n >= kib = fixed (fromIntegral n / fromIntegral kib) <> " KiB"
  | otherwise = tshow n <> " B"
  where
    kib = 1024 :: Integer
    mib = kib * 1024
    gib = mib * 1024
    fixed :: Double -> Text
    fixed x = T.pack (show (fromIntegral (round (x * 10) :: Integer) / 10 :: Double))

tshow :: Show a => a -> Text
tshow = T.pack . show
