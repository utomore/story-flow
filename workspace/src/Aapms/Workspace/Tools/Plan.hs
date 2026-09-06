-- | 本機外部工具三層探測的__純規劃__(P-006-workspace-doctor)。
--
-- 擁有的事實(唯一真相來源):三層候選清單怎麼排(覆寫 → @PATH@ 每個目錄的
-- @7z@ 與 @7zz@ → 內建候選;跨層去重保序、名稱外層目錄內層),以及「命中即停、
-- @tsSearched@ 是走過的前綴」這條掃描紀律。
--
-- 「這個路徑存不存在、可不可執行」是
-- "Aapms.Workspace.Effect.ToolProbe" 的操作,__本模組一行 IO 都沒有__。
--
-- __7-Zip 缺席不是錯誤__:'Aapms.Workspace.Types.NotFound' 是正常結果,本模組
-- 沒有失敗通道。
module Aapms.Workspace.Tools.Plan
  ( probes
  , detectTool
  ) where

import Data.List (nub)
import Effectful (Eff, (:>))
import System.FilePath ((<.>), (</>))

import Aapms.Workspace.Effect.ToolProbe (ToolProbe, isExecutable)
import Aapms.Workspace.Types
  ( ToolOrigin (FromCandidate, FromPath, FromToolsConfig, NotFound)
  , ToolSearchPlan (tspCandidates, tspExeExtension, tspPathDirs)
  , ToolStatus (ToolStatus)
  , ToolsConfig (tcSevenZip)
  )

-- | 三層候選清單:覆寫、@PATH@ 每個目錄的 @7z@ 與 @7zz@、內建候選;跨層去重保序。
--
-- 三層依序相接後 'Data.List.nub',所以__跨層__重複的只留第一次出現的位置;
-- 覆寫那一項(有的話)恒在最前面。第二層是__名稱外層、目錄內層__:@7z@ 掃完
-- 全部目錄才輪到 @7zz@。副檔名一律取自 'tspExeExtension'——那是 shell 才知道的
-- 平台事實,純這一層只拿它拼字串,__不查平台、不正規化路徑__。
probes :: ToolSearchPlan -> ToolsConfig -> [FilePath]
probes plan cfg = nub (override ++ pathLayer plan ++ tspCandidates plan)
  where
    override = maybe [] (: []) (tcSevenZip cfg)

-- | 依 'probes' 的順序逐一問 'Aapms.Workspace.Effect.ToolProbe.isExecutable',
-- 第一個命中就停;@tsSearched@ 是走過的前綴。
--
-- __沒有失敗通道__:走完整份清單都不合格時回
-- @'ToolStatus' \"7-Zip\" Nothing 'NotFound' ps@,@ps@ 是完整的候選清單——訊息要
-- 說得出「我看過哪裡」。命中時 @tsSearched@ 以命中的那一項結尾。
detectTool :: ToolProbe :> es => ToolSearchPlan -> ToolsConfig -> Eff es ToolStatus
detectTool plan cfg = go [] (probes plan cfg)
  where
    go acc [] = pure (ToolStatus "7-Zip" Nothing NotFound (reverse acc))
    go acc (p : ps) = do
      ok <- isExecutable p
      let acc' = p : acc
      if ok
        then pure (ToolStatus "7-Zip" (Just p) (originOf plan cfg p) (reverse acc'))
        else go acc' ps

--------------------------------------------------------------------------------
-- 私有

-- | 私有:第二層(@PATH@)展開後的候選路徑,__名稱外層、目錄內層__。
--
-- 查詢名稱只有 @7z@ 與 @7zz@ 兩個,依此順序;__不展開 @PATHEXT@__。
pathLayer :: ToolSearchPlan -> [FilePath]
pathLayer plan =
  [ d </> (n <.> tspExeExtension plan)
  | n <- sevenZipNames
  , d <- tspPathDirs plan
  ]

-- | 私有:@PATH@ 層的查詢名稱,依此順序(不含 legacy 的 @7za@)。
sevenZipNames :: [String]
sevenZipNames = ["7z", "7zz"]

-- | 私有:命中的路徑屬於哪一層。判定順序恒為覆寫 → @PATH@ → 內建候選,與
-- 'probes' 相接的順序一致——跨層去重只留第一次出現的位置,歸屬也就跟著第一層。
originOf :: ToolSearchPlan -> ToolsConfig -> FilePath -> ToolOrigin
originOf plan cfg p
  | tcSevenZip cfg == Just p = FromToolsConfig
  | p `elem` pathLayer plan = FromPath
  | otherwise = FromCandidate
