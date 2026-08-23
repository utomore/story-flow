-- | 契約 6:命名文法(ADR-019)——合法 / 非法名稱集。
--
-- 名稱集放在 @fixtures/naming-cases.txt@,是 P1 F002(registry-family-and-naming)的驗收輸入。
-- 實作還不存在(P0 只有 legacy/assetdb 裡的舊版),所以逐案驗證標成 pending;
-- 現在就能守的是:名稱集本身格式正確、兩邊都非空。
module Aapms.Contract.NamingGrammarSpec (spec) where

import Data.Char (isSpace)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.List (isPrefixOf)
import Test.Hspec

casesPath :: FilePath
casesPath = "fixtures/naming-cases.txt"

data Case = Ok String | Bad String deriving stock (Show, Eq)

parseCases :: String -> Either String [Case]
parseCases = traverse one . filter keep . map trimComment . lines
  where
    keep l = not (null (trim l)) && not ("#" `isPrefixOf` trim l)
    one l = case words l of
      ("ok" : n : _) -> Right (Ok n)
      ("bad" : n : _) -> Right (Bad n)
      _ -> Left ("看不懂的行:" <> l)
    -- 行尾註解(第一個 " #" 之後)丟掉,但名稱本身不含 #
    trimComment l = case breakOn " #" l of (a, _) -> a
    breakOn pat s = go [] s
      where
        go acc r@(c : cs) | pat `isPrefixOf` r = (reverse acc, r) | otherwise = go (c : acc) cs
        go acc [] = (reverse acc, [])
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

spec :: Spec
spec = describe "命名文法名稱集" $ do
  it "fixtures/naming-cases.txt 格式正確,合法與非法各至少一筆" $ do
    src <- readUtf8 casesPath
    case parseCases src of
      Left e -> expectationFailure e
      Right cs -> do
        length [() | Ok _ <- cs] `shouldSatisfy` (> 0)
        length [() | Bad _ <- cs] `shouldSatisfy` (> 0)

  it "契約卡的代表案例在名稱集裡" $ do
    src <- readUtf8 casesPath
    either (const []) id (parseCases src) `shouldSatisfy` (Ok "ui_gui_travel-book-frame_001" `elem`)

  it "逐案以 aapms 驗證(等 graph-core F002 落地)" $
    pendingWith "P1 F002 registry-family-and-naming 實作後,改為逐行呼叫 aapms 驗證"

readUtf8 :: FilePath -> IO String
readUtf8 p = T.unpack . TE.decodeUtf8 <$> BS.readFile p
