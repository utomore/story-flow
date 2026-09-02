-- | 測試共用的臨時目錄、小工具,與 graph-core\/F006 起的「story vault \/
-- asset vault」範例檔案組。
--
-- 落地層的測試一律在 'System.IO.Temp.withSystemTempDirectory' 建立的臨時目錄
-- 裡跑,測完即刪,不碰使用者真正的 vault。
module Aapms.Store.Fixtures
  ( withTempVault
  , orDie
  , idOf
  , refOf
  , typeOf
  , testRegistry

    -- * F006:story vault / asset vault 範例檔案組
  , storyVaultFiles
  , assetVaultFiles
  , writeFiles

    -- * graph-core\/B001:vault 目錄配置的判準
  , vaultLayoutViolations
  , withStoryVault
  , withAssetVault
  , withIndexedStoryVault
  , withIndexedAssetVault
  ) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Core.Id (Id, Ref, parseId, parseRef)
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Registry (TypeRegistry, buildRegistry)
import Aapms.Store.Error (StoreError, renderStoreError)
import Aapms.Store.Index (rebuildIndex)
import Aapms.Store.Marker (VaultHandle, closeVault, initVaultAt, openVault)
import Aapms.Store.Schema (VaultKind (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO.Temp (withSystemTempDirectory)

-- | 一個還沒有任何 marker 的臨時目錄。
withTempVault :: (FilePath -> IO a) -> IO a
withTempVault = withSystemTempDirectory "aapms-vault"

-- | 測試裡的前置動作失敗時直接爆掉,並印出人看得懂的訊息。
orDie :: Either StoreError a -> IO a
orDie = either (fail . T.unpack . renderStoreError) pure

-- | 空的型別註冊表,供 @openVault@ 的呼叫端測試使用。
--
-- 刻意__不__讀 @types\/registry\/@ 的實檔、也不引入 @aapms-types@:那是
-- @aapms-types@\/@Aapms.Types.Loader@ 的測試範圍(IO 載入層),落地層的測試不
-- 該因為別人改了一份 TOML 而變紅。__副作用__:本檔全部 fixture 用到的 @type@
-- (@character@\/@character-fragment@\/@asset-image@ 等)都不在這個空註冊表
-- 內,所以 'rebuildIndex' 對本檔 fixture 一定會回報一批
-- 'Aapms.Store.Schema.MetaWarningsFound'(@UnknownNodeType@)——這正好是
-- 「@checkMeta@ 警告進 'Aapms.Store.Schema.IndexIssue' 且不擋索引」這條驗收
-- 標準最自然的測試素材,不需要另外合成。
testRegistry :: TypeRegistry
testRegistry = case buildRegistry [] of
  Right r -> r
  Left es -> error ("空型別註冊表不該失敗:" <> show es)

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("測試裡的 ref 不合法:" <> show e)

typeOf :: Text -> TypeKey
typeOf = TypeKey

--------------------------------------------------------------------------------
-- F006 fixture:story vault(主題檔 + Level 檔)

-- | 主題檔:主體 'ent-00000001' + 兩個片段('ent-00000002'\/'ent-00000003',
-- 後者關聯回主體)。
storyLindaMd :: Text
storyLindaMd =
  T.unlines
    [ "---"
    , "id: ent-00000001"
    , "vault: liftgame"
    , "type: character"
    , "title: 測試角色"
    , "summary: F006 fixture 用的角色主體"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "主體內文。"
    , ""
    , "## 外貌 {#ent-00000002}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: 外貌片段"
    , "tags: [外觀]"
    , "aliases: [小測]"
    , "```"
    , ""
    , "外貌內文。"
    , ""
    , "## 背景 {#ent-00000003}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: 背景片段"
    , "tags: [背景]"
    , "links:"
    , "  - {kind: partOf, target: ent-00000001}"
    , "```"
    , ""
    , "背景內文。"
    ]

-- | Level 檔:根 'nod-00000001' 底下一個子節點 'nod-00000002'(至少兩個
-- Node,滿足 STEP-14 的要求),子節點關聯回主題檔的主體。
storyClassroomMd :: Text
storyClassroomMd =
  T.unlines
    [ "---"
    , "id: lvl-00000001"
    , "vault: liftgame"
    , "type: level"
    , "title: 測試場景"
    , "summary: F006 fixture 用的場景"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "場景整體說明。"
    , ""
    , "## 開場 {#nod-00000001}"
    , ""
    , "```meta"
    , "kind: scene"
    , "summary: 開場"
    , "```"
    , ""
    , "### 出場人物 {#nod-00000002}"
    , ""
    , "```meta"
    , "kind: cast"
    , "links:"
    , "  - {kind: involves, target: ent-00000001}"
    , "```"
    ]

-- | story vault 的完整範例檔案組(vault 相對路徑, 內容)。
storyVaultFiles :: [(FilePath, Text)]
storyVaultFiles =
  [ ("characters/test-character.md", storyLindaMd)
  , ("levels/test-classroom.md", storyClassroomMd)
  ]

--------------------------------------------------------------------------------
-- F006 fixture:asset vault(pack.md × 2 + licenses.md)

-- | 授權登記檔,'lic-0000000a' 供 pack 的 @license@ 欄位參照。
assetLicensesMd :: Text
assetLicensesMd =
  T.unlines
    [ "---"
    , "id: lic-00000001"
    , "vault: liftgame-assets"
    , "type: asset-license"
    , "title: 授權登記"
    , "status: canon"
    , "source: human"
    , "created: 2026-08-10"
    , "updated: 2026-08-10"
    , "---"
    , ""
    , "本檔登記授權條款。"
    , ""
    , "## CC0 {#lic-0000000a}"
    , ""
    , "```meta"
    , "commercial: true"
    , "attribution_required: false"
    , "```"
    ]

-- | 主要 pack.md:兩個 asset,其一 @status: missing@(STEP-14 要求)。
assetPackMd :: Text
assetPackMd =
  T.unlines
    [ "---"
    , "id: pck-00000001"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: 測試 Pack"
    , "vendor: test-vendor"
    , "license: lic-0000000a"
    , "status: canon"
    , "source: scan"
    , "revision: 1"
    , "created: 2026-08-10"
    , "updated: 2026-08-10"
    , "---"
    , ""
    , "Pack 說明。"
    , ""
    , "## panel.png {#ast-00000001}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "name: ui_gui_panel_001"
    , "entry: PNG/panel.png"
    , "sha256: \"1111111111111111111111111111111111111111111111111111111111111111\""
    , "tags: [gui]"
    , "```"
    , ""
    , "## missing.png {#ast-00000002}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: PNG/missing.png"
    , "sha256: \"2222222222222222222222222222222222222222222222222222222222222222\""
    , "status: missing"
    , "```"
    ]

-- | 位於 @library\/reference\/@ 之下的 pack.md,供 'nfIncludeReference' 測試用
-- (design.md:「是 reference」由 pack.md 的路徑決定)。
assetReferencePackMd :: Text
assetReferencePackMd =
  T.unlines
    [ "---"
    , "id: pck-00000002"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: 參考資料"
    , "status: canon"
    , "source: scan"
    , "revision: 1"
    , "created: 2026-08-10"
    , "updated: 2026-08-10"
    , "---"
    , ""
    , "參考資料說明,索引時不該預設出現在查詢結果裡。"
    , ""
    , "## temple.jpg {#ast-00000003}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: JPG/temple.jpg"
    , "sha256: \"3333333333333333333333333333333333333333333333333333333333333333\""
    , "```"
    ]

-- | asset vault 的完整範例檔案組。
assetVaultFiles :: [(FilePath, Text)]
assetVaultFiles =
  [ ("library/packs/test-vendor/test-pack/pack.md", assetPackMd)
  , ("library/licenses.md", assetLicensesMd)
  , ("library/reference/temple/pack.md", assetReferencePackMd)
  ]

--------------------------------------------------------------------------------
-- 寫檔 / 開 vault 輔助

-- | 一份 vault 檔案組裡,違反 @system.md:439@ 目錄配置的路徑(graph-core\/B001)。
--
-- 主架構對 asset vault 明訂 @library\/licenses.md@ 與
-- @library\/packs\/\<vendor\>\/\<pack-slug\>\/pack.md@,另有 @library\/reference\/\<topic\>\/@
-- 與 @library\/studio\/@ 兩種 pack 位置。三種位置的層數不同,所以判準只取兩條
-- __機械可判定__的子句:
--
-- 1. 檔名是 @licenses.md@ 的路徑,必須恰好是 @library\/licenses.md@
-- 2. 檔名是 @pack.md@ 的路徑,必須以 @library\/@ 起頭(不約束層數)
--
-- 比對的是 fixture 的__資料結構__(路徑字串本身),不是原始碼文字——所以沒有
-- graph-core\/GAP-3 與 GAP-12 那種「分不出註解與程式碼」的偽陽性問題。
--
-- 回傳空清單 = 這份檔案組符合主架構。
vaultLayoutViolations :: [(FilePath, Text)] -> [FilePath]
vaultLayoutViolations = filter (not . ok) . map fst
  where
    ok rel = case takeFileName rel of
      "licenses.md" -> norm rel == "library/licenses.md"
      "pack.md" -> "library/" `T.isPrefixOf` T.pack (norm rel)
      _ -> True

    -- Windows 上 fixture 也可能寫成反斜線,先正規化成正斜線再比對。
    norm = map (\c -> if c == '\\' then '/' else c)

-- | 把一組 (vault 相對路徑, 內容) 寫進指定的 vault 根目錄,自動建立子目錄。
writeFiles :: FilePath -> [(FilePath, Text)] -> IO ()
writeFiles root = mapM_ writeOne
  where
    writeOne (rel, content) = do
      let fp = root </> rel
      createDirectoryIfMissing True (takeDirectory fp)
      BS.writeFile fp (TE.encodeUtf8 content)

-- | 建一個全新的臨時 vault:@initVaultAt@ → 寫入 'storyVaultFiles' → @openVault@
-- (__不__自動 rebuild——'Aapms.Store.Index.rebuildIndex'\/'Aapms.Store.Index.refreshStale'
-- 是契約 E 的獨立函式,呼叫端自己決定何時索引,測試過時偵測\/rebuild 兩次等
-- 情境需要控制這個時機點)。收尾自動 'closeVault'。
withStoryVault :: (VaultHandle -> IO a) -> IO a
withStoryVault act = withTempVault $ \dir -> do
  _ <- orDie =<< initVaultAt dir StoryVault "story-fixture"
  writeFiles dir storyVaultFiles
  (h, _issues) <- orDie =<< openVault testRegistry dir
  result <- act h
  closeVault h
  pure result

withAssetVault :: (VaultHandle -> IO a) -> IO a
withAssetVault act = withTempVault $ \dir -> do
  _ <- orDie =<< initVaultAt dir AssetVault "asset-fixture"
  writeFiles dir assetVaultFiles
  (h, _issues) <- orDie =<< openVault testRegistry dir
  result <- act h
  closeVault h
  pure result

-- | 'withStoryVault' \/ 'withAssetVault' 再加一次 'rebuildIndex',給只關心
-- 「已經索引好的 vault」的查詢測試用。
withIndexedStoryVault :: (VaultHandle -> IO a) -> IO a
withIndexedStoryVault act = withStoryVault $ \h -> do
  _ <- orDie =<< rebuildIndex h
  act h

withIndexedAssetVault :: (VaultHandle -> IO a) -> IO a
withIndexedAssetVault act = withAssetVault $ \h -> do
  _ <- orDie =<< rebuildIndex h
  act h
