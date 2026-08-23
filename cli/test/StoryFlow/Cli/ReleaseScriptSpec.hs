-- | G-E002 T11:發佈腳本的組裝段。
--
-- 腳本分兩段:建置(@cabal install@ 三個執行檔)與組裝(複製 @registry\/@、寫
-- README、壓 zip)。測試只跑__組裝段__:餵一個放了三個假執行檔的目錄與一個假版本,
-- 幾秒內跑完,不在測試裡套 cabal——那要好幾分鐘,而且 cabal 套 cabal 會踩鎖。
--
-- Windows 跑 @release.ps1@(PowerShell 一定在),其他平台跑 @release.sh@(要有 bash)。
-- 找不到直譯器就 pending 並明說,不假裝通過。
--
-- 斷言的是「產出目錄裡__恰好__有這些檔案」:多一個少一個都紅——發佈物的內容就是
-- 使用者拿到的全部,這裡不准有驚喜。
module StoryFlow.Cli.ReleaseScriptSpec (spec) where

import Data.List (isPrefixOf, isSuffixOf, sort)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , findExecutable
  , listDirectory
  , removeDirectoryRecursive
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import System.Process (readProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec = describe "scripts/release(組裝段)" $
  it "產出目錄恰好是 3 個執行檔 + registry/ 5 份 TOML + README.md,且 zip 存在" $ do
    root <- repoRoot
    mInterp <- interpreter
    case mInterp of
      Nothing -> pendingWith "找不到 powershell / bash,略過腳本測試"
      Just (prog, mkArgs) ->
        withSystemTempDirectory "storyflow-stage" $ \stage -> do
          -- 三個假執行檔:組裝段只 copy,不執行它們
          mapM_ (\b -> writeFile (stage </> b) "fake") ["story-flow.exe", "story-flow-serve.exe", "story-flow-mcp.exe"]
          let outRoot = root </> "dist-release"
          (code, out, err) <- readProcessWithExitCode prog (mkArgs root stage) ""
          code `shouldBe` ExitSuccess
          -- 版本是假的 9.9.9,平台由腳本自己判斷;只認「唯一一個資料夾」
          entries <- listDirectory outRoot
          let dirs = filter (not . (".zip" `isSuffixOf`)) entries
              zips = filter (".zip" `isSuffixOf`) entries
          case (dirs, zips) of
            ([d], [z]) -> do
              takeFileName d `shouldSatisfy` ("story-flow-9.9.9-" `isPrefixOf`)
              z `shouldBe` d <> ".zip"
              files <- walk (outRoot </> d)
              sort files
                `shouldBe` sort
                  [ "README.md"
                  , "registry/character-fragment.toml"
                  , "registry/dialogue.toml"
                  , "registry/item-fragment.toml"
                  , "registry/lore-fragment.toml"
                  , "registry/plot-fragment.toml"
                  , "story-flow.exe"
                  , "story-flow-mcp.exe"
                  , "story-flow-serve.exe"
                  ]
            _ -> expectationFailure ("dist-release 內容不對:" <> show entries <> "\nstdout:\n" <> out <> "\nstderr:\n" <> err)
          removeDirectoryRecursive outRoot

-- | 依平台挑直譯器與引數。
interpreter :: IO (Maybe (FilePath, FilePath -> FilePath -> [String]))
interpreter
  | os == "mingw32" =
      fmap (\p -> (p, \root stage -> ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", root </> "scripts" </> "release.ps1", "-Stage", stage, "-Version", "9.9.9"]))
        <$> findExecutable "powershell"
  | otherwise =
      fmap (\p -> (p, \root stage -> [root </> "scripts" </> "release.sh", stage, "9.9.9"]))
        <$> findExecutable "bash"

-- | 測試可能從專案根目錄或從 @cli\/@ 底下跑。
repoRoot :: IO FilePath
repoRoot = go [".", ".."]
  where
    go [] = fail "找不到 scripts/release.sh"
    go (d : rest) = do
      ok <- doesFileExist (d </> "scripts" </> "release.sh")
      if ok then pure d else go rest

-- | 遞迴列出相對路徑(用 @/@),排除目錄本身。
walk :: FilePath -> IO [FilePath]
walk base = go ""
  where
    go rel = do
      let dir = if null rel then base else base </> rel
      names <- listDirectory dir
      fmap concat . mapM (\n -> step (if null rel then n else rel <> "/" <> n)) $ names
    step rel = do
      isDir <- doesDirectoryExist (base </> rel)
      if isDir then go rel else pure [rel]
