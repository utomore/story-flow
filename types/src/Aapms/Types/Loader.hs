-- | 型別註冊表的載入層。__本套件唯一的 IO 就是讀檔__。
--
-- 掃描目錄下所有 @*.toml@(排除 @naming.toml@,那份是命名文法詞彙表,不是型別
-- 宣告),逐檔解析,彙整後交給 "Aapms.Core.Registry" 的純驗證函式。單檔解析
-- 失敗__不中斷__,繼續讀其餘檔案,最後一次回報全部問題——作者一次改好幾份
-- 型別宣告時,修一個跑一次太慢。
--
-- 所有錯誤訊息一律帶檔名。ADR-005 明說型別宣告寫錯只能在載入時檢查並報錯,
-- 而沒有檔名的錯誤訊息在多個型別檔時等於沒有。
--
-- __套件歸屬__(design.md 契約 C,2026-08-23 釐清):純型別('Family' /
-- 'TypeDecl' / 'TypeRegistry' / 'NamingVocab' / 'lookupType' 與純驗證錯誤)定義
-- 在 "Aapms.Core.Registry" / "Aapms.Core.Registry.Build" / "Aapms.Core.Naming",
-- 本模組只有 'locateRegistry' \/ 'loadRegistry' 兩個 IO 入口(TOML 解析在
-- "Aapms.Types.Parse"),並 re-export 上述型別。
--
-- 'RegistrySource' 同理搬到 "Aapms.Types.Source"(型別層的模組不該為了一個列舉
-- 依賴本模組的 IO),本模組 import 後原樣 re-export,匯出清單逐字不變。
--
-- __TOML 解析同理搬到 "Aapms.Types.Parse"__(純):本模組因此只剩「找到檔案、
-- 把位元組讀進來、把結果彙整起來」,一行解析規則都不留;匯出清單逐字不變。
module Aapms.Types.Loader
  ( -- * 執行期定位
    RegistrySource (..)
  , locateRegistry
  , locateRegistryWith
  , registryBesideExecutable
  , defaultRegistryDir
  , registryEnvVar

    -- * 載入
  , loadRegistry
  , loadRegistryFrom

    -- * re-export:aapms-core 的純型別與純驗證(契約 C)
  , module Aapms.Core.Registry
  , module Aapms.Core.Registry.Build
  , module Aapms.Core.Naming
  ) where

import Aapms.Core.Naming
import Aapms.Core.Registry
import Aapms.Core.Registry.Build
import Aapms.Types.Parse (aggregate, parseNamingText, parseSpecText)
import Aapms.Types.Source (RegistrySource (..))
import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.Either (partitionEithers)
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, takeExtension, (</>))

import Paths_aapms_types (getDataDir)

-- 執行期定位 -----------------------------------------------------------------

-- | 覆寫註冊表位置的環境變數名。
--
-- 常數放在這裡而不是各呼叫端各寫一份字串:錯字不會被編譯器擋下來,而
-- 「設了環境變數卻沒生效」是最難查的那種設定問題。
--
-- __不改名__:S0 進度明寫 @STORYFLOW_*@ 環境變數是刻意留到 S3 由 @workspace@
-- 依 ADR-017 改的執行期名稱,graph-core 不碰。
registryEnvVar :: String
registryEnvVar = "STORYFLOW_REGISTRY"

-- | 型別註冊表在執行期的目錄,連同它是從哪一層找到的。
--
-- 三層,順序固定:
--
-- 1. 'registryEnvVar' ——開發時指向工作目錄的 @types\/registry\/@,作者要自訂型別
--    時也不必重編譯
-- 2. 執行檔旁的 @registry\/@ ——只複製執行檔到別台機器時,烙印的 cabal 路徑不存在,
--    這一層是唯一能跑起來的方式。放在 @data-files@ __之前__:同一台機器上有舊的
--    cabal 安裝時,zip 解開的那份要用自己帶的註冊表
-- 3. cabal 的 @data-files@(見 @aapms-types.cabal@)
--
-- __找到的目錄必須真的存在__,否則往下一層找;三層都沒有就回
-- 'RegistryNotFound',列出查過的路徑。
--
-- __例外是第一層__:環境變數指向不存在的目錄時__不往下退__——那會讓一個打錯的
-- 環境變數靜默地載入另一份註冊表;錯誤訊息只列出那一個查過的路徑。
locateRegistry :: IO (Either RegistryError (FilePath, RegistrySource))
locateRegistry = locateRegistryWith getExecutablePath

-- | 「執行檔旁」那一層__會去查__的路徑,不管它存不存在。
--
-- 找不到註冊表時的錯誤訊息要說得出「我查過這裡」;`service` 不依賴 `filepath`
-- 與 `directory`,這個路徑由本模組算好給它。
registryBesideExecutable :: IO FilePath
registryBesideExecutable = (</> "registry") . takeDirectory <$> getExecutablePath

