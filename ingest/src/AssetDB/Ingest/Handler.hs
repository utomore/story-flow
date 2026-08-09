-- | 格式處理器註冊表。
--
-- == 這個模組就是「加音效不需重構」的實作
--
-- 核心資料表不認識「圖片」。一個檔案是什麼、該抽出哪些中繼資料,
-- 全部由這張表決定,而表是一個清單。加入音效 = 往清單 append 一筆 'Handler',
-- 不動 @assets@、不動 @blobs@、不寫 migration。
--
-- kind 專屬的中繼資料一律以 JSON 存進 @meta_json@,所以不同 kind 的欄位
-- 差異(圖片的 width\/height 對音效的 durationMs\/sampleRate)不會反映成
-- 資料表結構的差異。
module AssetDB.Ingest.Handler
  ( Handler (..)
  , handlers
  , handlerFor
  , kindForPath
  , probeContent
  , extensionOf

    -- * 個別處理器(匯出供測試)
  , pngHandler
  , imageHandler
  , audioHandlerStub
  ) where

import AssetDB.Types
import Codec.Picture qualified as P
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Char (toLower)
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

-- | 一種或多種副檔名的處理方式。
data Handler = Handler
  { hName :: Text
  , hExtensions :: [Text]
  -- ^ 一律小寫,含點號。
  , hKind :: AssetKind
  , hProbe :: ByteString -> Maybe Value
  -- ^ 從內容抽出 kind 專屬中繼資料。回傳 'Nothing' 代表這個檔案
  -- 雖然副檔名對得上但內容讀不懂 —— 仍然入庫,只是沒有中繼資料。
  }

-- | **加入新格式只需要動這個清單。**
--
-- 順序有意義:'handlerFor' 取第一個命中的。
handlers :: [Handler]
handlers =
  [ pngHandler
  , imageHandler -- jpg / gif / bmp / tif / webp,尺寸靠 JuicyPixels 盡力而為
  , sourceHandler -- aseprite / psd / xcf:可編輯原始檔,不進遊戲
  , fontHandler
  , levelHandler
  , shaderHandler
  , docHandler
  , archiveHandler
  , audioHandlerStub -- 目前只認副檔名。實作解碼時只改這一筆
  ]

handlerFor :: Text -> Maybe Handler
handlerFor ext = find ((ext `elem`) . hExtensions) handlers

-- | 副檔名不認得時歸為 'KSource' 而不是丟棄。
--
-- 廠商壓縮檔裡什麼都有(.url、.rtf、.unitypackage、.DS_Store)。
-- 丟棄會讓「這包到底有幾個檔案」對不上,之後查帳時無從解釋差額。
kindForPath :: Text -> AssetKind
kindForPath = maybe KSource hKind . handlerFor . extensionOf

probeContent :: Text -> ByteString -> Maybe Value
probeContent path content = do
  h <- handlerFor (extensionOf path)
  hProbe h content

-- | 取小寫副檔名(含點號)。沒有副檔名時回空字串。
extensionOf :: Text -> Text
extensionOf path =
  let leaf = last ("" : T.splitOn "/" path)
   in case T.breakOnEnd "." leaf of
        (pre, suf) | not (T.null pre) && not (T.null suf) -> T.pack (map toLower ('.' : T.unpack suf))
        _ -> ""

--------------------------------------------------------------------------------
-- 圖片

-- | PNG 佔素材庫的 91%,值得走完整的解碼路徑取得色數。
pngHandler :: Handler
pngHandler =
  Handler
    { hName = "png"
    , hExtensions = [".png"]
    , hKind = KImage
    , hProbe = \bs -> do
        img <- either (const Nothing) Just (P.decodePng bs)
        pure (imageMetaJson img (Just (uniqueColours img)))
    }

-- | 其餘點陣格式。只取尺寸與 alpha,不數色數 ——
-- TIFF 與 JPEG 的解碼成本高,而色數只用來區分「手繪」與「色盤像素」風格,
-- 那個判斷對非 PNG 素材沒有實際用途。
imageHandler :: Handler
imageHandler =
  Handler
    { hName = "image"
    , hExtensions = [".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp"]
    , hKind = KImage
    , hProbe = \bs -> do
        img <- either (const Nothing) Just (P.decodeImage bs)
        pure (imageMetaJson img Nothing)
    }

