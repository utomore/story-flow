module AssetDB.Cli.Notes (NoteArgs (..), LinkArgs (..), runNoteImport, runNoteList, runLink) where

import AssetDB.Ingest.Notes
import AssetDB.Store
import AssetDB.Types (LinkRel, NoteKind, parseTextEnum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Exit (exitFailure)

data NoteArgs = NoteArgs {naKind :: Text, naPath :: FilePath}

data LinkArgs = LinkArgs
  { laFrom :: Text
  , laTo :: Text
  , laRel :: Text
  , laNote :: Maybe Text
  }

runNoteImport :: FilePath -> NoteArgs -> IO ()
runNoteImport dbPath NoteArgs {..} = do
  kind <- either die pure (parseTextEnum naKind :: Either Text NoteKind)
  withStore dbPath $ \st -> do
    _ <- initSchema st
    imported <- importNotes st kind naPath
    n <- reindexNotes st
    mapM_ (\(t, s) -> TIO.putStrLn ("  " <> t <> "   (" <> s <> ")")) imported
    TIO.putStrLn ("匯入 " <> tshow (length imported) <> " 篇,索引共 " <> tshow n <> " 篇")

runNoteList :: FilePath -> Maybe Text -> IO ()
runNoteList dbPath mk =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    kind <- traverse (either die pure . (parseTextEnum :: Text -> Either Text NoteKind)) mk
    rows <- listNotes st kind
    mapM_ (\(u, k, t, s) -> TIO.putStrLn (pad 10 k <> pad 40 t <> T.take 40 s <> "  " <> T.take 8 u)) rows
    TIO.putStrLn (tshow (length rows) <> " 篇")

-- | @--from asset:01ABC --to note:01XYZ --rel documents@
runLink :: FilePath -> LinkArgs -> IO ()
runLink dbPath LinkArgs {..} = do
  (st', su) <- either die pure (splitRef laFrom)
  (dt, du) <- either die pure (splitRef laTo)
  rel <- either die pure (parseTextEnum laRel :: Either Text LinkRel)
  withStore dbPath $ \store' -> do
    _ <- initSchema store'
    -- 型別與 ULID 都是使用者打的,錯了要用一句話講清楚,不是例外堆疊。
    linkEntities store' st' su dt du rel laNote >>= either die pure
    TIO.putStrLn ("已連結 " <> laFrom <> " --" <> laRel <> "--> " <> laTo)
    ls <- entityLinks store' st' su >>= either die pure
    mapM_ (\(d, r, t, i) -> TIO.putStrLn ("  " <> d <> "  " <> r <> "  " <> t <> "#" <> i)) ls

splitRef :: Text -> Either Text (Text, Text)
splitRef t = case T.breakOn ":" t of
  (ty, rest)
    | not (T.null rest) && ty `elem` ["asset", "project", "note", "collection", "pack"] ->
        Right (ty, T.drop 1 rest)
  _ -> Left ("實體參照要寫成 <型別>:<ULID>,如 asset:01ABC。收到 " <> t)

die :: Text -> IO a
die m = TIO.putStrLn ("✗ " <> m) >> exitFailure

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - w t)) " "
  where
    w = sum . map (\c -> if fromEnum c > 0x1100 then 2 else 1) . T.unpack

tshow :: Show a => a -> Text
tshow = T.pack . show
