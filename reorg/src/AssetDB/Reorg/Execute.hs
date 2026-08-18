-- | 重構的執行器。
--
-- == 兩個階段,刻意分開
--
-- 【階段 A】建目錄、搬壓縮檔、寫 @pack.toml@、搬工作室自有檔案。
-- **完全可回退** —— 每一筆都記錄在 @moves@ 表,@undo@ 可以整批倒回去。
--
-- 【階段 B】刪除已證明存在於壓縮檔內的散檔。**不可回退。**
--
-- 兩者需要不同的旗標。把它們綁在同一個指令裡,等於讓可回退的部分
-- 被不可回退的部分綁架 —— 使用者會為了完成搬移而被迫接受刪除。
--
-- == 對帳的關鍵洞見
--
-- 搬完之後不需要重算 6,393 筆項目的雜湊。**重算壓縮檔本身的 SHA-256 就夠了**
-- —— 檔案雜湊相同就代表裡面每一個位元組都相同,也就代表每一筆項目都完好。
-- 這把對帳成本從「重新解壓 3.2 GB」降到「循序讀取 3.2 GB」。
--
-- 對帳失敗就中止,而且**不執行任何刪除**。
module AssetDB.Reorg.Execute
  ( ApplyOptions (..)
  , defaultApplyOptions
  , ApplyEvent (..)
  , ApplyReport (..)
  , applyPlan
  , undoBatch
  , listBatches
  ) where

