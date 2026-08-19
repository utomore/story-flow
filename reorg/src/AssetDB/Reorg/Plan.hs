-- | 重構計畫的推導。**純函數,沒有 IO。**
--
-- == 目標結構
--
-- @
-- alchbees-assets\/
-- ├── library\/
-- │   ├── packs\/\<vendor\>\/\<slug\>\/     一包 = 一目錄 = 一個備份與溯源單位
-- │   │   ├── pack.toml
-- │   │   └── \<廠商原始檔名\>.zip
-- │   ├── reference\/\<slug\>\/
-- │   └── studio\/
-- ├── projects\/
-- ├── knowledge\/
-- ├── marketing\/
-- └── .assetdb\/
-- @
--
-- == 散檔:一律保留
--
-- 2026-08-09 的一次性搬遷(見 @docs\/architecture.md@ 開發階段 3)已執行
-- 完畢,當時的路徑規則 —— 廠商前綴的刪除閘門、中文頂層資料夾對應 ——
-- 已於 ingest/E003 退役,規則本身留在 git 歷史裡。散檔如今一律產生
-- 'OpKeep':再跑一次 @reorganize --apply@ 只會重組素材包,
-- 不會搬移或刪除任何散檔。
module AssetDB.Reorg.Plan
  ( Op (..)
  , Plan (..)
  , PlanStats (..)
  , planStats
  , buildPlan
  , targetDirFor
  , slugify
  ) where

import AssetDB.PathText (leafOf, slugify)
import AssetDB.Reorg.Snapshot
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

-- | 計畫裡的一個動作。刻意做成資料而不是直接執行 ——
-- 產生、檢視、審核、執行是四件事,混在一起就沒辦法在執行前看清楚。
data Op
  = OpMkDir {opPath :: Text}
  | OpMove {opFrom :: Text, opTo :: Text, opBytes :: Integer, opWhy :: Text}
  | OpWrite {opTo :: Text, opWhy :: Text}
  | -- | 刪除。'opCoveredBy' 是「這份內容存在於哪個壓縮檔」的證據。
    OpDelete {opFrom :: Text, opSha :: Text, opCoveredBy :: Text, opBytes :: Integer}
  | -- | 保留但需要人工決定。這是計畫裡最重要的一類 ——
    -- 一個沒有 'OpKeep' 的重構計畫代表工具自以為什麼都懂。
    OpKeep {opFrom :: Text, opWhy :: Text}
  deriving stock (Eq, Show)

data Plan = Plan
  { planSourceRoot :: Text
  , planTargetRoot :: Text
  , planOps :: [Op]
  , planWarnings :: [Text]
  }
  deriving stock (Eq, Show)

data PlanStats = PlanStats
  { psMkDir :: Int
  , psMove :: Int
  , psWrite :: Int
  , psDelete :: Int
  , psKeep :: Int
  , psBytesMoved :: Integer
  , psBytesFreed :: Integer
  }
  deriving stock (Eq, Show)

planStats :: Plan -> PlanStats
planStats p = foldr step (PlanStats 0 0 0 0 0 0 0) (planOps p)
  where
    step op s = case op of
      OpMkDir _ -> s {psMkDir = psMkDir s + 1}
      OpMove {..} -> s {psMove = psMove s + 1, psBytesMoved = psBytesMoved s + opBytes}
      OpWrite {} -> s {psWrite = psWrite s + 1}
      OpDelete {..} -> s {psDelete = psDelete s + 1, psBytesFreed = psBytesFreed s + opBytes}
      OpKeep {} -> s {psKeep = psKeep s + 1}

--------------------------------------------------------------------------------

buildPlan :: Text -> Text -> Snapshot -> Plan
buildPlan srcRoot dstRoot snap =
  Plan
    { planSourceRoot = srcRoot
    , planTargetRoot = dstRoot
    , planOps = dirs <> packOps <> looseOps
    , planWarnings = warnings
    }
  where
    packs = snPacks snap

    -- 目錄先建齊。執行器因此可以照順序跑而不必自己推導父目錄。
    dirs =
      map OpMkDir . dedupe . sortOn id $
        ["library", "library/packs", "library/reference", "library/studio", "projects", "knowledge", "marketing", ".assetdb"]
          <> map targetDirFor packs

    packOps = concatMap onePack packs

    onePack pk =
      let dir = targetDirFor pk
          leaf = leafOf (prArchiveRel pk)
       in [ OpMove
              { opFrom = prArchiveRel pk
              , opTo = dir <> "/" <> leaf
              , opBytes = prArchiveBytes pk
              , opWhy = "素材包「" <> prName pk <> "」的壓縮檔"
              }
          , OpWrite
              { opTo = dir <> "/pack.toml"
              , opWhy = "素材包中繼資料(授權、作者、AI 揭露)"
              }
          ]

    -- 散檔一律保留(見模組說明)。'OpMove' 與 'OpDelete' 只會出於
    -- 素材包重組,不會出於散檔。
    looseOps = map oneLoose (snLoose snap)

    oneLoose lr = OpKeep (lrRelPath lr) "散檔不再有自動搬移/刪除規則,保留待人工決定"

    warnings =
      concat
        [ ["素材包「" <> prName pk <> "」仍是 draft(缺授權或作者),重構仍會搬移它,但它不可用於建專案。" | pk <- packs, prStatus pk /= "ready"]
        , ["素材包「" <> prName pk <> "」沒有 vendor,將落在 library/packs/unknown/。" | pk <- packs, prKind pk == "packs", prVendor pk == Nothing]
        ]

--------------------------------------------------------------------------------

-- | 素材包在新結構裡的目錄。
--
-- @packs@ 依 vendor 分組。vendor 永遠不變,而分類(GUI \/ Ground \/ Book)
-- 是多值且會被重新歸類的 —— 那些屬於資料庫,不屬於資料夾。
targetDirFor :: PackRow -> Text
targetDirFor pk =
  case prKind pk of
    "reference" -> "library/reference/" <> prSlug pk
    "studio" -> "library/studio/" <> prSlug pk
    _ -> "library/packs/" <> vendorSlug <> "/" <> prSlug pk
  where
    vendorSlug = maybe "unknown" (nonEmpty . slugify) (prVendor pk)
    nonEmpty s = if T.null s then "unknown" else s

-- slugify 與 leafOf 的唯一實作在 core 的 AssetDB.PathText(G-E002):
-- slugify 同時決定掃描端的 pack slug 與這裡的目錄名,兩份實作會分家。
-- slugify 仍自本模組 re-export,呼叫端不變。

dedupe :: Ord a => [a] -> [a]
dedupe = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs
