-- | F001:'Aapms.Workspace.Types' 的 'renderWorkspaceError'(L14\/L15\/X21–X26)、
-- 'mkHub' 與五個 selector 的互逆(L16),以及依賴方向 \/ 職責界線的 import 清單
-- 檢查(L17,__預期綠__——見 spec「紅綠預期」)。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F001-hub-registry.md@):
--
-- @
-- L14  renderWorkspaceError 全建構子非空、含中文、可行動、不含 show 痕跡 -> allConstructors 迴圈
-- L15  renderWorkspaceError 含逐條列出的攜帶值                          -> carriedValues 迴圈
-- L16  mkHub 與五個 selector 互逆(預期綠)                              -> prop_L16
-- L17(a) Types.hs 不 import 本套件其他模組                              -> test_types_imports_no_sibling_module
-- L17(b) Location.hs 不 import Aapms.Workspace.Hub                      -> test_location_does_not_import_hub
-- L17(c) Location.hs/Hub.hs 完全不得 import Aapms.Store.Marker          -> test_location_and_hub_never_import_marker
-- L17(d) Types.hs 對 Aapms.Store.Marker 的 import 逐字只拿 VaultMarker  -> test_types_imports_marker_type_only
-- L17(e) 三檔都不 import openIndexAt/closeIndex/System.Process         -> test_no_index_or_process_imports
-- X21–X26 renderWorkspaceError 的具體例子                               -> it "X21".."X26"
--
-- 2026-08-29 閘門裁決:原 L17(c)「三個檔案都不 import Aapms.Store.Marker」與契約 C
-- 的 VaultRef.vrMarker 型別矛盾(本次-1),已拆成 (c)/(d) 兩條並改寫 spec,不再是 gap。
-- @
module Aapms.Workspace.TypesSpec (spec) where

