-- | F001 測試共用的臨時目錄、環境變數與固定佈局。
--
-- spec「數據」節「測試素材:一組固定的工作區佈局」的字面實作:
--
-- @
-- \<tmp\>\/hub\/config.toml          -- [[vaults]] 兩列:VA(story)、VB(asset);無 [llm]
-- \<tmp\>\/va\/.aapms\/config.toml    -- id = VA, kind = story, name = "story", refs = []
-- \<tmp\>\/vb\/.aapms\/config.toml    -- id = VB, kind = asset, name = "assets", refs = []
-- \<tmp\>\/outside\/                 -- 不是 vault,也不在任何 vault 底下
-- @
--
-- 'AAPMS_HOME' 指向 @hub\/@,'STORYFLOW_REGISTRY'(對照 'Aapms.Types.Loader.registryEnvVar')
-- 指向專案的 @types\/registry\/@ ——用真正的型別宣告,「註冊表在執行期找得到」正是
-- 驗收標準之一(對照 legacy @service-and-interfaces@ 的 'Aapms.Service.Fixtures.withVaultDir' 同一個理由)。
module Aapms.Service.Fixtures
  ( -- * 固定佈局
    FixedLayout (..)
  , withFixedLayout
  , vaKindText
  , vbKindText

    -- * 環境變數 / 臨時目錄的底層 helper
  , withEnvVars
  , withTempRoot
  , registryDir
  , aapmsHomeVar

    -- * 中樞 / marker 檔案的讀寫
  , writeHubConfigAt
  , hubConfigText
  , writeVaultMarkerAt
  , markerTomlText

  , -- * 開/關 Env 的便利包裝
    openEnvOrDie
  , withOpenEnv

    -- * 讀骨架原始碼(L23/X24/X25 用)
  , serviceSourceFiles
  , readServiceSource

    -- * 雜項
  , orDie
  , toTomlPath
  ) where

