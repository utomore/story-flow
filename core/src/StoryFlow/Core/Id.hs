-- | 實體識別碼與跨 Vault 定址。
--
-- ID 的格式是 @\<prefix\>-\<8 位小寫十六進位\>@,由 FNV-1a 64-bit 對
-- 「內容 + 時間 + salt」雜湊後取低 32 位產生。本模組零 IO:時間由呼叫端提供,
-- 唯一性由持有索引的那一層(entity-graph-core/F004 的 store)以 salt 遞增重試保證。
module StoryFlow.Core.Id
  ( -- * 前綴
    IdPrefix (..)
  , renderIdPrefix
  , parseIdPrefix

    -- * ID
  , Id
  , mkId
  , parseId
  , renderId
  , idPrefix

    -- * 跨 Vault 參照
  , Ref (..)
  , localRef
  , parseRef
  , renderRef

    -- * 錯誤
  , IdError (..)

    -- * 雜湊
  , fnv1a64
  ) where

import Data.Bits (xor, (.&.))
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime)
import Data.Word (Word64, Word8)
import qualified Data.ByteString as BS
import Numeric (showHex)

-- | ID 前綴,決定這個識別碼指的是哪一種實體。
data IdPrefix
  = PEnt
  | PLvl
  | PNod
  | PVlt
  deriving stock (Show, Eq, Ord, Enum, Bounded)

renderIdPrefix :: IdPrefix -> Text
renderIdPrefix = \case
  PEnt -> "ent"
  PLvl -> "lvl"
  PNod -> "nod"
  PVlt -> "vlt"

parseIdPrefix :: Text -> Either IdError IdPrefix
parseIdPrefix t = case t of
  "ent" -> Right PEnt
  "lvl" -> Right PLvl
  "nod" -> Right PNod
  "vlt" -> Right PVlt
  _ -> Left (UnknownIdPrefix t)

-- | 全域唯一識別碼。建構子不外露——只能透過 'mkId' 或 'parseId' 取得。
--
-- 不變量:@\<prefix\>-\<1 至 8 位小寫十六進位\>@。'mkId' __一律__產生 8 位;
-- 'parseId' 放寬到 1–8 位,因為 system.md 全篇的範例(@ent-7f3a@、
-- @nod-0001@)與作者手寫的 @{#ent-7f3b}@ 錨點都是短寫,解析端拒收它們會讓
-- 文件自己的範例檔變成非法輸入。
newtype Id = Id Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data IdError
  = -- | 整體格式不符 @\<prefix\>-\<8 hex\>@
    BadIdFormat Text
  | -- | 前綴不是 ent / lvl / nod / vlt
    UnknownIdPrefix Text
  | -- | 參照字串格式不符 @id@ 或 @vault:id@
    BadRefFormat Text
  deriving stock (Show, Eq)

-- | 由前綴、內容、時間、salt 產生 ID。純函式:相同輸入必得相同輸出。
--
-- @salt@ 供碰撞重試使用——呼叫端查索引發現 ID 已存在時 @salt + 1@ 重算。
-- core 只保證「相同輸入穩定、不同輸入分散」,唯一性不在這一層。
mkId :: IdPrefix -> Text -> UTCTime -> Int -> Id
mkId p content t salt =
  Id (renderIdPrefix p <> "-" <> hex8 low32)
  where
    payload =
      T.intercalate "\x1f" [content, T.pack (show t), T.pack (show salt)]
    low32 = fnv1a64 (TE.encodeUtf8 payload) .&. 0xFFFFFFFF

-- | 固定寬度 8 的小寫十六進位。
hex8 :: Word64 -> Text
hex8 w = T.justifyRight 8 '0' (T.pack (showHex w ""))

-- | FNV-1a 64-bit。選它而非 SHA-256 的理由:core 要維持零重量級依賴,
-- 而 ID 不需要密碼學強度,只要夠分散且可重現。
fnv1a64 :: BS.ByteString -> Word64
fnv1a64 = BS.foldl' step 0xcbf29ce484222325
  where
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 0x00000100000001b3

renderId :: Id -> Text
renderId (Id t) = t

-- | 解析 ID 字串,同時回傳它的前綴。接受 1–8 位小寫十六進位(見 'Id' 的說明)。
parseId :: Text -> Either IdError (IdPrefix, Id)
parseId t = case T.splitOn "-" t of
  [p, h]
    | T.length h >= 1
    , T.length h <= 8
    , T.all isHexLower h -> do
        pre <- parseIdPrefix p
        pure (pre, Id t)
  _ -> Left (BadIdFormat t)

-- | 取出 ID 的前綴。'Id' 的不變量保證這裡一定解析得出來,
-- 因此回傳 'IdPrefix' 而非 @Maybe IdPrefix@。
idPrefix :: Id -> IdPrefix
idPrefix (Id t) = either (const PEnt) fst (parseId t)
{-# INLINE idPrefix #-}

isHexLower :: Char -> Bool
isHexLower c = isDigit c || (c >= 'a' && c <= 'f')

-- | 對某個實體的參照。@refVault = Nothing@ 表示本 Vault。
--
-- 所有關聯的 target 都是 'Ref' 而非 'Id'——跨 Vault 引用(ADR-008)從型別上
-- 就是一等公民,不是後補的字串慣例。
data Ref = Ref
  { refVault :: Maybe Text
  , refId :: Id
  }
  deriving stock (Show, Eq, Ord)

-- | 本 Vault 內的參照。
localRef :: Id -> Ref
localRef = Ref Nothing

-- | 解析 @"ent-7f3a"@ 或 @"shared-lore:ent-7f3a"@。
parseRef :: Text -> Either IdError Ref
parseRef t = case T.splitOn ":" t of
  [i] -> Ref Nothing . snd <$> parseId i
  [v, i]
    | not (T.null v) -> Ref (Just v) . snd <$> parseId i
  _ -> Left (BadRefFormat t)

renderRef :: Ref -> Text
renderRef Ref {..} = maybe "" (<> ":") refVault <> renderId refId
