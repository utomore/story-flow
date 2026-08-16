-- | YAML → aeson 'Value' → core 的 @FromJSON@。
--
-- 解析方向用 __HsYAML + HsYAML-aeson__(純 Haskell,無 C 相依),把 YAML 轉成
-- aeson 'Value' 之後__一律__套用 "StoryFlow.Core.Json" 的實例——編碼規則因此
-- 全系統只有一份。序列化方向不用 YAML 編碼器,見 "StoryFlow.Md.Render"。
--
-- 唯一的表層語法糖是 @timeline@(func-0003 實作備註 1):architecture.md 的範例
-- 寫 @timeline: 埃提亞崩塌前@,而 core 的 @FromJSON Timeline@ 吃的是
-- @{label, order}@ 物件。這裡在 'Value' 層把字串補成 @{label: ...}@ 再交給 core,
-- 規則仍然只有一份,只是接受一種簡寫。
module StoryFlow.Md.Yaml
  ( -- * 低階
    decodeValue
  , fromValue
  , missingFields
  , requiredFrontFields

    -- * 兩個入口
  , decodeFrontmatter
  , decodeMeta
  , decodeFrontmatterAt
  , decodeMetaAt
  ) where

import Data.Aeson (FromJSON, Result (..), Value (..), fromJSON, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.YAML (Pos (..))
import qualified Data.YAML.Aeson as YA
import StoryFlow.Core.Json ()
import StoryFlow.Core.Meta (Meta)
import StoryFlow.Md.Inherit (MetaOverride)

-- | 解析一段 YAML 成 aeson 'Value'。錯誤帶 YAML 內部的行號(1 起算)。
--
-- 全空白或只有註解的內容視為空物件——frontmatter 只寫註解不該讓整份檔案讀不出來。
decodeValue :: Text -> Either (Int, Text) Value
decodeValue t
  | isBlankYaml t = Right (Object KM.empty)
  | otherwise = case YA.decode1 (BL.fromStrict (TE.encodeUtf8 t)) of
      Left (pos, msg) -> Left (posLine pos, T.pack msg)
      Right v -> Right (sugar v)

-- | 只有空白行與 @#@ 註解行。
isBlankYaml :: Text -> Bool
isBlankYaml = all blank . T.lines
  where
    blank l = let s = T.stripStart l in T.null s || "#" `T.isPrefixOf` s

-- | 表層語法糖:@timeline@ 為純字串時補成 @{label: ...}@。
sugar :: Value -> Value
sugar (Object o) = Object $ case KM.lookup "timeline" o of
  Just (String s) -> KM.insert "timeline" (object ["label" .= s]) o
  _ -> o
sugar v = v

fromValue :: (FromJSON a) => Value -> Either Text a
fromValue v = case fromJSON v of
  Success a -> Right a
  Error e -> Left (T.pack e)

-- | 檔案層 frontmatter 的必填欄位。core 的 @FromJSON Meta@ 對這六個用 @.:@,
-- 少一個就會得到 aeson 的通用訊息;先自己檢查才報得出 'RequiredFieldMissing'。
requiredFrontFields :: [Text]
requiredFrontFields = ["id", "vault", "type", "title", "created", "updated"]

-- | 給定必填欄位清單,列出 'Value' 裡缺哪些(非物件視為全缺)。
missingFields :: [Text] -> Value -> [Text]
missingFields req (Object o) = [f | f <- req, not (KM.member (K.fromText f) o)]
missingFields req _ = req

decodeFrontmatterAt :: Text -> Either (Int, Text) Meta
decodeFrontmatterAt t = decodeValue t >>= first (1,) . fromValue

decodeMetaAt :: Text -> Either (Int, Text) MetaOverride
decodeMetaAt t = decodeValue t >>= first (1,) . fromValue

-- | func-0003 「新增的介面」表列的簽名;丟掉行號的版本。
decodeFrontmatter :: Text -> Either Text Meta
decodeFrontmatter = first snd . decodeFrontmatterAt

-- | 同上,用於 @```meta@ 區塊。
decodeMeta :: Text -> Either Text MetaOverride
decodeMeta = first snd . decodeMetaAt
