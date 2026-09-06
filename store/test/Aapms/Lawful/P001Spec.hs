-- | lawful 測試:P-001-index-rebuild(qa 填入)。
--
-- 每條 @LAW-n@ 一個 @describe "P-001#LAW-n"@ 的 property test,每個 @EX-n@
-- 一個 @describe "P-001#EX-n"@ 的 example test。斷言逐字照 pipeline 檔的
-- @|-@ 行翻譯(@nub@ \/ @rights@ \/ @isRight@ \/ @member@ \/ @lookup@ 等識別字
-- 對應到 @Data.List@ \/ @Data.Either@ \/ @Data.Map.Strict@ 的同名函數,
-- @in@ 對清單是 @elem@)。
--
-- __效果怎麼跑__:pipeline 的 @=@ 列 'rebuild' 與 'refresh' \/ 'indexPath' 都是
-- 效果程式,laws 一律透過觀察點 'simulate'(@VaultFs@ 與 @Index@ 兩個純解譯器
-- 串起來跑到底)取值,測試不碰 IO。
--
-- __合法的 Markdown 從哪裡來__:一律由 P-025-md-document 的 stage 反向產 ——
-- 檔案層 frontmatter 走 @renderDocument (newDocument kind meta preamble)@,
-- 節層 meta 區塊走 @renderMetaBlock@,測試自己只拼標題行與正文,不手寫
-- frontmatter 或 meta 區塊的格式。
--
-- __指紋怎麼來__:每個檔的 'FileStat' 由內容推導(@size@ 是字元數、@mtime@ 是
-- 內容的 FNV-1a 低 32 位),所以「同一個路徑內容不同 ⇒ 指紋不同」是建構上成立
-- 的,LAW-5 的 @given statsDistinguish vf1 vf2@ 不必靠過濾。
--
-- __案例數__:@hspec-hedgehog@ 的 @Example (PropertyT IO ())@ instance 會把
-- hedgehog 的 @TestLimit@ 直接覆寫成 hspec 的 @maxSuccess@,因此 @withTests@
-- 寫在 property 上不會生效;等價寫法是 @modifyMaxSuccess (const 100)@ 包住
-- 整個模組(見 'spec')。
--
-- __尺寸__:全部 'Range' 上限都是常數 —— vault 最多六個固定路徑的檔、每個檔
-- 最多兩個節、文字取自固定字彙池或長度上限 32 的產生器,不產生無界結構。
--
-- __timeout__:整個模組經 'around_' 對每個 example 套 60 秒上限。
module Aapms.Lawful.P001Spec (spec) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad.IO.Class (liftIO)
import Data.Bits ((.&.))
import Data.Either (isRight, rights)
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (Day, fromGregorian)
import System.Timeout (timeout)

import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (assert, forAll, hedgehog, modifyMaxSuccess, (===))

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id
  ( Id
  , IdPrefix (..)
  , VaultId (..)
  , fnv1a64
  , parseId
  , renderId
  , renderIdPrefix
  )
import Aapms.Core.Level (NodeKind (..))
import Aapms.Core.Meta
  ( Meta (..)
  , Revision (..)
  , Source (..)
  , Status (..)
  , TypeKey (..)
  )
import Aapms.Core.Registry
  ( Family (..)
  , TypeDecl (..)
  , TypeRegistry
  , buildRegistry
  )
import Aapms.Md.Document (DocKind (..), LineEnding (..))
import Aapms.Md.Render (newDocument, renderDocument, renderMetaBlock)
import Aapms.Md.Section (MetaExtras (..), MetaOverride (..), emptyOverride)

import Aapms.Store.Indexing (indexDocument, indexPath, rebuild, refresh, staleFiles)
import Aapms.Store.Indexing.Internal (clashesEarlier, simulate)
import Aapms.Store.Types
  ( FileIndex (..)
  , FileStat (..)
  , IndexIssue (..)
  , IndexState (..)
  , IndexedNode (..)
  , VaultFiles
  , assetNames
  , emptyIndex
  , fileAt
  , indexedIds
  , indexedNodes
  , indexedPaths
  , statsDistinguish
  , vaultPaths
  , warnedIds
  )

--------------------------------------------------------------------------------
-- 固定值

fixedDay :: Day
fixedDay = fromGregorian 2026 1 1

