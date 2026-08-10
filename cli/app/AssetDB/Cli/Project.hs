module AssetDB.Cli.Project (ProjectArgs (..), runNewProject) where

import AssetDB.Archive (discoverTools)
import AssetDB.Project.Create
import AssetDB.Store
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))

data ProjectArgs = ProjectArgs
  { paName :: Text
  , paPath :: FilePath
  , paPacks :: [Text]
  , paQuery :: Maybe Text
  , paAllowNonCommercial :: Bool
  }

runNewProject :: FilePath -> ProjectArgs -> IO ()
runNewProject dbPath ProjectArgs {..} = do
  tools <- discoverTools
  let libRoot = takeDirectory (takeDirectory dbPath) </> "library"
  withStore dbPath $ \st -> do
    _ <- initSchema st
    r <-
      createProject
        st
        tools
        CreateOptions
          { coName = paName
          , coPath = paPath
          , coLibraryRoot = libRoot
          , coPacks = paPacks
          , coQuery = paQuery
          , coAllowNonCommercial = paAllowNonCommercial
          , coOnEvent = TIO.putStrLn
          }
    TIO.putStrLn ""
    TIO.putStrLn ("複製 " <> tshow (crCopied r) <> " 筆素材到 " <> T.pack paPath)
    case crSkipped r of
      [] -> pure ()
      ss -> do
        TIO.putStrLn ("⚠ " <> tshow (length ss) <> " 筆讀取失敗:")
        mapM_ (\s -> TIO.putStrLn ("    " <> T.take 100 s)) (take 5 ss)
    if crCopied r == 0
      then TIO.putStrLn "沒有任何素材被複製。可能是條件太窄,或素材尚未命名(assetdb cluster apply)。" >> exitFailure
      else do
        TIO.putStrLn ""
        TIO.putStrLn "接下來:"
        TIO.putStrLn "  1. 讀 SKILL.md"
        TIO.putStrLn "  2. 檢查 assets/manifest.json 與 assets/Assets.hs"
        TIO.putStrLn "  3. 若致謝區塊有標記「需署名」的素材包,發行時必須列入致謝畫面"

tshow :: Show a => a -> Text
tshow = T.pack . show
