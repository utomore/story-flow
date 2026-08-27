-- | graph-core\/F005:@readMarker@\/@initVaultAt@\/@openVault@\/@closeVault@。
module Aapms.Store.MarkerSpec (spec) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Only (..), execute_, query_)
import Aapms.Core.Id (VaultId (..))
import Aapms.Core.Registry (listTypes)
import Aapms.Store.Error (StoreError (..), renderStoreError)
import Aapms.Store.Fixtures (orDie, testRegistry, withTempVault)
import Aapms.Store.Marker
import Aapms.Store.Schema (VaultKind (..), indexTables)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "graph-core/F005 vault marker" $ do
  describe "initVaultAt" $ do
    it "寫出 .aapms/config.toml 與空索引,四欄可被 readMarker 讀回" $
      withTempVault $ \dir -> do
        marker <- orDie =<< initVaultAt dir AssetVault "alchbees-assets"
        vmKind marker `shouldBe` AssetVault
        vmName marker `shouldBe` "alchbees-assets"
        vmRefs marker `shouldBe` []
        let VaultId idText = vmId marker
        T.isPrefixOf "vlt-" idText `shouldBe` True

        doesFileExist (configPath dir) `shouldReturn` True
        reread <- orDie =<< readMarker dir
        reread `shouldBe` marker

        doesFileExist (indexDbPath dir) `shouldReturn` True

    it "對已有 marker 的目錄再次呼叫是錯誤,且不覆寫原有 config" $
      withTempVault $ \dir -> do
        _ <- orDie =<< initVaultAt dir StoryVault "liftgame"
        original <- BS.readFile (configPath dir)
        r <- initVaultAt dir StoryVault "另一個名字"
        r `shouldBe` Left (VaultAlreadyInitialized dir)
        again <- BS.readFile (configPath dir)
        again `shouldBe` original

  describe "readMarker" $ do
    it "目錄沒有 marker 時回 VaultMarkerMissing,且不建立任何檔案" $
      withTempVault $ \dir -> do
        r <- readMarker dir
        case r of
          Left (VaultMarkerMissing _) -> pure ()
          other -> expectationFailure ("預期 VaultMarkerMissing,得到 " <> show other)
        doesDirectoryExist (markerDir dir) `shouldReturn` False

    it "缺少 id 時回 VaultMarkerInvalid,訊息含 id" $
      withTempVault $ \dir ->
        expectInvalidField dir "kind = \"asset\"\nname = \"a\"\nrefs = []\n" "id"

    it "id 前綴不對時回 VaultMarkerInvalid,訊息含 id" $
      withTempVault $ \dir ->
        expectInvalidField
          dir
          "id = \"ent-7f3b2a91\"\nkind = \"asset\"\nname = \"a\"\nrefs = []\n"
          "id"

    it "缺少 kind 時回 VaultMarkerInvalid,訊息含 kind" $
      withTempVault $ \dir ->
        expectInvalidField dir "id = \"vlt-7f3b2a91\"\nname = \"a\"\nrefs = []\n" "kind"

    it "kind 值不對時回 VaultMarkerInvalid,訊息含 kind" $
      withTempVault $ \dir ->
        expectInvalidField
          dir
          "id = \"vlt-7f3b2a91\"\nkind = \"other\"\nname = \"a\"\nrefs = []\n"
          "kind"

    it "缺少 name 時回 VaultMarkerInvalid,訊息含 name" $
      withTempVault $ \dir ->
        expectInvalidField dir "id = \"vlt-7f3b2a91\"\nkind = \"asset\"\nrefs = []\n" "name"

  describe "openVault / closeVault" $ do
    it "對合法 marker 開起 handle,關閉後連線失效" $
      withTempVault $ \dir -> do
        marker <- orDie =<< initVaultAt dir StoryVault "liftgame"
        (handle, _issues) <- orDie =<< openVault testRegistry dir
        vhMarker handle `shouldBe` marker
        vhRoot handle `shouldSatisfy` (\r -> not (null r))

        -- schema_version(createSchema)+ vault_id/vault_kind/vault_name(setVaultInfo)
        rows <- query_ (vhConn handle) "SELECT count(*) FROM meta_info" :: IO [Only Int]
        rows `shouldBe` [Only 4]

        closeVault handle
        execute_ (vhConn handle) "SELECT 1" `shouldThrow` anyException

    -- D9:註冊表併入 VaultHandle,由呼叫端經 openVault 的第一個參數傳入,
    -- 不是 openVault 自己載入的——這裡只驗證「原樣收下、原樣放進 vhRegistry」。
    it "openVault 把呼叫端給的 TypeRegistry 原樣放進 vhRegistry(D9)" $
      withTempVault $ \dir -> do
        _ <- orDie =<< initVaultAt dir StoryVault "liftgame"
        (handle, _issues) <- orDie =<< openVault testRegistry dir
        listTypes (vhRegistry handle) `shouldBe` listTypes testRegistry
        closeVault handle

  describe "沒有任何程式路徑探測或讀中樞註冊表(驗收標準 6)" $
    it "Marker.hs 原始碼不含探測相關字串" $ do
      src <- readUtf8Source "Aapms/Store/Marker.hs"
      mapM_
        (\bad -> (bad `T.isInfixOf` src) `shouldBe` False)
        ["XdgConfig", "getXdgDirectory", "searchUp", "vaults.toml", "AAPMS_HOME"]

  describe "indexTables(graph-core/F007 擴充後)" $
    it "15 張表(F006 的 12 張 + F007 的 fts_tri/fts_cjk/fts_map),meta_info 仍是第一張,\
       \fts_map 是最後一張" $ do
      length indexTables `shouldBe` 15
      take 1 indexTables `shouldBe` ["meta_info"]
      -- D3(resetSchema 以反向順序 DROP,fts_map 要排最後,先砍掉建在它上面的觸發器)
      drop 14 indexTables `shouldBe` ["fts_map"]

-- | 手寫一份 marker 檔(略過 initVaultAt),驗證 'readMarker' 對壞欄位的訊息。
expectInvalidField :: FilePath -> Text -> Text -> IO ()
expectInvalidField dir raw keyword = do
  createDirectoryIfMissing True (markerDir dir)
  BS.writeFile (configPath dir) (TE.encodeUtf8 raw)
  r <- readMarker dir
  case r of
    Left e@(VaultMarkerInvalid _ msg) -> do
      msg `shouldSatisfy` T.isInfixOf keyword
      renderStoreError e `shouldSatisfy` (not . T.null)
    other -> expectationFailure ("預期 VaultMarkerInvalid,得到 " <> show other)

-- | 讀本套件 @src\/@ 底下的原始碼檔,對照舊 'Aapms.Store.VaultSpec' 的手法:
-- 兩個候選路徑因為 @cabal test@ 的工作目錄在套件目錄或專案根不一定相同。
readUtf8Source :: FilePath -> IO Text
readUtf8Source rel = go ["src" </> rel, "store" </> "src" </> rel]
  where
    go [] = fail ("找不到原始碼檔:" <> rel)
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then TE.decodeUtf8 <$> BS.readFile c else go rest