-- | 'Id' 的建構子沒有匯出,一律走型別層的 smart constructor 'parseId'。
mkId :: IdPrefix -> Text -> Id
mkId p hex = case parseId (renderIdPrefix p <> "-" <> hex) of
  Right (_, i) -> i
  Left e -> error ("P-001Spec:測試 id 不合法 " <> show e)

-- | 檔案層 Meta。@vault@ 刻意寫成 'vaultInFile' 而不是重建時給的 'VaultId' ——
-- LAW-7 \/ EX-9 的「不信檔案自己寫的」才觀察得到。
metaOf :: IdPrefix -> Text -> TypeKey -> Text -> Meta
metaOf p hex ty title =
  Meta
    { metaId = mkId p hex
    , metaVault = vaultInFile
    , metaType = ty
    , metaTitle = title
    , metaSummary = ""
    , metaTags = []
    , metaStatus = Draft
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = Revision 1
    , metaCreated = fixedDay
    , metaUpdated = fixedDay
    }

-- | 檔案裡寫的 vault id。與 'vaultA' \/ 'vaultB' 都不同。
vaultInFile :: VaultId
vaultInFile = VaultId "vlt-00000000"

vaultA, vaultB :: VaultId
vaultA = VaultId "vlt-7f3b2a91"
vaultB = VaultId "vlt-0000000a"

--------------------------------------------------------------------------------
-- 指紋與記憶體 vault

-- | 由內容推導的指紋:@size@ 是字元數,@mtime@ 是內容的 FNV-1a 低 32 位
-- ('Aapms.Core.Id.fnv1a64' 是型別層匯出的純函數)。內容一變指紋就變,
-- LAW-5 的 @given@ 因此是建構上成立的。
statOf :: Text -> FileStat
statOf t =
  FileStat
    (fromIntegral (fnv1a64 (TE.encodeUtf8 t) .&. 0xFFFFFFFF) :: Int64)
    (fromIntegral (T.length t))

vaultFilesOf :: [(FilePath, Text)] -> VaultFiles
vaultFilesOf = Map.fromList . map (\(p, t) -> (p, (statOf t, t)))

--------------------------------------------------------------------------------
-- 合法的 Markdown:一律由 P-025-md-document 的 stage 反向產

-- | 一份檔:@newDocument@ 產出檔案層 frontmatter 與 preamble,@renderDocument@
-- 寫成文字,再把各節接在後面。
fileTextOf :: DocKind -> Meta -> Text -> [Text] -> Text
fileTextOf kind m preamble secs =
  renderDocument (newDocument kind m preamble) <> T.concat secs