imageMetaJson :: P.DynamicImage -> Maybe Int -> Value
imageMetaJson img colours =
  object $
    [ "width" .= P.dynamicMap P.imageWidth img
    , "height" .= P.dynamicMap P.imageHeight img
    , "hasAlpha" .= hasAlphaChannel img
    ]
      <> maybe [] (\c -> ["colourCount" .= c]) colours

hasAlphaChannel :: P.DynamicImage -> Bool
hasAlphaChannel = \case
  P.ImageRGBA8 _ -> True
  P.ImageRGBA16 _ -> True
  P.ImageYA8 _ -> True
  P.ImageYA16 _ -> True
  _ -> False

-- | 唯一顏色數。
--
-- 這個數字是區分素材風格最便宜的訊號:Cainos 的手繪素材有 2,700+ 色,
-- 像素圖示通常在 32 色以內。它會變成自動標記 @pixel-art@ 與 @hand-painted@
-- 的依據,省下人工標 5,000 個檔案。
--
-- 上限 4096:超過就一定不是色盤像素風,繼續數下去只是浪費時間。
uniqueColours :: P.DynamicImage -> Int
uniqueColours img = go 0 0 Set.empty
  where
    rgba = P.convertRGBA8 img
    w = P.imageWidth rgba
    h = P.imageHeight rgba
    limit = 4096

    go !x !y !acc
      | Set.size acc >= limit = limit
      | y >= h = Set.size acc
      | x >= w = go 0 (y + 1) acc
      | otherwise =
          let P.PixelRGBA8 r g b a = P.pixelAt rgba x y
              key = (fromIntegral r, fromIntegral g, fromIntegral b, fromIntegral a) :: (Int, Int, Int, Int)
           in go (x + 1) y (Set.insert key acc)

--------------------------------------------------------------------------------
-- 其餘格式
--
-- 這些目前只做分類,不抽中繼資料。各自的解析都是獨立的工作項目,
-- 而分類本身已經讓搜尋的 facet 篩選可用。

sourceHandler :: Handler
sourceHandler =
  Handler
    { hName = "source"
    , hExtensions = [".aseprite", ".ase", ".psd", ".psb", ".xcf", ".clip", ".unitypackage"]
    , hKind = KSource
    , hProbe = const Nothing
    }

fontHandler :: Handler
fontHandler =
  Handler
    { hName = "font"
    , hExtensions = [".ttf", ".otf", ".fnt", ".woff", ".woff2"]
    , hKind = KFont
    , hProbe = const Nothing
    }

levelHandler :: Handler
levelHandler =
  Handler
    { hName = "level"
    , hExtensions = [".ldtk", ".tmx", ".tsx"]
    , hKind = KLevel
    , hProbe = const Nothing
    }

shaderHandler :: Handler
shaderHandler =
  Handler
    { hName = "shader"
    , hExtensions = [".glsl", ".frag", ".vert", ".shader", ".hlsl"]
    , hKind = KShader
    , hProbe = const Nothing
    }

docHandler :: Handler
docHandler =
  Handler
    { hName = "doc"
    , hExtensions = [".md", ".txt", ".pdf", ".rtf", ".doc", ".docx", ".url", ".html"]
    , hKind = KDoc
    , hProbe = const Nothing
    }

archiveHandler :: Handler
archiveHandler =
  Handler
    { hName = "archive"
    , hExtensions = [".zip", ".rar", ".7z", ".tar", ".gz"]
    , hKind = KArchive
    , hProbe = const Nothing
    }

-- | 音效目前只認副檔名,不解碼。
--
-- **這一筆存在就是設計正確性的證明**:素材庫現在一個音效檔都沒有,
-- 但音效進來時它會被正確分類、正確索引、正確出現在 facet 篩選裡,
-- 不需要動任何資料表。真正實作解碼(取得 durationMs \/ sampleRate \/ channels)
-- 時,唯一要改的是這裡的 'hProbe'。
audioHandlerStub :: Handler
audioHandlerStub =
  Handler
    { hName = "audio"
    , hExtensions = [".wav", ".ogg", ".mp3", ".flac", ".aiff", ".m4a", ".opus"]
    , hKind = KAudio
    , hProbe = const Nothing
    }
