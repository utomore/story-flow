-- | T6:'Aapms.Workshop.Session' 的快照讀寫(整合測試,真的碰檔案系統)。
module Aapms.Workshop.SessionIOSpec (spec) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import Aapms.Service (vaultRoot)
import Aapms.Workshop.Error (WorkshopError (..))
import Aapms.Workshop.Fixtures (runS, withWorkshopVault)
import Aapms.Workshop.Session (Session (..), loadSession, saveSession)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  it "saveSession 回 Right () 後,快照檔存在於 .storyflow/workshops/<id>.json" $
    withWorkshopVault $ \env -> do
      let session = sampleSession "wksp-a1b2c3d4"
      runS env (saveSession session) `shouldReturn` Right ()
      root <- runS env vaultRoot
      doesFileExist (root </> ".storyflow" </> "workshops" </> "wksp-a1b2c3d4.json")
        `shouldReturn` True

  it "loadSession 讀回的 Session 與寫入前相等" $
    withWorkshopVault $ \env -> do
      let session = sampleSession "wksp-b2c3d4e5"
      runS env (saveSession session) `shouldReturn` Right ()
      runS env (loadSession "wksp-b2c3d4e5") `shouldReturn` Right session

  it "loadSession 對不存在的 id 回 Left (WsSessionNotFound _)" $
    withWorkshopVault $ \env -> do
      result <- runS env (loadSession "wksp-ffffffff")
      case result of
        Left (WsSessionNotFound sid) -> sid `shouldBe` "wksp-ffffffff"
        other -> expectationFailure ("預期 WsSessionNotFound,拿到 " <> show other)

  it "快照檔內容不合法 JSON 時 loadSession 回 Left (WsSnapshotCorrupt _ _)" $
    withWorkshopVault $ \env -> do
      let session = sampleSession "wksp-c3d4e5f6"
      runS env (saveSession session) `shouldReturn` Right ()
      root <- runS env vaultRoot
      let path = root </> ".storyflow" </> "workshops" </> "wksp-c3d4e5f6.json"
      BS.writeFile path "不是合法的 JSON"
      result <- runS env (loadSession "wksp-c3d4e5f6")
      case result of
        Left (WsSnapshotCorrupt _ _) -> pure ()
        other -> expectationFailure ("預期 WsSnapshotCorrupt,拿到 " <> show other)

sampleSession :: Text -> Session
sampleSession sid =
  Session
    { wsId = sid
    , wsType = "character"
    , wsConstraints = []
    , wsStages = ["定位", "外貌與舉止"]
    , wsCurrent = 0
    , wsHistory = []
    , wsOwner = Nothing
    , wsPending = []
    , wsCommitted = []
    }
