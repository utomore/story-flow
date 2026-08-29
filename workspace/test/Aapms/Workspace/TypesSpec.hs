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
-- L17  三個檔案的 import 清單(預期綠;(c) 的 Marker 部分見「本次-1」)    -> describe "L17"
-- X21–X26 renderWorkspaceError 的具體例子                               -> it "X21".."X26"
-- @
module Aapms.Workspace.TypesSpec (spec) where

import Data.List (isInfixOf, isPrefixOf)
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

  describe "L17(預期綠): 依賴方向與職責界線,以 import 清單驗證" $ do
    it "test_types_imports_no_sibling_module: Types.hs 沒有任何 import Aapms.Workspace. 開頭的行" $ do
      importLines <- importLinesOf "Aapms/Workspace/Types.hs"
      mapM_ (\l -> l `shouldNotSatisfy` isInfixOf "Aapms.Workspace.") importLines

    it "(b) Location.hs 不 import Aapms.Workspace.Hub" $ do
      importLines <- importLinesOf "Aapms/Workspace/Location.hs"
      mapM_ (\l -> l `shouldNotSatisfy` isInfixOf "Aapms.Workspace.Hub") importLines

    -- (c) 的「三個檔案都不 import Aapms.Store.Marker」只驗 Location.hs / Hub.hs:
    -- Types.hs 的骨架已 import `Aapms.Store.Marker (VaultMarker)`(VaultRef.vrMarker
    -- 的型別來源,「使用到的既有串接介面」表明載),與這一條的字面矛盾——見「本次-1」,
    -- 該子句停下、不對 Types.hs 斷言。
    it "(c) Location.hs / Hub.hs 不 import Aapms.Store.Marker(Types.hs 見「本次-1」)" $ do
      mapM_
        ( \fp -> do
            importLines <- importLinesOf fp
            mapM_ (\l -> l `shouldNotSatisfy` isInfixOf "Aapms.Store.Marker") importLines
        )
        ["Aapms/Workspace/Location.hs", "Aapms/Workspace/Hub.hs"]

    it "test_modules_have_no_discovery_or_tooling_strings: 三個檔案的 import 行都不含 \
       \openIndexAt / closeIndex / System.Process" $ do
      let files = ["Aapms/Workspace/Types.hs", "Aapms/Workspace/Location.hs", "Aapms/Workspace/Hub.hs"]
          forbidden = ["openIndexAt", "closeIndex", "System.Process"]
      mapM_
        ( \fp -> do
            importLines <- importLinesOf fp
            mapM_ (\bad -> mapM_ (\l -> l `shouldNotSatisfy` isInfixOf bad) importLines) forbidden
        )
        files

-- | 一個骨架檔案裡,去除前導空白後以 @import@ 起頭的行。
importLinesOf :: FilePath -> IO [String]
importLinesOf rel = do
  src <- readWorkspaceSource rel
  pure (filter ("import" `isPrefixOf`) (map (dropWhile (== ' ')) (lines (T.unpack src))))
