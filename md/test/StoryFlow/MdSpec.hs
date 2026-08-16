-- | func-0001 T6 的對照測試:測試進入點的輸出編碼,以及 md → core 的依賴方向。
--
-- 本專案的測試描述一律繁體中文,Windows 終端預設 code page 950 會亂碼,
-- 因此每個 @test/Spec.hs@ 都在跑 hspec 前設定 handle 編碼。這裡確認它真的執行到。
module StoryFlow.MdSpec (spec) where

import StoryFlow.Core.Id (IdPrefix (PEnt), renderIdPrefix)
import StoryFlow.Md (MdWarning (EmptyBody), renderMdWarning)
import StoryFlow.Md.Fixtures (idOf)
import System.IO
import Test.Hspec

spec :: Spec
spec = do
  it "stdout 已設為 UTF-8" $ do
    enc <- hGetEncoding stdout
    fmap show enc `shouldBe` Just "UTF-8"

  it "stderr 已設為 UTF-8" $ do
    enc <- hGetEncoding stderr
    fmap show enc `shouldBe` Just "UTF-8"

  -- func-0001 T4:依賴方向的驗證。func-0003 把佔位的 mdVersion 換成真正的
  -- 解析器,這裡改用實際的 md 函式與 core 函式各一,意義不變。
  it "可 import storyflow-core,證明 md → core 的依賴方向已接上" $
    renderIdPrefix PEnt `shouldBe` "ent"

  it "md 的公開介面可由門面模組取得" $
    renderMdWarning (EmptyBody (idOf "ent-0001"))
      `shouldSatisfy` (not . null . show)
