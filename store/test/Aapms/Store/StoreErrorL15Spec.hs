-- | graph-core\/F008 L15\/E16\/E17:'Aapms.Store.Error.renderStoreError' 涵蓋
-- 'Aapms.Store.Error.StoreError' 全部 21 個建構子。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F008-store-write-operations.md@,
-- 2026-08-25 G7 裁決後的版本)
--
-- @
-- L15  renderStoreError 對全部 21 個建構子非空、含以「請」起頭的子句(不放寬,無例外) -> prop_L15_nonEmpty / prop_L15_qing
-- E16  renderStoreError (VaultMarkerMissing \"\/tmp\/v\")                              -> test_E16
-- E17  renderStoreError (SqliteError \"no such table: nodes\")(G7 裁決要改的既有訊息)  -> test_E17
-- @
--
-- __G7 已裁決__:L15 不放寬,`SqliteError` 的既有訊息改由 impl 這一輪換成
-- @\"索引操作失敗 —— \" <> msg <> \";請嘗試重新開啟 vault\"@(見 spec「@SqliteError@ 的訊息
-- 要改」)。因此本檔__不再對 @SqliteError@ 特殊處理__:它與其餘 20 個建構子一起套同一組斷言
-- (非空 + 含以「請」起頭的子句)。改之前這一筆會紅(舊訊息用「可以嘗試」收尾),這是
-- __預期的紅__,不是 gap——與 F008 新增的 15 個 @undefined@ 分支同一類「impl 還沒做」的紅。
-- F005 其餘 5 則既有訊息(`VaultMarkerMissing` \/ `VaultMarkerInvalid` \/
-- `VaultAlreadyInitialized` \/ `FileReadFailed` \/ `FileWriteFailed`)不受影響,應為綠。
module Aapms.Store.StoreErrorL15Spec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Link (Link (..), LinkKind (References))
import Aapms.Core.Meta (Revision (..), TypeKey (..))
import Aapms.Core.Tree (TreeError (..))
import Aapms.Md.Document (DocKind (..))
import Aapms.Md.Error (MdError (..), MdErrorKind (..))
import Aapms.Store.Error
import Aapms.Store.Fixtures (idOf, refOf)
import Test.Hspec

-- | F005 既有 6 個建構子(骨架已實作)。除 'SqliteError'(G7 這一輪要改的既有訊息,見模組
-- 說明)外,其餘 5 個在 L15 的兩個判準下都應為綠。
existingSix :: [(String, StoreError)]
existingSix =
  [ ("VaultMarkerMissing", VaultMarkerMissing "/tmp/v")
  , ("VaultMarkerInvalid", VaultMarkerInvalid "/tmp/v" "缺少必填鍵 name")
  , ("VaultAlreadyInitialized", VaultAlreadyInitialized "/tmp/v")
  , ("FileReadFailed", FileReadFailed "/tmp/v/x.md" "沒有這個檔案")
  , ("FileWriteFailed", FileWriteFailed "/tmp/v/x.md" "磁碟空間不足")
  , ("SqliteError", SqliteError "database is locked")
  ]

-- | F008 新增的 15 個建構子(骨架 undefined,兩個判準皆應為紅)。
newFifteen :: [(String, StoreError)]
newFifteen =
  [ ("NodeNotFound", NodeNotFound (idOf "ent-00000001"))
  , ("SectionMissing", SectionMissing "levels/x.md" (idOf "nod-00000001"))
  , ("RevisionMismatch", RevisionMismatch (idOf "ent-00000001") (Revision 2) (Revision 3))
  , ("MdWriteFailed", MdWriteFailed "characters/x.md" (MdError 12 NoFrontmatter))
  , ("TreeInvalidOnWrite", TreeInvalidOnWrite "levels/x.md" [NoRoot])
  , ("IndexUpdateFailed", IndexUpdateFailed "characters/x.md" "database is locked")
  , ("FileAlreadyExists", FileAlreadyExists "characters/x.md")
  , ("RegistryDirUnknown", RegistryDirUnknown (TypeKey "unknown-type"))
  , ("NotAnAsset", NotAnAsset (idOf "ent-00000001"))
  , ("NotALicense", NotALicense (idOf "ent-00000001"))
  , ("BadSectionPayload", BadSectionPayload (idOf "ent-00000001") PackDoc)
  , ("LinkNotFound", LinkNotFound (idOf "ent-00000001") (Link References (refOf "ent-00000002") Nothing))
  ,
    ( "ReferencedBy"
    , ReferencedBy (idOf "ent-00000001") [(idOf "ent-00000002", Link References (refOf "ent-00000001") Nothing)]
    )
  , ("CannotDeleteRootNode", CannotDeleteRootNode (idOf "nod-00000001"))
  , ("NodeDepthExceeded", NodeDepthExceeded (idOf "nod-00000001") 7)
  ]

allTwentyOne :: [(String, StoreError)]
allTwentyOne = existingSix ++ newFifteen

spec :: Spec
spec = describe "graph-core/F008 L15 renderStoreError 涵蓋 StoreError 全部 21 個建構子" $ do
  describe "L15(非空):既有 6 個(F005,骨架已實作,應為綠)" $
    mapM_ (\(name, e) -> it (name <> " 的 renderStoreError 非空") $ nonEmptyCheck e) existingSix

  describe "L15(非空):新增 15 個(F008,骨架 undefined,應為紅)" $
    mapM_ (\(name, e) -> it (name <> " 的 renderStoreError 非空") $ nonEmptyCheck e) newFifteen

  describe "L15(含以「請」起頭的子句,全部 21 個建構子一視同仁,無例外——2026-08-25 G7 裁決)" $
    mapM_ (\(name, e) -> it (name <> " 含以「請」起頭的子句") $ qingCheck e) allTwentyOne

  it "E16: renderStoreError (VaultMarkerMissing \"/tmp/v\") 非空,且含以「請」起頭的子句" $ do
    let msg = renderStoreError (VaultMarkerMissing "/tmp/v")
    msg `shouldNotBe` ""
    msg `shouldSatisfy` hasQingClause

  it "E17: renderStoreError (SqliteError \"no such table: nodes\") 逐字等於新原文(G7 裁決要改的既有訊息;改之前為紅,改完轉綠)" $
    renderStoreError (SqliteError "no such table: nodes")
      `shouldBe` "索引操作失敗 —— no such table: nodes;請嘗試重新開啟 vault"

  it "L15 涵蓋的範圍是 StoreError 全部 21 個建構子(對帳用計數)" $
    length allTwentyOne `shouldBe` 21

nonEmptyCheck :: StoreError -> Expectation
nonEmptyCheck e = renderStoreError e `shouldNotBe` ""

qingCheck :: StoreError -> Expectation
qingCheck e = renderStoreError e `shouldSatisfy` hasQingClause

-- | 是否含至少一個以「請」起頭的子句:訊息本身以「請」開頭,或緊接在常見的中文\/ASCII
-- 分句標點之後出現「請」。
hasQingClause :: Text -> Bool
hasQingClause msg =
  T.isPrefixOf "請" msg
    || any (\d -> (d <> "請") `T.isInfixOf` msg) delimiters
  where
    delimiters = [";", "；", "。", ",", "，", "、", ":", "：", "\n"]
