-- | 把計畫渲染成人看得懂的報告。
--
-- 一個五千多行的刪除清單沒有人會讀完,而讀不完的計畫等於沒有審核。
-- 所以預設把刪除依「被哪個壓縮檔涵蓋」分組,只顯示數量與代表性樣本;
-- 完整清單留給 @--verbose@。
--
-- 搬移與需要人工決定的項目一律完整列出 —— 那些數量少而且每一筆都重要。
module AssetDB.Reorg.Render
  ( Verbosity (..)
  , renderPlan
  , renderSummary
  , humanBytes
  ) where

import AssetDB.Reorg.Plan
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

data Verbosity = Summary | Verbose
  deriving stock (Eq, Show)

-- | 只有摘要、警告,與需要人工決定的項目。
--
-- 完整計畫寫進檔案時,終端機顯示這個。使用者必須**立刻**看到
-- 「要刪五千個檔案」,而不是自己去開檔案才發現 ——
-- 所以統計數字取自完整計畫,不是過濾後的子集。
renderSummary :: Plan -> Text
renderSummary p =
  T.unlines $
    ["## 摘要", ""]
      <> statLines p
      <> [""]
      <> warningLines p
      <> keepLines p

renderPlan :: Verbosity -> Plan -> Text
renderPlan v p =
  T.unlines $
    header
      <> summary
      <> warningsSection
      <> mkdirSection
      <> moveSection
      <> writeSection
      <> deleteSection
      <> keepSection
      <> footer
  where
    ops = planOps p

    header =
      [ "# 素材庫重構計畫"
      , "#"
      , "# 這是 dry-run。**沒有任何檔案被改動。**"
      , "#"
      , "# 來源:" <> planSourceRoot p
      , "# 目標:" <> planTargetRoot p
      , ""
      ]

    summary = ["## 摘要", ""] <> statLines p <> [""]

    warningsSection = warningLines p

    mkdirSection =
      section "建立目錄" [opPath o | o@OpMkDir {} <- ops] $ \paths ->
        map ("  " <>) paths

    moveSection =
      section "搬移" [o | o@OpMove {} <- ops] $ \os ->
        concatMap
          (\o -> ["  " <> opFrom o, "    → " <> opTo o <> "   [" <> opWhy o <> "]"])
          (sortOn opTo os)

    writeSection =
      section "寫入" [o | o@OpWrite {} <- ops] $ \os ->
        map (\o -> "  " <> opTo o) (sortOn opTo os)

    -- 刪除是唯一不可逆的部分,所以每一組都要標明證據來源。
    deleteSection =
      section "刪除散檔(已由 SHA-256 證明存在於壓縮檔內)" [o | o@OpDelete {} <- ops] $ \os ->
        let grouped = Map.toList (Map.fromListWith (<>) [(opCoveredBy o, [o]) | o <- os])
         in concatMap renderGroup (sortOn fst grouped)

    renderGroup (archive, os) =
      [ "  " <> T.justifyRight 6 ' ' (tshow (length os)) <> " 個檔案  ← " <> archive
      ]
        <> case v of
          Verbose -> map (\o -> "         " <> opFrom o <> "  " <> T.take 12 (opSha o)) (sortOn opFrom os)
          Summary -> map (\o -> "         " <> opFrom o) (take 3 (sortOn opFrom os))
            <> ["         …(其餘 " <> tshow (length os - 3) <> " 個以 --verbose 顯示)" | length os > 3]

    keepSection =
      section "保留(需要人工決定)" [o | o@OpKeep {} <- ops] $ \os ->
        map (\o -> "  " <> opFrom o <> "\n    " <> opWhy o) (sortOn opFrom os)

    footer =
      [ ""
      , "# 執行方式(尚未實作):"
      , "#   assetdb reorganize --apply --plan <這個檔案>"
      , "#"
      , "# 執行時會逐筆記錄到 moves 表,並在搬移後以雜湊逐筆對帳:"
      , "# 搬移前存在的每一個雜湊,搬移後必須仍然存在。對不上就中止並回退。"
      ]

    section _ [] _ = []
    section title xs f = ["## " <> title <> "(" <> tshow (length xs) <> ")", ""] <> f xs <> [""]

statLines :: Plan -> [Text]
statLines p =
  [ row "建立目錄" (psMkDir st)
  , row "搬移" (psMove st) <> "  (" <> humanBytes (psBytesMoved st) <> ")"
  , row "寫入 pack.toml" (psWrite st)
  , row "刪除散檔" (psDelete st) <> "  (釋出 " <> humanBytes (psBytesFreed st) <> ")"
  , row "保留待人工決定" (psKeep st)
  ]
  where
    st = planStats p
    row label n = "  " <> pad 18 label <> T.justifyRight 7 ' ' (tshow n)

warningLines :: Plan -> [Text]
warningLines p
  | null (planWarnings p) = []
  | otherwise = ["## 注意", ""] <> map ("  ⚠ " <>) (planWarnings p) <> [""]

keepLines :: Plan -> [Text]
keepLines p =
  case [o | o@OpKeep {} <- planOps p] of
    [] -> []
    os ->
      ["## 保留(需要人工決定)(" <> tshow (length os) <> ")", ""]
        <> map (\o -> "  " <> opFrom o <> "\n    " <> opWhy o) (sortOn opFrom os)
        <> [""]

humanBytes :: Integer -> Text
humanBytes n
  | n >= gib = fmt (fromIntegral n / fromIntegral gib) <> " GiB"
  | n >= mib = fmt (fromIntegral n / fromIntegral mib) <> " MiB"
  | n >= kib = fmt (fromIntegral n / fromIntegral kib) <> " KiB"
  | otherwise = tshow n <> " B"
  where
    kib = 1024 :: Integer
    mib = kib * 1024
    gib = mib * 1024
    fmt :: Double -> Text
    fmt x = T.pack (show (fromIntegral (round (x * 10) :: Integer) / 10 :: Double))

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - displayWidth t)) " "

-- | 中文字在等寬終端機佔兩格。
displayWidth :: Text -> Int
displayWidth = sum . map (\c -> if fromEnum c > 0x1100 then 2 else 1) . T.unpack

tshow :: Show a => a -> Text
tshow = T.pack . show