-- | 一節:標題行(含 @{#id}@ 錨點)+ @renderMetaBlock@ 產出的 meta 區塊 + 正文。
sectionTextOf :: Int -> Id -> Text -> MetaOverride -> [Text] -> Text -> Text
sectionTextOf lvl i title ov extras body =
  "\n"
    <> T.replicate lvl "#"
    <> " "
    <> title
    <> " {#"
    <> renderId i
    <> "}\n\n"
    <> renderMetaBlock ov (MetaExtras extras) LF
    <> "\n"
    <> body
    <> "\n"

-- | 主題檔:檔案層主體加零到多個片段。
topicMd :: Text -> TypeKey -> [Text] -> Text -> Text
topicMd hex ty frags body =
  fileTextOf TopicDoc (metaOf PEnt hex ty "主體") body $
    [ sectionTextOf
        2
        (mkId PEnt f)
        ("片段 " <> f)
        emptyOverride {moType = Just (TypeKey "character-fragment")}
        []
        "片段正文。"
    | f <- frags
    ]

-- | Level 檔。每一列是(標題層級, 節點 id 的十六進位),層級即樹(ADR-009)。
levelMd :: [(Int, Text)] -> Text
levelMd nodes =
  fileTextOf LevelDoc (metaOf PLvl "00000005" (TypeKey "level") "場景") "場景說明。\n" $
    [ sectionTextOf
        d
        (mkId PNod h)
        ("節點 " <> h)
        emptyOverride {moKind = Just KScene}
        []
        "節點正文。"
    | (d, h) <- nodes
    ]

-- | 合法的 Level 檔:一個根加一個子節點。
levelOkMd :: Text
levelOkMd = levelMd [(2, "00000001"), (3, "00000002")]

-- | 樹不合法的 Level 檔:兩個最淺層級的標題(多重根)。
levelMultiRootMd :: Text
levelMultiRootMd = levelMd [(2, "00000001"), (2, "00000002")]

-- | 樹不合法的 Level 檔:@nod-0000000b@ 底下又是 @nod-0000000b@ ——
-- 那一節的父節點就是它自己(EX-3 的「以自己為 parent」)。
levelSelfParentMd :: Text
levelSelfParentMd = levelMd [(2, "0000000b"), (3, "0000000b")]

-- | @pack.md@。每一列是(asset id 的十六進位, 邏輯名稱)。
packMd :: Text -> [(Text, Maybe Text)] -> Text
packMd hex assets =
  fileTextOf PackDoc (metaOf PPck hex (TypeKey "asset-pack") "素材包") "素材包說明。\n" $
    [ sectionTextOf
        2
        (mkId PAst a)
        ("素材 " <> a)
        emptyOverride {moType = Just (TypeKey "asset-image")}
        ( [ "entry: img/" <> a <> ".png"
          , "sha256: \"" <> a <> "0000\""
          ]
            <> maybe [] (\n -> ["name: " <> n]) nm
        )
        "素材說明。"
    | (a, nm) <- assets
    ]

-- | @licenses.md@。每一節一種授權,兩個必填維度一定寫。
licensesMd :: [Text] -> Text
licensesMd hexes =
  fileTextOf
    LicenseDoc
    (metaOf PLic "00000006" (TypeKey "asset-license") "授權登記")
    "本檔登記全部授權。\n"
    [ sectionTextOf
        2
        (mkId PLic h)
        ("授權 " <> h)
        emptyOverride
        ["commercial: true", "attribution_required: false"]
        ""
    | h <- hexes
    ]

-- | 解析不開的檔(P-025-md-document 的 EX-2 逐字)。
brokenMd :: Text
brokenMd = "---\nid: [broken"

--------------------------------------------------------------------------------
-- 型別註冊表

-- | 'TypeRegistry' 沒有 'Show' 實例,@forAll@ 需要 'Show';產生器因此產這個
-- 標籤,再由 'regOf' 換成註冊表。
data RegPick = RegFull | RegEmpty
  deriving stock (Show, Eq)

regOf :: RegPick -> TypeRegistry
regOf RegFull = regFull
regOf RegEmpty = regNone

typeDecl :: Text -> Family -> Maybe FilePath -> Maybe TypeKey -> TypeDecl
typeDecl k fam dir owner =
  TypeDecl
    { tdKey = TypeKey k
    , tdName = k
    , tdFamily = fam
    , tdDir = dir
    , tdOwnerType = owner
    , tdAllowedLinks = []
    , tdStages = []
    , tdFields = []
    , tdNameKinds = []
    }

mkRegistry :: [TypeDecl] -> TypeRegistry
mkRegistry ds = case buildRegistry ds of
  Right r -> r
  Left e -> error ("P-001Spec:測試註冊表不合法 " <> show e)

-- | 樣本檔用到的三個型別都宣告齊(@level@ \/ @asset-pack@ \/ @asset-license@ 是
-- 保留鍵,'buildRegistry' 不收)。
regFull :: TypeRegistry
regFull =
  mkRegistry
    [ typeDecl "character" FEntity (Just "characters") Nothing
    , typeDecl "character-fragment" FEntity Nothing (Just (TypeKey "character"))
    , typeDecl "asset-image" FAsset Nothing Nothing
    ]

-- | 空註冊表:每個節點的型別都查不到。
regNone :: TypeRegistry
regNone = mkRegistry []

--------------------------------------------------------------------------------
-- 產生器

genRegPick :: Gen RegPick
genRegPick = Gen.element [RegFull, RegEmpty]

genVaultId :: Gen VaultId
genVaultId = Gen.element [vaultA, vaultB]

-- | 主題檔槽:型別可能在註冊表裡(@character@)或不在(@ghost@),片段取子序列,
-- 偶爾整份是壞檔。
genTopicSlot :: Text -> [Text] -> Gen Text
genTopicSlot hex frags =
  Gen.frequency
    [
      ( 4
      , do
          ty <- Gen.element [TypeKey "character", TypeKey "ghost"]
          fs <- Gen.subsequence frags
          body <- Gen.element ["主體概述。\n", "另一段概述。\n"]
          pure (topicMd hex ty fs body)
      )
    , (1, pure brokenMd)
    ]

-- | Level 檔槽:合法的樹、多重根的樹、壞檔各佔一份。
genLevelSlot :: Gen Text
genLevelSlot =
  Gen.frequency
    [ (3, pure levelOkMd)
    , (1, pure levelMultiRootMd)
    , (1, pure brokenMd)
    ]

-- | @pack.md@ 槽:邏輯名稱取自兩個名字的小池,兩份 pack 因此可能撞名。
genPackSlot :: Text -> Text -> Gen Text
genPackSlot hex assetHex =
  Gen.frequency
    [
      ( 4
      , do
          nm <-
            Gen.element
              [Nothing, Just "ui_gui_frame_001", Just "ui_gui_map_001"]
          pure (packMd hex [(assetHex, nm)])
      )
    , (1, pure brokenMd)
    ]

genLicensesSlot :: Gen Text
genLicensesSlot =
  Gen.frequency
    [ (4, licensesMd <$> Gen.subsequence ["0000000c", "0000000d"])
    , (1, pure brokenMd)
    ]

-- | 六個固定路徑的檔案槽。id 在 vault 內兩兩不同。
allSlots :: [(FilePath, Gen Text)]
allSlots =
  [ ("a/pack.md", genPackSlot "00000001" "00000010")
  , ("b/pack.md", genPackSlot "00000002" "00000020")
  , ("characters/琳達.md", genTopicSlot "00000003" ["0000000a", "0000000b"])
  , ("levels/教室.md", genLevelSlot)
  , ("licenses.md", genLicensesSlot)
  , ("lore/history.md", genTopicSlot "00000004" [])
  ]

-- | 記憶體 vault:固定路徑的子序列,每個檔各自產內容,指紋由內容推導。
genVaultFiles :: Gen VaultFiles
genVaultFiles = do
  picks <- Gen.subsequence allSlots
  entries <- mapM (\(p, g) -> (\t -> (p, (statOf t, t))) <$> g) picks
  pure (Map.fromList entries)

-- | 任意舊索引(LAW-2 的 @ix0@)。內容與 vault 無關,重建本來就該把它整個換掉。
genIndexState :: Gen IndexState
genIndexState = do
  picks <- Gen.subsequence [("old/a.md", TopicDoc), ("characters/琳達.md", TopicDoc)]
  entries <-
    mapM
      ( \(p, k) -> do
          n <- Gen.int (Range.linear 0 2)
          ref <- Gen.bool
          let nodes =
                [ IndexedNode
                  { inNode =
                      NEntity
                        Entity
                          { entMeta = metaOf PEnt (oldHex j) (TypeKey "character") "舊節點"
                          , entBody = ""
                          }
                  , inOwner = Nothing
                  }
                | j <- [1 .. n]
                ]
          pure (p, FileIndex p k (FileStat 0 0) ref nodes)
      )
      picks
  pure (IndexState (Map.fromList entries))
  where
    oldHex j = T.justifyRight 8 '0' (T.pack (show (900 + j :: Int)))

statPool :: [FileStat]
statPool = [FileStat 1 1, FileStat 2 2, FileStat 9 9]

pathPool :: [FilePath]
pathPool = ["a.md", "b.md", "c.md", "d.md"]

genStatMap :: Gen (Map FilePath FileStat)
genStatMap = do
  ps <- Gen.subsequence pathPool
  entries <- mapM (\p -> (,) p <$> Gen.element statPool) ps
  pure (Map.fromList entries)

genFileStat :: Gen FileStat
genFileStat =
  FileStat
    <$> Gen.integral (Range.linear 0 100)
    <*> Gen.integral (Range.linear 0 100)

genAnyPath :: Gen FilePath
genAnyPath =
  Gen.element ["x.md", "", "characters/琳達.md", "a/pack.md", "levels/教室.md"]

-- | LAW-9 的 @txt in Text@:合法檔、壞檔、空字串與亂碼都在定義域裡。
genAnyText :: Gen Text
genAnyText =
  Gen.frequency
    [ (1, pure "")
    , (2, pure brokenMd)
    ,
      ( 3
      , Gen.element
          [ topicMd "00000003" (TypeKey "character") ["0000000a"] "主體概述。\n"
          , levelOkMd
          , levelSelfParentMd
          , packMd "00000001" [("00000010", Just "ui_gui_frame_001")]
          , licensesMd ["0000000c"]
          ]
      )
    , (3, Gen.text (Range.linear 0 32) (Gen.element ("-\n idbroken:[]{}琳" :: String)))
    ]

--------------------------------------------------------------------------------
-- Example 用的具體 vault

pathLinda, pathHistory, pathLevel, pathPackA, pathPackB, pathGhost :: FilePath
pathLinda = "characters/琳達.md"
pathHistory = "lore/history.md"
pathLevel = "levels/教室.md"
pathPackA = "a/pack.md"
pathPackB = "b/pack.md"
pathGhost = "characters/幽靈.md"

-- | EX-2 \/ EX-9 \/ EX-11:一份主題檔,主體加兩個片段。
vfLinda :: VaultFiles
vfLinda =
  vaultFilesOf
    [ ( pathLinda
      , topicMd "00000003" (TypeKey "character") ["0000000a", "0000000b"] "主體概述。\n"
      )
    ]

-- | EX-3:樹不合法的 Level 檔,加同 vault 的一份主題檔。
vfCycle :: VaultFiles
vfCycle =
  vaultFilesOf
    [ (pathLevel, levelMultiRootMd)
    , (pathLinda, topicMd "00000003" (TypeKey "character") [] "主體概述。\n")
    ]

-- | EX-4:兩份 pack 檔的 asset 邏輯名稱相同,路徑字母序 @a\/pack.md@ 在前。
dupName :: Text
dupName = "ui_gui_frame_001"

vfDupName :: VaultFiles
vfDupName =
  vaultFilesOf
    [ (pathPackA, packMd "00000001" [("00000010", Just dupName)])
    , (pathPackB, packMd "00000002" [("00000020", Just dupName)])
    ]

-- | EX-5:主題檔的 @type@ 是註冊表沒有的 @ghost@。
ghostId :: Id
ghostId = mkId PEnt "00000007"

vfGhost :: VaultFiles
vfGhost =
  vaultFilesOf
    [(pathGhost, topicMd "00000007" (TypeKey "ghost") [] "幽靈概述。\n")]

-- | EX-6:同一份 @lore\/history.md@ 的前後兩版,正文改一字且字數變。
vfHistory1, vfHistory2 :: VaultFiles
vfHistory1 =
  vaultFilesOf
    [(pathHistory, topicMd "00000004" (TypeKey "character") [] "崩塌前的歷史。\n")]
vfHistory2 =
  vaultFilesOf
    [(pathHistory, topicMd "00000004" (TypeKey "character") [] "崩塌前後的歷史。\n")]

-- | EX-7:磁碟有 a(指紋 1)、b(指紋 2)、c;索引有 a(指紋 1)、b(指紋 9)、d。
diskEx7, recEx7 :: Map FilePath FileStat
diskEx7 =
  Map.fromList [("a.md", FileStat 1 1), ("b.md", FileStat 2 2), ("c.md", FileStat 3 3)]
recEx7 =
  Map.fromList [("a.md", FileStat 1 1), ("b.md", FileStat 9 9), ("d.md", FileStat 4 4)]

-- | EX-10:三個檔的指紋表。
mEx10 :: Map FilePath FileStat
mEx10 =
  Map.fromList [("a.md", FileStat 1 1), ("b.md", FileStat 2 2), ("c.md", FileStat 9 9)]

-- | 一次重建的 issues(@Left@ 時是空清單)。
issuesOf :: Either e [IndexIssue] -> [IndexIssue]
issuesOf = either (const []) id

isTreeInvalidAt :: FilePath -> IndexIssue -> Bool
isTreeInvalidAt fp = \case
  TreeInvalid p _ -> p == fp
  _ -> False

isDupNameAt :: FilePath -> IndexIssue -> Bool
isDupNameAt fp = \case
  DuplicateAssetName p _ -> p == fp
  _ -> False

isMetaWarning :: IndexIssue -> Bool
isMetaWarning = \case
  MetaWarningsFound {} -> True
  _ -> False

--------------------------------------------------------------------------------
-- spec

-- | 每個 example 60 秒上限;逾時視同失敗。
perItemTimeout :: IO () -> IO ()
perItemTimeout act = do
  r <- timeout (60 * 1000000) act
  maybe (expectationFailure "P-001 測試逾時(60 秒)") pure r

spec :: Spec
spec = around_ perItemTimeout . modifyMaxSuccess (const 100) $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-001#LAW-1" $
    it "identity:重建冪等,對已重建的索引再重建結果與索引都不變" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
            (r1, ix1) = simulate vf emptyIndex (rebuild reg vid)
        simulate vf ix1 (rebuild reg vid) === (r1, ix1)

  describe "P-001#LAW-2" $
    it "equiv:從任何舊索引重建,與從空索引重建得到同一個索引" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        ix0 <- forAll genIndexState
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
        snd (simulate vf ix0 (rebuild reg vid))
          === snd (simulate vf emptyIndex (rebuild reg vid))

  describe "P-001#LAW-3" $
    it "equiv:全量重建等於逐檔索引" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
        snd (simulate vf emptyIndex (rebuild reg vid))
          === snd
            ( simulate
                vf
                emptyIndex
                (mapM_ (indexPath reg vid) (vaultPaths vf))
            )

  describe "P-001#LAW-4" $
    it "identity:檔案沒變時刷新是恆等,且不回報任何問題" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
            (_r1, ix1) = simulate vf emptyIndex (rebuild reg vid)
        simulate vf ix1 (refresh reg vid) === (Right [], ix1)

  describe "P-001#LAW-5" $
    it "equiv:增量刷新等於重建" $
      hedgehog $ do
        -- given statsDistinguish vf1 vf2:指紋由內容推導('statOf'),
        -- 同路徑內容不同時指紋一定不同,產生器直接建構滿足前提的值。
        vf1 <- forAll genVaultFiles
        vf2 <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
            (_r1, ix1) = simulate vf1 emptyIndex (rebuild reg vid)
        assert (statsDistinguish vf1 vf2)
        snd (simulate vf2 ix1 (refresh reg vid))
          === snd (simulate vf2 emptyIndex (rebuild reg vid))

  describe "P-001#LAW-6" $
    it "relation:一個檔在不在索引裡,由它自己的純核心成敗與邏輯名稱有沒有被字母序更前的檔佔走決定" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
            (_r, ix) = simulate vf emptyIndex (rebuild reg vid)
        -- forall p in vaultPaths vf, (st, txt) in fileAt vf p
        mapM_
          ( \p ->
              let (st, txt) = fileAt vf p
               in (p `elem` indexedPaths ix)
                    === ( isRight (indexDocument reg vid p st txt)
                            && not (clashesEarlier reg vid vf p)
                        )
          )
          (vaultPaths vf)

  describe "P-001#LAW-7" $
    it "invariant:索引裡每個節點的 vault 欄等於重建時給的 vault id" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
            (_r, ix) = simulate vf emptyIndex (rebuild reg vid)
        mapM_ (\n -> metaVault (anyMeta n) === vid) (indexedNodes ix)

  describe "P-001#LAW-8" $
    it "invariant:一個 vault 內已命名 asset 的邏輯名稱唯一" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
            (_r, ix) = simulate vf emptyIndex (rebuild reg vid)
        nub (assetNames ix) === assetNames ix

  describe "P-001#LAW-9" $
    it "total:單檔純核心對任何文字都有值,不拋例外" $
      hedgehog $ do
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        p <- forAll genAnyPath
        st <- forAll genFileStat
        txt <- forAll genAnyText
        let reg = regOf rp
        -- total:求值到正規形(show 會走遍整個結構)不拋例外。
        out <-
          liftIO
            ( try (evaluate (length (show (indexDocument reg vid p st txt))))
                :: IO (Either SomeException Int)
            )
        assert (isRight out)

  describe "P-001#LAW-10" $
    it "identity:指紋相同時沒有過時也沒有消失" $
      hedgehog $ do
        m <- forAll genStatMap
        staleFiles m m === ([], [])

  describe "P-001#LAW-11" $
    it "relation:過時是指紋不同或索引沒有,消失是索引有而磁碟沒有" $
      hedgehog $ do
        disk <- forAll genStatMap
        rec' <- forAll genStatMap
        p <- forAll (Gen.element pathPool)
        let (todo, gone) = staleFiles disk rec'
        assert
          ( ( (p `elem` todo)
                == (Map.member p disk && Map.lookup p disk /= Map.lookup p rec')
            )
              && ((p `elem` gone) == (Map.member p rec' && not (Map.member p disk)))
          )

  describe "P-001#LAW-12" $
    it "relation:警告不擋索引,被 MetaWarningsFound 點到的節點仍在索引裡" $
      hedgehog $ do
        vf <- forAll genVaultFiles
        rp <- forAll genRegPick
        vid <- forAll genVaultId
        let reg = regOf rp
            (r, ix) = simulate vf emptyIndex (rebuild reg vid)
        mapM_
          (\issues -> mapM_ (\i -> assert (i `elem` indexedIds ix)) (warnedIds issues))
          (rights [r])

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-001#EX-1" $
    it "空 vault 重建是 (Right [], emptyIndex),再跑一次相同" $ do
      let out = simulate Map.empty emptyIndex (rebuild regFull vaultA)
      out `shouldBe` (Right [], emptyIndex)
      simulate Map.empty (snd out) (rebuild regFull vaultA) `shouldBe` out

  describe "P-001#EX-2" $
    it "一份主題檔進索引三個節點,與逐檔 indexPath 相同" $ do
      let (_r, ix) = simulate vfLinda emptyIndex (rebuild regFull vaultA)
      indexedPaths ix `shouldBe` [pathLinda]
      length (indexedNodes ix) `shouldBe` 3
      snd (simulate vfLinda emptyIndex (indexPath regFull vaultA pathLinda))
        `shouldBe` ix

  describe "P-001#EX-3" $
    it "樹不合法的 Level 檔不進索引,同 vault 的主題檔照進" $ do
      let (r, ix) = simulate vfCycle emptyIndex (rebuild regFull vaultA)
      (pathLevel `elem` indexedPaths ix) `shouldBe` False
      any (isTreeInvalidAt pathLevel) (issuesOf r) `shouldBe` True
      (pathLinda `elem` indexedPaths ix) `shouldBe` True

  describe "P-001#EX-4" $
    it "邏輯名稱撞名時字母序在後的整檔不進,名稱只留一個" $ do
      let (r, ix) = simulate vfDupName emptyIndex (rebuild regFull vaultA)
      indexedPaths ix `shouldBe` [pathPackA]
      any (isDupNameAt pathPackB) (issuesOf r) `shouldBe` True
      assetNames ix `shouldBe` [LogicalName dupName]

  describe "P-001#EX-5" $
    it "註冊表沒有的型別只產警告,節點仍在索引裡" $ do
      let (r, ix) = simulate vfGhost emptyIndex (rebuild regFull vaultA)
      any isMetaWarning (issuesOf r) `shouldBe` True
      (ghostId `elem` indexedIds ix) `shouldBe` True

  describe "P-001#EX-6" $
    it "正文改一字後刷新,索引與對新 vault 從空重建相同" $ do
      let (_r1, ix1) = simulate vfHistory1 emptyIndex (rebuild regFull vaultA)
          (r2, ix2) = simulate vfHistory2 ix1 (refresh regFull vaultA)
      ix2 `shouldBe` snd (simulate vfHistory2 emptyIndex (rebuild regFull vaultA))
      r2 `shouldBe` Right []

  describe "P-001#EX-7" $
    it "指紋不同與索引沒有的都過時,索引有而磁碟沒有的是消失" $
      staleFiles diskEx7 recEx7 `shouldBe` (["b.md", "c.md"], ["d.md"])

  describe "P-001#EX-8" $
    it "解析不開的文字回 Left (ParseFailed …),不拋例外" $ do
      let out = indexDocument regFull vaultA "x.md" (statOf brokenMd) brokenMd
      -- 不拋例外:先求值到正規形(@show@ 走遍整個結構)。
      _ <- evaluate (length (show out))
      case out of
        Left (ParseFailed p _) -> p `shouldBe` "x.md"
        other ->
          expectationFailure
            ("P-001#EX-8 期望 Left (ParseFailed …),實得 " <> show other)

  describe "P-001#EX-9" $
    it "檔案裡寫的 vault 不算數,索引裡的節點一律是重建時給的 vault id" $ do
      let (_r, ix) = simulate vfLinda emptyIndex (rebuild regFull vaultA)
      map (metaVault . anyMeta) (indexedNodes ix)
        `shouldBe` map (const vaultA) (indexedNodes ix)

  describe "P-001#EX-10" $
    it "同一份指紋表比對自己沒有過時也沒有消失" $
      staleFiles mEx10 mEx10 `shouldBe` ([], [])

  describe "P-001#EX-11" $
    it "重建後不動任何檔再刷新是恆等" $ do
      let (_r1, ix1) = simulate vfLinda emptyIndex (rebuild regFull vaultA)
      simulate vfLinda ix1 (refresh regFull vaultA) `shouldBe` (Right [], ix1)