import AssetDB.Ingest.Hash (sha256File, unSha256)
import AssetDB.Reorg.PackToml (renderPackToml)
import AssetDB.Reorg.Plan
import AssetDB.Reorg.Snapshot
import AssetDB.Store
import Control.Exception (SomeException, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.Map.Strict qualified as Map
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple
import System.Directory
import System.FilePath

data ApplyOptions = ApplyOptions
  { aoBatchId :: Text
  , aoDeleteCovered :: Bool
  -- ^ 階段 B。預設 'False' —— 只搬移,不刪除。
  , aoOnEvent :: ApplyEvent -> IO ()
  }

defaultApplyOptions :: Text -> ApplyOptions
defaultApplyOptions batch = ApplyOptions batch False (const (pure ()))

data ApplyEvent
  = EvPreflight Text
  | EvPhase Text
  | EvProgress Int Int Text
  | EvNote Text
  | EvFailure Text
  deriving stock (Eq, Show)

data ApplyReport = ApplyReport
  { arDirsCreated :: Int
  , arMoved :: Int
  , arWritten :: Int
  , arDeleted :: Int
  , arReconciled :: Int
  , arBytesMoved :: Integer
  , arErrors :: [Text]
  }
  deriving stock (Eq, Show)

emptyReport :: ApplyReport
emptyReport = ApplyReport 0 0 0 0 0 0 []

--------------------------------------------------------------------------------

applyPlan :: Store -> Snapshot -> ApplyOptions -> Plan -> IO ApplyReport
applyPlan st snap opts@ApplyOptions {..} plan = do
  let src = T.unpack (planSourceRoot plan)
      dst = T.unpack (planTargetRoot plan)

  problems <- preflight opts src dst plan
  if not (null problems)
    then do
      mapM_ (aoOnEvent . EvFailure) problems
      pure emptyReport {arErrors = problems}
    else do
      aoOnEvent (EvPhase "階段 A:建立目錄")
      r1 <- runMkDirs opts dst plan emptyReport

      aoOnEvent (EvPhase "階段 A:搬移")
      r2 <- runMoves st opts src dst plan r1

      aoOnEvent (EvPhase "階段 A:寫入 pack.toml")
      r3 <- runWrites st opts dst snap plan r2

      aoOnEvent (EvPhase "對帳:重算壓縮檔雜湊")
      reconcileErrs <- reconcile opts dst snap plan
      let r4 = r3 {arReconciled = length (packMoves plan) - length reconcileErrs}

      if not (null reconcileErrs)
        then do
          mapM_ (aoOnEvent . EvFailure) reconcileErrs
          aoOnEvent (EvFailure "對帳失敗。**不執行任何刪除。** 用 undo 回退這個批次。")
          pure r4 {arErrors = arErrors r4 <> reconcileErrs}
        else do
          aoOnEvent (EvNote "對帳通過:每個壓縮檔的 SHA-256 與搬移前一致。")
          if not aoDeleteCovered
            then do
              aoOnEvent
                ( EvNote
                    "階段 B(刪除散檔)未執行 —— 需要 --delete-covered。\n\
                    \這個批次目前完全可回退。確認搬移結果無誤後再執行刪除。"
                )
              pure r4
            else do
              aoOnEvent (EvPhase "階段 B:刪除已證明的散檔(不可回退)")
              runDeletes st opts src plan r4

--------------------------------------------------------------------------------
-- 前置檢查
--
-- 每一項都是「發生了會很難收拾」的事。寧可在動任何檔案之前就拒絕。

-- | 前置檢查。
--
-- == 為什麼不能只看「目標目錄是不是空的」
--
-- 兩階段設計要求 apply 是**冪等的**:階段 A 跑完之後,使用者確認結果無誤,
-- 才會加上 @--delete-covered@ 再跑一次執行階段 B。第二次跑的時候目標目錄
-- 當然非空 —— 那是第一次跑的成果,不是障礙。
--
-- 所以檢查的對象是每一筆搬移的**狀態**,而不是目錄的空滿:
--
-- * 來源在、目標不在 → 還沒做
-- * 來源不在、目標在 → 已經做過,跳過
-- * 兩邊都不在      → 計畫過期或檔案遺失,**拒絕動作**
-- * 兩邊都在        → 曖昧狀態,可能上次中斷,**拒絕動作**
preflight :: ApplyOptions -> FilePath -> FilePath -> Plan -> IO [Text]
preflight ApplyOptions {..} src dst plan = do
  aoOnEvent (EvPreflight "檢查來源目錄")
  srcOk <- doesDirectoryExist src

  aoOnEvent (EvPreflight "逐筆檢查搬移狀態")
  states <- forM [(f, t) | OpMove f t _ _ <- planOps plan] $ \(f, t) -> do
    hasFrom <- doesPathExist (src </> T.unpack f)
    hasTo <- doesPathExist (dst </> T.unpack t)
    pure (f, hasFrom, hasTo)

  let gone = [f | (f, False, False) <- states]
      both = [f | (f, True, True) <- states]
      done = length [() | (_, False, True) <- states]

  when (done > 0) $
    aoOnEvent (EvNote (tshow done <> " 筆搬移已經完成過,將跳過"))

  pure $
    concat
      [ ["來源目錄不存在:" <> T.pack src | not srcOk]
      , [ "有 " <> tshow (length gone) <> " 個檔案在來源與目標都找不到。\n"
            <> "  計畫可能已經過期,或檔案遺失。請重新產生計畫。\n"
            <> T.unlines (map ("    " <>) (take 5 gone))
        | not (null gone)
        ]
      , [ "有 " <> tshow (length both) <> " 個檔案在來源與目標同時存在。\n"
            <> "  這通常代表上一次執行中斷了。請先確認哪一份是正確的。\n"
            <> T.unlines (map ("    " <>) (take 5 both))
        | not (null both)
        ]
      ]

--------------------------------------------------------------------------------
-- 階段 A

-- 這些函式一律在 list comprehension 裡**解構**而不是用選取子。
-- opFrom / opTo 這類選取子在 Op 這種 sum type 上是部分函數,
-- 用錯建構子會在執行期爆炸 —— GHC 的 -Wincomplete-record-selectors 是對的。
-- 解構讓型別系統保證只拿到該有的欄位。

runMkDirs :: ApplyOptions -> FilePath -> Plan -> ApplyReport -> IO ApplyReport
runMkDirs _ dst plan acc = do
  let dirs = [T.unpack p | OpMkDir p <- planOps plan]
  forM_ dirs $ \d -> createDirectoryIfMissing True (dst </> d)
  pure acc {arDirsCreated = length dirs}

runMoves :: Store -> ApplyOptions -> FilePath -> FilePath -> Plan -> ApplyReport -> IO ApplyReport
runMoves st ApplyOptions {..} src dst plan acc = do
  let moves = [(f, t, b) | OpMove f t b _ <- planOps plan]
      total = length moves
  foldM (step total) acc (zip [1 ..] moves)
  where
    step total a (i, (f, t, b)) = do
      let from = src </> T.unpack f
          to = dst </> T.unpack t
      -- 已經搬過就跳過。前置檢查已經排除「兩邊都在」與「兩邊都不在」,
      -- 所以來源不在就等於已完成。
      alreadyDone <- not <$> doesPathExist from
      if alreadyDone
        then pure a
        else do
          aoOnEvent (EvProgress i total f)
          createDirectoryIfMissing True (takeDirectory to)
          r <- moveFile from to
          case r of
            Left err -> pure a {arErrors = arErrors a <> [f <> ":" <> err]}
            Right () -> do
              recordMove st aoBatchId "move" (Just f) (Just t) b
              pure a {arMoved = arMoved a + 1, arBytesMoved = arBytesMoved a + b}

-- | 先試 rename(同磁碟區時是原子操作且瞬間完成),失敗再退回複製。
--
-- 跨磁碟區時 rename 會失敗,那時只能複製 —— 而複製完成後**先不刪來源**,
-- 留給對帳階段確認之後再處理。這裡的順序不能反過來。
moveFile :: FilePath -> FilePath -> IO (Either Text ())
moveFile from to = do
  r <- try (renamePath from to)
  case r of
    Right () -> pure (Right ())
    Left (_ :: SomeException) -> do
      r2 <- try (copyFileWithMetadata from to >> removeFile from)
      pure $ case r2 of
        Right () -> Right ()
        Left (e :: SomeException) -> Left (compact e)

runWrites :: Store -> ApplyOptions -> FilePath -> Snapshot -> Plan -> ApplyReport -> IO ApplyReport
runWrites st ApplyOptions {..} dst snap plan acc = do
  let byDir = Map.fromList [(targetDirFor pk, pk) | pk <- snPacks snap]
  written <-
    forM [t | OpWrite t _ <- planOps plan] $ \t -> do
      let dir = T.pack (takeDirectory (T.unpack t))
      case Map.lookup dir byDir of
        Nothing -> pure (Left ("找不到 " <> t <> " 對應的素材包"))
        Just pk -> do
          let target = dst </> T.unpack t
          createDirectoryIfMissing True (takeDirectory target)
          writeUtf8 target (renderPackToml pk)
          recordMove st aoBatchId "write" Nothing (Just t) 0
          pure (Right ())
  pure
    acc
      { arWritten = length [() | Right () <- written]
      , arErrors = arErrors acc <> [e | Left e <- written]
      }

--------------------------------------------------------------------------------
-- 對帳

-- | 重算每個壓縮檔在新位置的 SHA-256,與資料庫記錄比對。
--
-- 這一步是刪除的前提。壓縮檔的雜湊相同,就代表裡面 6,393 筆項目
-- 全部完好 —— 不需要重新解壓驗證。
reconcile :: ApplyOptions -> FilePath -> Snapshot -> Plan -> IO [Text]
reconcile ApplyOptions {..} dst snap plan = do
  let moves = packMoves plan
      byLeaf = Map.fromList [(leafOf (prArchiveRel pk), pk) | pk <- snPacks snap]
      total = length moves
  results <- forM (zip [1 ..] moves) $ \(i, t) -> do
    aoOnEvent (EvProgress i total t)
    let target = dst </> T.unpack t
    exists <- doesFileExist target
    if not exists
      then pure (Just (t <> ":搬移後找不到檔案"))
      else case Map.lookup (leafOf t) byLeaf of
        Nothing -> pure (Just (t <> ":資料庫裡沒有這個壓縮檔的雜湊紀錄"))
        Just pk -> do
          actual <- unSha256 <$> sha256File target
          pure $
            if actual == prArchiveSha pk
              then Nothing
              else
                Just
                  ( t
                      <> ":雜湊不符\n      預期 "
                      <> prArchiveSha pk
                      <> "\n      實際 "
                      <> actual
                  )
  pure [e | Just e <- results]

-- | 只有壓縮檔的搬移需要對帳 —— 對帳比對的是資料庫裡的雜湊紀錄,
-- 而工作室自有檔案沒有那筆紀錄。它們也不會觸發任何刪除,所以不對帳沒有風險。
packMoves :: Plan -> [Text]
packMoves plan =
  [t | OpMove _ t _ _ <- planOps plan, isArchiveLike t]
  where
    isArchiveLike t = any (`T.isSuffixOf` T.toLower t) [".zip", ".rar", ".7z"]

--------------------------------------------------------------------------------
-- 階段 B

-- 2026-08-09 一次性搬遷的空目錄清理(pruneEmptyDirs 掃 "Game Assets itchio/")
-- 已隨該次搬遷的路徑規則一併退役(enhance-0009),實作見 git 歷史。
-- 這個執行器保留:它對 Plan 是通用的,雖然現行規劃器已不會產生 OpDelete。
runDeletes :: Store -> ApplyOptions -> FilePath -> Plan -> ApplyReport -> IO ApplyReport
runDeletes st ApplyOptions {..} src plan acc = do
  let dels = [(f, b) | OpDelete f _ _ b <- planOps plan]
      total = length dels
  foldM (step total) acc (zip [1 ..] dels)
  where
    step total a (i, (rel, bytes)) = do
      when (i `mod` 500 == 0 || i == total) (aoOnEvent (EvProgress i total rel))
      r <- try (removeFile (src </> T.unpack rel))
      case r of
        Left (e :: SomeException) -> pure a {arErrors = arErrors a <> [rel <> ":" <> compact e]}
        Right () -> do
          recordMove st aoBatchId "delete" (Just rel) Nothing bytes
          pure a {arDeleted = arDeleted a + 1}

--------------------------------------------------------------------------------
-- 稽核與回退

recordMove :: Store -> Text -> Text -> Maybe Text -> Maybe Text -> Integer -> IO ()
recordMove st batch action from to bytes = do
  now <- T.pack . iso8601Show <$> getCurrentTime
  execute
    (storeConn st)
    "INSERT INTO moves (batch_id,ts,action,from_path,to_path,bytes) VALUES (?,?,?,?,?,?)"
    (batch, now, action, from, to, bytes)

listBatches :: Store -> IO [(Text, Int, Text)]
listBatches st =
  query_
    (storeConn st)
    "SELECT batch_id, COUNT(*), MIN(ts) FROM moves WHERE undone = 0 GROUP BY batch_id ORDER BY MIN(ts)"

-- | 把一個批次倒回去。
--
-- **刪除無法回退。** 這正是階段 B 需要另一個旗標的理由 ——
-- 執行刪除之前,整個重構都還是可逆的。
undoBatch :: Store -> FilePath -> FilePath -> Text -> (Text -> IO ()) -> IO (Int, [Text])
undoBatch st src dst batch say = do
  rows <-
    query
      (storeConn st)
      "SELECT id, action, from_path, to_path FROM moves \
      \WHERE batch_id = ? AND undone = 0 ORDER BY id DESC"
      (Only batch) ::
      IO [(Int, Text, Maybe Text, Maybe Text)]

  let deletes = [() | (_, "delete", _, _) <- rows]
  unless (null deletes) $
    say
      ( "⚠ 這個批次包含 " <> tshow (length deletes) <> " 筆刪除,**無法回退**。\n"
          <> "  其餘搬移仍會倒回去。"
      )

  results <- forM rows $ \(rid, action, from, to) ->
    case (action, from, to) of
      ("move", Just f, Just t) -> do
        r <- moveFile (dst </> T.unpack t) (src </> T.unpack f)
        case r of
          Right () -> markUndone st rid >> pure Nothing
          Left e -> pure (Just (t <> ":" <> e))
      ("write", _, Just t) -> do
        r <- try (removeFile (dst </> T.unpack t))
        case r of
          Right () -> markUndone st rid >> pure Nothing
          Left (_ :: SomeException) -> markUndone st rid >> pure Nothing
      ("delete", Just f, _) -> pure (Just (f <> ":刪除無法回退"))
      _ -> pure Nothing

  pure (length [() | Nothing <- results], [e | Just e <- results])

markUndone :: Store -> Int -> IO ()
markUndone st rid = execute (storeConn st) "UPDATE moves SET undone = 1 WHERE id = ?" (Only rid)

--------------------------------------------------------------------------------

-- | 一律以 UTF-8 位元組寫檔。
--
-- 'Data.Text.IO.writeFile' 用的是 **locale 編碼** —— Windows 上是系統 ANSI
-- 字碼頁,編不出 @⚠@(U+26A0),中文也可能走 Big5。這會**寫壞我們自己產生的檔案**,
-- 比終端機顯示亂碼嚴重得多:@pack.toml@ 是要進版控、要被別的工具讀的。
--
-- 這個陷阱與 stdout 那個是同一類,但更難發現 —— 檔案寫出去之後
-- 要等到有人用別的工具讀才會爆。
writeUtf8 :: FilePath -> Text -> IO ()
writeUtf8 p = BS.writeFile p . encodeUtf8

leafOf :: Text -> Text
leafOf p = last ("" : T.splitOn "/" p)

compact :: SomeException -> Text
compact = T.unwords . T.words . T.pack . show

tshow :: Show a => a -> Text
tshow = T.pack . show
