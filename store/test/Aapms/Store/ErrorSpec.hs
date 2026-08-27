-- | graph-core\/F005:六個建構子的 @renderStoreError@ 訊息皆非空、含中文、
-- 說得出下一步,且不洩漏原始 @show@ 痕跡。
module Aapms.Store.ErrorSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Store.Error
import Test.Hspec

-- | 本 feature 的六個建構子。
allErrors :: [(String, StoreError)]
allErrors =
  [ ("VaultMarkerMissing", VaultMarkerMissing "vault/.aapms/config.toml")
  , ("VaultMarkerInvalid", VaultMarkerInvalid "vault/.aapms/config.toml" "缺少必填鍵 name")
  , ("VaultAlreadyInitialized", VaultAlreadyInitialized "vault")
  , ("FileReadFailed", FileReadFailed "vault/characters/琳達.md" "沒有這個檔案")
  , ("FileWriteFailed", FileWriteFailed "vault/characters/琳達.md" "磁碟空間不足")
  , ("SqliteError", SqliteError "database is locked")
  ]

spec :: Spec
spec = describe "graph-core/F005 StoreError" $ do
  describe "六個建構子的訊息" $
    mapM_
      ( \(name, e) -> it (name <> " 的訊息非空、含中文、且不含原始 show 痕跡") $ do
          let msg = renderStoreError e
          msg `shouldNotBe` ""
          msg `shouldSatisfy` hasHan
          mapM_ (\bad -> msg `shouldSatisfy` (not . T.isInfixOf bad)) showTraces
      )
      allErrors

  it "每一則都說得出下一步該做什麼" $
    mapM_
      (\(name, e) -> (name, actionable (renderStoreError e)) `shouldBe` (name, True))
      allErrors

  it "VaultMarkerMissing 提到 vault init" $
    renderStoreError (VaultMarkerMissing "x/.aapms/config.toml")
      `shouldSatisfy` T.isInfixOf "vault init"

  it "VaultMarkerInvalid 把指出的欄位訊息原樣帶出來" $
    renderStoreError (VaultMarkerInvalid "x/.aapms/config.toml" "缺少必填鍵 kind")
      `shouldSatisfy` T.isInfixOf "缺少必填鍵 kind"

  it "VaultAlreadyInitialized 帶出路徑" $
    renderStoreError (VaultAlreadyInitialized "some/root")
      `shouldSatisfy` T.isInfixOf "some/root"

-- | 原始 @show@ 會漏出來的痕跡。
showTraces :: [Text]
showTraces = ["Left", "Right", "Just ", "Nothing", "StoreError", "fromList"]

-- | 訊息裡有沒有「下一步」。既有訊息全部是這個風格。
actionable :: Text -> Bool
actionable msg = any (`T.isInfixOf` msg) ["請", "改用", "可以", "才"]

hasHan :: Text -> Bool
hasHan = T.any (\c -> c >= '\x4e00' && c <= '\x9fff')
