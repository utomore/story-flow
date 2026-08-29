-- | 本機外部工具的三層探測(design.md「內部模組劃分」的 Tools)。
--
-- 擁有的事實(唯一真相來源):__外部工具在哪、怎麼找的__——三層的順序、內建候選
-- 清單的內容,以及「什麼樣的路徑算是找到了」。
--
-- 探測順序固定三層(design.md 契約 E),__命中即停__:
--
-- > 1. FromToolsConfig  中樞 [tools] 的 tcSevenZip 覆寫
-- > 2. FromPath         PATH 的每個目錄 </> ("7z" / "7zz" <.> exeExtension)
-- > 3. FromCandidate    內建候選清單(沿用 legacy assetdb 的七條)
--
-- 判準只有「__檔案存在且可執行__」——'System.Directory.doesFileExist' 為真,且
-- 'System.Directory.getPermissions' 的 'System.Directory.executable' 為真。平台差異
-- (Windows 看副檔名、POSIX 看 @access@ 的 x 位元)__委給 @directory@__,本模組不自己
-- 判副檔名、不讀 ACL。
--
-- __不執行找到的檔案__:不查版本、不測試解壓能力(那是 @asset-ingest@ 真的要用時的
-- 事),所以本模組一個外部行程都不啟動,也__不建立、不修改、不刪除任何檔案或目錄__。
--
-- __7-Zip 缺席不是錯誤__(system.md:「sidecar 缺席只影響預覽與縮圖,不影響索引」;
-- ADR-020),所以本組__沒有失敗通道__:'ToolStatus' 一律回得出來,'NotFound' 是一種
-- 正常結果,不是例外。
--
-- __明確不做__(契約卡):不查版本、不測試解壓能力;不探測 LLM 端點的可達性(那是
-- @ai@ 子系統——本子系統只捧著 @[llm]@ 那張表);不把工具路徑寫回中樞。
module Aapms.Workspace.Tools
  ( -- * 契約 E
    detectSevenZip
    -- $plan
  , ToolSearchPlan (..)
  , detectSevenZipIn
  ) where

import Aapms.Workspace.Types
  ( ToolOrigin (FromCandidate, FromPath, FromToolsConfig, NotFound)
  , ToolStatus (ToolStatus)
  , ToolsConfig (tcSevenZip)
  )
import Data.List (nub)
import System.Directory (doesFileExist, executable, exeExtension, getPermissions)
import System.Environment (lookupEnv)
import System.FilePath (splitSearchPath, (<.>), (</>))

-- $plan
-- 'detectSevenZip' 的兩份外部清單(@PATH@ 的目錄、內建候選清單)在真實環境下是
-- __測不掉的事實__:開發機上 @C:\\Program Files\\7-Zip\\7z.exe@ 實際存在,於是
-- 契約卡的「三層都找不到時 @tsPath == Nothing@」永遠觸發不到。'detectSevenZipIn'
-- 把這兩份清單變成參數,'detectSevenZip' 只是「拿真實的兩份清單去呼叫它」。
-- 契約 E 的 'detectSevenZip' 簽名一字未動。

-- | 三層探測裡__可以被替換掉的那兩層__的來源。
--
-- 第三層(內建候選清單)與第二層(@PATH@)都是環境事實;把它們收成一個值,
-- 'detectSevenZipIn' 就成了「給定這兩份清單,依序探測」的確定性函式。
data ToolSearchPlan = ToolSearchPlan
  { tspPathDirs :: [FilePath]
  -- ^ 第二層:要當成 @PATH@ 來掃的目錄清單,__保留順序__。真實呼叫時是
  -- @PATH@ 環境變數以 'System.FilePath.splitSearchPath' 切開的結果;該變數
  -- 未設時是空清單(不是失敗)。
  , tspCandidates :: [FilePath]
  -- ^ 第三層:要逐一探測的__完整檔案路徑__清單,__保留順序__。真實呼叫時是本模組
  -- 內建的七條(沿用 legacy assetdb 的 @sevenZipCandidates@),__不隨平台變動__。
  }
  deriving stock (Show, Eq)

