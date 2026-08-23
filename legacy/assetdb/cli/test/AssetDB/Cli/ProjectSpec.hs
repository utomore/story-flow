-- | @project sync@ 的結束碼(delivery/F006 T9)。
--
-- 結束碼是易錯的判斷,而且腳本只看得到它:
--
-- * **0 筆新增不是失敗。**「沒有東西要加」是同步的正常結果 ——
--   這一點與 @new-project@ 相反(那裡空專案是失敗)。
-- * **有東西要加卻一筆都加不進去才是失敗。**
--
-- 走到這個判斷需要一整組真實壓縮檔,而 'runProjectSync' 自己會呼叫
-- @exitFailure@、測不動,所以 'syncExitCode' 單獨匯出以便直接測。
module AssetDB.Cli.ProjectSpec (spec) where

import AssetDB.Cli.Project (SyncArgs (..), syncExitCode)
import AssetDB.Project.Sync
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "syncExitCode" $ do
  it "沒有 --confirm 時永遠以 0 結束" $ do
    syncExitCode preview (result [SyncNew] 0 ["讀取失敗"]) `shouldBe` ExitSuccess
    syncExitCode preview (result [SyncLocallyModified] 0 []) `shouldBe` ExitSuccess

  it "0 筆新增時以 0 結束(與 new-project 相反)" $ do
    syncExitCode confirm (result [] 0 []) `shouldBe` ExitSuccess
    syncExitCode confirm (result [SyncUnchanged, SyncSourceUpdated] 0 []) `shouldBe` ExitSuccess

  it "有新增項但一筆都沒複製成功時以非 0 結束" $
    syncExitCode confirm (result [SyncNew, SyncNew] 0 ["讀取失敗", "讀取失敗"])
      `shouldNotBe` ExitSuccess

  it "部分成功仍以 0 結束(單筆失敗記錄後續跑)" $
    syncExitCode confirm (result [SyncNew, SyncNew] 1 ["讀取失敗"]) `shouldBe` ExitSuccess

--------------------------------------------------------------------------------

preview, confirm :: SyncArgs
preview = args False
confirm = args True

args :: Bool -> SyncArgs
args c =
  SyncArgs
    { syName = "game"
    , syPacks = []
    , syQuery = Nothing
    , syAllowNonCommercial = False
    , syConfirm = c
    }

result :: [SyncClass] -> Int -> [Text] -> SyncResult
result classes copied skipped =
  SyncResult
    { syPlan =
        SyncPlan
          { spProjectPath = "C:/games/game"
          , spEntries = zipWith entry [1 :: Int ..] classes
          , spBlocked = []
          , spWarnedPacks = []
          }
    , syCopied = copied
    , sySkipped = skipped
    }
  where
    entry i c =
      SyncEntry
        { seUlid = "01ARZ3NDEKTSV4RRFFQ69G5FA" <> T.pack (show i)
        , seName = "ui_gui_x_0" <> T.pack (show i)
        , seRelPath = "assets/sprites/ui_gui_x_0" <> T.pack (show i) <> ".png"
        , seClass = c
        }
