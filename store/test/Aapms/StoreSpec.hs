module Aapms.StoreSpec (spec) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Aapms.Core.Id (IdPrefix (PEnt), renderIdPrefix)
import Aapms.Store
  ( StoreError
  , VaultKind (StoryVault)
  , emptyNodeFilter
  , initVaultAt
  , listNodes
  , openVault
  , rebuildIndex
  , renderStoreError
  )
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

  describe "graph-core/F006+F007+F008 cabal 範圍" $
    -- graph-core/F008(Create/Edit/Node/Write)與 graph-core/F007(Tokenize)都已經
    -- 落地,舊版斷言「cabal 原始碼仍不列出 F008 範圍的模組」(2026-08-22 版,F008
    -- 尚未展開時寫的)因此過時、直接與現況矛盾,予以更新:現況是全部模組都已
    -- 列在 exposed-modules 裡。
    it "aapms-store.cabal 原始碼列出 Index/Query/Row/Tokenize/Create/Edit/Node/Write 與 aapms-md 依賴" $ do
      src <- readUtf8Source "aapms-store.cabal"
      mapM_
        (\present -> (present `T.isInfixOf` src) `shouldBe` True)
        [ "Aapms.Store.Index"
        , "Aapms.Store.Query"
        , "Aapms.Store.Row"
        , "Aapms.Store.Tokenize"
        , "Aapms.Store.Create"
        , "Aapms.Store.Edit"
        , "Aapms.Store.Node"
        , "Aapms.Store.Write"
        , "aapms-md"
        ]

  describe "graph-core/F005+F006 門面模組" $
    it "從 Aapms.Store(而非個別子模組)可以 import 並呼叫 openVault/initVaultAt/rebuildIndex/listNodes" $
      withSystemTempDirectory "aapms-store-facade" $ \dir -> do
        initResult <- initVaultAt dir StoryVault "facade"
        case initResult of
          Left e -> expectationFailure (T.unpack (renderStoreError (e :: StoreError)))
          Right _marker -> pure ()
        openResult <- openVault testRegistry dir
        case openResult of
          Right (_handle, _issues) -> do
            rebuildResult <- rebuildIndex _handle
            case rebuildResult of
              Left e -> expectationFailure (T.unpack (renderStoreError (e :: StoreError)))
              Right _issues -> pure ()
            _metas <- listNodes _handle emptyNodeFilter
            pure ()
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
