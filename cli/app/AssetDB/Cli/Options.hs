module AssetDB.Cli.Options
  ( Command (..)
  , ScanArgs (..)
  , ReorgArgs (..)
  , GlobalArgs (..)
  , Invocation (..)
  , parseInvocation
  , resolveDbPath
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))

data GlobalArgs = GlobalArgs
  { gaDbPath :: Maybe FilePath
  }

data Invocation = Invocation GlobalArgs Command

data Command
  = CmdScan ScanArgs
  | CmdTools
  | CmdDoctor
  | CmdPackList
  | CmdPackApply FilePath
  | CmdReorgPlan ReorgArgs

data ReorgArgs = ReorgArgs
  { raSource :: FilePath
  , raTarget :: FilePath
  , raOut :: Maybe FilePath
  , raVerbose :: Bool
  }

data ScanArgs = ScanArgs
  { saRoot :: FilePath
  , saKind :: Text
  , saLabel :: Maybe Text
  , saRehash :: Bool
  , saQuiet :: Bool
  }

parseInvocation :: IO Invocation
parseInvocation =
  execParser $
    info
      (helper <*> (Invocation <$> globalP <*> commandP))
      ( fullDesc
          <> progDesc "Alchbees 資源與專案管理系統"
          <> header "assetdb"
      )

globalP :: Parser GlobalArgs
globalP =
  GlobalArgs
    <$> optional
      ( strOption
          ( long "db"
              <> metavar "PATH"
              <> help "資料庫檔案。預設 ./.assetdb/assetdb.sqlite"
          )
      )

commandP :: Parser Command
commandP =
  hsubparser
    ( command "scan" (info (CmdScan <$> scanP) (progDesc "掃描素材庫,計算內容雜湊並建立索引"))
        <> command "tools" (info (pure CmdTools) (progDesc "檢查外部工具(7-Zip)是否可用"))
        <> command "doctor" (info (pure CmdDoctor) (progDesc "檢查資料庫狀態與待辦"))
        <> command "pack" (info packP (progDesc "素材包的授權與作者中繼資料"))
        <> command "reorganize" (info reorgP (progDesc "素材庫重構。目前只支援 --dry-run"))
    )

-- | 目前**只有** dry-run。
--
-- 把 @--dry-run@ 做成必填而不是預設值,是刻意的:這個指令未來會有
-- 能刪掉五千個檔案的模式,而「忘記加旗標」不該是通往那個模式的路。
reorgP :: Parser Command
reorgP =
  CmdReorgPlan
    <$> ( ReorgArgs
            <$> strOption (long "source" <> metavar "PATH" <> help "現有素材庫根目錄")
            <*> strOption (long "target" <> metavar "PATH" <> help "重構後的根目錄")
            <*> optional (strOption (long "out" <> metavar "FILE" <> help "把完整計畫寫進檔案,終端機只顯示摘要"))
            <*> switch (long "verbose" <> help "列出每一個要刪除的檔案,而不是只顯示分組數量")
        )
    <* flag'
      ()
      ( long "dry-run"
          <> help "必填。目前唯一支援的模式 —— 不會改動任何檔案"
      )

packP :: Parser Command
packP =
  hsubparser
    ( command "list" (info (pure CmdPackList) (progDesc "列出素材包與其授權狀態"))
        <> command
          "apply"
          ( info
              (CmdPackApply <$> strOption (long "catalogue" <> metavar "FILE" <> help "packs.toml 的路徑"))
              (progDesc "從 packs.toml 套用作者與授權")
          )
    )

scanP :: Parser ScanArgs
scanP =
  ScanArgs
    <$> strOption (long "root" <> metavar "PATH" <> help "要掃描的素材庫根目錄")
    <*> option
      (T.pack <$> str)
      ( long "kind"
          <> metavar "KIND"
          <> value "packs"
          <> showDefault
          <> help "根目錄類型:packs / reference / studio"
      )
    <*> optional (option (T.pack <$> str) (long "label" <> metavar "NAME" <> help "根目錄顯示名稱,預設取目錄名"))
    <*> switch
      ( long "rehash"
          <> help "忽略「壓縮檔雜湊未變就跳過」的最佳化,強制重新計算全部內容"
      )
    <*> switch (long "quiet" <> help "只輸出最後的摘要")

-- | 資料庫預設放在工作目錄下的 @.assetdb\/@。
--
-- 刻意**不**放進素材庫根目錄:資料庫是衍生物,而素材庫是備份目標 ——
-- 混在一起會讓每次掃描都弄髒備份。
resolveDbPath :: GlobalArgs -> IO FilePath
resolveDbPath GlobalArgs {..} =
  case gaDbPath of
    Just p -> pure p
    Nothing -> do
      cwd <- getCurrentDirectory
      pure (cwd </> ".assetdb" </> "assetdb.sqlite")
