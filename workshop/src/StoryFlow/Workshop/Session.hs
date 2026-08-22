-- | 一次工作坊的狀態(llm-workshop-mcp/F002):型別、硬約束、目前階段、對話歷程、
-- 各階段的定案草稿——以及它的可序列化快照。
--
-- __狀態只在這裡變動__:'StoryFlow.Workshop.Stages' 讀寫 'Session' 都經本模組的
-- 'saveSession' \/ 'loadSession',不自己組快照的位元組。
module StoryFlow.Workshop.Session
  ( -- * 型別
    Session (..)
  , StageDraft (..)

    -- * 快照
  , loadSession
  , saveSession

    -- * session id
  , newSessionId
  , newSessionIdAt
  , sessionIdCandidate
  ) where

import Control.Exception (IOException, bracketOnError, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Types (Parser)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, getCurrentTime)
import Data.Word (Word64)
import Numeric (showHex)
import StoryFlow.Core.Id (Id, fnv1a64, renderId)
import StoryFlow.Core.Json ()
import StoryFlow.Core.Meta (Timeline)
import StoryFlow.Llm (Message (..), Role (..))
import StoryFlow.Service (ServiceM, vaultRoot)
import StoryFlow.Workshop.Error (WorkshopError (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renamePath)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hClose, hFlush, openBinaryTempFile)

-- 型別 -------------------------------------------------------------------------

-- | 一次工作坊。可序列化成快照,中斷後接得回來。逐字等於 @design.md@「模組間
-- 公開介面與資料結構」的定義——九個欄位是 Level 2 契約鎖定的形狀,不多不少。
data Session = Session
  { wsId :: Text
  , wsType :: Text
  , wsConstraints :: [Id]
  , wsStages :: [Text]
  , wsCurrent :: Int
  , wsHistory :: [Message]
  , wsOwner :: Maybe Id
  , wsPending :: [StageDraft]
  , wsCommitted :: [Id]
  }
  deriving stock (Show, Eq)

-- | 一個還沒寫進圖譜的片段草稿,由 'StoryFlow.Workshop.Stages.stepWorkshop' 從
-- 模型回覆的約定 JSON 解析而來。刻意比 @NewFragmentReq@ 小:@status@ \/
-- @links@ \/ @source@ 由 @commitStage@ 依契約自己填,不讓模型決定。
-- 'sdTimeline' 不同——它是內容,只有讀過草稿的模型答得出來。
data StageDraft = StageDraft
  { sdTitle :: Text
  , sdSummary :: Text
  , sdBody :: Text
  , sdTags :: [Text]
  , sdTimeline :: Maybe Timeline
  }
  deriving stock (Show, Eq)

-- JSON 編碼 ---------------------------------------------------------------------
--
-- 目前唯一的消費者是這個套件自己(快照的落地格式),因此直接寫在這裡,不另開
-- @.Json@ 模組——與 storyflow-conflict 的 @Verdict@ 同一個先例。

instance ToJSON Session where
  toJSON Session {..} =
    object $
      [ "id" .= wsId
      , "type" .= wsType
      , "constraints" .= wsConstraints
      , "stages" .= wsStages
      , "current" .= wsCurrent
      , "history" .= map messageJson wsHistory
      , "pending" .= wsPending
      , "committed" .= wsCommitted
      ]
        ++ ["owner" .= v | Just v <- [wsOwner]]

instance FromJSON Session where
  parseJSON = withObject "Session" $ \o ->
    Session
      <$> o .: "id"
      <*> o .: "type"
      <*> o .: "constraints"
      <*> o .: "stages"
      <*> o .: "current"
      <*> (o .: "history" >>= traverse parseMessage)
      <*> o .:? "owner"
      <*> o .: "pending"
      <*> o .: "committed"

instance ToJSON StageDraft where
  toJSON StageDraft {..} =
    object $
      [ "title" .= sdTitle
      , "summary" .= sdSummary
      , "body" .= sdBody
      , "tags" .= sdTags
      ]
        ++ ["timeline" .= v | Just v <- [sdTimeline]]

instance FromJSON StageDraft where
  parseJSON = withObject "StageDraft" $ \o ->
    StageDraft
      <$> o .: "title"
      <*> o .: "summary"
      <*> o .: "body"
      <*> o .:? "tags" .!= []
      <*> o .:? "timeline"

-- | 'StoryFlow.Llm.Client' 刻意不定義 'Message' \/ 'Role' 的 aeson 實例(它們
-- 是門面之外的內部細節),所以這裡手動轉成 @{"role":…,"content":…}@,與
-- 'StoryFlow.Llm.Client' 內部的 @roleWire@ 同樣的字串但各自一份——不對
-- 'storyflow-llm' 的公開型別加孤兒實例。
messageJson :: Message -> Value
messageJson Message {..} = object ["role" .= roleWire msgRole, "content" .= msgContent]

roleWire :: Role -> Text
roleWire = \case
  System -> "system"
  User -> "user"
  Assistant -> "assistant"

parseMessage :: Value -> Parser Message
parseMessage = withObject "Message" $ \o -> do
  roleText <- o .: "role"
  content <- o .: "content"
  role <- roleFromWire roleText
  pure (Message role content)

roleFromWire :: Text -> Parser Role
roleFromWire = \case
  "system" -> pure System
  "user" -> pure User
  "assistant" -> pure Assistant
  other -> fail ("Message 的 role 不是 system / user / assistant:" <> T.unpack other)

-- 快照路徑 ----------------------------------------------------------------------

