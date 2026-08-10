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
-- == 刪除閘門
--
-- 只有**同時滿足**兩個條件的散檔會被刪除:
--
-- 1. 它有 SHA-256(掃描時讀得到內容)
-- 2. 那個 SHA-256 出現在某個保留下來的壓縮檔內
--
-- 任何不滿足的檔案一律保留,並列入報告。「檔名相同」「大小相同」
-- 「看起來像是那包裡的」都不算證據。
module AssetDB.Reorg.Plan
  ( Op (..)
  , Plan (..)
  , PlanStats (..)
  , planStats
  , buildPlan
  , targetDirFor
  , mapTopLevel
  , slugify
  ) where

import AssetDB.Reorg.Snapshot
import Data.Char (isAscii, isDigit, isLower, toLower)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
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

    -- 每個散檔要嘛能證明存在於壓縮檔內(刪),要嘛有明確的搬移目的地(搬),
    -- 要嘛需要人工決定(留)。沒有第四種情況。
    looseOps = map oneLoose (snLoose snap)

    oneLoose lr =
      case (lrSha lr, mapTopLevel (lrRelPath lr)) of
        (Nothing, _) ->
          OpKeep (lrRelPath lr) "掃描時讀不到內容,沒有雜湊可證明"
        (Just sha, dest)
          | Just archive <- Map.lookup sha (snArchivedBy snap)
          , isVendorAsset (lrRelPath lr) ->
              OpDelete
                { opFrom = lrRelPath lr
                , opSha = sha
                , opCoveredBy = archive
                , opBytes = lrBytes lr
                }
          | Just d <- dest ->
              OpMove
                { opFrom = lrRelPath lr
                , opTo = d
                , opBytes = lrBytes lr
                , opWhy = "工作室自有內容,搬移而非刪除"
                }
          | otherwise ->
              OpKeep (lrRelPath lr) "不在已知的頂層對應規則內,需要人工決定"

    -- 只刪除**廠商素材**的解壓副本。工作室自己的檔案即使雜湊碰巧
    -- 出現在某個壓縮檔內,也不該被當成解壓副本刪掉。
    isVendorAsset p = "Game Assets itchio/" `T.isPrefixOf` p

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

-- | 頂層資料夾的對應。回傳新結構裡的完整相對路徑。
--
-- 中文資料夾名改成 ASCII:跨平台編碼、shell 跳脫、git 路徑。
-- **檔案內容與資料庫顯示名稱仍然是中文** —— 改的只有路徑。
mapTopLevel :: Text -> Maybe Text
mapTopLevel p =
  case [(from, to) | (from, to) <- rules, from `T.isPrefixOf` p] of
    ((from, to) : _) -> Just (to <> T.drop (T.length from) p)
    [] -> Nothing
  where
    rules =
      [ ("GameProjects/", "projects/")
      , ("Papers/", "knowledge/papers/")
      , ("行銷/", "marketing/")
      ]

-- | 路徑安全的識別字串。非 ASCII 字元會被丟掉,所以結果可能是空的 ——
-- 呼叫端必須處理,不能假設它有內容。
slugify :: Text -> Text
slugify =
  T.intercalate "-"
    . filter (not . T.null)
    . T.splitOn "-"
    . T.map safeChar
    . T.map toLower
  where
    safeChar c
      | isAscii c && (isLower c || isDigit c) = c
      | otherwise = '-'

leafOf :: Text -> Text
leafOf p = last ("" : T.splitOn "/" p)

dedupe :: Ord a => [a] -> [a]
dedupe = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs
