-- | graph-core\/F008:契約 E 的建檔\/增節\/刪除組——'createTopicFile' \/
-- 'createLevelFile' \/ 'createPackFile' \/ 'addSection' \/ 'deleteNode'。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F008-store-write-operations.md@)
--
-- @
-- L9   createPackFile 順序保持                      -> prop_L9
-- L10  createTopicFile 落點                          -> prop_L10
-- L11  createLevelFile 產出可解析的 Level             -> prop_L11
-- L12a addSection AtEnd 追加不動前面(G14 裁決後含插入點行尾但書) -> test_L12a
-- L12b addSection UnderParent 只在插入點動刀(G14 裁決後含插入點行尾但書) -> test_E12(即 L12b 的具體案例)
-- L12c UnderParent 兩條失敗路徑不寫檔                  -> test_E13 / test_E14
-- L13  deleteNode 的兩種模式                          -> prop_L13
-- L25  createPackFile 的 pack 專屬七欄往返(2026-08-25 G17 裁決,__現在會紅__,見模組說明) -> test_E22
-- E1   createTopicFile 正常路徑                       -> test_E1
-- E2   createLevelFile 根 Node                        -> test_E2
-- E3   createPackFile 節順序                          -> test_E3
-- E8   deleteNode 根節點刪不得                         -> test_E8
-- E10  addSection payload 與文件種類不符               -> test_E10
-- E12  UnderParent 正常路徑                           -> test_E12
-- E13  UnderParent 父節點不存在                        -> test_E13
-- E14  UnderParent 父節點已達六級                       -> test_E14
-- E22  createPackFile 七個 pack 專屬欄位全給非預設值    -> test_E22
-- @
--
-- __編排者歸因(第二輪,2026-08-25)__:
--
-- * 'levelE12Md' 原本從三級標題直接跳到六級(@HeadingSkip 3 6@),不是合法的 Level 檔
--   (ADR-009 標題階層必須逐級遞增)。已改成收束(3)之後接深一(4)→深二(5)→最深(6)逐級鋪下去,
--   序幕\/開場\/收束的順序與 id 不變(E12\/E13 依賴那個順序)。
-- * L9 的 generator 曾經跨迭代重用同一批 @nsId@,而短 id 依 ADR-014 是__vault 內__唯一,不是
--   __檔案內__唯一——同一個 vault 裡兩個檔用同一個 id 本來就不合法。'l9SamplePools' 現在三組
--   彼此__完全不相交__。
--
-- __L25\/E22(G17)__:'createPackFile' 現在被驗出把 'NewPack' 的七個 pack 專屬欄位全部
-- 丟掉(重讀後全解成 'Nothing' \/ 'AiUnknown')。這是 @aapms-md@ 檔案層缺對稱節層
-- @MetaExtras@ 機制的根因,F004 正在另一條線補;__本檔的 test_E22 現在就是紅的,而且會一直
-- 紅到 F004 那一半落地為止__——這是它的工作,不弱化、不標 pending、不因為現在做不到而放寬。
module Aapms.Store.CreateSpec (spec) where

import Control.Monad (forM_)
import Data.List (find, sort)
import qualified Data.Text as T
import Data.Aeson (Value (Null))
import Test.Hspec
import Aapms.Core.Asset (Asset (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, Ref (..), localRef)
import Aapms.Core.Level (Level (..), Node (..), NodeKind (..))
import Aapms.Core.Link (Link (..), LinkKind (Involves))
import Aapms.Core.Meta (Meta (..), Revision (..), Source (..), Status (..), TypeKey (..))
import Aapms.Core.Pack (AiDisclosure (..), Author (..), Pack (..))
import Aapms.Core.Registry
  ( Family (FEntity)
  , TypeDecl (..)
  , TypeRegistry
  , buildRegistry
  )
import Aapms.Core.Tree (buildTree)
import Aapms.Md.Document (Document (..), DocKind (..), Section (..))
import Aapms.Md.Inherit (MetaOverride (..), emptyOverride)
import Aapms.Md.Parse (parseDocument, toLevel, toPack, toTopic)
import Aapms.Md.Render (NewAsset (..), NewNode (..), NewSection (..), NewSectionPayload (..), renderSection)
import Aapms.Store.Atomic (readTextFile)
import Aapms.Store.Create
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Fixtures
import Aapms.Store.Index (rebuildIndex)
import Aapms.Store.Marker (VaultHandle, closeVault, initVaultAt, openVault, vhRoot)
import Aapms.Store.Schema (VaultKind (StoryVault))
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

--------------------------------------------------------------------------------
-- 共用素材

charDecl :: TypeDecl
charDecl =
  TypeDecl
    { tdKey = TypeKey "character"
    , tdName = "角色"
    , tdFamily = FEntity
    , tdDir = Just "characters"
    , tdOwnerType = Nothing
    , tdAllowedLinks = []
    , tdStages = []
    , tdFields = []
    , tdNameKinds = []
    }

itemDecl :: TypeDecl
itemDecl =
  TypeDecl
    { tdKey = TypeKey "item"
    , tdName = "道具"
    , tdFamily = FEntity
    , tdDir = Just "items"
    , tdOwnerType = Nothing
    , tdAllowedLinks = []
    , tdStages = []
    , tdFields = []
    , tdNameKinds = []
    }

regWithTypes :: TypeRegistry
regWithTypes = case buildRegistry [charDecl, itemDecl] of
  Right r -> r
  Left es -> error ("CreateSpec 測試註冊表建立失敗:" <> show es)

-- | 全新的臨時 vault,套用 'regWithTypes',不預先寫入任何檔案。
withFreshVault :: (VaultHandle -> IO a) -> IO a
withFreshVault act = withTempVault $ \dir -> do
  _ <- orDie =<< initVaultAt dir StoryVault "create-spec-fixture"
  (vh, _issues) <- orDie =<< openVault regWithTypes dir
  r <- act vh
  closeVault vh
  pure r

mkEntity :: TypeKey -> FilePath -> String -> NewEntity
mkEntity ty _ title =
  NewEntity
    { neType = ty
    , neTitle = T.pack title
    , neSummary = "CreateSpec 測試摘要"
    , neBody = "CreateSpec 測試主體內文"
    , neTags = []
    , neAliases = []
    , neStatus = Canon
    , neTimeline = Nothing
    , neLinks = []
    , neSource = Human
    , nePath = Nothing
    }

parseOrFail :: T.Text -> IO Document
parseOrFail raw = either (\e -> fail ("解析失敗:" <> show e)) pure (parseDocument raw)

-- | G14 裁決:插入一節之後,除了插入點之前那一段之外,其餘每一節都必須逐位元組不變。
-- 插入點之前那一段__只__允許差在尾端補上的行尾(@blankTail@ 冪等,已是空行結尾就不動)——
-- 機械判定是 @T.stripEnd@ 之後兩者相同。'strictBytes' 給所有其他節用,'looseBytes' 只給
-- 插入點前一段用。
strictBytesUnchanged :: Document -> Document -> Id -> Expectation
strictBytesUnchanged beforeDoc afterDoc sid =
  fmap renderSection (find ((== sid) . secId) (docSections afterDoc))
    `shouldBe` fmap renderSection (find ((== sid) . secId) (docSections beforeDoc))

insertionPointBytesUnchangedModuloBlankTail :: Document -> Document -> Id -> Expectation
insertionPointBytesUnchangedModuloBlankTail beforeDoc afterDoc sid =
  fmap (T.stripEnd . renderSection) (find ((== sid) . secId) (docSections afterDoc))
    `shouldBe` fmap (T.stripEnd . renderSection) (find ((== sid) . secId) (docSections beforeDoc))

--------------------------------------------------------------------------------
-- E1 / L10: createTopicFile

spec :: Spec
spec = describe "graph-core/F008 Aapms.Store.Create" $ do
  describe "E1 / L10: createTopicFile" $ do
    it "E1: 落點依註冊表 dir,crPath = characters/琳達.md,crRevision = Revision 1,toTopic 解得 metaTitle == 琳達" $
      withFreshVault $ \vh -> do
        r <- createTopicFile vh regWithTypes (mkEntity (TypeKey "character") "characters" "琳達")
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right cr -> do
            crPath cr `shouldBe` "characters/琳達.md"
            crRevision cr `shouldBe` Revision 1
            raw <- orDie =<< readTextFile (vhRoot vh </> crPath cr)
            doc <- parseOrFail raw
            (ent, _frags) <- either (\e -> fail ("toTopic 失敗:" <> show e)) pure (toTopic doc)
            metaTitle (entMeta ent) `shouldBe` "琳達"

    it "L10: 對已知型別建檔,crPath 以該 dir 為前綴、以 .md 結尾;未知型別回 Left (RegistryDirUnknown t) 且不新增任何檔案" $
      withFreshVault $ \vh -> do
        forM_
          [ (TypeKey "character", "characters", "測試甲")
          , (TypeKey "item", "items", "測試乙")
          ]
          $ \(ty, dir, title) -> do
            r <- createTopicFile vh regWithTypes (mkEntity ty dir title)
            case r of
              Right cr -> do
                (T.pack dir <> "/") `T.isPrefixOf` T.pack (crPath cr) `shouldBe` True
                ".md" `T.isSuffixOf` T.pack (crPath cr) `shouldBe` True
              Left e -> expectationFailure ("預期成功,得到 " <> show e)
        before <- sort <$> listVaultFiles vh
        r2 <- createTopicFile vh regWithTypes (mkEntity (TypeKey "unknown-type") "?" "不存在型別")
        r2 `shouldBe` Left (RegistryDirUnknown (TypeKey "unknown-type"))
        after <- sort <$> listVaultFiles vh
        after `shouldBe` before

  --------------------------------------------------------------------------------
  -- E2 / L11: createLevelFile

  describe "E2 / L11: createLevelFile" $ do
    it "E2: 產生 levels/第一章.md;toLevel 回 Level 與恰好一個 Node,lvlRoot == 該 Node 的 metaId,根節點標題層級為 2" $
      withFreshVault $ \vh -> do
        let nl =
              NewLevel
                { nlTitle = "第一章"
                , nlSummary = "E2 摘要"
                , nlBody = "E2 主體"
                , nlStatus = Canon
                , nlSource = Human
                , nlRootTitle = "序幕"
                , nlRootKind = KScene
                , nlPath = Nothing
                }
        r <- createLevelFile vh regWithTypes nl
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right cr -> do
            crPath cr `shouldBe` "levels/第一章.md"
            raw <- orDie =<< readTextFile (vhRoot vh </> crPath cr)
            doc <- parseOrFail raw
            (lvl, nodes) <- either (\e -> fail ("toLevel 失敗:" <> show e)) pure (toLevel doc)
            length nodes `shouldBe` 1
            let rootId = metaId (nodMeta (head nodes))
            lvlRoot lvl `shouldBe` rootId
            case find ((== rootId) . secId) (docSections doc) of
              Just sec -> secLevel sec `shouldBe` 2
              Nothing -> expectationFailure "找不到根節點對應的 section"

    it "L11: 對多組標題,crPath 皆以 levels/ 為前綴,toLevel 成功、恰有一個 Node" $
      withFreshVault $ \vh ->
        forM_ [("第二章", "楔子"), ("尾聲", "終幕")] $ \(t, rt) -> do
          let nl =
                NewLevel
                  { nlTitle = T.pack t
                  , nlSummary = ""
                  , nlBody = ""
                  , nlStatus = Canon
                  , nlSource = Human
                  , nlRootTitle = T.pack rt
                  , nlRootKind = KScene
                  , nlPath = Nothing
                  }
          r <- createLevelFile vh regWithTypes nl
          case r of
            Left e -> expectationFailure ("預期成功,得到 " <> show e)
            Right cr -> do
              "levels/" `T.isPrefixOf` T.pack (crPath cr) `shouldBe` True
              raw <- orDie =<< readTextFile (vhRoot vh </> crPath cr)
              doc <- parseOrFail raw
              (_lvl, nodes) <- either (\e -> fail ("toLevel 失敗:" <> show e)) pure (toLevel doc)
              length nodes `shouldBe` 1

  --------------------------------------------------------------------------------
  -- E3 / L9: createPackFile

  describe "E3 / L9: createPackFile" $ do
    it "E3: [sA,sB,sC](皆 NSAsset)保留給定順序" $
      withFreshVault $ \vh -> do
        let np = mkPack "packs/e3-fixture"
            secs = [mkAssetSection (idOf "ast-0000000a") "a", mkAssetSection (idOf "ast-0000000b") "b", mkAssetSection (idOf "ast-0000000c") "c"]
        r <- createPackFile vh np secs
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right cr -> do
            crPath cr `shouldBe` "packs/e3-fixture/pack.md"
            raw <- orDie =<< readTextFile (vhRoot vh </> crPath cr)
            doc <- parseOrFail raw
            (_pack, assets) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc)
            map (metaId . astMeta) assets `shouldBe` [idOf "ast-0000000a", idOf "ast-0000000b", idOf "ast-0000000c"]

    it "L9: 對不同長度/順序的 [NewSection],toPack 解回的 asset 順序與長度都等於給定的 xs" $
      withFreshVault $ \vh ->
        forM_ (zip [1 :: Int ..] l9SamplePools) $ \(n, ids) -> do
          let dir = "packs/l9-fixture-" <> show n
              np = mkPack dir
              secs = [mkAssetSection i ("asset-" <> show k) | (k, i) <- zip [1 :: Int ..] ids]
          r <- createPackFile vh np secs
          case r of
            Left e -> expectationFailure ("預期成功,得到 " <> show e)
            Right cr -> do
              raw <- orDie =<< readTextFile (vhRoot vh </> crPath cr)
              doc <- parseOrFail raw
              (_pack, assets) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc)
              length assets `shouldBe` length ids
              map (metaId . astMeta) assets `shouldBe` ids

  --------------------------------------------------------------------------------
  -- L25 / E22(2026-08-25 G17 裁決):createPackFile 的 pack 專屬七欄往返。
  -- __現在會紅,而且要一直紅到 F004 補上檔案層 extras 為止——這正是它的價值,不弱化__。

  describe "L25 / E22: createPackFile 的 pack 專屬七欄往返(G17,現在會紅,見模組說明)" $
    it "E22: 七個 pack 專屬欄位全給非預設值,重讀後 toPack 解出的 Pack 七欄逐欄等於傳入的 NewPack" $
      withFreshVault $ \vh -> do
        let npNonDefault =
              (mkPack "packs/e22-fixture")
                { npVendor = Just "Kenney"
                , npArchive = Just "packs/kenney-ui.zip"
                , npSha256 = Just (Sha256 "aa1122334455aa1122334455aa1122334455aa1122334455aa1122334455aa")
                , npLicense = Just (localRef (idOf "lic-0000000a"))
                , npAuthor = Just (Author "Kenney" (Just "https://kenney.nl") Nothing)
                , npSourceUrl = Just "https://kenney.nl/assets/ui-pack"
                , npAiDisclosure = AiNone
                }
            secs = [mkAssetSection (idOf "ast-0000000e") "e22"]
        r <- createPackFile vh npNonDefault secs
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right cr -> do
            raw <- orDie =<< readTextFile (vhRoot vh </> crPath cr)
            doc <- parseOrFail raw
            (pck, _assets) <- either (\e -> fail ("toPack 失敗:" <> show e)) pure (toPack doc)
            pckVendor pck `shouldBe` npVendor npNonDefault
            pckArchive pck `shouldBe` npArchive npNonDefault
            pckSha256 pck `shouldBe` npSha256 npNonDefault
            pckLicense pck `shouldBe` npLicense npNonDefault
            pckAuthor pck `shouldBe` npAuthor npNonDefault
            pckSourceUrl pck `shouldBe` npSourceUrl npNonDefault
            pckAiDisclosure pck `shouldBe` npAiDisclosure npNonDefault

  --------------------------------------------------------------------------------
  -- addSection:L12a(AtEnd)、E10(BadSectionPayload)

  describe "L12a: addSection AtEnd 追加在檔尾、不動前面既有節(G14 裁決:插入點前一段允許 blankTail 補行尾)" $
    it "對主題檔追加一個片段:插入點之前的既有節(ent-00000003)至多差在補行尾,更早的節(ent-00000002)逐位元組不變,新節排在最後,toTopic 仍成功" $
      withIndexedStoryVault $ \vh -> do
        let topicPath = "characters/test-character.md"
        beforeDoc <- parseOrFail =<< (orDie =<< readTextFile (vhRoot vh </> topicPath))
        let newFrag =
              NewSection
                { nsId = idOf "ent-00000009"
                , nsLevel = 2
                , nsTitle = "新片段"
                , nsBody = "新片段內文"
                , nsPayload = NSFragment emptyOverride
                }
        r <- addSection vh (idOf "ent-00000001") AtEnd newFrag
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right cr -> crId cr `shouldBe` idOf "ent-00000009"
        afterDoc <- parseOrFail =<< (orDie =<< readTextFile (vhRoot vh </> topicPath))
        -- ent-00000002 在插入點(檔尾追加的插入點是原本最後一節 ent-00000003)之前,不受但書影響
        strictBytesUnchanged beforeDoc afterDoc (idOf "ent-00000002")
        -- ent-00000003 是 AtEnd 的插入點前一段,至多允許補行尾(blankTail 冪等)
        insertionPointBytesUnchangedModuloBlankTail beforeDoc afterDoc (idOf "ent-00000003")
        map secId (docSections afterDoc)
          `shouldBe` map secId (docSections beforeDoc) ++ [idOf "ent-00000009"]
        _ <- either (\e -> fail ("toTopic 失敗:" <> show e)) pure (toTopic afterDoc)
        pure ()

  describe "E10: addSection payload 與文件種類不符" $
    it "對 pack.md 傳 NSFragment payload,回 Left (BadSectionPayload (nsId s) PackDoc),檔案不變" $
      withIndexedAssetVault $ \vh -> do
        let packPath = "library/packs/test-vendor/test-pack/pack.md"
            badSection =
              NewSection
                { nsId = idOf "ast-00000009"
                , nsLevel = 2
                , nsTitle = "壞資料"
                , nsBody = ""
                , nsPayload = NSFragment emptyOverride
                }
        beforeRaw <- orDie =<< readTextFile (vhRoot vh </> packPath)
        r <- addSection vh (idOf "pck-00000001") AtEnd badSection
        r `shouldBe` Left (BadSectionPayload (idOf "ast-00000009") PackDoc)
        afterRaw <- orDie =<< readTextFile (vhRoot vh </> packPath)
        afterRaw `shouldBe` beforeRaw

  --------------------------------------------------------------------------------
  -- addSection UnderParent:E12(=L12b)、E13、E14(=L12c 的兩條失敗路徑)

  describe "L12b / E12 / L12c / E13 / E14: addSection UnderParent" $ do
    it "E12/L12b: 插在「開場」之後、「收束」之前;nsLevel(呼叫端故意給 2)被 headingDepthFor 推導的 4 覆寫;插入點之後逐位元組不變,插入點前一段(開場)至多差在補行尾" $
      withE12Vault $ \vh -> do
        beforeDoc <- parseOrFail =<< (orDie =<< readTextFile (levelE12AbsPath vh))
        let newNode =
              NewSection
                { nsId = idOf "nod-e0000004"
                , nsLevel = 2 -- 故意給錯,驗證 store 以 headingDepthFor 覆寫,不理會這個值
                , nsTitle = "新節點"
                , nsBody = "新節點內文"
                , nsPayload = NSNode emptyOverride (NewNode KScene)
                }
        r <- addSection vh (idOf "lvl-e0000001") (UnderParent (idOf "nod-e0000002")) newNode
        case r of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right cr -> crId cr `shouldBe` idOf "nod-e0000004"
        afterDoc <- parseOrFail =<< (orDie =<< readTextFile (levelE12AbsPath vh))
        -- 開場(nod-e0000002)的子樹是空的(k=0),所以插入點前一段就是開場自己
        map secId (docSections afterDoc)
          `shouldBe` map idOf ["nod-e0000001", "nod-e0000002", "nod-e0000004", "nod-e0000003", "nod-e0000006", "nod-e0000007", "nod-e0000005"]
        strictBytesUnchanged beforeDoc afterDoc (idOf "nod-e0000001")
        insertionPointBytesUnchangedModuloBlankTail beforeDoc afterDoc (idOf "nod-e0000002")
        forM_ [idOf "nod-e0000003", idOf "nod-e0000006", idOf "nod-e0000007", idOf "nod-e0000005"] $
          strictBytesUnchanged beforeDoc afterDoc
        case find ((== idOf "nod-e0000004") . secId) (docSections afterDoc) of
          Just sec -> secLevel sec `shouldBe` 4
          Nothing -> expectationFailure "找不到新節"
        (lvl, nodes) <- either (\e -> fail ("toLevel 失敗:" <> show e)) pure (toLevel afterDoc)
        _ <- either (\es -> fail ("buildTree 失敗:" <> show es)) pure (buildTree lvl nodes)
        case find ((== idOf "nod-e0000004") . metaId . nodMeta) nodes of
          Just n -> nodParent n `shouldBe` Just (idOf "nod-e0000002")
          Nothing -> expectationFailure "找不到新節的 Node"

    it "E13: 父節點不在檔案裡,回 Left (SectionMissing path p),檔案不變" $
      withE12Vault $ \vh -> do
        beforeRaw <- orDie =<< readTextFile (levelE12AbsPath vh)
        let missing = idOf "nod-99999999"
            newNode =
              NewSection
                { nsId = idOf "nod-e0000099"
                , nsLevel = 2
                , nsTitle = "不會用到"
                , nsBody = ""
                , nsPayload = NSNode emptyOverride (NewNode KScene)
                }
        r <- addSection vh (idOf "lvl-e0000001") (UnderParent missing) newNode
        r `shouldBe` Left (SectionMissing levelE12RelPath missing)
        afterRaw <- orDie =<< readTextFile (levelE12AbsPath vh)
        afterRaw `shouldBe` beforeRaw

    it "E14: 父節點已是六級標題,回 Left (NodeDepthExceeded p 7),檔案不變" $
      withE12Vault $ \vh -> do
        beforeRaw <- orDie =<< readTextFile (levelE12AbsPath vh)
        let newNode =
              NewSection
                { nsId = idOf "nod-e0000099"
                , nsLevel = 2
                , nsTitle = "不會用到"
                , nsBody = ""
                , nsPayload = NSNode emptyOverride (NewNode KScene)
                }
        r <- addSection vh (idOf "lvl-e0000001") (UnderParent (idOf "nod-e0000005")) newNode
        r `shouldBe` Left (NodeDepthExceeded (idOf "nod-e0000005") 7)
        afterRaw <- orDie =<< readTextFile (levelE12AbsPath vh)
        afterRaw `shouldBe` beforeRaw

  --------------------------------------------------------------------------------
  -- deleteNode:E8、L13

  describe "E8: deleteNode 根 Node 刪不得(兩種模式皆擋)" $
    it "DeleteSafe 與 DeleteForce 皆回 Left (CannotDeleteRootNode root),檔案不變" $
      withIndexedStoryVault $ \vh -> do
        let levelPath = "levels/test-classroom.md"
        beforeRaw <- orDie =<< readTextFile (vhRoot vh </> levelPath)
        beforeDoc <- parseOrFail beforeRaw
        -- 不假設根 Node 的 revision 繼承自檔案層(那是另一條假設鏈);直接讀目前
        -- 的實際值,確保無論 CannotDeleteRootNode 與 RevisionMismatch 的檢查順序
        -- 為何,樂觀鎖都不會是導致這個結果的原因。
        (_lvl, nodes) <- either (\e -> fail ("toLevel 失敗:" <> show e)) pure (toLevel beforeDoc)
        rootRevision <- case find ((== idOf "nod-00000001") . metaId . nodMeta) nodes of
          Just n -> pure (metaRevision (nodMeta n))
          Nothing -> fail "找不到根節點 nod-00000001"
        forM_ [DeleteSafe, DeleteForce] $ \mode -> do
          r <- deleteNode vh (idOf "nod-00000001") rootRevision mode
          r `shouldBe` Left (CannotDeleteRootNode (idOf "nod-00000001"))
        afterRaw <- orDie =<< readTextFile (vhRoot vh </> levelPath)
        afterRaw `shouldBe` beforeRaw

  describe "L13: deleteNode 的兩種模式(以主題檔的檔案層主體為目標)" $
    it "DeleteSafe 對被引用的目標回 Left (ReferencedBy …) 且檔案不變;DeleteForce 照刪,drRemovedIds/drBrokenLinks 正確,檔案消失" $
      withIndexedStoryVault $ \vh -> do
        let topicPath = "characters/test-character.md"
            victims = map idOf ["ent-00000001", "ent-00000002", "ent-00000003"]
            expectedBroken = (idOf "nod-00000002", Link Involves (localRef (idOf "ent-00000001")) Nothing)
        beforeRaw <- orDie =<< readTextFile (vhRoot vh </> topicPath)
        rSafe <- deleteNode vh (idOf "ent-00000001") (Revision 1) DeleteSafe
        case rSafe of
          Left (ReferencedBy i vs) -> do
            i `shouldBe` idOf "ent-00000001"
            vs `shouldSatisfy` elem expectedBroken
          other -> expectationFailure ("預期 Left (ReferencedBy _ _),得到 " <> show other)
        afterSafeRaw <- orDie =<< readTextFile (vhRoot vh </> topicPath)
        afterSafeRaw `shouldBe` beforeRaw

        rForce <- deleteNode vh (idOf "ent-00000001") (Revision 1) DeleteForce
        case rForce of
          Left e -> expectationFailure ("預期成功,得到 " <> show e)
          Right dr -> do
            drPath dr `shouldBe` topicPath
            drRemovedIds dr `shouldBe` victims
            drBrokenLinks dr `shouldSatisfy` elem expectedBroken
        stillThere <- doesFileExist (vhRoot vh </> topicPath)
        stillThere `shouldBe` False

--------------------------------------------------------------------------------
-- createPackFile 用的固定素材

mkPack :: FilePath -> NewPack
mkPack dir =
  NewPack
    { npDir = dir
    , npTitle = "CreateSpec Pack"
    , npSummary = "CreateSpec 用摘要"
    , npBody = "CreateSpec 用主體"
    , npTags = []
    , npStatus = Canon
    , npSource = Scan
    , npVendor = Nothing
    , npArchive = Nothing
    , npSha256 = Nothing
    , npLicense = Nothing
    , npAuthor = Nothing
    , npSourceUrl = Nothing
    , npAiDisclosure = AiUnknown
    }

mkAssetSection :: Id -> String -> NewSection
mkAssetSection i label =
  NewSection
    { nsId = i
    , nsLevel = 2
    , nsTitle = T.pack label
    , nsBody = ""
    , nsPayload =
        NSAsset
          emptyOverride {moType = Just (TypeKey "asset-image")}
          NewAsset
            { naName = Nothing
            , naSha256 = Sha256 (T.replicate 64 "1")
            , naEntry = "PNG/" <> T.pack label <> ".png"
            , naExt = Nothing
            , naKindMeta = Null
            , naLicense = Nothing
            , naAuthor = Nothing
            }
    }

-- | L9 用的三組代表性 id 池:單一元素、逆序、四元素洗牌。__三組彼此完全不相交__
-- (編排者歸因:短 id 依 ADR-014 是 vault 內唯一,不是檔案內唯一;三組全在同一個
-- 'withFreshVault' 裡跑,跨組重複的 id 本來就會撞 @nodes.id@ 主鍵)。
l9SamplePools :: [[Id]]
l9SamplePools =
  [ [idOf "ast-00000001"]
  , [idOf "ast-00000006", idOf "ast-00000005", idOf "ast-00000004"]
  , [idOf "ast-0000000d", idOf "ast-0000000a", idOf "ast-0000000c", idOf "ast-0000000b"]
  ]

--------------------------------------------------------------------------------
-- E12 / E13 / E14 用的 Level 檔 fixture:序幕(根,2級)→ 開場(3級)、收束(3級,
-- 與開場同層兄弟),收束之後__逐級遞增__鋪到深一(4級)→深二(5級)→最深(6級,供 E14 用)。
-- ADR-009 標題階層即樹,不可跳級(編排者歸因:原本從 3 級直接跳到 6 級,不是合法 Level 檔)。

levelE12RelPath :: FilePath
levelE12RelPath = "levels/e12-fixture.md"

levelE12AbsPath :: VaultHandle -> FilePath
levelE12AbsPath vh = vhRoot vh </> levelE12RelPath

levelE12Md :: T.Text
levelE12Md =
  T.unlines
    [ "---"
    , "id: lvl-e0000001"
    , "vault: liftgame"
    , "type: level"
    , "title: E12 場景"
    , "summary: addSection UnderParent 用"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-21"
    , "updated: 2026-08-21"
    , "---"
    , ""
    , "場景整體說明。"
    , ""
    , "## 序幕 {#nod-e0000001}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "### 開場 {#nod-e0000002}"
    , ""
    , "```meta"
    , "kind: cast"
    , "```"
    , ""
    , "### 收束 {#nod-e0000003}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "#### 深一 {#nod-e0000006}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "##### 深二 {#nod-e0000007}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    , ""
    , "###### 最深 {#nod-e0000005}"
    , ""
    , "```meta"
    , "kind: scene"
    , "```"
    ]

-- | 編排者歸因(第二輪):原本忘了 'rebuildIndex','locate' 因此在索引裡查不到任何 id,
-- 全部回 'NodeNotFound'——這不是 spec bug,是這個 fixture helper 本身漏了一步。
withE12Vault :: (VaultHandle -> IO a) -> IO a
withE12Vault act = withTempVault $ \dir -> do
  _ <- orDie =<< initVaultAt dir StoryVault "e12-fixture"
  writeFiles dir [(levelE12RelPath, levelE12Md)]
  (vh, _issues) <- orDie =<< openVault regWithTypes dir
  _ <- orDie =<< rebuildIndex vh
  r <- act vh
  closeVault vh
  pure r

--------------------------------------------------------------------------------
-- L10 用:除 @.aapms@ 外的整個 vault 檔案清單(相對路徑,已排序)。

listVaultFiles :: VaultHandle -> IO [FilePath]
listVaultFiles vh = walk (vhRoot vh)
  where
    walk dir = do
      entries <- filter (/= ".aapms") <$> listDirectory dir
      fmap concat . mapM (step dir) $ entries
    step dir e = do
      let p = dir </> e
      isDir <- doesDirectoryExist p
      if isDir then walk p else pure [p]
