-- | 業務層測試的共用底稿。
--
-- ADR-0006 的正面影響之一是「@service@ 可以直接用 hspec 做完整的業務測試」,
-- 前提是測試__不能碰使用者真實的環境__。兩個環境變數因此在每次建臨時 Vault 時
-- 一起設好:
--
-- * @STORYFLOW_VAULTS@ 指向臨時目錄裡的 @vaults.toml@,不動
--   @~\/.config\/story-flow\/@
-- * @STORYFLOW_REGISTRY@ 指向原始碼樹的 @types\/registry\/@ ——測的是真正的
--   五份型別宣告,因為「註冊表在執行期找得到」正是 func-0006 的驗收標準之一
module StoryFlow.Service.Fixtures
  ( -- * 環境
    withServiceEnv
  , withVaultDir
  , withEnvVars
  , registryDir

    -- * 跑業務操作
  , runS
  , runE
  , orDieS
  , shouldFailWith

    -- * 請求建構
  , newEntity
  , newFragment
  , newLevel
  , newNode

    -- * 其他
  , idOf
  , refOf
  , rootOf
  , firstChildId
  , sceneKind
  , castKind
  ) where

import Control.Exception (bracket)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, Ref, parseId, parseRef)
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind (KCast, KScene))
import StoryFlow.Core.Meta (Meta (..), Source (Human), Status (Canon), emptyTimeline)
import StoryFlow.Core.Tree (NodeTree (..))
import StoryFlow.Service
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- 環境 -------------------------------------------------------------------------

-- | 原始碼樹裡的 @types\/registry\/@。
--
-- 測試的工作目錄是套件目錄(@service\/@),但直接跑執行檔時可能是專案根目錄,
-- 兩種都試過再放棄——找不到就直接讓測試爆掉,而不是靜默用空註冊表跑完。
registryDir :: IO FilePath
registryDir = go candidates
  where
    candidates = ["../types/registry", "types/registry", "../../types/registry"]
    go [] = fail "找不到 types/registry/;測試需要真正的型別註冊表"
    go (c : rest) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go rest

-- | 設定環境變數跑一段,結束後還原成原本的值(沒設過就還原成沒設)。
withEnvVars :: [(String, String)] -> IO a -> IO a
withEnvVars vars act = bracket save restore (const act)
  where
    save = mapM apply vars
    apply (k, v) = do
      old <- lookupEnv k
      setEnv k v
      pure (k, old)
    restore = mapM_ (\(k, mv) -> maybe (unsetEnv k) (setEnv k) mv)

-- | 一個臨時目錄,環境變數已經指到它自己的 @vaults.toml@ 與真正的註冊表。
withVaultDir :: (FilePath -> IO a) -> IO a
withVaultDir act =
  withSystemTempDirectory "storyflow-service" $ \dir -> do
    reg <- registryDir
    withEnvVars
      [ ("STORYFLOW_VAULTS", dir </> "vaults.toml")
      , ("STORYFLOW_REGISTRY", reg)
      ]
      (act dir)

-- | 臨時目錄 + 已建好並登記的 Vault + 開好的 'Env'。
withServiceEnv :: (Env -> IO a) -> IO a
withServiceEnv act = withVaultDir $ \dir -> do
  _ <- orDieS =<< createVault dir "liftgame"
  bracket (openEnvAt dir) closeEnv act
  where
    openEnvAt dir = fst <$> (orDieS =<< openEnv Nothing dir)

-- 跑業務操作 --------------------------------------------------------------------

-- | 跑一個業務操作,失敗就讓測試爆掉並印出人看得懂的訊息。
runS :: Env -> ServiceM a -> IO a
runS env m = orDieS =<< runService env m

-- | 期待失敗時用:原樣把 'Either' 交出來。
runE :: Env -> ServiceM a -> IO (Either ServiceError a)
runE = runService

orDieS :: Either ServiceError a -> IO a
orDieS = either (fail . T.unpack . renderServiceError) pure

-- | 斷言某個操作以特定的錯誤收場。比對用 @errorCode@ 之外還印出訊息,
-- 失敗時才看得出實際發生了什麼。
shouldFailWith :: (Show a) => Either ServiceError a -> Text -> Expectation
shouldFailWith r code = case r of
  Left e
    | errorCode e == code -> pure ()
    | otherwise ->
        expectationFailure $
          "預期 "
            <> T.unpack code
            <> ",實際是 "
            <> T.unpack (errorCode e)
            <> ":"
            <> T.unpack (renderServiceError e)
  Right x -> expectationFailure ("預期失敗(" <> T.unpack code <> "),但成功了:" <> show x)

-- 請求建構 ---------------------------------------------------------------------

-- | 型別 + 標題 + 一句話總結。其餘欄位是各測試自己 record update 上去。
newEntity :: Text -> Text -> Text -> NewEntityReq
newEntity ty title summary =
  NewEntityReq
    { nerType = ty
    , nerTitle = title
    , nerSummary = summary
    , nerBody = ""
    , nerTags = []
    , nerAliases = []
    , nerStatus = Canon
    , nerTimeline = emptyTimeline
    , nerLinks = []
    , nerSource = Human
    }

newFragment :: Text -> Text -> NewFragmentReq
newFragment title summary =
  NewFragmentReq
    { nfrTitle = title
    , nfrSummary = summary
    , nfrBody = ""
    , nfrType = Nothing
    , nfrTags = []
    , nfrAliases = []
    , nfrStatus = Nothing
    , nfrTimeline = Nothing
    , nfrLinks = []
    , nfrSource = Nothing
    }

newLevel :: Text -> Text -> NodeKind -> NewLevelReq
newLevel title rootTitle rootKind =
  NewLevelReq
    { nlrTitle = title
    , nlrSummary = title <> "的說明"
    , nlrBody = ""
    , nlrRootTitle = rootTitle
    , nlrRootKind = rootKind
    , nlrStatus = Canon
    }

newNode :: Text -> NodeKind -> NewNodeReq
newNode title kind =
  NewNodeReq
    { nnrTitle = title
    , nnrKind = kind
    , nnrSummary = ""
    , nnrBody = ""
    , nnrLinks = []
    }

-- 其他 -------------------------------------------------------------------------

-- | Level 的根 Node。'LevelView' 帶的是整棵樹,但要往下掛節點時要的是根的 id。
rootOf :: LevelView -> Id
rootOf = lvlRoot . lvLevel

-- | 樹上第一個子節點的 id ——「剛剛掛上去的那個」。
firstChildId :: NodeTree -> Id
firstChildId t = case ntChildren t of
  (c : _) -> metaId (nodMeta (ntNode c))
  [] -> error "測試預期這棵樹至少有一個子節點"

-- | 只 import 門面的測試(T16)也需要 'NodeKind' 的值,而門面沒有(也不該)
-- 重新匯出 core 的建構子。借道底稿,測試本身因此仍然只認得門面。
sceneKind :: NodeKind
sceneKind = KScene

castKind :: NodeKind
castKind = KCast

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("測試裡的 ref 不合法:" <> show e)
