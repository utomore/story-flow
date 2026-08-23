-- | 跨套件共用的路徑/文字小工具(G-E002)。
--
-- 這些函數原本散落在 ingest / reorg / project / ai / server 各寫一份。
-- 其中兩組是**會咬人的重複**:
--
-- * 'slugify' 決定素材包目錄名與掃描 slug —— 兩份實作若有一份日後修改,
--   pack 目錄名與掃描 slug 會分家;
-- * 'thumbPath' 是縮圖快取的定址規則 —— 產生端(ingest)、讀取端(ai、
--   server)必須是同一套,否則縮圖找不到卻不報錯,是靜默失敗。
--
-- 收進 core 是因為 core 已是所有套件的共同依賴,不引入新耦合。
module AssetDB.PathText
  ( leafOf
  , extensionOf
  , slugify

    -- * 縮圖快取定址
  , ThumbSize (..)
  , thumbSizes
  , thumbSizePx
  , thumbSizeTag
  , thumbPath
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))

-- | 取 @\/@ 分隔路徑的最後一段。空字串回空字串。
leafOf :: Text -> Text
leafOf p = last ("" : T.splitOn "/" p)

-- | 取小寫副檔名(含點號)。沒有副檔名時回空字串。
--
-- 點號後沒有東西(@name.@)也視為沒有副檔名 —— Windows 根本建不出
-- 這種檔名,回 @\".\"@ 只會讓下游拼出以點結尾的名稱。
extensionOf :: Text -> Text
extensionOf path =
  case T.breakOnEnd "." (leafOf path) of
    (pre, suf) | not (T.null pre) && not (T.null suf) -> T.toLower ("." <> suf)
    _ -> ""

-- | 路徑安全的識別字串:小寫化後只留 @[a-z0-9]@,其餘變 @-@ 並收斂連續的 @-@。
--
-- 非 ASCII 字元(如純中文名稱)會被全部丟掉,結果可能是**空字串** ——
-- 呼叫端必須處理,不能假設它有內容(ingest 用 @orElse@ 退回候選、
-- reorg 退回 @unknown@)。
slugify :: Text -> Text
slugify =
  T.intercalate "-"
    . filter (not . T.null)
    . T.splitOn "-"
    . T.map safeChar
    . T.toLower
  where
    safeChar c
      | c `elem` ("abcdefghijklmnopqrstuvwxyz0123456789" :: String) = c
      | otherwise = '-'

--------------------------------------------------------------------------------
-- 縮圖快取定址

-- | 縮圖尺寸。網格用 128,放大檢視與視覺標註用 512。
data ThumbSize = Thumb128 | Thumb512
  deriving stock (Eq, Ord, Enum, Bounded, Show)

thumbSizes :: [ThumbSize]
thumbSizes = [minBound .. maxBound]

thumbSizePx :: ThumbSize -> Int
thumbSizePx = \case Thumb128 -> 128; Thumb512 -> 512

thumbSizeTag :: ThumbSize -> Text
thumbSizeTag = \case Thumb128 -> "128"; Thumb512 -> "512"

-- | 縮圖快取路徑。內容定址(以 blob 的 SHA-256 為鍵),前兩碼分層,
-- 避免單一目錄塞進六千個檔案。
--
-- 產生端(ingest)與讀取端(ai、server)都必須用這一個函式 ——
-- 規則分家的症狀是縮圖找不到卻不報錯。
thumbPath :: FilePath -> Text -> ThumbSize -> FilePath
thumbPath cacheRoot sha size =
  cacheRoot </> T.unpack (T.take 2 sha) </> T.unpack (sha <> "_" <> thumbSizeTag size <> ".png")
