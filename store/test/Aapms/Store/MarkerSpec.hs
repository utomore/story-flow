-- | graph-core\/F005:@readMarker@\/@initVaultAt@\/@openVault@\/@closeVault@。
--
-- graph-core\/E002(@initVaultAtWith@ 的明碼時間版本,兼修 @initVaultAt@ 的
-- @IOException@ 逸出)的測試併入同一個 describe 區塊,對照表見下方
-- \"graph-core\/E002 initVaultAtWith\" 區塊開頭的註解
-- (@.design\/subsystems\/graph-core\/enhancements\/E002-init-vault-at-explicit-time.md@)。
module Aapms.Store.MarkerSpec (spec) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time
  ( Day (ModifiedJulianDay)
  , UTCTime (..)
  , fromGregorian
  , getCurrentTime
  , secondsToDiffTime
  )
import Database.SQLite.Simple (Only (..), execute_, query_)
import Hedgehog (Gen, assert, evalIO, forAll, (/==), (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.Id (IdPrefix (PVlt), VaultId (..), newId, renderId)
import Aapms.Core.Registry (listTypes)
import Aapms.Store.Error (StoreError (..), renderStoreError)
import Aapms.Store.Fixtures (orDie, testRegistry, withTempVault)
import Aapms.Store.Marker
import Aapms.Store.Schema (VaultKind (..), indexTables)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , makeAbsolute
  )
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

  -- E002 · spec 對照
  -- (.design/subsystems/graph-core/enhancements/E002-init-vault-at-explicit-time.md)
  -- R1    initVaultAt 成功後四欄符合(id 格式/kind/name/refs)                 -> "R1: ..."   [綠]
  -- R2a   已有 marker,initVaultAt 回 VaultAlreadyInitialized,檔案逐位元組不變 -> "R2a: ..."  [綠]
  -- R2b   已有 marker,initVaultAtWith 同樣回 VaultAlreadyInitialized、不變    -> "R2b: ..."  [紅]
  -- R3    initVaultAt 成功後 index.db 存在且 openVault 開得起來               -> "R3: ..."   [綠]
  -- R4    initVaultAt 簽名逐字比對(骨架原文自身承載)                         -> "R4: ..."   [綠]
  -- R5    同名連續兩次 initVaultAt(不同空目錄)vmId 不同                      -> "R5: ..."   [綠]
  -- L1    initVaultAtWith 決定性:同 (kind,name,t) 兩個空目錄 vmId 相同        -> "L1: ..."   [紅]
  -- L2    initVaultAtWith 的 vmId == newId 可獨立算出                        -> "L2: ..."   [紅]
  -- L3    initVaultAt 與 initVaultAtWith 除 vmId 外逐欄相同、檔案集合一致     -> "L3: ..."   [紅]
  -- L4    initVaultAt 對父層被佔用的路徑不拋 IOException                     -> "L4: ..."   [紅]
  -- L4b   initVaultAtWith 對父層被佔用的路徑不拋 IOException                 -> "L4b: ..."  [紅]
  -- L5/E5 父層被一般檔案佔住,initVaultAt 回 Left (FileWriteFailed …),msg 非空 -> "E5: ..."   [紅]
  -- E1    = 現況,已由上方「initVaultAt」describe 涵蓋(F005 既有測試)         -> 既有測試   [綠]
  -- E2    initVaultAtWith 撞號可重現(L1 的具名版本)                          -> "E2: ..."   [紅]
  -- E3    initVaultAtWith 的期望值可獨立算出(L2 的具名版本)                  -> "E3: ..."   [紅]
  -- E4    = 現況,已由上方「initVaultAt」describe 涵蓋(F005 既有測試)         -> 既有測試   [綠]
  -- E6    同 E5,改呼叫 initVaultAtWith,回傳與 E5 逐欄相同的 Left            -> "E6: ..."   [紅]
  describe "graph-core/E002 initVaultAtWith" $ do
    describe "回歸 law(R1-R5:initVaultAt 的現有行為不得變動)" $ do
      it "R1: 任意空目錄/kind/非空 name,initVaultAt 成功後 config.toml 讀回的四欄符合" $
        hedgehog $ do
          kind <- forAll genKind
          name <- forAll genName
          reread <- evalIO $ withTempVault $ \dir -> do
            _ <- orDie =<< initVaultAt dir kind name
            orDie =<< readMarker dir
          vmKind reread === kind
          vmName reread === name
          vmRefs reread === []
          let VaultId idText = vmId reread
          assert (isVltIdText idText)

      it "R2a: 已有 marker 的目錄再次呼叫 initVaultAt 回 VaultAlreadyInitialized,\
         \且底下每個檔案逐位元組不變" $
        hedgehog $ do
          kind1 <- forAll genKind
          name1 <- forAll genName
          kind2 <- forAll genKind
          name2 <- forAll genName
          (result, before, after, absDir) <- evalIO $ withTempVault $ \dir -> do
            _ <- orDie =<< initVaultAt dir kind1 name1
            snap0 <- snapshotDir dir
            r <- initVaultAt dir kind2 name2
            snap1 <- snapshotDir dir
            ad <- makeAbsolute dir
            pure (r, snap0, snap1, ad)
          result === Left (VaultAlreadyInitialized absDir)
          after === before

      it "R2b: 已有 marker 的目錄呼叫 initVaultAtWith 同樣回 VaultAlreadyInitialized,\
         \且底下每個檔案逐位元組不變(骨架未實作,預期紅)" $
        hedgehog $ do
          kind1 <- forAll genKind
          name1 <- forAll genName
          kind2 <- forAll genKind
          name2 <- forAll genName
          t <- forAll genTime
          (result, before, after, absDir) <- evalIO $ withTempVault $ \dir -> do
            _ <- orDie =<< initVaultAt dir kind1 name1
            snap0 <- snapshotDir dir
            r <- initVaultAtWith dir kind2 name2 t
            snap1 <- snapshotDir dir
            ad <- makeAbsolute dir
            pure (r, snap0, snap1, ad)
          result === Left (VaultAlreadyInitialized absDir)
          after === before

      it "R3: initVaultAt 成功後 index.db 存在,且 openVault 開得起來" $
        withTempVault $ \dir -> do
          _ <- orDie =<< initVaultAt dir StoryVault "liftgame"
          doesFileExist (indexDbPath dir) `shouldReturn` True
          (handle, _issues) <- orDie =<< openVault testRegistry dir
          closeVault handle

      it "R4: initVaultAt 的型別簽名逐字等於 \
         \FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)(骨架原文自身承載)" $ do
        let _typeCheck :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
            _typeCheck = initVaultAt
        True `shouldBe` True

      it "R5: 同一個 name 連續兩次呼叫 initVaultAt(不同空目錄),vmId 不同" $
        hedgehog $ do
          kind <- forAll genKind
          name <- forAll genName
          (id1, id2) <- evalIO $
            withTempVault $ \d1 ->
              withTempVault $ \d2 -> do
                m1 <- orDie =<< initVaultAt d1 kind name
                m2 <- orDie =<< initVaultAt d2 kind name
                pure (vmId m1, vmId m2)
          id1 /== id2

    describe "新 law(L1-L5:initVaultAtWith,骨架未實作,預期紅)" $ do
      it "L1: 任意 kind/name/t,兩個不同空目錄各呼叫一次 initVaultAtWith,vmId 相同" $
        hedgehog $ do
          kind <- forAll genKind
          name <- forAll genName
          t <- forAll genTime
          (m1, m2) <- evalIO $
            withTempVault $ \d1 ->
              withTempVault $ \d2 -> do
                r1 <- orDie =<< initVaultAtWith d1 kind name t
                r2 <- orDie =<< initVaultAtWith d2 kind name t
                pure (r1, r2)
          vmId m1 === vmId m2

      it "L2: initVaultAtWith 成功時 vmId == VaultId (renderId (newId PVlt name t 0))" $
        hedgehog $ do
          kind <- forAll genKind
          name <- forAll genName
          t <- forAll genTime
          marker <- evalIO $ withTempVault $ \dir -> orDie =<< initVaultAtWith dir kind name t
          vmId marker === VaultId (renderId (newId PVlt name t 0))

      it "L3: initVaultAt 與 initVaultAtWith(任意 t)的結果除 vmId 外逐欄相同,\
         \落地檔案相對路徑集合一致" $
        hedgehog $ do
          kind <- forAll genKind
          name <- forAll genName
          t <- forAll genTime
          (mAt, filesAt, mWith, filesWith) <- evalIO $
            withTempVault $ \dAt ->
              withTempVault $ \dWith -> do
                mA <- orDie =<< initVaultAt dAt kind name
                fA <- snapshotDir dAt
                mW <- orDie =<< initVaultAtWith dWith kind name t
                fW <- snapshotDir dWith
                pure (mA, fA, mW, fW)
          vmKind mAt === vmKind mWith
          vmName mAt === vmName mWith
          vmRefs mAt === vmRefs mWith
          map fst filesAt === map fst filesWith

      it "L4: initVaultAt 對父層被一般檔案佔住的路徑不拋 IOException" $
        withTempVault $ \dir -> do
          let blockerPath = dir </> "blocker"
          writeFile blockerPath "not a directory"
          outcome <-
            try (initVaultAt (blockerPath </> "sub") StoryVault "liftgame") ::
              IO (Either IOException (Either StoreError VaultMarker))
          case outcome of
            Left ex -> expectationFailure ("initVaultAt 拋出 IOException:" <> show ex)
            Right (Left _) -> pure ()
            Right (Right v) -> expectationFailure ("預期 Left,得到 Right " <> show v)

      it "L4b: initVaultAtWith 對父層被一般檔案佔住的路徑不拋 IOException" $
        withTempVault $ \dir -> do
          now <- getCurrentTime
          let blockerPath = dir </> "blocker"
          writeFile blockerPath "not a directory"
          outcome <-
            try (initVaultAtWith (blockerPath </> "sub") StoryVault "liftgame" now) ::
              IO (Either IOException (Either StoreError VaultMarker))
          case outcome of
            Left ex -> expectationFailure ("initVaultAtWith 拋出 IOException:" <> show ex)
            Right (Left _) -> pure ()
            Right (Right v) -> expectationFailure ("預期 Left,得到 Right " <> show v)

      it "E5/L5: 父層被一般檔案佔住,initVaultAt 回 Left (FileWriteFailed (markerDir root) msg),\
         \msg 非空,不拋例外" $
        withTempVault $ \dir -> do
          let blockerPath = dir </> "blocker"
              subPath = blockerPath </> "sub"
          writeFile blockerPath "not a directory"
          absSub <- makeAbsolute subPath
          outcome <-
            try (initVaultAt subPath StoryVault "liftgame") ::
              IO (Either IOException (Either StoreError VaultMarker))
          case outcome of
            Left ex -> expectationFailure ("拋出 IOException:" <> show ex)
            Right (Left (FileWriteFailed fp msg)) -> do
              fp `shouldBe` markerDir absSub
              T.null msg `shouldBe` False
            Right (Left other) -> expectationFailure ("預期 FileWriteFailed,得到 " <> show other)
            Right (Right v) -> expectationFailure ("預期 Left,得到 Right " <> show v)

    describe "Examples(E2/E3/E6:骨架未實作,預期紅)" $ do
      it "E2: 兩個不同空目錄、同 StoryVault/\"liftgame\"/同一個 t,各呼叫一次 initVaultAtWith,\
         \兩次都 Right 且 vmId 相同" $ do
        let t = UTCTime (ModifiedJulianDay 61094) 0
        (r1, r2) <-
          withTempVault $ \d1 ->
            withTempVault $ \d2 -> do
              a <- initVaultAtWith d1 StoryVault "liftgame" t
              b <- initVaultAtWith d2 StoryVault "liftgame" t
              pure (a, b)
        case (r1, r2) of
          (Right m1, Right m2) -> vmId m1 `shouldBe` vmId m2
          other -> expectationFailure ("預期兩次都 Right,得到 " <> show other)

      it "E3: initVaultAtWith d StoryVault \"liftgame\" t 的\
         \ vmId == VaultId (renderId (newId PVlt \"liftgame\" t 0))" $ do
        let t = UTCTime (ModifiedJulianDay 61094) 0
        r <- withTempVault $ \dir -> initVaultAtWith dir StoryVault "liftgame" t
        case r of
          Right m -> vmId m `shouldBe` VaultId (renderId (newId PVlt "liftgame" t 0))
          Left e -> expectationFailure ("預期成功,得到 " <> show e)

      it "E6: 同 E5,改呼叫 initVaultAtWith … t,回傳與 initVaultAt 的 Left 逐欄相同" $
        withTempVault $ \dir -> do
          let blockerPath = dir </> "blocker"
              subPath = blockerPath </> "sub"
          writeFile blockerPath "not a directory"
          let t = UTCTime (fromGregorian 2026 8 30) 0
          leftAt <- initVaultAt subPath StoryVault "liftgame"
          leftWith <- initVaultAtWith subPath StoryVault "liftgame" t
          leftWith `shouldBe` leftAt

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

--------------------------------------------------------------------------------
-- graph-core/E002 用的產生器與小工具

-- | 任意 kind(L1/L2/R1 等的定義域涵蓋兩種 kind)。
genKind :: Gen VaultKind
genKind = Gen.element [AssetVault, StoryVault]

-- | 任意非空 name。限定字母、數字與少數安全符號——TOML escaping 之外的邊界
-- 不是 E002 的 scope,不在此處測。
genName :: Gen Text
genName = Gen.text (Range.linear 1 20) (Gen.choice [Gen.alpha, Gen.digit, Gen.element ("-_ " :: String)])

-- | 任意 'UTCTime',給 L1/L2/L3/R2b 的通用性質測試用(與
-- "Aapms.Workspace.ProjectsSpec".genUTCTime 同型)。
genTime :: Gen UTCTime
genTime = do
  d <- Gen.integral (Range.linear 60000 62000)
  s <- Gen.integral (Range.linear 0 86399)
  pure (UTCTime (ModifiedJulianDay d) (secondsToDiffTime s))

-- | @vlt-@ + 8 個小寫十六進位字元(R1 的 id 格式判準)。
isVltIdText :: Text -> Bool
isVltIdText t = case T.stripPrefix "vlt-" t of
  Just rest -> T.length rest == 8 && T.all isLowerHex rest
  Nothing -> False
  where
    isLowerHex c = c `elem` ("0123456789abcdef" :: String)

-- | 遞迴列出 root 底下每一個檔案的相對路徑與內容,供 R2a/R2b「逐位元組不變」的比對。
snapshotDir :: FilePath -> IO [(FilePath, BS.ByteString)]
snapshotDir root = go ""
  where
    go rel = do
      let full = if null rel then root else root </> rel
      entries <- listDirectory full
      fmap concat $ forM entries $ \e -> do
        let relE = if null rel then e else rel </> e
        isDir <- doesDirectoryExist (root </> relE)
        if isDir
          then go relE
          else do
            content <- BS.readFile (root </> relE)
            pure [(relE, content)]
