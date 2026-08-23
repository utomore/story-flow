-- | T8:並發寫入被序列化,而且沒有 Vault 時 @\/vaults@ 仍可用。
--
-- 兩件事其實是同一個設計的兩面:'Aapms.Server.State.AppState' 那個 'MVar'
-- 既是「所有請求序列化」的鎖,也是「'Env' 延遲取得」的記憶體。
module Aapms.Server.ConcurrencySpec (spec) where

import Control.Concurrent.Async (forConcurrently)
import Data.Either (lefts, rights)
import Data.List (sort)
import qualified Data.List as L
import qualified Data.Text as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import qualified Network.Wai.Handler.Warp as Warp
import Servant.Client (BaseUrl (..), Scheme (Http), mkClientEnv)
import Aapms.Api (NewVaultReq (..))
import Aapms.Server (app)
import Aapms.Server.Fixtures
import Aapms.Server.State (newAppState)
import Aapms.Service
import Test.Hspec

spec :: Spec
spec = describe "並發與延遲取得 Env" $ do
  it "20 個並發 PATCH:沒有例外逸出,最終 revision 等於成功次數 + 1" $ withServer $ \env -> do
    i <- evId <$> runC env (cCreateEntity api (newEntity "character" "琳達" "第七織手"))

    -- 每個請求各自先 GET 拿 revision 再 PATCH,這正是「先讀再寫」在多客戶端下的
    -- 真實樣子:大部分會撞上 stale_revision,而那是樂觀鎖在做它該做的事。
    results <- forConcurrently [1 .. 20 :: Int] $ \n -> do
      cur <- runE env (cGetEntity api i)
      case cur of
        Left e -> pure (Left (show e))
        Right v ->
          runE env (cUpdateEntity api i (evRevision v) emptyPatch {epSummary = Just (T.pack (show n))})
            >>= pure . either (Left . show) (Right . evRevision)

    let ok = rights results
    -- 至少有一個成功,而且沒有任何請求以「伺服器崩了」收場(連線被切、非 JSON 回應)
    length ok `shouldSatisfy` (>= 1)
    mapM_ (\e -> e `shouldSatisfy` isBusinessFailure) (lefts results)

    -- 成功的那些拿到的 revision 互不相同:序列化生效,沒有兩個請求讀到同一個值
    -- 又都寫成功。
    sort ok `shouldBe` sort (nubOrd ok)

    -- 最終狀態與成功次數一致:起始 1,每次成功 +1。
    final <- runC env (cGetEntity api i)
    evRevision final `shouldBe` 1 + length ok

  it "並發讀取全部成功" $ withServer $ \env -> do
    _ <- runC env (cCreateEntity api (newEntity "character" "琳達" "第七織手"))
    results <- forConcurrently [1 .. 20 :: Int] $ \_ ->
      runE env (cListEntities api Nothing Nothing Nothing Nothing)
    lefts (map (either (Left . show) Right) results) `shouldBe` []
    map (length . either (const []) id) results `shouldBe` replicate 20 1

  it "沒有目前 Vault 時 GET /vaults 仍回 200,而需要 Env 的路由回錯誤" $
    withVaultDir $ \dir -> do
      -- 刻意不 createVault:這個目錄裡沒有 .storyflow/,而 --vault 指到一個
      -- 註冊表裡沒有的名稱。Env 因此開不起來。
      st <- newAppState (Just "不存在的-vault") dir
      mgr <- newManager defaultManagerSettings
      Warp.testWithApplication (pure (app Nothing st)) $ \port -> do
        let env = mkClientEnv mgr (BaseUrl Http "127.0.0.1" port "")
        vs <- runC env (cListVaults api)
        vs `shouldBe` []
        r <- runE env (cVaultInfo api)
        statusOf r `shouldBe` Just 404
        codeOf r `shouldBe` Just "vault_not_found"

  it "Env 開失敗不會被快取:之後建好 Vault 就用得了" $ withVaultDir $ \dir -> do
    st <- newAppState (Just "liftgame") dir
    mgr <- newManager defaultManagerSettings
    Warp.testWithApplication (pure (app Nothing st)) $ \port -> do
      let env = mkClientEnv mgr (BaseUrl Http "127.0.0.1" port "")
      noVault <- runE env (cVaultInfo api)
      statusOf noVault `shouldBe` Just 404
      -- 透過 API 自己把 Vault 建起來,不重啟伺服器
      _ <- runC env (cCreateVault api (NewVaultReq dir "liftgame"))
      withVault <- runC env (cVaultInfo api)
      vvName withVault `shouldBe` "liftgame"

-- | 「業務失敗」= 伺服器好好地回了一個狀態碼。
--
-- 對照組是連線被切、逾時、非 JSON 回應——那些代表 handler 拋了例外或
-- 'Control.Concurrent.MVar.MVar' 死鎖,正是這條測試要排除的。
isBusinessFailure :: String -> Bool
isBusinessFailure e = "FailureResponse" `L.isInfixOf` e

nubOrd :: (Ord a) => [a] -> [a]
nubOrd = go . sort
  where
    go (x : y : rest) | x == y = go (y : rest)
    go (x : rest) = x : go rest
    go [] = []
