-- | ULID —— 資源的永久識別碼。
--
-- 為什麼不是自增整數:專案的 @manifest.json@ 會被 commit 進遊戲 repo,
-- 而素材庫可能重建、合併、或未來多人各自匯入。自增整數在這些情境下會撞號。
--
-- 為什麼不是 UUIDv4:ULID 的前 48 bits 是毫秒時間戳,所以**字典序 == 時間序**。
-- 這讓 @ORDER BY ulid@ 免費得到建檔順序,索引也不會因為隨機分佈而碎裂。
--
-- 為什麼自己實作而不用 @ulid@ 套件:只有六十行,而且省掉一個在 GHC 新版本上
-- 可能落後的依賴。編解碼是純函數,用 QuickCheck 測 round-trip 就夠了。
module AssetDB.Id
  ( ULID
  , unULID
  , newULID
  , mkULID
  , renderULID
  , parseULID
  , ulidTimestamp
  , ulidRandomness
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Char (toUpper)
import Data.List (elemIndex)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Word (Word16, Word64)
import System.Random (randomIO)

-- | 128 位元識別碼。內部用 'Integer' 是為了讓位元運算讀起來像規格書;
-- 值域由建構子強制在 @[0, 2^128)@。
newtype ULID = ULID Integer
  deriving stock (Eq, Ord)

instance Show ULID where
  show = T.unpack . renderULID

-- | 取出正規的 26 字元表示。存進 SQLite 與 JSON 的就是這個。
unULID :: ULID -> Text
unULID = renderULID

--------------------------------------------------------------------------------
-- Crockford Base32

-- | 刻意排除 I、L、O、U:前三個與 1/0 混淆,U 是為了避免意外拼出髒話。
alphabet :: String
alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

ulidChars :: Int
ulidChars = 26

-- 26 個字元 × 5 bits = 130 bits,比 128 多 2 bits。
-- 也就是第一個字元只有 3 bits 可用,合法的首字元最大是 '7'。
maxULID :: Integer
maxULID = (1 `shiftL` 128) - 1

timestampBits, randomBits :: Int
timestampBits = 48
randomBits = 80

--------------------------------------------------------------------------------
-- 建構

-- | 由時間戳(毫秒)與 80 位元亂數組出 ULID。純函數,測試用這個。
mkULID
  :: Integer  -- ^ Unix 毫秒時間戳,必須落在 @[0, 2^48)@
  -> Integer  -- ^ 亂數,必須落在 @[0, 2^80)@
  -> Either Text ULID
mkULID ts rnd
  | ts < 0 || ts >= (1 `shiftL` timestampBits) =
      Left $ "ULID 時間戳超出 48 位元範圍:" <> T.pack (show ts)
  | rnd < 0 || rnd >= (1 `shiftL` randomBits) =
      Left $ "ULID 亂數部分超出 80 位元範圍:" <> T.pack (show rnd)
  | otherwise = Right $ ULID ((ts `shiftL` randomBits) .|. rnd)

-- | 以當下時間產生新 ULID。
--
-- 沒有做「同毫秒單調遞增」處理:80 位元亂數在單機掃描的寫入速率下,
-- 同毫秒碰撞機率遠低於磁碟出錯的機率。真的需要嚴格單調時再加。
newULID :: IO ULID
newULID = do
  now <- getPOSIXTime
  hi <- randomIO :: IO Word16
  lo <- randomIO :: IO Word64
  let ts = floor (now * 1000) `mod` (1 `shiftL` timestampBits)
      rnd = (fromIntegral hi `shiftL` 64) .|. fromIntegral lo
  case mkULID ts rnd of
    Right u -> pure u
    -- 上面兩個值都已經被 mod 與型別限制在範圍內,這個分支不可能發生。
    Left err -> errorWithoutStackTrace ("newULID: " <> T.unpack err)

--------------------------------------------------------------------------------
-- 編解碼

renderULID :: ULID -> Text
renderULID (ULID n) =
  T.pack [alphabet !! digitAt i | i <- [ulidChars - 1, ulidChars - 2 .. 0]]
  where
    digitAt i = fromIntegral ((n `shiftR` (5 * i)) .&. 31)

-- | 寬鬆解碼,遵循 Crockford 的建議:接受小寫,並把 @I@/@L@ 視為 @1@、@O@ 視為 @0@。
-- 人工轉抄或從截圖打字時這幾個字元最容易出錯,而放寬不會造成歧義
-- —— 因為 I/L/O 本來就不在字母表裡。
parseULID :: Text -> Either Text ULID
parseULID t
  | T.length t /= ulidChars =
      Left $ "ULID 長度必須是 26,收到 " <> T.pack (show (T.length t)) <> ":" <> t
  | otherwise = do
      digits <- traverse decodeChar (T.unpack t)
      let n = foldl (\acc d -> (acc `shiftL` 5) .|. fromIntegral d) (0 :: Integer) digits
      if n > maxULID
        then Left $ "ULID 超出 128 位元範圍(首字元最大為 '7'):" <> t
        else Right (ULID n)
  where
    decodeChar c =
      let c' = case toUpper c of
            'I' -> '1'; 'L' -> '1'; 'O' -> '0'
            other -> other
       in case elemIndex c' alphabet of
            Just i -> Right i
            Nothing -> Left $ "ULID 含有非法字元 " <> T.pack (show c) <> ":" <> t

--------------------------------------------------------------------------------
-- 取值

ulidTimestamp :: ULID -> UTCTime
ulidTimestamp (ULID n) =
  posixSecondsToUTCTime (fromRational (toRational (n `shiftR` randomBits) / 1000))

ulidRandomness :: ULID -> Integer
ulidRandomness (ULID n) = n .&. ((1 `shiftL` randomBits) - 1)

--------------------------------------------------------------------------------
-- JSON

instance ToJSON ULID where
  toJSON = toJSON . renderULID

instance FromJSON ULID where
  parseJSON = withText "ULID" $ either (fail . T.unpack) pure . parseULID
