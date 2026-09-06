{-# LANGUAGE DataKinds #-}

-- | P-006-workspace-doctor 的觀察點:兩個純解譯器一起跑到底,以及逐列重讀
-- marker 的參考實作。
--
-- 這些簽名__沒有 production 消費者__,只為 law 的觀察而匯出(rules\/boundary.md
-- 「測試與邊界」),所以住 @.Internal@:只有 "Aapms.Service.Machine" 自己與測試
-- 准 import。
module Aapms.Service.Machine.Internal
  ( -- * 純解譯器跑到底
    simulateDoctor

    -- * 參考實作
  , markerIssues
  ) where

import Data.Maybe (catMaybes)
import Effectful (Eff, runPureEff)

import Aapms.Store.Types (VaultMarker (vmId))
import Aapms.Workspace.Effect.Markers (Markers, dirExists, readMarkerAt, runMarkersPure)
import Aapms.Workspace.Effect.ToolProbe (ToolProbe, runToolProbePure)
import Aapms.Workspace.Types
  ( Hub
  , MarkerWorld
  , ScopeIssue (VaultIdDrift, VaultMarkerBroken, VaultPathMissing)
  , ToolWorld
  , VaultEntry (veId, vePath)
  , hubVaults
  )

-- | 觀察:'Markers' 與 'ToolProbe' 的純解譯器跑到底。
--
-- 兩層效果都被解掉之後就沒有效果了,所以拿得到裸的結果——里程碑 @=@ 列的 law
-- 因此完全不碰 IO。解的順序與堆疊順序一致('Markers' 在外、'ToolProbe' 在內),
-- 兩者互不影響:一個只讀 marker 表,一個只讀可執行檔表。
simulateDoctor :: MarkerWorld -> ToolWorld -> Eff '[Markers, ToolProbe] a -> a
simulateDoctor w tw act = runPureEff (runToolProbePure tw (runMarkersPure w act))

-- | 觀察:參考實作,中樞順序逐列重讀 marker 的降級清單。
--
-- __不呼叫 "Aapms.Workspace.Resolve"__(rules\/roles.md:拿受測程式當參考就沒有
-- 參考可言):它直接對 'Aapms.Workspace.Effect.Markers' 的兩個操作重寫一次三種
-- 降級的判定——先問路徑是不是既存目錄('Aapms.Workspace.Types.VaultPathMissing')、
-- 再讀 marker('Aapms.Workspace.Types.VaultMarkerBroken')、最後比 id
-- ('Aapms.Workspace.Types.VaultIdDrift'),依序、互斥,順序同
-- 'Aapms.Workspace.Types.hubVaults'。
--
-- 走純解譯器而不是自己查 'Aapms.Workspace.Types.MarkerWorld',是因為
-- 「路徑不在表上算不算讀不到 marker」「目錄怎麼比對」是那個__世界__的語意,不是
-- 受測程式的自由度;參考實作要重寫的是降級規則,不是世界。
markerIssues :: MarkerWorld -> Hub -> [ScopeIssue]
markerIssues w h = runPureEff (runMarkersPure w (catMaybes <$> mapM issueOf (hubVaults h)))
  where
    issueOf e = do
      exists <- dirExists (vePath e)
      if not exists
        then pure (Just (VaultPathMissing e (vePath e)))
        else do
          markerR <- readMarkerAt (vePath e)
          pure $ case markerR of
            Left err -> Just (VaultMarkerBroken e err)
            Right m
              | vmId m /= veId e -> Just (VaultIdDrift e (vmId m))
              | otherwise -> Nothing
