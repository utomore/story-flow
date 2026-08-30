-- | @aapms-service@ 測試的彙總器。
--
-- __這是手寫彙總器,不是 hspec-discover__:新增測試模組後必須自己在下面的
-- 'main' 裡加一行 @describe@\/@Spec.spec@,否則它一條都不會被執行,而測試輸出
-- 看起來仍然全綠(graph-core\/E001 踩過這個坑:12 條測試整批沒跑而沒有人發現)。
--
-- 同時要把模組名加進 @aapms-service.cabal@ 的 @test-suite@ @other-modules@ ——
-- 那個檔案由 @\/subsys-build@ 的編排者單線維護(build-log 的 D1),qa 不碰它,
-- 請在回報裡列出要加的模組名。
module Main (main) where

import Test.Hspec (hspec)

main :: IO ()
main = hspec $ pure ()