-- | 'locateRegistry' 的可注入版本:執行檔路徑由呼叫端給。
--
-- 測試要驗「執行檔旁」這一層,而測試執行檔旁邊不會真的有 @registry\/@;
-- 把 'getExecutablePath' 換成指向臨時目錄的動作就測得到。
locateRegistryWith :: IO FilePath -> IO (Either RegistryError (FilePath, RegistrySource))
locateRegistryWith exePath =
  lookupEnv registryEnvVar >>= \case
    Just p | not (null p) -> do
      found <- existing p
      pure $ case found of
        Just d -> Right (d, FromEnv)
        Nothing -> Left (RegistryNotFound [p])
    _ -> do
      besideDir <- (</> "registry") . takeDirectory <$> exePath
      besideFound <- existing besideDir
      case besideFound of
        Just d -> pure (Right (d, BesideExecutable))
        Nothing -> do
          baseE <- try getDataDir :: IO (Either IOException FilePath)
          case baseE of
            Left e ->
              pure (Left (RegistryNotFound [besideDir, "(cabal data-files 目錄無法定位:" <> show e <> ")"]))
            Right base -> do
              let dataDir = base </> "registry"
              dataFound <- existing dataDir
              pure $ case dataFound of
                Just d -> Right (d, FromDataDir)
                Nothing -> Left (RegistryNotFound [besideDir, dataDir])
  where
    existing p = do
      ok <- doesDirectoryExist p
      pure (if ok then Just p else Nothing)

-- | 'locateRegistry' 的投影:只要目錄,不問來源、不問失敗原因。
defaultRegistryDir :: IO (Maybe FilePath)
defaultRegistryDir = either (const Nothing) (Just . fst) <$> locateRegistry

-- 載入 ------------------------------------------------------------------------

-- | 命名文法詞彙表的檔名。載入時特別排除,不當成型別宣告解析。
namingFileName :: FilePath
namingFileName = "naming.toml"

-- | 掃描目錄下所有 @*.toml@(排除 'namingFileName')並建成註冊表 +
-- 詞彙表。空目錄(扣掉 @naming.toml@ 之後沒有任何型別宣告)仍是合法的空
-- 註冊表,不是錯誤;缺 @naming.toml@ 才是錯誤('NamingFileMissing')。
loadRegistry :: FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))
loadRegistry dir = do
  ok <- doesDirectoryExist dir
  if not ok
    then pure (Left (RegistryDirMissing dir))
    else do
      names <- listDirectory dir
      let files = sort [dir </> n | n <- names, takeExtension n == ".toml", n /= namingFileName]
      loadRegistryFrom files (dir </> namingFileName)

-- | 由明確的型別宣告檔清單 + 明確的 @naming.toml@ 路徑載入。供測試指定臨時
-- 目錄,與未來「內建 + Vault 覆蓋」兩層註冊表使用。
loadRegistryFrom :: [FilePath] -> FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))
loadRegistryFrom typeFiles namingPath = do
  declResults <- mapM readSpec typeFiles
  namingExists <- doesFileExist namingPath
  vocabResult <-
    if namingExists
      then readNamingToml namingPath
      else pure (Left [NamingFileMissing namingPath])
  let (declErrss, decls) = partitionEithers declResults
      declErrs = concat declErrss
      (vocabErrs, mVocab) = case vocabResult of
        Left es -> (es, Nothing)
        Right v -> ([], Just v)
      parseErrs = declErrs ++ vocabErrs
  pure $
    if not (null parseErrs)
      then Left (aggregate parseErrs)
      else case (buildRegistry decls, mVocab) of
        (Left es, _) -> Left (aggregate es)
        (Right reg, Just vocab) -> Right (reg, vocab)
        (Right _, Nothing) -> Left (aggregate [NamingFileMissing namingPath])

-- | 讀一個檔並解析成一份型別宣告。回傳該檔的__全部__問題。
--
-- 解析規則本身在 'Aapms.Types.Parse.parseSpecText';本函式只負責把位元組讀進來
-- 並確認它是 UTF-8。
readSpec :: FilePath -> IO (Either [RegistryError] TypeDecl)
readSpec fp = do
  raw <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
  pure $ case raw of
    Left e -> Left [TomlParseError fp (T.pack (show e))]
    Right bytes -> case TE.decodeUtf8' bytes of
      Left e -> Left [TomlParseError fp ("檔案不是合法的 UTF-8:" <> T.pack (show e))]
      Right txt -> parseSpecText fp txt

-- naming.toml -----------------------------------------------------------------

-- | 讀 @naming.toml@:@kinds@(強制詞彙,命名文法第一段的合法值)、@domains@
-- (不強制,只為與 @kinds@ 對稱)、@states@(強制、封閉,'parseLogicalName'
-- 拆解時唯一查的表,2026-08-23 階段一閘門新增)三個字串陣列。
--
-- 解析規則本身在 'Aapms.Types.Parse.parseNamingText';本函式只負責把位元組讀
-- 進來並確認它是 UTF-8。
readNamingToml :: FilePath -> IO (Either [RegistryError] NamingVocab)
readNamingToml fp = do
  raw <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
  pure $ case raw of
    Left e -> Left [TomlParseError fp (T.pack (show e))]
    Right bytes -> case TE.decodeUtf8' bytes of
      Left e -> Left [TomlParseError fp ("檔案不是合法的 UTF-8:" <> T.pack (show e))]
      Right txt -> parseNamingText fp txt