-- | 路徑字串用字面組,不 import @storyflow-store@ 的 @storyflowDir@——本套件的
-- build-depends 裡沒有 @storyflow-store@,與 @llm/test/.../Fixtures.hs@ 的
-- @appendConfig@ 同一個理由。
snapshotDir :: FilePath -> FilePath
snapshotDir root = root </> ".storyflow" </> "workshops"

snapshotPath :: FilePath -> Text -> FilePath
snapshotPath root sid = snapshotDir root </> (T.unpack sid <> ".json")

-- 讀寫 -------------------------------------------------------------------------

-- | 寫出快照。__原子寫入__:暫存檔同目錄、寫完 flush\/close 再 rename 覆蓋——
-- 同構於 @StoryFlow.Store.Atomic.atomicWriteText@ 的邏輯,而不是呼叫它:
-- 本套件的相依清單擋著 @storyflow-store@,兩份實作各自完整、互不依賴。
saveSession :: Session -> ServiceM (Either WorkshopError ())
saveSession session = do
  root <- vaultRoot
  let dir = snapshotDir root
      path = snapshotPath root (wsId session)
  liftIO (createDirectoryIfMissing True dir)
  r <- liftIO (try (atomicWriteJson path (encode session)) :: IO (Either IOException ()))
  pure $ case r of
    Left e -> Left (WsSnapshotWriteFailed path (T.pack (show e)))
    Right () -> Right ()

-- | 讀回快照。缺檔 → 'WsSessionNotFound';JSON 壞掉 → 'WsSnapshotCorrupt'。
loadSession :: Text -> ServiceM (Either WorkshopError Session)
loadSession sid = do
  root <- vaultRoot
  let path = snapshotPath root sid
  exists <- liftIO (doesFileExist path)
  if not exists
    then pure (Left (WsSessionNotFound sid))
    else do
      raw <- liftIO (BS.readFile path)
      pure $ case eitherDecodeStrict' raw of
        Left err -> Left (WsSnapshotCorrupt path (T.pack err))
        Right s -> Right s

-- | 暫存檔與目標檔同一個目錄、@hFlush@\/@hClose@ 再 @renamePath@;失敗清暫存檔。
atomicWriteJson :: FilePath -> LBS.ByteString -> IO ()
atomicWriteJson target bytes =
  bracketOnError
    (openBinaryTempFile (takeDirectory target) (takeFileName target <> ".tmp"))
    discard
    $ \(tmp, h) -> do
      LBS.hPut h bytes
      hFlush h
      hClose h
      renamePath tmp target
  where
    discard (tmp, h) = do
      ignoring (hClose h)
      ignoring (removeFile tmp)
    ignoring act = () <$ (try act :: IO (Either IOException ()))

-- session id 產生 -----------------------------------------------------------------

-- | 前綴 @wksp-@ + 'fnv1a64' 雜湊(型別鍵、硬約束 id 清單、目前時間、salt)+
-- 碰撞重試。__不重用 'StoryFlow.Core.Id.mkId'__:它的 'StoryFlow.Core.Id.IdPrefix'
-- 只認得四個封閉前綴('StoryFlow.Core.Id.PEnt' \/ 'StoryFlow.Core.Id.PLvl' \/
-- 'StoryFlow.Core.Id.PNod' \/ 'StoryFlow.Core.Id.PVlt'),工作坊 session 不是
-- 其中之一,只重用它有匯出的雜湊原語 'fnv1a64'。
--
-- 碰撞以「快照檔是否已存在」判斷;重試到保守上限後仍碰撞,理論上不會發生
-- (雜湊空間 32 位元、salt 隨時間與內容變動),直接採用最後一個候選 id——
-- 與 core 的 'StoryFlow.Core.Id.mkId' 同一個立場:「唯一性不在雜湊這一層」,
-- 真正的唯一性保證留給下一次 'saveSession' 覆蓋前的 'loadSession' 檢查。
newSessionId :: Text -> [Id] -> ServiceM Text
newSessionId ty constraints = do
  now <- liftIO getCurrentTime
  newSessionIdAt now ty constraints

-- | 'newSessionId' 的可控時間版本:@now@ 由呼叫端給,而不是內部自己
-- 'getCurrentTime'。__存在的理由是測試__:碰撞重試要能被決定性地驗證,呼叫端
-- 必須能預測某個 @(ty, constraints, now, salt)@ 組合會產生哪個候選 id,再
-- 預先造出那個檔案來構造碰撞——若時間是內部才知道的,這件事做不到。
newSessionIdAt :: UTCTime -> Text -> [Id] -> ServiceM Text
newSessionIdAt now ty constraints = do
  root <- vaultRoot
  go root (0 :: Int)
  where
    go root salt = do
      let candidate = sessionIdCandidate ty constraints now salt
      exists <- liftIO (doesFileExist (snapshotPath root candidate))
      if exists && salt < maxSaltRetries
        then go root (salt + 1)
        else pure candidate

maxSaltRetries :: Int
maxSaltRetries = 5

sessionIdCandidate :: Text -> [Id] -> UTCTime -> Int -> Text
sessionIdCandidate ty constraints now salt =
  "wksp-" <> hex8 low32
  where
    payload =
      T.intercalate
        "\x1f"
        (ty : map renderId constraints ++ [T.pack (show now), T.pack (show salt)])
    low32 = fnv1a64 (TE.encodeUtf8 payload) .&. 0xFFFFFFFF

hex8 :: Word64 -> Text
hex8 w = T.justifyRight 8 '0' (T.pack (showHex w ""))
