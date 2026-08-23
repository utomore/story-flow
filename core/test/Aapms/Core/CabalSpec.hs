-- | graph-core/F001 T13+T14 的對照測試:@.cabal@ 檔案文字層級的斷言。
--
-- __為什麼讀檔案文字而非套件相依圖__:cabal-install 沒有提供「這個套件的
-- build-depends 有沒有某個套件」的程式化查詢介面(要嘛跑 @cabal-plan@,要嘛
-- 剖析 @.cabal@ 檔)。逐字比對已足夠——沿用本 monorepo conflict \/ llm \/
-- service \/ … 已建立的先例。
module Aapms.Core.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

-- | design.md「使用的技術」一節逐字列出的禁用清單:@aapms-core@ 是遊戲本體
-- 會 import 的相依面,不能因為某個 feature 的實作細節悄悄長出重量級套件。
forbidden :: [String]
forbidden =
  [ "direct-sqlite"
  , "toml-reader"
  , "HsYAML-aeson"
  , "HsYAML"
  , "Win32"
  , "sqlite-simple"
  , "zip"
  , "JuicyPixels"
  ]

spec :: Spec
spec = describe "aapms-core.cabal —— graph-core/F001 契約卡驗收" $ do
  it "build-depends 不含 8 項禁用套件(CabalSpec 斷言,驗收標準 6)" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  it "exposed-modules 含 Asset / Pack / License / AnyNode / Naming / Registry" $ do
    txt <- readCabal
    mapM_
      (\m -> (m, m `isInfixOf` txt) `shouldBe` (m, True))
      [ "Aapms.Core.Asset"
      , "Aapms.Core.Pack"
      , "Aapms.Core.License"
      , "Aapms.Core.AnyNode"
      , "Aapms.Core.Naming"
      , "Aapms.Core.Registry"
      ]

  -- graph-core/F002:'Aapms.Core.Registry' 由本 feature 重建(新形狀,見
  -- design.md 契約 C),F001 當時的斷言已過時,只有 'Graph' 仍是永久刪除。
  it "exposed-modules 不含已刪除的 Graph" $ do
    txt <- readCabal
    ("Aapms.Core.Graph", "Aapms.Core.Graph" `isInfixOf` txt) `shouldBe` ("Aapms.Core.Graph", False)

-- | 以 UTF-8 讀,不走系統預設編碼:@.cabal@ 裡有繁中註解,Windows 的預設
-- code page 會在讀到第一個中文字時直接丟 InvalidArgument。測試可能從專案
-- 根目錄或從 @core/@ 底下跑,兩個路徑都試。
readCabal :: IO String
readCabal = go ["aapms-core.cabal", "core/aapms-core.cabal"]
  where
    go [] = fail "找不到 aapms-core.cabal"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok
        then T.unpack . TE.decodeUtf8 <$> BS.readFile c
        else go rest

-- | 只看以逗號開頭的行,避免把註解裡出現的字算進去——本檔的註解就正好提到了
-- 禁用清單的套件名。
dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False
