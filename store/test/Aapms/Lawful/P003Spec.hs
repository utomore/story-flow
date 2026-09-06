-- | lawful 測試:P-003-node-write(qa 填入)。
--
-- 每條 @LAW-n@ 一個 @describe "P-003#LAW-n"@ 的 property test,每個 @EX-n@
-- 一個 @describe "P-003#EX-n"@ 的 example test。斷言逐字照 pipeline 檔的
-- @|-@ 行翻譯(@rights@ \/ @isRight@ \/ @isLeft@ \/ @isNothing@ \/ @elemIndex@ \/
-- @isSuffixOf@ \/ @nub@ \/ @notElem@ \/ @lookup@ \/ @toList@ 等識別字對應到
-- @Data.Either@ \/ @Data.List@ \/ @Data.Maybe@ \/ @Data.Map.Strict@ 的同名函數,
-- @in@ 對清單是 @elem@,@=>@ 是蘊涵)。
--
-- __效果怎麼跑__:@=@ 列 'applyWrite' 是效果程式,laws 一律透過觀察點
-- 'simulateWrite'(@VaultFs@ \/ @Index@ \/ @Clock@ 三個純解譯器串起來跑到底)
-- 取值,測試不碰 IO。
--
-- __合法的 Markdown 從哪裡來__:一律由 P-025-md-document 的 stage 反向產 ——
-- 檔案層 frontmatter 走 @renderDocument (newDocumentWith kind meta extras preamble)@,
-- 節層 meta 區塊走 @renderMetaBlock@,測試自己只拼標題行與正文,不手寫
-- frontmatter 或 meta 區塊的格式;'Document' 值一律由
-- @parseDocument@(P-003 的步驟 3)從那些文字產生,不手工組 'Document'。
--
-- __指紋怎麼來__:每個檔的 'FileStat' 由內容推導(@mtime@ 是內容的 FNV-1a 低
-- 32 位、@size@ 是字元數),與 P-001-index-rebuild 的測試同一套。
--
-- __前提(@given@)怎麼滿足__:一律__建構__而不是過濾 —— 固定 vault 裡每個節點
-- 的 id、所在檔、'Revision' 都是已知常數('targetPool'),產生器直接照它組出
-- 滿足 @opTarget op == Just i@ \/ @opRevision op == Just r@ \/
-- @locatedFile ix i == Just p@ 的請求。只有需要__取值__的前提
-- (@metaAt vf ix i == Just m@ 這種要把 @m@ 綁出來用的)才呼叫觀察點,
-- 取不到值時直接紅(不是靜默通過)。
--
-- __案例數__:@modifyMaxSuccess (const 100)@ 包住整個模組(hspec-hedgehog 會用
-- hspec 的 @maxSuccess@ 覆寫 hedgehog 的 @TestLimit@,所以不寫 @withTests@)。
--
-- __尺寸__:全部 'Range' 上限都是常數 —— vault 是四個固定路徑的檔、產生器只從
-- 固定的小池取值,不產生無界結構。
--
-- __timeout__:整個模組經 'around_' 對每個 example 套 60 秒上限。
module Aapms.Lawful.P003Spec (spec) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad.IO.Class (liftIO)
import Data.Bits ((.&.))
import Data.Either (isLeft, isRight, rights)
import Data.Int (Int64)
import Data.List (elemIndex, isSuffixOf, nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (Day, UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Timeout (timeout)

import Data.Aeson (Value (..))

import Hedgehog (Gen, MonadTest, annotate, failure)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (assert, forAll, hedgehog, modifyMaxSuccess, (===))

import Aapms.Core.AnyNode (AnyNode (..))
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id
  ( Id
  , IdPrefix (..)
  , Ref
  , VaultId (..)
  , fnv1a64
  , idPrefix
  , localRef
  , newId
  , parseId
  , renderId
  , renderIdPrefix
  )
import Aapms.Core.Level (Level (..), Node (..), NodeKind (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), LinkKind (..))
import Aapms.Core.Meta
  ( Meta (..)
  , Revision (..)
  , Source (..)
  , Status (..)
  , TypeKey (..)
  )
import Aapms.Core.Pack (AiDisclosure (..), Author (..), Pack (..))
import Aapms.Core.Registry
  ( Family (..)
  , TypeDecl (..)
  , TypeRegistry
  , buildRegistry
  , lookupDir
  )
import Aapms.Core.Tree (TreeError (..), buildTree)
import Aapms.Md.Document
  ( DocKind (..)
  , Document
  , LineEnding (..)
  , Section (..)
  , docKind
  , sectionById
  , sectionIds
  )
import Aapms.Md.Parse (parseDocument)
import Aapms.Md.Render (newDocumentWith, renderDocument, renderMetaBlock)
import Aapms.Md.Section
  ( FrontExtras (..)
  , MetaExtras (..)
  , MetaOverride (..)
  , NewAsset (..)
  , NewLicense (..)
  , NewNode (..)
  , NewSection (..)
  , NewSectionPayload (..)
  , emptyOverride
  )

import Aapms.Store.Editing (applyWrite, planEdit, sanitizeFileName)
-- REV-2:'documentAt' \/ 'sectionBytes' \/ 'metaAt' \/ 'assetAt' \/ 'licensesAt' \/
-- 'assetIdsAt' \/ 'packAt' \/ 'levelAt' \/ 'levelOf' 九個解析類觀察點由 types 層的
-- "Aapms.Store.Types" 搬到 pure 層的這裡(簽名不變)。
import Aapms.Store.Editing.Internal
  ( allocateN
  , assetAt
  , assetIdsAt
  , documentAt
  , levelAt
  , levelOf
  , licensesAt
  , metaAt
  , packAt
  , sectionBytes
  , simulateWrite
  )
import Aapms.Store.Node
  ( headingDepthFor
  , isRootNode
  , subtreeIds
  , validateLevelDoc
  )
import Aapms.Store.Types
  ( AssetPatch (..)
  , DeleteMode (..)
  , FileIndex (..)
  , FileStat (..)
  , IndexState (..)
  , IndexedNode (..)
  , Located (..)
  , NewEntity (..)
  , NewLevel (..)
  , NewPack (..)
  , PackFields (..)
  , SectionPlacement (..)
  , StoreError (..)
  , VaultFiles
  , WriteOp (..)
  , WriteOutcome
  , WriteRun (..)
  , brokenLinks
  , emptyIndex
  , fileStatsOf
  , locatedFile
  , newPackFields
  , outcomePath
  , outcomeRevision
  , packFields
  , patchedName
  , removedIds
  , stripStamps
  )

--------------------------------------------------------------------------------
-- 小工具

-- | @given ... == Just m@ 這種需要把值綁出來的前提:取不到就紅,不靜默通過。
needJust :: (MonadTest m) => String -> Maybe a -> m a
needJust msg = maybe (annotate msg >> failure) pure

fixedDay :: Day
fixedDay = fromGregorian 2026 1 1

-- | 固定時鐘。'Clock' 的純解譯器吃它。
fixedTime :: UTCTime
fixedTime = UTCTime fixedDay (secondsToDiffTime 0)

altTime :: UTCTime
altTime = UTCTime (fromGregorian 2026 2 2) (secondsToDiffTime 3600)

-- | 'Id' 的建構子沒有匯出,一律走型別層的 smart constructor 'parseId'。
mkId :: IdPrefix -> Text -> Id
mkId p hex = case parseId (renderIdPrefix p <> "-" <> hex) of
  Right (_, i) -> i
  Left e -> error ("P-003Spec:測試 id 不合法 " <> show e)

-- | 由固定文字產出的 'Document';解析不開就是測試素材壞了。
docOf :: Text -> Document
docOf t = case parseDocument t of
  Right d -> d
  Left e -> error ("P-003Spec:測試素材解析失敗 " <> show e)

sha64 :: Char -> Text
sha64 c = T.replicate 64 (T.singleton c)

revInt :: Revision -> Int
revInt (Revision n) = n

--------------------------------------------------------------------------------
-- 型別鍵與 vault

vaultA :: VaultId
vaultA = VaultId "vlt-7f3b2a91"

tyCharacter, tyFragment, tyAssetImage, tyLevel, tyPack, tyLicense, tyGhost :: TypeKey
tyCharacter = TypeKey "character"
tyFragment = TypeKey "character-fragment"
tyAssetImage = TypeKey "asset-image"
tyLevel = TypeKey "level"
tyPack = TypeKey "asset-pack"
tyLicense = TypeKey "asset-license"
tyGhost = TypeKey "ghost"

--------------------------------------------------------------------------------
-- 固定 id

idEntMain, idFragA, idFragB, idFragC :: Id
idEntMain = mkId PEnt "00000003"
idFragA = mkId PEnt "0000000a"
idFragB = mkId PEnt "0000000b"
idFragC = mkId PEnt "0000000d"

idLvl, idNodRoot, idNodA, idNodA1, idNodB, idNodC, idNodD, idNodDeep, idNodZzz :: Id
idLvl = mkId PLvl "00000005"
idNodRoot = mkId PNod "00000001"
idNodA = mkId PNod "0000000a"
idNodA1 = mkId PNod "0000001a"
idNodB = mkId PNod "0000000b"
idNodC = mkId PNod "0000000c"
idNodD = mkId PNod "0000000d"
idNodDeep = mkId PNod "0000000e"
idNodZzz = mkId PNod "00000fff"

idPck, idAstA, idAstB :: Id
idPck = mkId PPck "00000001"
idAstA = mkId PAst "00000010"
idAstB = mkId PAst "00000011"

idLicRoot, idLicC, idLicNew :: Id
idLicRoot = mkId PLic "00000006"
idLicC = mkId PLic "0000000c"
idLicNew = mkId PLic "0000000a"

--------------------------------------------------------------------------------
-- 指紋與記憶體 vault

statOf :: Text -> FileStat
statOf t =
  FileStat
    (fromIntegral (fnv1a64 (TE.encodeUtf8 t) .&. 0xFFFFFFFF) :: Int64)
    (fromIntegral (T.length t))

vaultFilesOf :: [(FilePath, Text)] -> VaultFiles
vaultFilesOf = Map.fromList . map (\(p, t) -> (p, (statOf t, t)))

--------------------------------------------------------------------------------
-- 合法的 Markdown:一律由 P-025-md-document 的 stage 反向產

metaOf :: IdPrefix -> Text -> TypeKey -> Text -> Int -> Meta
metaOf p hex ty title rev =
  Meta
    { metaId = mkId p hex
    , metaVault = vaultA
    , metaType = ty
    , metaTitle = title
    , metaSummary = ""
    , metaTags = []
    , metaStatus = Draft
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = Revision rev
    , metaCreated = fixedDay
    , metaUpdated = fixedDay
    }

-- | 一份檔:@newDocumentWith@ 產出檔案層 frontmatter 與 preamble,
-- @renderDocument@ 寫成文字,再把各節接在後面。
fileTextOf :: DocKind -> Meta -> [Text] -> Text -> [Text] -> Text
fileTextOf kind m frontExtra preamble secs =
  renderDocument (newDocumentWith kind m (FrontExtras (MetaExtras frontExtra)) preamble)
    <> T.concat secs

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

-- | 節層的 meta:每一節都寫明 @revision@,樂觀鎖的期望值才是常數而不是繼承來的。
ovRev :: Int -> MetaOverride
ovRev rev = emptyOverride {moRevision = Just (Revision rev)}

--------------------------------------------------------------------------------
-- 固定 vault 的四個檔

pathTopic, pathLevel, pathPack, pathLicenses :: FilePath
pathTopic = "characters/琳達.md"
pathLevel = "levels/教室.md"
pathPack = "a/pack.md"
pathLicenses = "licenses.md"

-- | 主體 revision 3;三個片段 revision 1 \/ 2 \/ 1。第三個片段以 @involves@
-- 指向 Level 檔的 @nod-0000000a@ ——EX-13 的被引用檢查靠它。
topicText :: Text
topicText =
  fileTextOf TopicDoc (metaOf PEnt "00000003" tyCharacter "琳達" 3) [] "主體概述。\n" $
    [ sectionTextOf 2 idFragA "外貌" (ovRev 1) {moType = Just tyFragment} [] "外貌內文。"
    , sectionTextOf 2 idFragB "背景" (ovRev 2) {moType = Just tyFragment} [] "背景內文。"
    , sectionTextOf
        2
        idFragC
        "關聯"
        (ovRev 1) {moType = Just tyFragment, moLinks = Just [linkToNodA]}
        []
        "關聯內文。"
    ]

linkToNodA :: Link
linkToNodA = Link Involves (localRef idNodA) Nothing

-- | Level 檔:root(2)> a(3)> a1(4)、b(3)> c(4)> d(5)> deep(6)。
-- @deep@ 已在第六級,'headingDepthFor' 對它一定回 'NodeDepthExceeded'。
levelText :: Text
levelText =
  fileTextOf
    LevelDoc
    (metaOf PLvl "00000005" tyLevel "教室" 2)
    ["root: " <> renderId idNodRoot]
    "場景說明。\n"
    [ nodeSection 2 idNodRoot "開場"
    , nodeSection 3 idNodA "A 段"
    , nodeSection 4 idNodA1 "A1 段"
    , nodeSection 3 idNodB "B 段"
    , nodeSection 4 idNodC "C 段"
    , nodeSection 5 idNodD "D 段"
    , nodeSection 6 idNodDeep "Deep 段"
    ]

nodeSection :: Int -> Id -> Text -> Text
nodeSection lvl i title =
  sectionTextOf lvl i title (ovRev 1) {moKind = Just KScene} [] (title <> "內文。")

-- | 樹不合法的 Level 檔:frontmatter 宣告了 @root@,檔案裡一個 Node 節都沒有,
-- @toLevel@ 過得去而 @buildTree@ 回 'Left'。
--
-- __為什麼不是「成環」__:EX-20 的輸入(@nod-b@ 的 parent 是自己)在
-- P-025-md-document 底下建構不出來 —— 父子關係由標題階層推導,「自己是自己的
-- 父」要求同一個 id 出現兩次,而 @parseDocument@ 對此直接回
-- @DuplicateSectionId@(見回報的 GAP 本次-1)。LAW-23 的 @d in Document@ 定義域
-- 需要一份樹不合法的 Level 檔,這一份是能建構出來的那種。
levelNoNodeText :: Text
levelNoNodeText =
  fileTextOf
    LevelDoc
    (metaOf PLvl "00000005" tyLevel "教室" 2)
    ["root: " <> renderId idNodRoot]
    "沒有任何 Node,frontmatter 宣告的 root 不存在。\n"
    []

-- | REV-1:EX-20 的輸入。兩個最淺層級的節同層(@nod-a@ 與 @nod-b@ 都是第 2
-- 級標題,彼此不是對方的子樹)—— 'structure'(P-025)不會回報 'HeadingSkip'
-- 或 'HeadingAboveRoot',兩節都解出 @nodParent = Nothing@;'buildTree' 因此
-- 看到兩個根,回 'MultipleRoots'。這一份與 GAP 本次-1 裡「成環」那種建構不出來
-- 的輸入不同:兩個最淺層級節不需要重複 id,'parseDocument' 解得開。只給
-- 'EX-20' 用,不進 'docPool'(LAW-22 \/ LAW-23 \/ LAW-24 的定義域不受影響)。
-- 合法 Markdown 仍由既有 helper('fileTextOf' \/ 'nodeSection',P-025-md-document
-- 的 stage 反向產)組出。
levelTwoRootsText :: Text
levelTwoRootsText =
  fileTextOf
    LevelDoc
    (metaOf PLvl "00000005" tyLevel "教室" 2)
    ["root: " <> renderId idNodA]
    "兩個最淺層級的節,兩個根。\n"
    [ nodeSection 2 idNodA "A 段"
    , nodeSection 2 idNodB "B 段"
    ]

packText :: Text
packText =
  fileTextOf PackDoc (metaOf PPck "00000001" tyPack "素材包" 1) [] "素材包說明。\n"
    [ sectionTextOf
        2
        idAstA
        "panel.png"
        (ovRev 1) {moType = Just tyAssetImage}
        [ "name: ui_gui_panel_001"
        , "entry: PNG/panel.png"
        , "sha256: \"" <> sha64 '1' <> "\""
        ]
        "素材說明。"
    , sectionTextOf
        2
        idAstB
        "icon.png"
        (ovRev 2) {moType = Just tyAssetImage}
        [ "entry: PNG/icon.png"
        , "sha256: \"" <> sha64 '2' <> "\""
        ]
        "另一素材。"
    ]

licensesText :: Text
licensesText =
  fileTextOf
    LicenseDoc
    (metaOf PLic "00000006" tyLicense "授權登記" 1)
    []
    "本檔登記全部授權。\n"
    [ sectionTextOf
        2
        idLicC
        "CC0"
        (ovRev 1)
        ["commercial: true", "attribution_required: false"]
        ""
    ]

-- | 全部四個檔的記憶體 vault。
vfBase :: VaultFiles
vfBase =
  vaultFilesOf
    [ (pathTopic, topicText)
    , (pathLevel, levelText)
    , (pathPack, packText)
    , (pathLicenses, licensesText)
    ]

--------------------------------------------------------------------------------
-- 對應的索引

entityNode :: Id -> Meta -> Maybe Id -> IndexedNode
entityNode _i m owner = IndexedNode (NEntity (Entity m "")) owner

levelNode :: Meta -> IndexedNode
levelNode m = IndexedNode (NLevel (Level m idNodRoot)) Nothing

sceneNode :: Meta -> Maybe Id -> Int -> IndexedNode
sceneNode m parent ord =
  IndexedNode
    ( NNode
        Node
          { nodMeta = m
          , nodLevel = idLvl
          , nodParent = parent
          , nodOrder = ord
          , nodKind = KScene
          , nodEntities = []
          }
    )
    (Just idLvl)

assetNode :: Meta -> Maybe LogicalName -> Char -> Text -> IndexedNode
assetNode m nm shaChar entry =
  IndexedNode
    ( NAsset
        Asset
          { astMeta = m
          , astName = nm
          , astSha256 = Sha256 (sha64 shaChar)
          , astEntry = entry
          , astExt = Nothing
          , astKindMeta = Null
          , astLicense = Nothing
          , astAuthor = Nothing
          , astBody = ""
          }
    )
    (Just idPck)

packNode :: Meta -> IndexedNode
packNode m =
  IndexedNode
    ( NPack
        Pack
          { pckMeta = m
          , pckVendor = Nothing
          , pckArchive = Nothing
          , pckSha256 = Nothing
          , pckLicense = Nothing
          , pckAuthor = Nothing
          , pckSourceUrl = Nothing
          , pckAiDisclosure = AiUnknown
          , pckBody = ""
          }
    )
    Nothing

licenseNode :: Meta -> IndexedNode
licenseNode m =
  IndexedNode
    ( NLicense
        License
          { licMeta = m
          , licCommercial = True
          , licAttributionRequired = False
          , licCreditText = Nothing
          , licModificationAllowed = Nothing
          , licRedistributionAllowed = Nothing
          , licResaleAllowed = Nothing
          , licNftAllowed = Nothing
          , licSourceUrl = Nothing
          , licFullText = Nothing
          }
    )
    Nothing

metaSec :: IdPrefix -> Text -> TypeKey -> Text -> Int -> [Link] -> Meta
metaSec p hex ty title rev ls = (metaOf p hex ty title rev) {metaLinks = ls}

-- | 與 'vfBase' 逐節對應的索引。
ixBase :: IndexState
ixBase =
  IndexState $
    Map.fromList
      [
        ( pathTopic
        , FileIndex
            pathTopic
            TopicDoc
            (statOf topicText)
            False
            [ entityNode idEntMain (metaOf PEnt "00000003" tyCharacter "琳達" 3) Nothing
            , entityNode idFragA (metaSec PEnt "0000000a" tyFragment "外貌" 1 []) (Just idEntMain)
            , entityNode idFragB (metaSec PEnt "0000000b" tyFragment "背景" 2 []) (Just idEntMain)
            , entityNode
                idFragC
                (metaSec PEnt "0000000d" tyFragment "關聯" 1 [linkToNodA])
                (Just idEntMain)
            ]
        )
      ,
        ( pathLevel
        , FileIndex
            pathLevel
            LevelDoc
            (statOf levelText)
            False
            [ levelNode (metaOf PLvl "00000005" tyLevel "教室" 2)
            , sceneNode (metaOf PNod "00000001" tyLevel "開場" 1) Nothing 0
            , sceneNode (metaOf PNod "0000000a" tyLevel "A 段" 1) (Just idNodRoot) 0
            , sceneNode (metaOf PNod "0000001a" tyLevel "A1 段" 1) (Just idNodA) 0
            , sceneNode (metaOf PNod "0000000b" tyLevel "B 段" 1) (Just idNodRoot) 1
            , sceneNode (metaOf PNod "0000000c" tyLevel "C 段" 1) (Just idNodB) 0
            , sceneNode (metaOf PNod "0000000d" tyLevel "D 段" 1) (Just idNodC) 0
            , sceneNode (metaOf PNod "0000000e" tyLevel "Deep 段" 1) (Just idNodD) 0
            ]
        )
      ,
        ( pathPack
        , FileIndex
            pathPack
            PackDoc
            (statOf packText)
            False
            [ packNode (metaOf PPck "00000001" tyPack "素材包" 1)
            , assetNode
                (metaOf PAst "00000010" tyAssetImage "panel.png" 1)
                (Just (LogicalName "ui_gui_panel_001"))
                '1'
                "PNG/panel.png"
            , assetNode
                (metaOf PAst "00000011" tyAssetImage "icon.png" 2)
                Nothing
                '2'
                "PNG/icon.png"
            ]
        )
      ,
        ( pathLicenses
        , FileIndex
            pathLicenses
            LicenseDoc
            (statOf licensesText)
            False
            [ licenseNode (metaOf PLic "00000006" tyLicense "授權登記" 1)
            , licenseNode (metaOf PLic "0000000c" tyLicense "CC0" 1)
            ]
        )
      ]

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
  Left e -> error ("P-003Spec:測試註冊表不合法 " <> show e)

-- | @character@ 有落點目錄、@ghost@ 有宣告但沒有 dir(EX-8 的第二半)。
-- @level@ \/ @asset-pack@ \/ @asset-license@ 是保留鍵,'buildRegistry' 不收。
regFull :: TypeRegistry
regFull =
  mkRegistry
    [ typeDecl "character" FEntity (Just "characters") Nothing
    , typeDecl "character-fragment" FEntity Nothing (Just (TypeKey "character"))
    , typeDecl "asset-image" FAsset Nothing Nothing
    , typeDecl "ghost" FEntity Nothing Nothing
    ]

regNone :: TypeRegistry
regNone = mkRegistry []

--------------------------------------------------------------------------------
-- 目標池:每個既有節點的 id、所在檔、檔案裡的 revision

data Target = Target
  { tId :: Id
  , tPath :: FilePath
  , tRev :: Revision
  , tKind :: DocKind
  , tIsAsset :: Bool
  }
  deriving stock (Show, Eq)

targetPool :: [Target]
targetPool =
  [ Target idEntMain pathTopic (Revision 3) TopicDoc False
  , Target idFragA pathTopic (Revision 1) TopicDoc False
  , Target idFragB pathTopic (Revision 2) TopicDoc False
  , Target idNodA pathLevel (Revision 1) LevelDoc False
  , Target idNodB pathLevel (Revision 1) LevelDoc False
  , Target idAstA pathPack (Revision 1) PackDoc True
  , Target idAstB pathPack (Revision 2) PackDoc True
  ]

genTarget :: Gen Target
genTarget = Gen.element targetPool

-- | 與 't' 的實際 revision 不同的 revision(LAW-1 的 @r /= metaRevision m@ 由
-- 建構滿足)。
genWrongRevision :: Target -> Gen Revision
genWrongRevision t =
  Gen.element [Revision n | n <- [0 .. 5], Revision n /= tRev t]

genAnyRevision :: Gen Revision
genAnyRevision = Gen.element [Revision n | n <- [0 .. 4]]

--------------------------------------------------------------------------------
-- 產生器:請求的零件

genLink :: Gen Link
genLink =
  Gen.element
    [ Link Involves (localRef idEntMain) Nothing
    , Link References (localRef idFragB) Nothing
    , Link Uses (localRef idAstA) Nothing
    ]

genMetaOverride :: Gen MetaOverride
genMetaOverride =
  Gen.element
    [ emptyOverride {moSummary = Just "x"}
    , emptyOverride {moTags = Just ["gui"]}
    , emptyOverride {moStatus = Just Canon}
    , emptyOverride
    ]

genBody :: Gen Text
genBody = Gen.element ["改過的正文。", "另一段正文。", ""]

genLogicalName :: Gen LogicalName
genLogicalName = Gen.element [LogicalName "ui_gui_a_001", LogicalName "ui_gui_b_001"]

genRef :: Gen Ref
genRef = Gen.element [localRef idLicC, localRef idLicNew]

genAssetPatch :: Gen AssetPatch
genAssetPatch =
  AssetPatch
    <$> Gen.choice [pure Nothing, pure (Just Nothing), Just . Just <$> genLogicalName]
    <*> Gen.choice [pure Nothing, pure (Just Nothing), Just . Just <$> genRef]
    <*> Gen.element [Nothing, Just Nothing, Just (Just "琳達"), Just (Just "Kenney")]
    <*> Gen.element [Nothing, Just [], Just ["gui"], Just ["gui", "ui"]]

genDeleteMode :: Gen DeleteMode
genDeleteMode = Gen.element [DeleteSafe, DeleteForce]

-- | 新節的 id 一律用固定 vault 裡沒有的 hex。
genNewSectionFor :: DocKind -> Gen NewSection
genNewSectionFor kind = do
  lvl <- Gen.int (Range.linear 2 9)
  title <- Gen.element ["新節", "另一個新節"]
  body <- genBody
  case kind of
    TopicDoc ->
      pure
        (NewSection (mkId PEnt "000000f1") lvl title body (NSFragment (emptyOverride {moType = Just tyFragment})))
    LevelDoc ->
      pure (NewSection (mkId PNod "000000f2") lvl title body (NSNode emptyOverride (NewNode KScene)))
    PackDoc ->
      pure
        ( NewSection
            (mkId PAst "000000f3")
            lvl
            title
            body
            (NSAsset (emptyOverride {moType = Just tyAssetImage}) newAssetF3)
        )
    LicenseDoc ->
      pure (NewSection (mkId PLic "000000f4") lvl title body (NSLicense emptyOverride newLicenseF4))

newAssetF3 :: NewAsset
newAssetF3 =
  NewAsset
    { naName = Nothing
    , naSha256 = Sha256 (sha64 'f')
    , naEntry = "PNG/new.png"
    , naExt = Nothing
    , naKindMeta = Null
    , naLicense = Nothing
    , naAuthor = Nothing
    }

newLicenseF4 :: NewLicense
newLicenseF4 =
  NewLicense
    { nlcCommercial = True
    , nlcAttributionRequired = False
    , nlcCreditText = Nothing
    , nlcModificationAllowed = Nothing
    , nlcRedistributionAllowed = Nothing
    , nlcResaleAllowed = Nothing
    , nlcNftAllowed = Nothing
    , nlcSourceUrl = Nothing
    }

genNewEntity :: Gen NewEntity
genNewEntity = do
  ty <- Gen.element [tyCharacter, tyGhost]
  title <- Gen.element ["新角色", "另一個新角色"]
  pure (newEntityOf ty title Nothing)

newEntityOf :: TypeKey -> Text -> Maybe FilePath -> NewEntity
newEntityOf ty title mp =
  NewEntity
    { neType = ty
    , neTitle = title
    , neSummary = "概述"
    , neBody = "正文。"
    , neTags = []
    , neAliases = []
    , neStatus = Draft
    , neTimeline = Nothing
    , neLinks = []
    , neSource = Human
    , nePath = mp
    }

genNewLevel :: Gen NewLevel
genNewLevel = do
  title <- Gen.element ["新場景", "另一個新場景"]
  pure (newLevelOf title "序幕" Nothing)

newLevelOf :: Text -> Text -> Maybe FilePath -> NewLevel
newLevelOf title rootTitle mp =
  NewLevel
    { nlTitle = title
    , nlSummary = "概述"
    , nlBody = "正文。"
    , nlStatus = Draft
    , nlSource = Human
    , nlRootTitle = rootTitle
    , nlRootKind = KScene
    , nlPath = mp
    }

genNewPack :: Gen NewPack
genNewPack = do
  d <- Gen.element ["packs/x", "packs/y"]
  pure (newPackPlain d)

newPackPlain :: FilePath -> NewPack
newPackPlain d =
  NewPack
    { npDir = d
    , npTitle = "新素材包"
    , npSummary = "概述"
    , npBody = "正文。"
    , npTags = []
    , npStatus = Draft
    , npSource = Scan
    , npVendor = Nothing
    , npArchive = Nothing
    , npSha256 = Nothing
    , npLicense = Nothing
    , npAuthor = Nothing
    , npSourceUrl = Nothing
    , npAiDisclosure = AiUnknown
    }

-- | EX-17:七欄全給非預設值。
newPackFull :: NewPack
newPackFull =
  (newPackPlain "packs/full")
    { npVendor = Just "Kenney"
    , npArchive = Just "packs/full/archive.zip"
    , npSha256 = Just (Sha256 (sha64 'a'))
    , npLicense = Just (localRef idLicNew)
    , npAuthor = Just (Author "Kenney" (Just "https://kenney.nl") Nothing)
    , npSourceUrl = Just "https://kenney.nl/assets"
    , npAiDisclosure = AiNone
    }

licenseOf :: Id -> Int -> Bool -> License
licenseOf i rev commercial =
  License
    { licMeta = (metaOf PLic "0000000c" tyLicense "授權" rev) {metaId = i}
    , licCommercial = commercial
    , licAttributionRequired = not commercial
    , licCreditText = Just "Kenney"
    , licModificationAllowed = Just True
    , licRedistributionAllowed = Just True
    , licResaleAllowed = Nothing
    , licNftAllowed = Nothing
    , licSourceUrl = Just "https://kenney.nl"
    , licFullText = Nothing
    }

genLicense :: Gen License
genLicense = do
  i <- Gen.element [idLicNew, idLicC]
  commercial <- Gen.bool
  pure (licenseOf i 1 commercial)

--------------------------------------------------------------------------------
-- 產生器:整個請求

-- | 不插入新節的請求(@not (isInsertOp op)@ 由建構滿足)。
genNonInsertOpAt :: Target -> Revision -> Gen WriteOp
genNonInsertOpAt t r =
  Gen.choice $
    [ WriteMeta i r <$> genMetaOverride
    , WriteBody i r <$> genBody
    , AddLink i r <$> genLink
    , RemoveLink i r <$> genLink
    , DeleteNode i r <$> genDeleteMode
    ]
      <> [WriteAssetFields i r <$> genAssetPatch | tIsAsset t]
  where
    i = tId t

-- | REV-1(LAW-3 專用):既不插入也不刪除節的請求 —— @not (isInsertOp op)@ 與
-- @not (isDeleteOp op)@ 都由建構滿足。與 'genNonInsertOpAt' 同一套建構方式,
-- 差別只在選項清單裡__不放__ 'DeleteNode':不呼叫 'isDeleteOp'(它在 types 層還是
-- stub),直接把刪節類請求排除在產生器的值域之外。'genNonInsertOpAt' 本身給
-- LAW-1 \/ LAW-2 用,兩條不受 REV-1 影響,原樣不動。
genNonInsertNonDeleteOpAt :: Target -> Revision -> Gen WriteOp
genNonInsertNonDeleteOpAt t r =
  Gen.choice $
    [ WriteMeta i r <$> genMetaOverride
    , WriteBody i r <$> genBody
    , AddLink i r <$> genLink
    , RemoveLink i r <$> genLink
    ]
      <> [WriteAssetFields i r <$> genAssetPatch | tIsAsset t]
  where
    i = tId t

-- | 會插入新節的請求。
genInsertOpAt :: Target -> Gen WriteOp
genInsertOpAt t = do
  s <- genNewSectionFor (tKind t)
  placement <-
    if tKind t == LevelDoc
      then Gen.element [AtEnd, UnderParent idNodA, UnderParent idNodB]
      else pure AtEnd
  pure (AddSection (tId t) placement s)

genCreateOp :: Gen WriteOp
genCreateOp =
  Gen.choice
    [ CreateTopic <$> genNewEntity
    , CreateLevel <$> genNewLevel
    , CreatePack <$> genNewPack <*> genPackSections
    ]

genPackSections :: Gen [NewSection]
genPackSections = do
  n <- Gen.int (Range.linear 0 3)
  pure (take n packSectionPool)

packSectionPool :: [NewSection]
packSectionPool =
  [ packSection (mkId PAst "0000000a") "a.png" 'a'
  , packSection (mkId PAst "0000000b") "b.png" 'b'
  , packSection (mkId PAst "0000000c") "c.png" 'c'
  ]

packSection :: Id -> Text -> Char -> NewSection
packSection i title c =
  NewSection
    { nsId = i
    , nsLevel = 2
    , nsTitle = title
    , nsBody = "素材說明。"
    , nsPayload =
        NSAsset
          (emptyOverride {moType = Just tyAssetImage})
          newAssetF3 {naEntry = "PNG/" <> title, naSha256 = Sha256 (sha64 c)}
    }

-- | 全定義域的請求(LAW-18 \/ LAW-19 \/ LAW-25 用):成功與失敗都在裡面。
genWriteOp :: Gen WriteOp
genWriteOp =
  Gen.choice
    [ genCreateOp
    , do
        t <- genTarget
        r <- Gen.choice [pure (tRev t), genAnyRevision]
        Gen.choice [genNonInsertOpAt t r, genInsertOpAt t]
    , UpsertLicense <$> genLicense
    ]

genRegPick :: Gen RegPick
genRegPick = Gen.element [RegFull, RegEmpty]

genTime :: Gen UTCTime
genTime = Gen.element [fixedTime, altTime]

genLocated :: Gen Located
genLocated = do
  t <- genTarget
  anchor <- Gen.element [Nothing, Just (tId t)]
  pure (Located (tPath t) anchor (tKind t))

-- | 文件池:四個固定檔與成環的 Level 檔。'Document' 一律由 @parseDocument@ 產。
docPool :: [Document]
docPool = map docOf [topicText, levelText, packText, licensesText, levelNoNodeText]

genDocument :: Gen Document
genDocument = Gen.element docPool

genIdAny :: Gen Id
genIdAny =
  Gen.element
    [idEntMain, idFragA, idNodRoot, idNodA, idNodA1, idNodB, idNodDeep, idNodZzz, idAstA]

genPathAny :: Gen FilePath
genPathAny = Gen.element [pathTopic, pathLevel, pathPack, pathLicenses, "x.md"]

-- | LAW-21 的 @s in Text@ 與 @fb in Text@。
genSanitizeInput :: Gen Text
genSanitizeInput =
  Gen.frequency
    [ (1, pure "")
    , (2, Gen.element ["  ", "...", ". .", "<", "<>?", "第一章: 序幕 ", "琳達 的筆記"])
    , (3, Gen.text (Range.linear 0 16) (Gen.element ("<>:\"/\\|?* .琳達a1" :: String)))
    ]

genFallback :: Gen Text
genFallback = Gen.element ["untitled", "無題", "fb"]

genIdPrefix :: Gen IdPrefix
genIdPrefix = Gen.element [PEnt, PAst, PLvl, PNod]

--------------------------------------------------------------------------------
-- 觀察點的簡寫

runOp :: UTCTime -> VaultFiles -> IndexState -> TypeRegistry -> VaultId -> WriteOp -> WriteRun (Either StoreError WriteOutcome)
runOp t vf ix reg vid op = simulateWrite t vf ix (applyWrite reg vid op)

--------------------------------------------------------------------------------
-- spec

perItemTimeout :: IO () -> IO ()
perItemTimeout act = do
  r <- timeout (60 * 1000000) act
  maybe (expectationFailure "P-003 測試逾時(60 秒)") pure r

spec :: Spec
spec = around_ perItemTimeout . modifyMaxSuccess (const 100) $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-003#LAW-1" $
    it "relation:樂觀鎖不符即拒,檔案與索引都不動" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll genTarget
        r <- forAll (genWrongRevision tgt)
        op <- forAll (genNonInsertOpAt tgt r)
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
            run = runOp t vf ix reg vaultA op
        -- given metaAt vf ix i == Just m
        m <- needJust "P-003#LAW-1:metaAt 取不到目標的 Meta" (metaAt vf ix i)
        -- given r /= metaRevision m(產生器建構滿足)
        assert (r /= metaRevision m)
        runResult run === Left (RevisionMismatch i r (metaRevision m))
        runFiles run === vf
        runIndex run === ix

  describe "P-003#LAW-2" $
    it "relation:成功時 revision 恰好加一,重讀檔案得到的 revision 等於回傳的" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll genTarget
        op <- forAll (Gen.choice [genNonInsertOpAt tgt (tRev tgt), genInsertOpAt tgt])
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
            n = revInt (tRev tgt)
            run = runOp t vf ix reg vaultA op
        mapM_
          ( \o -> do
              outcomeRevision o === Revision (n + 1)
              fmap metaRevision (metaAt (runFiles run) (runIndex run) i)
                === Just (Revision (n + 1))
          )
          (rights [runResult run])

  describe "P-003#LAW-3" $
    it "invariant:位元組保留,不插入也不刪除節的請求(REV-1)成功後目標節以外每一節位元組不變" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll genTarget
        r <- forAll (Gen.choice [pure (tRev tgt), genAnyRevision])
        -- given not (isInsertOp op) and not (isDeleteOp op)(REV-1):產生器
        -- 直接不把 DeleteNode 放進選項,建構滿足兩個前提,不呼叫 isDeleteOp stub
        op <- forAll (genNonInsertNonDeleteOpAt tgt r)
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
            run = runOp t vf ix reg vaultA op
        -- given locatedFile ix i == Just p
        p <- needJust "P-003#LAW-3:locatedFile 取不到目標所在檔" (locatedFile ix i)
        -- given isRight (runResult run)
        if isRight (runResult run)
          then
            filter ((/= i) . fst) (sectionBytes (runFiles run) p)
              === filter ((/= i) . fst) (sectionBytes vf p)
          else pure ()

  describe "P-003#LAW-4" $
    it "invariant:改 asset 人給欄位不動 sha256、entry、ext、kind meta、正文" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll (Gen.element (filter tIsAsset targetPool))
        r <- forAll (Gen.choice [pure (tRev tgt), genAnyRevision])
        patch <- forAll genAssetPatch
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
            run = runOp t vf ix reg vaultA (WriteAssetFields i r patch)
        -- given assetAt vf ix i == Just a
        a <- needJust "P-003#LAW-4:assetAt 取不到目標 asset" (assetAt vf ix i)
        if isRight (runResult run)
          then
            mapM_
              ( \a2 -> do
                  astSha256 a2 === astSha256 a
                  astEntry a2 === astEntry a
                  astExt a2 === astExt a
                  astKindMeta a2 === astKindMeta a
                  astBody a2 === astBody a
              )
              (maybe [] pure (assetAt (runFiles run) (runIndex run) i))
          else pure ()

  describe "P-003#LAW-5" $
    it "relation:AssetPatch 三態,Nothing 不動、Just v 設成 v" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll (Gen.element (filter tIsAsset targetPool))
        r <- forAll (Gen.choice [pure (tRev tgt), genAnyRevision])
        patch <- forAll genAssetPatch
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
            run = runOp t vf ix reg vaultA (WriteAssetFields i r patch)
        a <- needJust "P-003#LAW-5:assetAt 取不到目標 asset" (assetAt vf ix i)
        if isRight (runResult run)
          then
            fmap astName (assetAt (runFiles run) (runIndex run) i)
              === Just (patchedName patch (astName a))
          else pure ()

  describe "P-003#LAW-6" $
    it "roundtrip:先加關聯再刪同一條,關聯與去掉 revision/updated 兩行的位元組回到原狀" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll genTarget
        l <- forAll genLink
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
            n = revInt (tRev tgt)
            run1 = runOp t vf ix reg vaultA (AddLink i (Revision n) l)
            run2 =
              runOp t (runFiles run1) (runIndex run1) reg vaultA
                (RemoveLink i (Revision (n + 1)) l)
        m <- needJust "P-003#LAW-6:metaAt 取不到目標的 Meta" (metaAt vf ix i)
        assert (metaRevision m == Revision n)
        -- given notElem l (metaLinks m):固定 vault 的節點關聯清單與 'genLink'
        -- 的三條互斥,前提由建構滿足
        assert (notElem l (metaLinks m))
        p <- needJust "P-003#LAW-6:locatedFile 取不到目標所在檔" (locatedFile ix i)
        if isRight (runResult run1)
          then do
            fmap metaLinks (metaAt (runFiles run2) (runIndex run2) i) === Just (metaLinks m)
            fmap stripStamps (fmap snd (lookup p (Map.toList (runFiles run2))))
              === fmap stripStamps (fmap snd (lookup p (Map.toList vf)))
          else pure ()

  describe "P-003#LAW-7" $
    it "relation:刪不存在的關聯回 LinkNotFound 且不寫檔" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll genTarget
        l <- forAll genLink
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
        m <- needJust "P-003#LAW-7:metaAt 取不到目標的 Meta" (metaAt vf ix i)
        assert (notElem l (metaLinks m))
        let run = runOp t vf ix reg vaultA (RemoveLink i (metaRevision m) l)
        runResult run === Left (LinkNotFound i l)
        runFiles run === vf

  describe "P-003#LAW-8" $
    it "roundtrip:更新授權後重讀相等,對同一個 id 做兩次節數不變" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        l <- forAll genLicense
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            run1 = runOp t vf ix reg vaultA (UpsertLicense l)
            run2 = runOp t (runFiles run1) (runIndex run1) reg vaultA (UpsertLicense l)
        if isRight (runResult run1)
          then
            mapM_
              ( \l2 -> do
                  licCommercial l2 === licCommercial l
                  licAttributionRequired l2 === licAttributionRequired l
                  licCreditText l2 === licCreditText l
                  licSourceUrl l2 === licSourceUrl l
                  length (licensesAt (runFiles run2))
                    === length (licensesAt (runFiles run1))
              )
              ( filter
                  ((== metaId (licMeta l)) . metaId . licMeta)
                  (licensesAt (runFiles run1))
              )
          else pure ()

  describe "P-003#LAW-9" $
    it "invariant:建 pack 檔時 asset 節順序等於給定順序" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        np <- forAll genNewPack
        xs <- forAll genPackSections
        let reg = regOf rp
            run = runOp t vfBase ixBase reg vaultA (CreatePack np xs)
        mapM_
          (\o -> assetIdsAt (runFiles run) (outcomePath o) === map nsId xs)
          (rights [runResult run])

  describe "P-003#LAW-10" $
    it "relation:建主題檔的落點由註冊表決定,沒有 dir 就 RegistryDirUnknown 且不寫檔" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        ne <- forAll genNewEntity
        let reg = regOf rp
            vf = vfBase
            run = runOp t vf ixBase reg vaultA (CreateTopic ne)
        -- given nePath ne == Nothing(產生器只產 Nothing)
        assert (isNothing (nePath ne))
        assert
          ( maybe
              (runResult run == Left (RegistryDirUnknown (neType ne)) && runFiles run == vf)
              (const (all (isSuffixOf ".md") (map outcomePath (rights [runResult run]))))
              (lookupDir reg (neType ne))
          )

  describe "P-003#LAW-11" $
    it "relation:建 Level 檔產出可解析且樹合法的檔,根就是唯一那個 Node" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        nl <- forAll genNewLevel
        let reg = regOf rp
            run = runOp t vfBase ixBase reg vaultA (CreateLevel nl)
        mapM_
          ( \o ->
              mapM_
                ( \(lvl, nodes) -> do
                    length nodes === 1
                    assert (isRight (buildTree lvl nodes))
                    lvlRoot lvl === metaId (nodMeta (head nodes))
                )
                (maybe [] pure (levelAt (runFiles run) (outcomePath o)))
          )
          (rights [runResult run])

  describe "P-003#LAW-12" $
    it "relation:檔尾增節排最後,前面每一節位元組不變" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        tgt <- forAll genTarget
        s <- forAll (genNewSectionFor (tKind tgt))
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = tId tgt
            run = runOp t vf ix reg vaultA (AddSection i AtEnd s)
        p <- needJust "P-003#LAW-12:locatedFile 取不到目標所在檔" (locatedFile ix i)
        if isRight (runResult run)
          then
            mapM_
              ( \d0 ->
                  mapM_
                    ( \d1 -> do
                        sectionIds d1 === sectionIds d0 <> [nsId s]
                        map fst (init (sectionBytes (runFiles run) p))
                          === map fst (sectionBytes vf p)
                        init (init (sectionBytes (runFiles run) p))
                          === init (sectionBytes vf p)
                    )
                    (maybe [] pure (documentAt (runFiles run) p))
              )
              (maybe [] pure (documentAt vf p))
          else pure ()

  describe "P-003#LAW-13" $
    it "relation:父節點下增節排在父的子樹之後,層級等於父加一,插入點之後位元組不變" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        par <- forAll (Gen.element [idNodA, idNodB, idNodC])
        s <- forAll (genNewSectionFor LevelDoc)
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = idLvl
            run = runOp t vf ix reg vaultA (AddSection i (UnderParent par) s)
        p <- needJust "P-003#LAW-13:locatedFile 取不到目標所在檔" (locatedFile ix i)
        if isRight (runResult run)
          then
            mapM_
              ( \d0 ->
                  mapM_
                    ( \d1 -> do
                        let k = length (subtreeIds d0 par)
                        mapM_
                          ( \j ->
                              mapM_
                                ( \sec ->
                                    mapM_
                                      ( \psec -> do
                                          sectionIds d1
                                            === take (j + k) (sectionIds d0)
                                              <> [nsId s]
                                              <> drop (j + k) (sectionIds d0)
                                          secLevel sec === secLevel psec + 1
                                          drop (j + k + 1) (sectionBytes (runFiles run) p)
                                            === drop (j + k) (sectionBytes vf p)
                                      )
                                      (maybe [] pure (sectionById par d0))
                                )
                                (maybe [] pure (sectionById (nsId s) d1))
                          )
                          (maybe [] pure (elemIndex par (sectionIds d0)))
                    )
                    (maybe [] pure (documentAt (runFiles run) p))
              )
              (maybe [] pure (documentAt vf p))
          else pure ()

  describe "P-003#LAW-14" $
    it "relation:父不在檔裡回 SectionMissing、父已是第 6 層回 NodeDepthExceeded,都不寫檔" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        par <- forAll (Gen.element [idNodZzz, idNodDeep])
        s <- forAll (genNewSectionFor LevelDoc)
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = idLvl
            run = runOp t vf ix reg vaultA (AddSection i (UnderParent par) s)
        p <- needJust "P-003#LAW-14:locatedFile 取不到目標所在檔" (locatedFile ix i)
        mapM_
          ( \d0 -> do
              -- given isLeft (headingDepthFor p d0 par):'idNodZzz' 不在檔裡、
              -- 'idNodDeep' 已在第六級,前提由建構滿足
              assert (isLeft (headingDepthFor p d0 par))
              fmap (const ()) (runResult run) === fmap (const ()) (headingDepthFor p d0 par)
              runFiles run === vf
          )
          (maybe [] pure (documentAt vf p))

  describe "P-003#LAW-15" $
    it "relation:Safe 被引用即拒且不動,Force 消失集合等於子樹、斷點恰是指向它們的關聯" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        i <- forAll (Gen.element [idNodA, idNodB, idNodC, idNodDeep])
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
        p <- needJust "P-003#LAW-15:locatedFile 取不到目標所在檔" (locatedFile ix i)
        r <-
          needJust
            "P-003#LAW-15:metaAt 取不到目標的 Meta"
            (fmap metaRevision (metaAt vf ix i))
        mapM_
          ( \d0 -> do
              -- given isRootNode p d0 i == Right False
              assert (isRootNode p d0 i == Right False)
              let victims = subtreeIds d0 i
                  runS = runOp t vf ix reg vaultA (DeleteNode i r DeleteSafe)
                  runF = runOp t vf ix reg vaultA (DeleteNode i r DeleteForce)
              mapM_
                ( \o -> do
                    removedIds o === victims
                    (isLeft (runResult runS) == not (null (brokenLinks o))) === True
                    if isLeft (runResult runS)
                      then runFiles runS === vf
                      else pure ()
                )
                (rights [runResult runF])
          )
          (maybe [] pure (documentAt vf p))

  describe "P-003#LAW-16" $
    it "relation:根 Node 刪不得,兩種模式皆然" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        mode <- forAll genDeleteMode
        r <- forAll genAnyRevision
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            i = idNodRoot
            run = runOp t vf ix reg vaultA (DeleteNode i r mode)
        p <- needJust "P-003#LAW-16:locatedFile 取不到根 Node 所在檔" (locatedFile ix i)
        mapM_
          ( \d0 -> do
              -- given isRootNode p d0 i == Right True
              assert (isRootNode p d0 i == Right True)
              runResult run === Left (CannotDeleteRootNode i)
              runFiles run === vf
          )
          (maybe [] pure (documentAt vf p))

  describe "P-003#LAW-17" $
    it "invariant:同一個時間連續配號 n 次全部成功且兩兩相異、前綴正確" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 0 5))
        pre <- forAll genIdPrefix
        c <- forAll (Gen.element ["琳達", "教室", ""])
        t <- forAll genTime
        let ids = allocateN n pre c t ixBase
        -- given n >= 0(產生器的 Range 下界就是 0)
        assert (n >= 0)
        length ids === n
        nub ids === ids
        assert (all ((== pre) . idPrefix) ids)

  describe "P-003#LAW-18" $
    it "invariant:任何失敗都不動檔案與索引" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        op <- forAll genWriteOp
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            run = runOp t vf ix reg vaultA op
        if isLeft (runResult run)
          then do
            runFiles run === vf
            runIndex run === ix
          else pure ()

  describe "P-003#LAW-19" $
    it "invariant:成功時索引只重讀目標檔,其他檔的指紋不變" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        op <- forAll genWriteOp
        let reg = regOf rp
            vf = vfBase
            ix = ixBase
            run = runOp t vf ix reg vaultA op
        mapM_
          ( \o ->
              filter ((/= outcomePath o) . fst) (fileStatsOf (runIndex run))
                === filter ((/= outcomePath o) . fst) (fileStatsOf ix)
          )
          (rights [runResult run])

  describe "P-003#LAW-20" $
    it "relation:建 pack 檔的七個 pack 專屬欄位往返逐欄相等" $
      hedgehog $ do
        t <- forAll genTime
        rp <- forAll genRegPick
        np <- forAll (Gen.choice [genNewPack, pure newPackFull])
        xs <- forAll genPackSections
        let reg = regOf rp
            run = runOp t vfBase ixBase reg vaultA (CreatePack np xs)
        mapM_
          ( \o ->
              fmap packFields (packAt (runFiles run) (outcomePath o))
                === Just (newPackFields np)
          )
          (rights [runResult run])

  describe "P-003#LAW-21" $
    it "relation:檔名淨化的值域,非法字元換成 -、只由空白與 . 組成才退回 fallback" $
      hedgehog $ do
        s <- forAll genSanitizeInput
        fb <- forAll genFallback
        -- given not (null fb)
        assert (not (T.null fb))
        assert
          ( ( if T.all (`elem` [' ', '.']) s
                then sanitizeFileName s fb == fb
                else True
            )
              && ( if not (T.any (`elem` ("<>:\"/\\|?*" :: String)) s)
                    && not (T.null s)
                    && notElem (T.head s) [' ', '.']
                    && notElem (T.last s) [' ', '.']
                    then sanitizeFileName s fb == s
                    else True
                 )
          )

  describe "P-003#LAW-22" $
    it "relation:subtreeIds 以自己開頭,其後每一節層級都嚴格大於自己" $
      hedgehog $ do
        d <- forAll genDocument
        i <- forAll genIdAny
        mapM_
          ( \sec -> do
              head (subtreeIds d i) === i
              assert
                ( all
                    (maybe False ((> secLevel sec) . secLevel))
                    (map (`sectionById` d) (drop 1 (subtreeIds d i)))
                )
          )
          (maybe [] pure (sectionById i d))

  describe "P-003#LAW-23" $
    it "equiv:寫檔前驗證等價於 toLevel 成功且 buildTree 合法" $
      hedgehog $ do
        p <- forAll genPathAny
        d <- forAll genDocument
        isRight (validateLevelDoc p d)
          === maybe False (isRight . uncurry buildTree) (levelOf d)

  describe "P-003#LAW-24" $
    it "relation:isRootNode 對不在檔裡的 id 回 SectionMissing 不是 Right False" $
      hedgehog $ do
        p <- forAll genPathAny
        d <- forAll genDocument
        i <- forAll genIdAny
        isNothing (sectionById i d) === (isRootNode p d i == Left (SectionMissing p i))

  describe "P-003#LAW-25" $
    it "total:純核心對任何請求與文件都有值,不拋例外" $
      hedgehog $ do
        rp <- forAll genRegPick
        t <- forAll genTime
        loc <- forAll genLocated
        d <- forAll genDocument
        op <- forAll genWriteOp
        let reg = regOf rp
        out <-
          liftIO
            ( try (evaluate (length (show (planEdit reg t loc d op))))
                :: IO (Either SomeException Int)
            )
        assert (isRight out)

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-003#EX-1" $
    it "檔案 revision 3 而 expected 2:RevisionMismatch,檔案與索引不動" $ do
      let op = WriteMeta idEntMain (Revision 2) (emptyOverride {moSummary = Just "x"})
          run = runOp fixedTime vfBase ixBase regFull vaultA op
      runResult run
        `shouldBe` Left (RevisionMismatch idEntMain (Revision 2) (Revision 3))
      runFiles run `shouldBe` vfBase
      runIndex run `shouldBe` ixBase

  describe "P-003#EX-2" $
    it "expected 3 時成功,新 revision 4,其他節位元組不變" $ do
      let op = WriteMeta idEntMain (Revision 3) (emptyOverride {moSummary = Just "x"})
          run = runOp fixedTime vfBase ixBase regFull vaultA op
      case runResult run of
        Right o -> do
          outcomeRevision o `shouldBe` Revision 4
          fmap metaRevision (metaAt (runFiles run) (runIndex run) idEntMain)
            `shouldBe` Just (Revision 4)
          filter ((/= idEntMain) . fst) (sectionBytes (runFiles run) pathTopic)
            `shouldBe` filter ((/= idEntMain) . fst) (sectionBytes vfBase pathTopic)
        other -> expectationFailure ("P-003#EX-2 期望 Right,實得 " <> show other)

  describe "P-003#EX-3" $
    it "改 asset 人給欄位:name 設值、author 清空,sha256 與 license 未變" $ do
      let n' = LogicalName "ui_gui_a_001"
          patch = AssetPatch (Just (Just n')) Nothing (Just Nothing) Nothing
          op = WriteAssetFields idAstA (Revision 1) patch
          run = runOp fixedTime vfBase ixBase regFull vaultA op
      before' <- maybe (fail "EX-3:assetAt 取不到原始 asset") pure (assetAt vfBase ixBase idAstA)
      case assetAt (runFiles run) (runIndex run) idAstA of
        Just a2 -> do
          astName a2 `shouldBe` Just n'
          astAuthor a2 `shouldBe` Nothing
          astSha256 a2 `shouldBe` astSha256 before'
          astLicense a2 `shouldBe` astLicense before'
        Nothing -> expectationFailure "P-003#EX-3 寫入後 assetAt 取不到 asset"

  describe "P-003#EX-4" $
    it "加關聯再刪同一條:links 回到原狀,去掉 revision/updated 兩行後逐位元組相同" $ do
      let l = Link Involves (localRef idEntMain) Nothing
          run1 = runOp fixedTime vfBase ixBase regFull vaultA (AddLink idFragA (Revision 1) l)
          run2 =
            runOp fixedTime (runFiles run1) (runIndex run1) regFull vaultA
              (RemoveLink idFragA (Revision 2) l)
      m <- maybe (fail "EX-4:metaAt 取不到 Meta") pure (metaAt vfBase ixBase idFragA)
      fmap metaLinks (metaAt (runFiles run2) (runIndex run2) idFragA)
        `shouldBe` Just (metaLinks m)
      fmap stripStamps (fmap snd (lookup pathTopic (Map.toList (runFiles run2))))
        `shouldBe` fmap stripStamps (fmap snd (lookup pathTopic (Map.toList vfBase)))

  describe "P-003#EX-5" $
    it "刪不存在的關聯:LinkNotFound,檔案不變" $ do
      let l = Link Involves (localRef idEntMain) Nothing
          run = runOp fixedTime vfBase ixBase regFull vaultA (RemoveLink idFragA (Revision 1) l)
      runResult run `shouldBe` Left (LinkNotFound idFragA l)
      runFiles run `shouldBe` vfBase

  describe "P-003#EX-6" $
    it "UpsertLicense 兩次:第一次後重讀相等,第二次後節數不變" $ do
      let l = licenseOf idLicNew 1 True
          run1 = runOp fixedTime vfBase ixBase regFull vaultA (UpsertLicense l)
          run2 =
            runOp fixedTime (runFiles run1) (runIndex run1) regFull vaultA (UpsertLicense l)
      case filter ((== idLicNew) . metaId . licMeta) (licensesAt (runFiles run1)) of
        (l2 : _) -> do
          licCommercial l2 `shouldBe` licCommercial l
          licAttributionRequired l2 `shouldBe` licAttributionRequired l
          licCreditText l2 `shouldBe` licCreditText l
          licSourceUrl l2 `shouldBe` licSourceUrl l
        [] -> expectationFailure "P-003#EX-6 第一次 upsert 後找不到該授權"
      length (licensesAt (runFiles run2))
        `shouldBe` length (licensesAt (runFiles run1))

  describe "P-003#EX-7" $
    it "CreatePack 三節:assetIdsAt 依給定順序" $ do
      let xs = packSectionPool
          run = runOp fixedTime vfBase ixBase regFull vaultA (CreatePack (newPackPlain "packs/x") xs)
      case runResult run of
        Right o -> assetIdsAt (runFiles run) (outcomePath o) `shouldBe` map nsId xs
        other -> expectationFailure ("P-003#EX-7 期望 Right,實得 " <> show other)

  describe "P-003#EX-8" $
    it "有 dir 的型別落在 characters/,沒有 dir 的回 RegistryDirUnknown 且不寫檔" $ do
      let runOk =
            runOp fixedTime Map.empty emptyIndex regFull vaultA
              (CreateTopic (newEntityOf tyCharacter "琳達" Nothing))
          runBad =
            runOp fixedTime Map.empty emptyIndex regFull vaultA
              (CreateTopic (newEntityOf tyGhost "幽靈" Nothing))
      case runResult runOk of
        Right o -> do
          outcomePath o `shouldBe` "characters/琳達.md"
          outcomeRevision o `shouldBe` Revision 1
        other -> expectationFailure ("P-003#EX-8 期望 Right,實得 " <> show other)
      runResult runBad `shouldBe` Left (RegistryDirUnknown tyGhost)
      runFiles runBad `shouldBe` Map.empty

  describe "P-003#EX-9" $
    it "CreateLevel:落在 levels/,恰一個 Node,lvlRoot 等於它,buildTree Right" $ do
      let run =
            runOp fixedTime Map.empty emptyIndex regFull vaultA
              (CreateLevel (newLevelOf "第一章" "序幕" Nothing))
      case runResult run of
        Right o -> do
          outcomePath o `shouldBe` "levels/第一章.md"
          case levelAt (runFiles run) (outcomePath o) of
            Just (lvl, nodes) -> do
              length nodes `shouldBe` 1
              isRight (buildTree lvl nodes) `shouldBe` True
              lvlRoot lvl `shouldBe` metaId (nodMeta (head nodes))
            Nothing -> expectationFailure "P-003#EX-9 levelAt 解不出新建的 Level 檔"
        other -> expectationFailure ("P-003#EX-9 期望 Right,實得 " <> show other)

  describe "P-003#EX-10" $
    it "三節的主題檔檔尾增節:sectionIds 多一個,前三節位元組不變" $ do
      let s =
            NewSection
              (mkId PEnt "000000f1")
              2
              "新節"
              "新節正文。"
              (NSFragment (emptyOverride {moType = Just tyFragment}))
          run = runOp fixedTime vfBase ixBase regFull vaultA (AddSection idEntMain AtEnd s)
          d0 = docOf topicText
      length (sectionIds d0) `shouldBe` 3
      case documentAt (runFiles run) pathTopic of
        Just d1 -> do
          sectionIds d1 `shouldBe` sectionIds d0 <> [nsId s]
          map fst (init (sectionBytes (runFiles run) pathTopic))
            `shouldBe` map fst (sectionBytes vfBase pathTopic)
          init (init (sectionBytes (runFiles run) pathTopic))
            `shouldBe` init (sectionBytes vfBase pathTopic)
        Nothing -> expectationFailure "P-003#EX-10 documentAt 取不到寫入後的文件"

  describe "P-003#EX-11" $
    it "父節點下增節:排在 A1 之後 B 之前,層級是父加一(nsLevel 9 也一樣)" $ do
      let s = NewSection (mkId PNod "000000f2") 9 "新節" "新節正文。" (NSNode emptyOverride (NewNode KScene))
          run =
            runOp fixedTime vfBase ixBase regFull vaultA
              (AddSection idLvl (UnderParent idNodA) s)
          d0 = docOf levelText
      case documentAt (runFiles run) pathLevel of
        Just d1 -> do
          sectionIds d1
            `shouldBe` [idNodRoot, idNodA, idNodA1, nsId s, idNodB, idNodC, idNodD, idNodDeep]
          fmap secLevel (sectionById (nsId s) d1)
            `shouldBe` fmap ((+ 1) . secLevel) (sectionById idNodA d0)
          drop 4 (sectionBytes (runFiles run) pathLevel)
            `shouldBe` drop 3 (sectionBytes vfBase pathLevel)
        Nothing -> expectationFailure "P-003#EX-11 documentAt 取不到寫入後的文件"

  describe "P-003#EX-12" $
    it "父不在檔裡回 SectionMissing、父已在第 6 層回 NodeDepthExceeded,檔案不變" $ do
      let s = NewSection (mkId PNod "000000f2") 3 "新節" "新節正文。" (NSNode emptyOverride (NewNode KScene))
          runMissing =
            runOp fixedTime vfBase ixBase regFull vaultA
              (AddSection idLvl (UnderParent idNodZzz) s)
          runDeep =
            runOp fixedTime vfBase ixBase regFull vaultA
              (AddSection idLvl (UnderParent idNodDeep) s)
      runResult runMissing `shouldBe` Left (SectionMissing pathLevel idNodZzz)
      runFiles runMissing `shouldBe` vfBase
      runResult runDeep `shouldBe` Left (NodeDepthExceeded idNodDeep 7)
      runFiles runDeep `shouldBe` vfBase

  describe "P-003#EX-13" $
    it "被引用的節點:Safe 回 ReferencedBy 檔案不變,Force 刪整棵子樹並列出斷點" $ do
      let runS =
            runOp fixedTime vfBase ixBase regFull vaultA
              (DeleteNode idNodA (Revision 1) DeleteSafe)
          runF =
            runOp fixedTime vfBase ixBase regFull vaultA
              (DeleteNode idNodA (Revision 1) DeleteForce)
      case runResult runS of
        Left (ReferencedBy i _) -> i `shouldBe` idNodA
        other ->
          expectationFailure ("P-003#EX-13 Safe 期望 Left (ReferencedBy …),實得 " <> show other)
      runFiles runS `shouldBe` vfBase
      case runResult runF of
        Right o -> do
          removedIds o `shouldBe` [idNodA, idNodA1]
          brokenLinks o `shouldBe` [(idFragC, linkToNodA)]
        other -> expectationFailure ("P-003#EX-13 Force 期望 Right,實得 " <> show other)

  describe "P-003#EX-14" $
    it "刪根 Node:CannotDeleteRootNode,檔案不變" $ do
      let run =
            runOp fixedTime vfBase ixBase regFull vaultA
              (DeleteNode idNodRoot (Revision 1) DeleteForce)
      runResult run `shouldBe` Left (CannotDeleteRootNode idNodRoot)
      runFiles run `shouldBe` vfBase

  describe "P-003#EX-15" $
    it "salt 0 與 1 都被佔走時,配到的是 salt 2 那一個" $
      allocateN 1 PEnt "琳達" fixedTime ixTakenTwice
        `shouldBe` [newId PEnt "琳達" fixedTime 2]

  describe "P-003#EX-16" $
    it "成功的 WriteBody:索引裡除目標檔外每檔指紋不變" $ do
      let run =
            runOp fixedTime vfBase ixBase regFull vaultA
              (WriteBody idFragA (Revision 1) "改過的正文。")
      case runResult run of
        Right o ->
          filter ((/= outcomePath o) . fst) (fileStatsOf (runIndex run))
            `shouldBe` filter ((/= outcomePath o) . fst) (fileStatsOf ixBase)
        other -> expectationFailure ("P-003#EX-16 期望 Right,實得 " <> show other)

  describe "P-003#EX-17" $
    it "七欄全給非預設值的 CreatePack:packFields 往返相等" $ do
      let run =
            runOp fixedTime vfBase ixBase regFull vaultA
              (CreatePack newPackFull [head packSectionPool])
      case runResult run of
        Right o ->
          fmap packFields (packAt (runFiles run) (outcomePath o))
            `shouldBe` Just (newPackFields newPackFull)
        other -> expectationFailure ("P-003#EX-17 期望 Right,實得 " <> show other)

  describe "P-003#EX-18" $
    it "檔名淨化的六個逐字例子" $ do
      sanitizeFileName "第一章: 序幕 " fbEx `shouldBe` "第一章- 序幕"
      sanitizeFileName "   " fbEx `shouldBe` fbEx
      sanitizeFileName "..." fbEx `shouldBe` fbEx
      sanitizeFileName "<" fbEx `shouldBe` "-"
      sanitizeFileName "<>?" fbEx `shouldBe` "---"
      sanitizeFileName "琳達 的筆記" fbEx `shouldBe` "琳達 的筆記"

  describe "P-003#EX-19" $
    it "subtreeIds 對 nod-a 是 [nod-a, nod-a1],a1 層級 4 大於 3" $ do
      let d = docOf levelText
      subtreeIds d idNodA `shouldBe` [idNodA, idNodA1]
      fmap secLevel (sectionById idNodA1 d) `shouldBe` Just 4
      fmap secLevel (sectionById idNodA d) `shouldBe` Just 3

  describe "P-003#EX-20" $
    it "REV-1:兩個最淺層級的節(兩個根)的 Level 檔,validateLevelDoc 回 Left (TreeInvalidOnWrite …),與 buildTree 的 Left(MultipleRoots)一致" $ do
      let d = docOf levelTwoRootsText
      case levelOf d of
        Just (lvl, nodes) -> case buildTree lvl nodes of
          Left errs -> do
            errs `shouldBe` [MultipleRoots [idNodA, idNodB]]
            validateLevelDoc pathLevel d `shouldBe` Left (TreeInvalidOnWrite pathLevel errs)
          Right _ ->
            expectationFailure "P-003#EX-20 buildTree 對兩個根的 Level 檔沒有回 Left"
        Nothing -> expectationFailure "P-003#EX-20 levelOf 解不出 Level 檔"

  describe "P-003#EX-21" $
    it "isRootNode 的三種結果" $ do
      let d = docOf levelText
      isRootNode pathLevel d idNodRoot `shouldBe` Right True
      isRootNode pathLevel d idNodA `shouldBe` Right False
      isRootNode pathLevel d idNodZzz `shouldBe` Left (SectionMissing pathLevel idNodZzz)

  describe "P-003#EX-22" $
    it "planEdit 對任意文件與請求求值到底不拋例外" $ do
      let loc = Located pathTopic (Just idEntMain) TopicDoc
          op = WriteMeta idEntMain (Revision 3) emptyOverride
      out <-
        try (evaluate (length (show (planEdit regFull fixedTime loc (docOf levelNoNodeText) op))))
          :: IO (Either SomeException Int)
      isRight out `shouldBe` True

fbEx :: Text
fbEx = "untitled"

-- | EX-15:同一個 t 的 salt 0 與 salt 1 都已經在索引裡。
ixTakenTwice :: IndexState
ixTakenTwice =
  IndexState $
    Map.fromList
      [
        ( "taken.md"
        , FileIndex
            "taken.md"
            TopicDoc
            (FileStat 0 0)
            False
            [ IndexedNode
                (NEntity (Entity (takenMeta (newId PEnt "琳達" fixedTime 0)) ""))
                Nothing
            , IndexedNode
                (NEntity (Entity (takenMeta (newId PEnt "琳達" fixedTime 1)) ""))
                Nothing
            ]
        )
      ]
  where
    takenMeta i = (metaOf PEnt "00000003" tyCharacter "琳達" 1) {metaId = i}
