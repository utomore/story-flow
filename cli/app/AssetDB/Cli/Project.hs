module AssetDB.Cli.Project
  ( ProjectArgs (..)
  , runNewProject
  , SyncArgs (..)
  , runProjectSync

    -- * 結束碼
    --
    -- $exitCode
  , syncExitCode
  ) where

import AssetDB.Archive (discoverTools)
import AssetDB.Project.Create
import AssetDB.Project.Sync
import AssetDB.Store
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Exit (ExitCode (..), exitFailure, exitWith)
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

--------------------------------------------------------------------------------

data SyncArgs = SyncArgs
  { syName :: Text
  , syPacks :: [Text]
  , syQuery :: Maybe Text
  , syAllowNonCommercial :: Bool
  , syConfirm :: Bool
  }

runProjectSync :: FilePath -> SyncArgs -> IO ()
runProjectSync dbPath args@SyncArgs {..} = do
  tools <- discoverTools
  let libRoot = takeDirectory (takeDirectory dbPath) </> "library"
  withStore dbPath $ \st -> do
    _ <- initSchema st
    r <-
      syncProject
        st
        tools
        SyncOptions
          { soName = syName
          , soLibraryRoot = libRoot
          , soPacks = syPacks
          , soQuery = syQuery
          , soAllowNonCommercial = syAllowNonCommercial
          , soConfirm = syConfirm
          , soOnEvent = TIO.putStrLn
          }
    case r of
      Left (ProjectNotRegistered n) -> do
        TIO.putStrLn ("✗ 專案「" <> n <> "」未登記。用 assetdb new-project 建立,或確認 --name 拼字")
        exitFailure
      Left (ProjectDirMissing p) -> do
        TIO.putStrLn ("✗ 專案目錄不存在:" <> T.pack p)
        TIO.putStrLn "  登記還在,但磁碟上的目錄已經被移走或刪除。同步不會重建它。"
        exitFailure
      Right res -> do
        report res
        exitWith (syncExitCode args res)
  where
    report res = do
      let plan = syPlan res
          entriesOf c = [e | e <- spEntries plan, seClass e == c]
      TIO.putStrLn ""
      TIO.putStrLn ("專案目錄:" <> T.pack (spProjectPath plan))
      mapM_
        (uncurry (section entriesOf))
        [ (SyncNew, "新增")
        , (SyncUnchanged, "已存在")
        , (SyncSourceUpdated, "來源已更新(只回報,不覆蓋)")
        , (SyncLocallyModified, "本地已修改(只回報,不覆蓋)")
        ]
      case spBlocked plan of
        [] -> pure ()
        bs -> TIO.putStrLn ("⚠ 授權閘門擋下 " <> tshow (length bs) <> " 個素材包的新增素材:" <> T.intercalate "、" bs)
      -- 涵蓋登記的**全集**,不是本次候選(B006):既有素材不會被移除,
      -- 但發行前必須處理,所以它必須在回報裡出現一次。
      case spWarnedPacks plan of
        [] -> pure ()
        ws ->
          TIO.putStrLn
            ( "⚠ "
                <> tshow (length ws)
                <> " 個素材包的既有素材授權為不可商用或未查證,仍留在專案內:"
                <> T.intercalate "、" ws
                <> "。發行前請自行確認風險"
            )
      TIO.putStrLn ""
      if syConfirm
        then do
          TIO.putStrLn ("複製 " <> tshow (syCopied res) <> " 筆素材到 " <> T.pack (spProjectPath plan))
          case sySkipped res of
            [] -> pure ()
            ss -> do
              TIO.putStrLn ("⚠ " <> tshow (length ss) <> " 筆讀取失敗:")
              mapM_ (\s -> TIO.putStrLn ("    " <> T.take 100 s)) (take 5 ss)
          if syCopied res == 0
            then TIO.putStrLn "沒有東西要加。既有素材與手寫程式碼都沒有被動過。"
            else TIO.putStrLn "assets/manifest.json 與 assets/Assets.hs 已依登記的全集重新產生。"
        else TIO.putStrLn "這是預覽。加上 --confirm 才會真的複製與登記。"

    section entriesOf c label =
      case entriesOf c of
        [] -> pure ()
        es -> do
          TIO.putStrLn ""
          TIO.putStrLn (label <> ":" <> tshow (length es) <> " 筆")
          mapM_ (\e -> TIO.putStrLn ("    " <> seName e <> "  →  " <> seRelPath e)) es

-- $exitCode
--
-- 'syncExitCode' 匯出是為了讓它**被直接測到**,理由與 'nonCommercialPacks' 相同:
-- 它是易錯的判斷(0 筆新增是成功、全部讀取失敗是失敗),而走到它需要一整組
-- 真實壓縮檔;'runProjectSync' 本身會呼叫 'exitFailure',測不動。

-- | 「沒有東西要加」是同步的正常結果(與 @new-project@ 相反),所以 0 筆新增
-- 結束碼是 0。真正的失敗是「有東西要加,但一筆都加不進去」。
syncExitCode :: SyncArgs -> SyncResult -> ExitCode
syncExitCode args res
  | not (syConfirm args) = ExitSuccess
  | newCount == 0 = ExitSuccess
  | syCopied res == 0 && not (null (sySkipped res)) = ExitFailure 1
  | otherwise = ExitSuccess
  where
    newCount = length [e | e <- spEntries (syPlan res), seClass e == SyncNew]

tshow :: Show a => a -> Text
tshow = T.pack . show
