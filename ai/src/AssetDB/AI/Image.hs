-- | 縮圖檔 → @data:@ URL。
--
-- 這件事單獨成一個模組,是因為它有一個很容易踩到的效能陷阱:512px 的
-- PNG 約 40–120 KB,base64 之後 55–160 KB。若中途經過 'String',那是每張
-- 約兩百萬個 cons cell —— 乘以 6,238 次呼叫。全程走 strict 'ByteString'
-- 與 'Text',只有一個實作,就不會有人不小心寫出第二種。
module AssetDB.AI.Image
  ( thumbPath
  , ThumbSize (..)
  , dataUrl
  , loadThumbDataUrl
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist)
import System.FilePath ((</>))

data ThumbSize = Thumb128 | Thumb512
  deriving stock (Eq, Show)

sizeText :: ThumbSize -> String
sizeText = \case
  Thumb128 -> "128"
  Thumb512 -> "512"

-- | 縮圖快取路徑。內容定址,前兩碼分桶。
--
-- 注意:這與 @server\/src\/AssetDB\/Server\/App.hs@ 的 thumbH 是同一套規則,
-- 目前各寫一份。刻意不為此讓 assetdb-ai 相依 assetdb-ingest —— 那會把
-- JuicyPixels 與 zip 拖進伺服器,代價遠大於這幾行重複。
thumbPath :: FilePath -> Text -> ThumbSize -> FilePath
thumbPath cacheRoot sha size =
  cacheRoot </> T.unpack (T.take 2 sha) </> T.unpack sha <> "_" <> sizeText size <> ".png"

-- | 組成 @data:image\/png;base64,…@。全程 strict,不經過 'String'。
dataUrl :: BS.ByteString -> Text
dataUrl bytes = "data:image/png;base64," <> TE.decodeUtf8 (B64.encode bytes)

-- | 讀縮圖並編碼。檔案不存在時回傳 'Nothing' —— 那不是錯誤,是
-- 「這份內容還沒產生縮圖」,呼叫端應該把它記成 skipped 而不是 failed。
loadThumbDataUrl :: FilePath -> Text -> ThumbSize -> IO (Maybe Text)
loadThumbDataUrl cacheRoot sha size = do
  let p = thumbPath cacheRoot sha size
  ok <- doesFileExist p
  if not ok
    then pure Nothing
    else Just . dataUrl <$> BS.readFile p