import Control.Exception (bracket)
import Data.List (isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO
  ( IOMode (ReadMode, WriteMode)
  , hSetEncoding
  , hSetNewlineMode
  , noNewlineTranslation
  , utf8
  , withFile
  )
import System.IO.Temp (withSystemTempDirectory)

import Aapms.Core.Id (VaultId (..))
import Aapms.Types.Loader (registryEnvVar)

import Aapms.Service.Monad (Env, closeEnv, openEnv)
import Aapms.Service.Types (renderServiceError)

--------------------------------------------------------------------------------
-- 顯式 UTF-8、不做換行轉換的讀寫(對照 memory「hedgehog 在 cp950 下會蓋掉真正的失敗」)

readUtf8NoTranslate :: FilePath -> IO Text
readUtf8NoTranslate fp = withFile fp ReadMode $ \h -> do
  hSetEncoding h utf8
  hSetNewlineMode h noNewlineTranslation
  txt <- TIO.hGetContents h
  T.length txt `seq` pure txt

writeUtf8NoTranslate :: FilePath -> Text -> IO ()
writeUtf8NoTranslate fp content = withFile fp WriteMode $ \h -> do
  hSetEncoding h utf8
  hSetNewlineMode h noNewlineTranslation
  TIO.hPutStr h content

--------------------------------------------------------------------------------
-- 環境變數 / 臨時目錄

-- | 'Aapms.Workspace.Location.hubLocation' 讀的環境變數名。字面常數獨立宣告
-- (不依賴 production 介面),與 'Aapms.Types.Loader.registryEnvVar' 同一個道理。
aapmsHomeVar :: String
aapmsHomeVar = "AAPMS_HOME"

-- | 設定一批環境變數跑一段動作,結束後還原(沒設過就還原成沒設)。
withEnvVars :: [(String, String)] -> IO a -> IO a
withEnvVars vars act = bracket save restore (const act)
  where
    save = mapM apply vars
    apply (k, v) = do
      old <- lookupEnv k
      setEnv k v
      pure (k, old)
    restore = mapM_ (\(k, mv) -> maybe (unsetEnv k) (setEnv k) mv)

-- | 一個空的臨時目錄,測完自動刪除。
withTempRoot :: (FilePath -> IO a) -> IO a
withTempRoot = withSystemTempDirectory "aapms-service"

-- | 專案的 @types\/registry\/@:測試工作目錄可能是套件目錄(@service\/@)或專案根,
-- 兩種都試過再放棄(對照 legacy @service-and-interfaces@ 的
-- 'Aapms.Service.Fixtures.registryDir')。
registryDir :: IO FilePath
registryDir = go candidates
  where
    candidates = ["../types/registry", "types/registry", "../../types/registry"]
    go [] = fail "找不到 types/registry/;測試需要真正的型別註冊表"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

-- | Windows 的反斜線在 TOML 字串裡要跳脫;測試素材一律改用正斜線
-- (對照 workspace fixtures 的 'sampleHubText')。
toTomlPath :: FilePath -> Text
toTomlPath = T.pack . map (\c -> if c == '\\' then '/' else c)

--------------------------------------------------------------------------------
-- 中樞 / marker 檔案

writeHubConfigAt :: FilePath -> Text -> IO ()
writeHubConfigAt hubDir content = do
  createDirectoryIfMissing True hubDir
  writeUtf8NoTranslate (hubDir </> "config.toml") content

-- | 兩列 @[[vaults]]@,依 spec「數據」節逐字。
hubConfigText :: [(VaultId, Text, Text, FilePath)] -> Text
hubConfigText entries = T.unlines (concatMap oneVault entries)
  where
    oneVault (VaultId idText, name, kind, path) =
      [ "[[vaults]]"
      , "id   = \"" <> idText <> "\""
      , "name = \"" <> name <> "\""
      , "kind = \"" <> kind <> "\""
      , "path = \"" <> toTomlPath path <> "\""
      , ""
      ]

writeVaultMarkerAt :: FilePath -> Text -> IO ()
writeVaultMarkerAt root content = do
  createDirectoryIfMissing True (root </> ".aapms")
  writeUtf8NoTranslate (root </> ".aapms" </> "config.toml") content

-- | spec「數據」節 marker 檔案格式的字面樣板(對照 workspace fixtures 的
-- 'markerTomlText')。
markerTomlText :: VaultId -> Text -> Text -> [VaultId] -> Text
markerTomlText (VaultId idText) kindText nameText refs =
  T.unlines
    [ "id   = \"" <> idText <> "\""
    , "kind = \"" <> kindText <> "\""
    , "name = \"" <> nameText <> "\""
    , "refs = [" <> T.intercalate ", " (map (\(VaultId r) -> "\"" <> r <> "\"") refs) <> "]"
    ]

vaKindText, vbKindText :: Text
vaKindText = "story"
vbKindText = "asset"

--------------------------------------------------------------------------------
-- 固定佈局

data FixedLayout = FixedLayout
  { flRoot :: FilePath
  , flHubDir :: FilePath
  , flVaPath :: FilePath
  , flVbPath :: FilePath
  , flOutsidePath :: FilePath
  , flVaId :: VaultId
  , flVbId :: VaultId
  }

-- | 建好 spec「測試素材」那組固定佈局,設好 'aapmsHomeVar' 與 'registryEnvVar'
-- 兩個環境變數(真正的 @types\/registry\/@),交給動作跑;結束後臨時目錄整個刪除、
-- 環境變數還原。
withFixedLayout :: (FixedLayout -> IO a) -> IO a
withFixedLayout act = withTempRoot $ \root -> do
  reg <- registryDir
  let hubDir = root </> "hub"
      vaPath = root </> "va"
      vbPath = root </> "vb"
      outsidePath = root </> "outside"
      vaId = VaultId "vlt-aaaa1111"
      vbId = VaultId "vlt-bbbb2222"
  createDirectoryIfMissing True outsidePath
  writeVaultMarkerAt vaPath (markerTomlText vaId vaKindText "story" [])
  writeVaultMarkerAt vbPath (markerTomlText vbId vbKindText "assets" [])
  writeHubConfigAt
    hubDir
    (hubConfigText [(vaId, "story", vaKindText, vaPath), (vbId, "assets", vbKindText, vbPath)])
  withEnvVars [(aapmsHomeVar, hubDir), (registryEnvVar, reg)] $
    act
      FixedLayout
        { flRoot = root
        , flHubDir = hubDir
        , flVaPath = vaPath
        , flVbPath = vbPath
        , flOutsidePath = outsidePath
        , flVaId = vaId
        , flVbId = vbId
        }

--------------------------------------------------------------------------------
-- 開/關 Env

-- | 'openEnv' 一定得成功時用:失敗就讓測試爆掉並印出 'renderServiceError'。
openEnvOrDie :: Maybe Text -> FilePath -> IO Env
openEnvOrDie sel cwd =
  openEnv sel cwd >>= either (\e -> fail ("openEnv 失敗:" <> T.unpack (renderServiceError e))) pure

-- | 開一個 'Env' 跑一段動作,結束後 'closeEnv'(不經 'Aapms.Service.Monad.withEnv',
-- 因為 'withEnv' 本身就是 L7 的受測對象)。
withOpenEnv :: Maybe Text -> FilePath -> (Env -> IO a) -> IO a
withOpenEnv sel cwd = bracket (openEnvOrDie sel cwd) closeEnv

--------------------------------------------------------------------------------
-- 讀骨架原始碼(L23/X24/X25 用)

-- | @service\/src\/@ 的實際位置。測試工作目錄可能是套件目錄或專案根
-- (對照 "Aapms.Workspace.Fixtures.readWorkspaceSource")。
resolveServiceSrcDir :: IO FilePath
resolveServiceSrcDir = go ["src", "service" </> "src"]
  where
    go [] = fail "找不到 service/src/"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

-- | 讀單一個骨架原始碼檔(相對於 @service\/src\/@,例如
-- @"Aapms\/Service\/Scope.hs"@)。
readServiceSource :: FilePath -> IO Text
readServiceSource rel = do
  dir <- resolveServiceSrcDir
  readUtf8NoTranslate (dir </> rel)

-- | @service\/src\/@ 底下__遞迴__取得的每一個 @.hs@ 檔,(相對路徑、檔案全文)。
-- __不是一份寫死的清單__(L23 明文):之後 F002–F008 新增的模組都自動被納入。
-- 相對路徑一律用正斜線,不受平台影響。
serviceSourceFiles :: IO [(FilePath, Text)]
serviceSourceFiles = do
  root <- resolveServiceSrcDir
  rels <- filter (".hs" `isSuffixOf`) <$> walk root ""
  mapM (\rel -> (,) (normSlashes rel) <$> readUtf8NoTranslate (root </> rel)) rels
  where
    walk root rel = do
      let full = if null rel then root else root </> rel
      isDir <- doesDirectoryExist full
      if isDir
        then do
          entries <- listDirectory full
          concat <$> mapM (\e -> walk root (if null rel then e else rel </> e)) entries
        else pure [rel]
    normSlashes = map (\c -> if c == '\\' then '/' else c)

--------------------------------------------------------------------------------
-- 雜項

-- | 攤平一個測試前置作業裡「一定得成功」的 'Either'(對照
-- "Aapms.Workspace.Fixtures.orDie")。
orDie :: (Show e) => Either e a -> IO a
orDie = either (\e -> fail ("測試前置作業失敗:" <> show e)) pure