import Data.List (dropWhileEnd, isInfixOf, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Error (StoreError (VaultMarkerMissing), renderStoreError)
import Aapms.Store.Schema (VaultKind (..), renderVaultKind)
import Aapms.Workspace.Fixtures
import Aapms.Workspace.Types

-- | 契約 F 全部 16 個建構子的代表值(X21\/X23\/X24\/X25\/X26 用 spec 給的具體值;
-- 其餘 10 個用同一種風格自己造)。
allConstructors :: [(String, WorkspaceError)]
allConstructors =
  [ ("HubNotFound", HubNotFound "C:/hub/config.toml")
  , ("HubUnreadable", HubUnreadable "C:/hub/config.toml" "TOML 語法錯誤於第 1 行")
  , ("HubMalformed", HubMalformed "C:/hub/config.toml" "缺少必填鍵 id")
  , ("HubWriteFailed", HubWriteFailed "C:/hub/config.toml" "磁碟空間不足")
  , ("VaultSelectorNotFound", VaultSelectorNotFound "lore")
  , ("VaultSelectorAmbiguous", VaultSelectorAmbiguous "lore" [sampleVault1, sampleVault2])
  , ("VaultKindMismatch", VaultKindMismatch (VaultId "vlt-7f3b2a91") AssetVault StoryVault)
  , ("NoWriteTarget", NoWriteTarget "D:/games/Circle")
  , ("VaultAlreadyInitialized", VaultAlreadyInitialized "D:/vaults/liftgame")
  , ("VaultDirMissing", VaultDirMissing "D:/vaults/liftgame")
  , ("VaultDirNotEmpty", VaultDirNotEmpty "D:/vaults/liftgame")
  , ("VaultIdCollision", VaultIdCollision (VaultId "vlt-7f3b2a91") "C:/a" "D:/b")
  , ("MarkerUnreadable", MarkerUnreadable "D:/v" (VaultMarkerMissing "D:/v/.aapms/config.toml"))
  , ("ProjectSelectorNotFound", ProjectSelectorNotFound "Circle")
  , ("ProjectPathMissing", ProjectPathMissing "Circle" "D:/games/missing-circle")
  , ("InvalidName", InvalidName "   ")
  ]

-- | 「訊息規格」表逐條列出的、每個建構子必須含有的值。
carriedValues :: WorkspaceError -> [Text]
carriedValues = \case
  HubNotFound fp -> [T.pack fp]
  HubUnreadable fp reason -> [T.pack fp, reason]
  HubMalformed fp reason -> [T.pack fp, reason]
  HubWriteFailed fp reason -> [T.pack fp, reason]
  VaultSelectorNotFound s -> [s]
  VaultSelectorAmbiguous s es -> s : concatMap (\e -> [vaultIdText (veId e), T.pack (vePath e)]) es
  VaultKindMismatch vid want got -> [vaultIdText vid, renderVaultKind want, renderVaultKind got]
  NoWriteTarget start -> [T.pack start]
  VaultAlreadyInitialized dir -> [T.pack dir]
  VaultDirMissing dir -> [T.pack dir]
  VaultDirNotEmpty dir -> [T.pack dir]
  VaultIdCollision vid old new -> [vaultIdText vid, T.pack old, T.pack new]
  MarkerUnreadable root e -> [T.pack root, renderStoreError e]
  ProjectSelectorNotFound s -> [s]
  ProjectPathMissing name fp -> [name, T.pack fp]
  InvalidName raw -> ["「" <> raw <> "」"]

-- | 原始 @show@ 會漏出來的痕跡(對照 "Aapms.Store.ErrorSpec")。
showTraces :: [Text]
showTraces = ["Left", "Right", "Just ", "Nothing"]

hasHan :: Text -> Bool
hasHan = T.any (\c -> c >= '\x4e00' && c <= '\x9fff')

actionable :: Text -> Bool
actionable msg = any (`T.isInfixOf` msg) ["請", "改用", "可以", "才"]

spec :: Spec
spec = describe "F001 Aapms.Workspace.Types" $ do
  describe "L14: renderWorkspaceError 全建構子非空、含中文、可行動、不含 show 痕跡" $
    mapM_
      ( \(name, e) -> it (name <> " 的訊息合格") $ do
          let msg = renderWorkspaceError e
          msg `shouldNotBe` ""
          msg `shouldSatisfy` hasHan
          msg `shouldSatisfy` actionable
          mapM_
            (\bad -> msg `shouldSatisfy` (not . T.isInfixOf bad))
            (showTraces ++ [T.pack name])
      )
      allConstructors

  describe "L15: renderWorkspaceError 含「訊息規格」表逐條列出的攜帶值" $
    mapM_
      ( \(name, e) -> it (name <> " 訊息含全部攜帶值") $ do
          let msg = renderWorkspaceError e
          mapM_ (\v -> msg `shouldSatisfy` T.isInfixOf v) (carriedValues e)
      )
      allConstructors

  describe "Examples X21-X26" $ do
    it "X21: HubNotFound 訊息非空繁中、含路徑、含下一步指示" $ do
      let msg = renderWorkspaceError (HubNotFound "C:/hub/config.toml")
      msg `shouldNotBe` ""
      msg `shouldSatisfy` hasHan
      msg `shouldSatisfy` T.isInfixOf "C:/hub/config.toml"
      msg `shouldSatisfy` actionable

    it "X22: VaultSelectorAmbiguous 含 selector 字串與兩列各自的 veId/vePath" $ do
      let e1 = sampleVault1
          e2 = sampleVault2
          msg = renderWorkspaceError (VaultSelectorAmbiguous "lore" [e1, e2])
      msg `shouldSatisfy` T.isInfixOf "lore"
      msg `shouldSatisfy` T.isInfixOf (vaultIdText (veId e1))
      msg `shouldSatisfy` T.isInfixOf (T.pack (vePath e1))
      msg `shouldSatisfy` T.isInfixOf (vaultIdText (veId e2))
      msg `shouldSatisfy` T.isInfixOf (T.pack (vePath e2))

    it "X23: VaultKindMismatch 含 id、asset、story,不含 Haskell 建構子名" $ do
      let msg = renderWorkspaceError (VaultKindMismatch (VaultId "vlt-7f3b2a91") AssetVault StoryVault)
      msg `shouldSatisfy` T.isInfixOf "vlt-7f3b2a91"
      msg `shouldSatisfy` T.isInfixOf "asset"
      msg `shouldSatisfy` T.isInfixOf "story"
      msg `shouldSatisfy` (not . T.isInfixOf "AssetVault")
      msg `shouldSatisfy` (not . T.isInfixOf "StoryVault")

    it "X24: VaultIdCollision 三個值都在" $ do
      let msg = renderWorkspaceError (VaultIdCollision (VaultId "vlt-7f3b2a91") "C:/a" "D:/b")
      msg `shouldSatisfy` T.isInfixOf "vlt-7f3b2a91"
      msg `shouldSatisfy` T.isInfixOf "C:/a"
      msg `shouldSatisfy` T.isInfixOf "D:/b"

    it "X25: InvalidName 含以「」夾住的原始字串(全空白也驗得出來)" $
      renderWorkspaceError (InvalidName "   ") `shouldSatisfy` T.isInfixOf "「   」"

    it "X26: MarkerUnreadable 含 root 與 renderStoreError 對該 StoreError 的輸出" $ do
      let se = VaultMarkerMissing "D:/v/.aapms/config.toml"
          msg = renderWorkspaceError (MarkerUnreadable "D:/v" se)
      msg `shouldSatisfy` T.isInfixOf "D:/v"
      msg `shouldSatisfy` T.isInfixOf (renderStoreError se)

  describe "L16(預期綠): mkHub 與五個 selector 互逆" $
    it "對任意 vs/ps/llm/tools/txt,mkHub 之後五個 selector 原樣還回來" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 0 5) genVaultEntry)
        ps <- forAll (Gen.list (Range.linear 0 5) genProjectEntry)
        llm <- forAll (Gen.maybe genLlmSection)
        tools <- forAll genToolsConfig
        txt <- forAll genHubSourceText
        let h = mkHub vs ps llm tools txt
        hubVaults h === vs
        hubProjects h === ps
        hubLlm h === llm
        hubTools h === tools
        hubSourceText h === txt

  -- 2026-08-29 閘門裁決(本次-1 已由開發者裁決、spec 改寫):L17 從 3 條子斷言改成
  -- (a)-(e) 五條,原本互相矛盾的 (c)「三個檔案都不 import Aapms.Store.Marker」拆成
  -- (c)(收窄到 Location.hs / Hub.hs)與新增的 (d)(Types.hs 逐字限定只拿 VaultMarker
  -- 型別、拿不到任何函式)。五條全部只掃 import 行,不做全檔字串搜尋(spec 明文)。
  describe "L17(預期綠): 依賴方向與職責界線,以 import 清單驗證" $ do
    it "test_types_imports_no_sibling_module(a): Types.hs 沒有任何 import Aapms.Workspace. 開頭的行" $ do
      importLines <- importLinesOf "Aapms/Workspace/Types.hs"
      mapM_ (\l -> l `shouldNotSatisfy` isInfixOf "Aapms.Workspace.") importLines

    it "test_location_does_not_import_hub(b): Location.hs 不 import Aapms.Workspace.Hub" $ do
      importLines <- importLinesOf "Aapms/Workspace/Location.hs"
      mapM_ (\l -> l `shouldNotSatisfy` isInfixOf "Aapms.Workspace.Hub") importLines

    it "test_location_and_hub_never_import_marker(c): Location.hs 與 Hub.hs 完全不得 import \
       \Aapms.Store.Marker" $
      mapM_
        ( \fp -> do
            importLines <- importLinesOf fp
            mapM_ (\l -> l `shouldNotSatisfy` isInfixOf "Aapms.Store.Marker") importLines
        )
        ["Aapms/Workspace/Location.hs", "Aapms/Workspace/Hub.hs"]

    it "test_types_imports_marker_type_only(d): Types.hs 對 Aapms.Store.Marker 的 import 行 \
       \逐字是 \"import Aapms.Store.Marker (VaultMarker)\",拿不到任何函式" $ do
      importLines <- importLinesOf "Aapms/Workspace/Types.hs"
      let markerLines = filter (isInfixOf "Aapms.Store.Marker") importLines
      markerLines `shouldBe` ["import Aapms.Store.Marker (VaultMarker)"]

    it "test_no_index_or_process_imports(e): 三個檔案的 import 行都不含 \
       \openIndexAt / closeIndex / System.Process" $ do
      let files = ["Aapms/Workspace/Types.hs", "Aapms/Workspace/Location.hs", "Aapms/Workspace/Hub.hs"]
          forbidden = ["openIndexAt", "closeIndex", "System.Process"]
      mapM_
        ( \fp -> do
            importLines <- importLinesOf fp
            mapM_ (\bad -> mapM_ (\l -> l `shouldNotSatisfy` isInfixOf bad) importLines) forbidden
        )
        files

-- | 一個骨架檔案裡,去除前導空白、__去除行尾 @\\r@__(切行終止符的產物,不屬於
-- import 行本身的內容——`Prelude.lines` 只切 @\\n@,CRLF checkout 上每一行會拖著一個
-- 尾隨 @\\r@,逐字比對前要先正規化掉)之後、以 @import@ 起頭的行。
-- L17 五條子斷言 (a)-(e) 全部經由本函式讀 import 行,行尾正規化只做這一處。
importLinesOf :: FilePath -> IO [String]
importLinesOf rel = do
  src <- readWorkspaceSource rel
  let stripLine = dropWhile (== ' ') . dropWhileEnd (== '\r')
  pure (filter ("import" `isPrefixOf`) (map stripLine (lines (T.unpack src))))
