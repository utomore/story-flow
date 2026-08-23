-- | T7:'Aapms.Workshop.Session' 的 session id 產生。
module Aapms.Workshop.SessionIdSpec (spec) where

import Control.Monad (replicateM)
import qualified Data.ByteString as BS
import Data.List (nub)
import Data.Text (unpack)
import Data.Time (UTCTime (..), fromGregorian)
import Aapms.Service (vaultRoot)
import Aapms.Workshop.Fixtures (runS, withWorkshopVault)
import Aapms.Workshop.Session (newSessionId, newSessionIdAt, sessionIdCandidate)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  it "連續產生 50 個 id 全部不重複" $
    withWorkshopVault $ \env -> do
      -- 唯一性靠「快照檔是否已存在」判斷碰撞,所以要比照 startWorkshop
      -- 的真實用法:每產生一個就登記(寫出一份佔位快照),下一次的碰撞
      -- 判斷才看得到它——否則同一輪內時間解析度不夠細時(Windows 的
      -- getCurrentTime 精度有限)會誤判成「還沒被用過」而重複。
      root <- runS env vaultRoot
      let dir = root </> ".storyflow" </> "workshops"
      createDirectoryIfMissing True dir
      ids <- replicateM 50 $ do
        sid <- runS env (newSessionId "character" [])
        BS.writeFile (dir </> (unpack sid <> ".json")) "{}"
        pure sid
      length (nub ids) `shouldBe` 50

  it "候選 id 已存在時會跳過,拿到不同的 id(以雜湊輸入回推構造碰撞)" $
    withWorkshopVault $ \env -> do
      root <- runS env vaultRoot
      let now = fixedNow
          candidate0 = sessionIdCandidate "character" [] now 0
          candidate1 = sessionIdCandidate "character" [] now 1
          dir = root </> ".storyflow" </> "workshops"
      createDirectoryIfMissing True dir
      -- 預先造出「即將產生的候選 id」同名的空檔,構造碰撞。
      BS.writeFile (dir </> (unpack candidate0 <> ".json")) "{}"
      got <- runS env (newSessionIdAt now "character" [])
      got `shouldBe` candidate1
      got `shouldNotBe` candidate0

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 8 22) 0