-- | 探測這台機器上的 7-Zip:@[tools]@ 覆寫 → @PATH@ → 內建候選清單,__命中即停__。
--
-- 等價於以「真實的 @PATH@ 目錄清單」與「內建候選清單」組成的 'ToolSearchPlan'
-- 呼叫 'detectSevenZipIn'。
--
-- __沒有失敗通道__:找不到時回 @'ToolStatus' \"7-Zip\" Nothing 'NotFound' searched@,
-- 而 @searched@ 必為非空(內建候選清單非空)——訊息要說得出下一步,所以「找過哪些
-- 地方」是必要資訊。
detectSevenZip :: ToolsConfig -> IO ToolStatus
detectSevenZip cfg = do
  pathEnv <- lookupEnv "PATH"
  let dirs = maybe [] splitSearchPath pathEnv
  detectSevenZipIn (ToolSearchPlan dirs sevenZipCandidates) cfg

-- | 'detectSevenZip' 的可注入版本:@PATH@ 目錄與候選清單都由呼叫端給。
--
-- 探測的候選路徑依序是
--
-- > [tcSevenZip]  ++  [ d </> (n <.> exeExtension) | n <- ["7z","7zz"], d <- tspPathDirs ]
-- >               ++  tspCandidates
--
-- 保序去重後__逐一__以「存在且可執行」判準測試,第一個為真的即命中;
-- 'Aapms.Workspace.Types.tsSearched' 是這串候選被問過的那一段前綴(命中時以命中的
-- 那一項結尾,全不中時是完整的一串),路徑一律__逐字__捧著,不做任何正規化。
detectSevenZipIn :: ToolSearchPlan -> ToolsConfig -> IO ToolStatus
detectSevenZipIn plan cfg = do
  let probes = buildProbes plan cfg
  (searched, hit) <- probeAll probes
  pure $ case hit of
    Just p -> ToolStatus "7-Zip" (Just p) (originOf plan cfg p) searched
    Nothing -> ToolStatus "7-Zip" Nothing NotFound searched

-- | 「存在且可執行」判準(私有):先問存在,再問可執行,__順序不可調換__——
-- 'getPermissions' 對不存在的路徑會拋例外,而契約 E 沒有失敗通道。
qualifies :: FilePath -> IO Bool
qualifies p = do
  exists <- doesFileExist p
  if exists then executable <$> getPermissions p else pure False

-- | 內建候選清單(第三層),逐字沿用 legacy @Sidecar.hs@,__順序不變、不隨平台過濾__。
sevenZipCandidates :: [FilePath]
sevenZipCandidates =
  [ "C:\\Program Files\\7-Zip\\7z.exe"
  , "C:\\Program Files (x86)\\7-Zip\\7z.exe"
  , "/usr/bin/7z"
  , "/usr/local/bin/7z"
  , "/opt/homebrew/bin/7z"
  , "/usr/bin/7zz"
  , "/opt/homebrew/bin/7zz"
  ]

-- | PATH 層的查詢名稱(第二層),__依此順序__,不含 legacy 的 @"7za"@。
sevenZipNames :: [String]
sevenZipNames = ["7z", "7zz"]

-- | 第二層(PATH)展開後的候選路徑:__名稱外層、目錄內層__。
pathLayer :: ToolSearchPlan -> [FilePath]
pathLayer plan = [d </> (n <.> exeExtension) | n <- sevenZipNames, d <- tspPathDirs plan]

-- | 三層依序串起來、保序去重(跨層):覆寫 → PATH → 內建候選清單。
buildProbes :: ToolSearchPlan -> ToolsConfig -> [FilePath]
buildProbes plan cfg = nub (l1 ++ l2 ++ l3)
  where
    l1 = maybe [] (: []) (tcSevenZip cfg)
    l2 = pathLayer plan
    l3 = tspCandidates plan

-- | 依序對候選路徑問 'qualifies',命中即停。回傳「被問過的那段前綴」與命中的路徑
-- (全不中則回傳完整清單與 'Nothing')。
probeAll :: [FilePath] -> IO ([FilePath], Maybe FilePath)
probeAll = go []
  where
    go acc [] = pure (reverse acc, Nothing)
    go acc (p : ps) = do
      ok <- qualifies p
      let acc' = p : acc
      if ok then pure (reverse acc', Just p) else go acc' ps

-- | 命中的路徑屬於哪一層:判定順序恒為覆寫 → PATH → 候選清單。
originOf :: ToolSearchPlan -> ToolsConfig -> FilePath -> ToolOrigin
originOf plan cfg p
  | tcSevenZip cfg == Just p = FromToolsConfig
  | p `elem` pathLayer plan = FromPath
  | otherwise = FromCandidate
