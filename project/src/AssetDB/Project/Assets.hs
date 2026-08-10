-- | 產生 @Assets.hs@ —— 型別安全的素材 key。
--
-- == 為什麼值得產生一個模組
--
-- 遊戲的載入器是 @HashMap Text Texture@,查表用字串。字串打錯的後果是
-- **執行期黑畫面**,而且通常在展示前五分鐘才發現。
--
-- 產生一個模組之後,打錯變成編譯錯誤;而且 IDE 的 find-references 直接
-- 回答「這個專案用了哪些素材、每個素材用在哪裡」—— 那是資料夾與試算表
-- 都給不出的答案。
module AssetDB.Project.Assets
  ( AssetRef (..)
  , renderAssetsModule
  , haskellIdent
  ) where

import Data.Char (isDigit, toUpper)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T

data AssetRef = AssetRef
  { arKey :: Text
  -- ^ 邏輯名稱,也是載入器的查表 key。
  , arPath :: Text
  -- ^ 專案內的相對路徑。
  , arPack :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | 邏輯名稱 → Haskell 識別字。
--
-- @ui_gui_travel-book-frame_01a@ → @uiGuiTravelBookFrame01a@
--
-- 開頭是數字時前置底線 —— Haskell 的識別字不能以數字開頭,
-- 而 @00.png@ 這種檔名在素材庫裡真的存在。
haskellIdent :: Text -> Text
haskellIdent name =
  case T.uncons camel of
    Just (c, _) | isDigit c -> "_" <> camel
    _ -> camel
  where
    parts = filter (not . T.null) (T.split (\c -> c == '_' || c == '-') name)
    camel = case parts of
      [] -> "_unnamed"
      (p : ps) -> T.concat (T.toLower p : map capitalise ps)
    capitalise t = case T.uncons t of
      Just (c, rest) -> T.cons (toUpper c) rest
      Nothing -> t

renderAssetsModule :: Text -> [AssetRef] -> Text
renderAssetsModule projectName refs =
  T.unlines $
    header <> concatMap entry (dedupe (sortOn arKey refs))
  where
    header =
      [ "-- | " <> projectName <> " 的素材 key。"
      , "--"
      , "-- **由 assetdb 產生,請勿手動編輯。** 重新產生:"
      , "--"
      , "-- @assetdb project sync@"
      , "--"
      , "-- 用這些常數而不是字串字面值:打錯是編譯錯誤,不是執行期黑畫面。"
      , "module Assets where"
      , ""
      , "import AssetDB.Manifest (AssetKey (..))"
      , ""
      ]

    entry r =
      [ "-- | @" <> arPath r <> "@" <> maybe "" (\p -> "  (" <> p <> ")") (arPack r)
      , haskellIdent (arKey r) <> " :: AssetKey"
      , haskellIdent (arKey r) <> " = AssetKey " <> T.pack (show (arKey r))
      , ""
      ]

    -- 兩個不同的邏輯名稱可能轉出同一個識別字(travel-book 與 travel_book)。
    -- 命名文法保證邏輯名稱唯一,但不保證識別字唯一,所以這裡要去重
    -- —— 產生重複定義的模組根本編不過。
    dedupe = go []
      where
        go _ [] = []
        go seen (x : xs)
          | haskellIdent (arKey x) `elem` seen = go seen xs
          | otherwise = x : go (haskellIdent (arKey x) : seen) xs
