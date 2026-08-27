-- | 相依方向規則(@CabalRulesSpec@)的專屬入口。
--
-- __為什麼不共用 @Spec.hs@__:那一支走 @hspec-discover@,會把 @test/@ 底下
-- 每一個 @*Spec.hs@ 都吸進來——包含五組要跑 @aapms@ \/ @aapms-serve@ 執行檔的
-- 契約測試。規則測試只讀 @.cabal@ 的文字,不需要任何執行檔,共用入口就會把它
-- 重新綁回被凍結的下游套件(G-B001 的根因)。
--
-- 這裡逐一列出要跑的 spec,新增規則類的 spec 時手動加一行即可。
module Main (main) where

import qualified Aapms.Contract.CabalRulesSpec as CabalRulesSpec
import Test.Hspec (describe, hspec)

main :: IO ()
main = hspec (describe "Aapms.Contract.CabalRulesSpec" CabalRulesSpec.spec)
