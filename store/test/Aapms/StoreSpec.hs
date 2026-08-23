module Aapms.StoreSpec (spec) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Aapms.Core.Id (IdPrefix (PEnt), renderIdPrefix)
import Aapms.Store (StoreError, VaultKind (StoryVault), initVaultAt, openVault, renderStoreError)
import Aapms.Store.Fixtures (testRegistry)
import System.Directory (doesFileExist)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "aapms-store 骨架" $
    -- entity-graph-core/F001 T5:依賴方向的驗證。entity-graph-core/F004 把佔位的 storeVersion 換成真正的
    -- 門面模組後,這條改以 core 的實際函式證明同一件事。
    it "可 import aapms-core,證明 store → core 的依賴方向已接上" $
      renderIdPrefix PEnt `shouldBe` "ent"

  describe "SQLite 建置環境" $ do
    it "direct-sqlite 已編入 FTS5 且支援 trigram tokenizer" $
      withTrigramTable $ \conn -> do
        rows <-
          query_ conn "SELECT body FROM t WHERE t MATCH '織紋刀'" ::
            IO [Only Text]
        rows `shouldBe` [Only "埃提亞崩塌前的織紋刀"]

    -- trigram 以三字元為索引單位,查詢字串少於 3 個字元一律不命中。
    -- 這不是 flag 沒生效,而是 tokenizer 的固有限制;searchEntities 因此對
    -- 二字詞改走 LIKE 掃描(見 Aapms.Store.SearchSpec)。
    it "查詢字串少於 3 個字元時 trigram 不命中(已知限制)" $
      withTrigramTable $ \conn -> do
        rows <-
          query_ conn "SELECT body FROM t WHERE t MATCH '織紋'" ::
            IO [Only Text]
        rows `shouldBe` []

  describe "graph-core/F005 cabal 範圍" $
    it "aapms-store.cabal 原始碼不再列出移出範圍的模組與 aapms-md 依賴" $ do
      src <- readUtf8Source "aapms-store.cabal"
      mapM_
        (\bad -> (bad `T.isInfixOf` src) `shouldBe` False)
        [ "Aapms.Store.Index"
        , "Aapms.Store.Write"
        , "Aapms.Store.Create"
        , "Aapms.Store.Query"
        , "Aapms.Store.Node"
        , "Aapms.Store.Edit"
        , "Aapms.Store.Row"
        , "aapms-md"
        ]

  describe "graph-core/F005 門面模組" $
    it "從 Aapms.Store(而非個別子模組)可以 import 並呼叫 openVault/initVaultAt" $
      withSystemTempDirectory "aapms-store-facade" $ \dir -> do
        initResult <- initVaultAt dir StoryVault "facade"
        case initResult of
          Left e -> expectationFailure (T.unpack (renderStoreError (e :: StoreError)))
          Right _marker -> pure ()
        openResult <- openVault testRegistry dir
        case openResult of
          Right (_handle, _issues) -> pure ()
          Left e -> expectationFailure (T.unpack (renderStoreError (e :: StoreError)))

-- | 建立一張裝了測試內容的 FTS5 trigram 表。
withTrigramTable :: (Connection -> IO a) -> IO a
withTrigramTable act =
  withConnection ":memory:" $ \conn -> do
    execute_ conn "CREATE VIRTUAL TABLE t USING fts5(body, tokenize='trigram')"
    execute_ conn "INSERT INTO t(body) VALUES ('埃提亞崩塌前的織紋刀')"
    act conn

-- | 讀本套件 @src\/@ 上層的檔案(如 @aapms-store.cabal@)。兩個候選路徑因為
-- @cabal test@ 的工作目錄在套件目錄或專案根不一定相同。
readUtf8Source :: FilePath -> IO Text
readUtf8Source rel = go [rel, "store/" <> rel]
  where
    go [] = fail ("找不到檔案:" <> rel)
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then TE.decodeUtf8 <$> BS.readFile c else go rest
