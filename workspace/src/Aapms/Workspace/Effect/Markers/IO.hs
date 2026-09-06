{-# LANGUAGE DataKinds #-}

-- | "Aapms.Workspace.Effect.Markers" 的__真解譯器__(shell)。
--
-- 效果的描述是純資料,住 effects 層;__執行__它的這一個住 shell:@directory@ 的
-- @canonicalizePath@ \/ @doesDirectoryExist@ 與 graph-core 的 @readMarker@。
--
-- __不動檔案系統__:不建 @.aapms@、不開 @index.db@、不修補 marker、不寫中樞
-- (P-029 的決定,由 shell 的內部測試守)。
module Aapms.Workspace.Effect.Markers.IO
  ( runMarkersIO
  ) where

import Effectful (Eff, IOE, (:>))

import Aapms.Workspace.Effect.Markers (Markers)

-- | 以真的檔案系統跑 'Markers'。
runMarkersIO :: IOE :> es => Eff (Markers : es) a -> Eff es a
runMarkersIO _act = error "P-029#runMarkersIO stub"
