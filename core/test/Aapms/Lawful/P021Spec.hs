-- | lawful 測試:P-021-registry-build(qa 填入)。
--
-- 每條 law 一條 property test,每個 example 一條 example test;歸屬字串只出現在
-- @describe@ 那一行。產生器一律用型別層的建構子與 smart constructor 組合法值,
-- 清單長度與欄位數都有上限,整個模組每個項目有 timeout。
module Aapms.Lawful.P021Spec (spec) where

import Data.Either (isLeft)
import Data.List (nub, sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Fixtures
  ( refOf
  , sampleAsset
  , sampleEntity
  , sampleLevel
  , sampleLicense
  , sampleNode
  , samplePack
  )
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), LinkKind (..), renderLinkKind)
import Aapms.Core.Meta (Meta (..), MetaWarning (..), TypeKey (..), metaFieldNames)
import Aapms.Core.Name (Segment, mkSegment)
import Aapms.Core.Pack (Pack (..))
import Aapms.Core.Registry
import Aapms.Core.Registry.Build (checkMeta)

--------------------------------------------------------------------------------
-- 上限

-- | 案例數上限。hspec-hedgehog 的 'Example' instance 會拿 hspec 的 maxSuccess
-- 覆蓋 hedgehog 的 @withTests@,所以案例數在這裡用 'modifyMaxSuccess' 宣告。
testLimit :: Int
testLimit = 100

-- | 每個測試項目的 timeout(微秒)。
itemTimeout :: Int
itemTimeout = 30 * 1000 * 1000

-- | 產生器的尺寸上限。
maxDecls, maxFields, maxLinks, maxKinds :: Int
maxDecls = 5
maxFields = 3
maxLinks = 4
maxKinds = 3

--------------------------------------------------------------------------------
-- 詞彙池

-- | 合法、非保留、非空白的型別鍵。
keyPool :: [TypeKey]
keyPool =
  map
    TypeKey
    [ "character-fragment"
    , "world-fragment"
    , "prop"
    , "dialogue"
    , "plot-fragment"
    , "asset-image"
    , "asset-audio"
    , "asset-archive"
    ]

-- | 保證不在 'keyPool' 內的型別鍵,用來直接建構「註冊表查不到」的前提。
foreignKeys :: [TypeKey]
foreignKeys = map TypeKey ["ghost", "phantom", "nobody"]

dirPool :: [FilePath]
dirPool = ["characters", "props", "dialogues", "worlds"]

kindPool :: [Segment]
kindPool = map seg ["spr", "tex", "atlas", "ui", "sfx"]

-- | 測試用的 'Segment' 字面值;寫錯就讓測試直接爆掉。
seg :: Text -> Segment
seg t = case mkSegment t of
  Right s -> s
  Left e -> error ("P-021 測試的 segment 字面值不合法:" <> show e)

--------------------------------------------------------------------------------
-- 產生器

genFamily :: Gen Family
genFamily = Gen.element [FEntity, FAsset]

genLinkKind :: Gen LinkKind
genLinkKind =
  Gen.element [Involves, PartOf, References, Depicts, Uses, Custom "手繪"]

genLink :: Gen Link
genLink = do
  k <- genLinkKind
  pure (Link k (refOf "ent-7f3a") Nothing)

-- | 欄位名一律取自 'metaFieldNames',所以不會製造 'UnknownMetaField'。
genValidField :: Gen FieldDecl
genValidField = do
  n <- Gen.element metaFieldNames
  req <- Gen.bool
  pure (FieldDecl n req "提示")

-- | 基底宣告:全部欄位取最保守的值,由各產生器與 example 逐一覆寫。
baseDecl :: TypeKey -> TypeDecl
baseDecl k =
  TypeDecl
    { tdKey = k
    , tdName = "示例型別"
    , tdFamily = FEntity
    , tdDir = Nothing
    , tdOwnerType = Nothing
    , tdAllowedLinks = []
    , tdStages = []
    , tdFields = []
    , tdNameKinds = []
    }

-- | 一份保證通過五條規則的宣告。@owner@ 由呼叫端指派,見 'genValidDecls'。
genValidDecl :: TypeKey -> TypeKey -> Gen TypeDecl
genValidDecl k owner = do
  fam <- genFamily
  dir <- Gen.maybe (Gen.element dirPool)
  own <- Gen.maybe (pure owner)
  links <- Gen.list (Range.linear 0 maxLinks) genLinkKind
  fields <- Gen.list (Range.linear 0 maxFields) genValidField
  kinds <- Gen.list (Range.linear 0 maxKinds) (Gen.element kindPool)
  stages <- Gen.list (Range.linear 0 2) (Gen.element ["s1", "s5"])
  pure
    (baseDecl k)
      { tdFamily = fam
      , tdDir = dir
      , tdOwnerType = own
      , tdAllowedLinks = links
      , tdStages = stages
      , tdFields = fields
      , tdNameKinds = kinds
      }

-- | 一份宣告(鍵合法、不保留、欄位名存在),單獨送進 'buildRegistry' 會成功。
genOneValidDecl :: Gen TypeDecl
genOneValidDecl = do
  k <- Gen.element keyPool
  owner <- Gen.element keyPool
  genValidDecl k owner

-- | 直接建構「'buildRegistry' 會成功」這個前提:鍵去重,而 @owner_type@ 用
-- @i -> i+1@ 這個雙射指派,所以同一個 @owner@ 最多只被一份宣告認領,
-- 'ConflictingOwnerDir' 在結構上就不可能發生。
genValidDeclsWith :: Range.Range Int -> Gen [TypeDecl]
genValidDeclsWith r = do
  raw <- Gen.list r (Gen.element keyPool)
  let keys = nub raw
      n = length keys
  sequence
    [ genValidDecl k (keys !! ((i + 1) `mod` n))
    | (i, k) <- zip [0 :: Int ..] keys
    ]

genValidDecls :: Gen [TypeDecl]
genValidDecls = genValidDeclsWith (Range.linear 0 maxDecls)

-- | 至少一份宣告,供需要從 'listTypes' 取一份出來的 law 使用。
genNonEmptyValidDecls :: Gen [TypeDecl]
genNonEmptyValidDecls = genValidDeclsWith (Range.linear 1 maxDecls)

-- | 每一份都「沒有必填欄位、沒有 allowed_links、沒有 name_kinds」,
-- 直接建構 LAW-10 的前提。
genLaxDecls :: Gen [TypeDecl]
genLaxDecls = do
  ds <- genNonEmptyValidDecls
  pure
    [ d
        { tdOwnerType = Nothing
        , tdAllowedLinks = []
        , tdNameKinds = []
        , tdFields = [f {fdRequired = False} | f <- tdFields d]
        }
    | d <- ds
    ]

-- | 每一份都宣告了非空的 @allowed_links@,直接建構 LAW-11 的前提。
genLinkyDecls :: Gen [TypeDecl]
genLinkyDecls = do
  ds <- genNonEmptyValidDecls
  sequence
    [ do
        allowed <- Gen.element [[Depicts], [Uses], [Depicts, Uses]]
        pure d {tdOwnerType = Nothing, tdAllowedLinks = allowed}
    | d <- ds
    ]

-- | LAW-2 的定義域是「任何宣告清單」:保留鍵、空白鍵、重複鍵、不存在的欄位名、
-- 互相打架的 @owner_type@ / @dir@ 全都可能出現。
genAnyDecls :: Gen [TypeDecl]
genAnyDecls = Gen.list (Range.linear 0 maxDecls) genAnyDecl

genAnyDecl :: Gen TypeDecl
genAnyDecl = do
  k <- Gen.element anyKeyPool
  fam <- genFamily
  dir <- Gen.maybe (Gen.element dirPool)
  own <- Gen.maybe (Gen.element anyKeyPool)
  links <- Gen.list (Range.linear 0 maxLinks) genLinkKind
  fields <- Gen.list (Range.linear 0 maxFields) genAnyField
  kinds <- Gen.list (Range.linear 0 maxKinds) (Gen.element kindPool)
  pure
    (baseDecl k)
      { tdFamily = fam
      , tdDir = dir
      , tdOwnerType = own
      , tdAllowedLinks = links
      , tdFields = fields
      , tdNameKinds = kinds
      }

anyKeyPool :: [TypeKey]
anyKeyPool =
  keyPool <> reservedTypeKeys <> map TypeKey ["", "   ", "GHOST"]

genAnyField :: Gen FieldDecl
genAnyField = do
  n <- Gen.element (metaFieldNames <> ["ghost", ""])
  req <- Gen.bool
  pure (FieldDecl n req "提示")

-- | 六種節點各一份最小 fixture,再把 'Meta' 換成指定型別鍵與隨機關聯。
genAnyNode :: TypeKey -> Gen AnyNode
genAnyNode k = do
  base <-
    Gen.element
      [ NEntity sampleEntity
      , NAsset sampleAsset
      , NPack samplePack
      , NLicense sampleLicense
      , NLevel sampleLevel
      , NNode sampleNode
      ]
  links <- Gen.list (Range.linear 0 maxLinks) genLink
  pure (setMeta ((anyMeta base) {metaType = k, metaLinks = links}) base)

setMeta :: Meta -> AnyNode -> AnyNode
setMeta m = \case
  NEntity e -> NEntity e {entMeta = m}
  NAsset a -> NAsset a {astMeta = m}
  NPack p -> NPack p {pckMeta = m}
  NLicense l -> NLicense l {licMeta = m}
  NLevel lv -> NLevel lv {lvlMeta = m}
  NNode nd -> NNode nd {nodMeta = m}

--------------------------------------------------------------------------------
-- 輔助

-- | 'TypeRegistry' 不透明也沒有 'Show',所以「求值到正規形」用它的兩個可觀察
-- 投影來逼:'RegistryError' 清單,或 'listTypes' 的全部宣告。
renderOutcome :: Either [RegistryError] TypeRegistry -> String
renderOutcome = either show (show . listTypes)

leftOf :: Either [RegistryError] TypeRegistry -> Maybe [RegistryError]
leftOf = either Just (const Nothing)

expectRight :: Either [RegistryError] TypeRegistry -> IO TypeRegistry
expectRight (Right reg) = pure reg
expectRight (Left errs) = do
  expectationFailure ("buildRegistry 應該成功,卻回 Left:" <> show errs)
  -- 'expectationFailure' 已經拋出,這行只是給型別交代。
  fail "P-021:expectRight 不該走到這裡"

isNameKindWarning :: MetaWarning -> Bool
isNameKindWarning = \case
  NameKindNotAllowed _ _ -> True
  _ -> False

withTimeout :: IO () -> IO ()
withTimeout act =
  timeout itemTimeout act >>= \case
    Just () -> pure ()
    Nothing ->
      expectationFailure
        ("P-021 的測試項目超過 " <> show itemTimeout <> " 微秒仍未結束")

-- | 把 fixture 的素材換成指定的型別鍵、名稱與關聯。
assetWith :: TypeKey -> Maybe LogicalName -> [Link] -> AnyNode
assetWith k nm links =
  NAsset
    sampleAsset
      { astMeta = (astMeta sampleAsset) {metaType = k, metaLinks = links}
      , astName = nm
      }

--------------------------------------------------------------------------------
-- spec

spec :: Spec
spec = modifyMaxSuccess (const testLimit) $ around_ withTimeout $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-021#LAW-1" $
    it "保留鍵一律進不了註冊表" $
      hedgehog $ do
        k <- forAll (Gen.element reservedTypeKeys)
        owner <- forAll (Gen.element keyPool)
        d <- forAll (genValidDecl k owner)
        assert (isLeft (buildRegistry [d]))

  describe "P-021#LAW-2" $
    it "任何宣告清單丟給 buildRegistry 都有值,不拋例外" $
      hedgehog $ do
        ds <- forAll genAnyDecls
        n <- eval (length (renderOutcome (buildRegistry ds)))
        assert (n >= 0)

  describe "P-021#LAW-3" $
    it "同一份宣告出現兩次一定被拒,鍵不可重複" $
      hedgehog $ do
        d <- forAll genOneValidDecl
        assert (isLeft (buildRegistry [d, d]))

  describe "P-021#LAW-4" $
    it "建得起來的註冊表列得出送進去的每一份宣告" $
      hedgehog $ do
        ds <- forAll genValidDecls
        reg <- evalEither (buildRegistry ds)
        let listed = map tdKey (listTypes reg)
        annotateShow listed
        mapM_ (\d -> assert (tdKey d `elem` listed)) ds

  describe "P-021#LAW-5" $
    it "listTypes 列出來的每一份,lookupType 都查得到而且就是它自己" $
      hedgehog $ do
        ds <- forAll genValidDecls
        reg <- evalEither (buildRegistry ds)
        mapM_ (\d -> lookupType reg (tdKey d) === Just d) (listTypes reg)

  describe "P-021#LAW-6" $
    it "listTypes 依鍵排序且鍵不重複" $
      hedgehog $ do
        ds <- forAll genValidDecls
        reg <- evalEither (buildRegistry ds)
        let listed = listTypes reg
            listedKeys = map tdKey listed
        sortOn tdKey listed === listed
        nub listedKeys === listedKeys

  describe "P-021#LAW-7" $
    it "型別自己宣告了 dir 時,lookupDir 就回那一個" $
      hedgehog $ do
        ds <- forAll genValidDecls
        reg <- evalEither (buildRegistry ds)
        let withDir = [d | d <- listTypes reg, isJust (tdDir d)]
        cover 10 "至少一份宣告帶 dir" (not (null withDir))
        mapM_ (\d -> lookupDir reg (tdKey d) === tdDir d) withDir

  describe "P-021#LAW-8" $
    it "家族的文字表示與解析互為反函式" $
      hedgehog $ do
        f <- forAll genFamily
        parseFamily (renderFamily f) === Just f

  describe "P-021#LAW-9" $
    it "型別沒宣告時,checkMeta 只回一則 UnknownNodeType" $
      hedgehog $ do
        ds <- forAll genValidDecls
        reg <- evalEither (buildRegistry ds)
        k <- forAll (Gen.element foreignKeys)
        n <- forAll (genAnyNode k)
        lookupType reg k === Nothing
        checkMeta reg n === [UnknownNodeType k]

  describe "P-021#LAW-10" $
    it "沒有必填欄位、沒有 allowed_links、沒有 name_kinds 時不產生警告" $
      hedgehog $ do
        ds <- forAll genLaxDecls
        reg <- evalEither (buildRegistry ds)
        d <- forAll (Gen.element (listTypes reg))
        n <- forAll (genAnyNode (tdKey d))
        checkMeta reg n === []

  describe "P-021#LAW-11" $
    it "宣告了 allowed_links 之後,不在裡面的關聯逐條產生 LinkNotAllowed" $
      hedgehog $ do
        ds <- forAll genLinkyDecls
        reg <- evalEither (buildRegistry ds)
        d <- forAll (Gen.element (listTypes reg))
        n <- forAll (genAnyNode (tdKey d))
        let ws = checkMeta reg n
            offending =
              [ l
              | l <- metaLinks (anyMeta n)
              , linkKind l `notElem` tdAllowedLinks d
              ]
        annotateShow ws
        cover 30 "節點帶了不被允許的關聯" (not (null offending))
        mapM_
          ( \l ->
              assert
                (LinkNotAllowed (tdKey d) (renderLinkKind (linkKind l)) `elem` ws)
          )
          offending

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-021#EX-1" $
    it "空目錄是合法的:buildRegistry [] 建得出空註冊表" $ do
      reg <- expectRight (buildRegistry [])
      listTypes reg `shouldBe` []

  describe "P-021#EX-2" $
    it "三個保留鍵各自被擋下" $
      mapM_
        ( \k ->
            leftOf (buildRegistry [baseDecl k]) `shouldBe` Just [ReservedTypeKey k]
        )
        [TypeKey "level", TypeKey "asset-pack", TypeKey "asset-license"]

  describe "P-021#EX-3" $
    it "同一個 tdKey 的兩份宣告被拒,該鍵只列一次" $ do
      let d = baseDecl (TypeKey "dialogue")
          errs = fromMaybe [] (leftOf (buildRegistry [d, d]))
          dup = DuplicateTypeKey (TypeKey "dialogue")
      errs `shouldSatisfy` elem dup
      length (filter (== dup) errs) `shouldBe` 1

  describe "P-021#EX-4" $
    it "兩份宣告依鍵字母序列出,兩個鍵都查得到" $ do
      reg <- expectRight (buildRegistry [ex4Dialogue, ex4CharacterFragment])
      listTypes reg `shouldBe` [ex4CharacterFragment, ex4Dialogue]
      lookupType reg (TypeKey "character-fragment") `shouldBe` Just ex4CharacterFragment
      lookupType reg (TypeKey "dialogue") `shouldBe` Just ex4Dialogue

  describe "P-021#EX-5" $
    it "lookupDir 回型別自己宣告的目錄" $ do
      reg <- expectRight (buildRegistry [ex4Dialogue, ex4CharacterFragment])
      lookupDir reg (TypeKey "character-fragment") `shouldBe` Just "characters"

  describe "P-021#EX-6" $
    it "宣告了 Meta 上不存在的欄位名會被擋下" $ do
      let d = (baseDecl (TypeKey "prop")) {tdFields = [FieldDecl "ghost" False "提示"]}
      leftOf (buildRegistry [d])
        `shouldBe` Just [UnknownMetaField (TypeKey "prop") "ghost"]

  describe "P-021#EX-7" $
    it "空白鍵與保留鍵的錯誤同時出現在一個清單裡" $ do
      let blank = baseDecl (TypeKey "   ")
          reserved = baseDecl (TypeKey "asset-pack")
          errs = fromMaybe [] (leftOf (buildRegistry [blank, reserved]))
      errs `shouldSatisfy` elem EmptyTypeKey
      errs `shouldSatisfy` elem (ReservedTypeKey (TypeKey "asset-pack"))

  describe "P-021#EX-8" $
    it "家族的文字互轉" $ do
      renderFamily FEntity `shouldBe` "entity"
      renderFamily FAsset `shouldBe` "asset"
      parseFamily "ghost" `shouldBe` Nothing

  describe "P-021#EX-9" $
    it "註冊表沒有的型別鍵恰好產生一則 UnknownNodeType" $ do
      reg <- expectRight (buildRegistry [baseDecl (TypeKey "character-fragment")])
      let ghost = TypeKey "ghost"
          n = setMeta ((entMeta sampleEntity) {metaType = ghost}) (NEntity sampleEntity)
      checkMeta reg n `shouldBe` [UnknownNodeType ghost]

  describe "P-021#EX-10" $
    it "空清單是「未宣告限制」而不是「什麼都不准」" $ do
      let d = (baseDecl (TypeKey "asset-archive")) {tdFamily = FAsset}
      reg <- expectRight (buildRegistry [d])
      checkMeta
        reg
        ( assetWith
            (TypeKey "asset-archive")
            (Just (LogicalName "ui_gui_travel-book-frame_001"))
            []
        )
        `shouldBe` []

  describe "P-021#EX-11" $
    it "不在 allowed_links 內的關聯產生 LinkNotAllowed" $ do
      let d =
            (baseDecl (TypeKey "asset-image"))
              { tdFamily = FAsset
              , tdAllowedLinks = [Depicts]
              }
      reg <- expectRight (buildRegistry [d])
      let n =
            assetWith
              (TypeKey "asset-image")
              (Just (LogicalName "ui_gui_travel-book-frame_001"))
              [Link Involves (refOf "ent-7f3a") Nothing]
      checkMeta reg n
        `shouldSatisfy` elem (LinkNotAllowed (TypeKey "asset-image") "involves")

  describe "P-021#EX-12" $
    it "命名第一段在 name_kinds 內才不產生 NameKindNotAllowed" $ do
      let d =
            (baseDecl (TypeKey "asset-image"))
              { tdFamily = FAsset
              , tdNameKinds = map seg ["spr", "tex", "atlas", "ui"]
              }
      reg <- expectRight (buildRegistry [d])
      let warn nm = checkMeta reg (assetWith (TypeKey "asset-image") nm [])
      filter isNameKindWarning (warn (Just (LogicalName "ui_gui_travel-book-frame_001")))
        `shouldBe` []
      warn (Just (LogicalName "sfx_ui_click_001"))
        `shouldSatisfy` elem (NameKindNotAllowed (TypeKey "asset-image") "sfx")
      filter isNameKindWarning (warn Nothing) `shouldBe` []

ex4CharacterFragment :: TypeDecl
ex4CharacterFragment =
  (baseDecl (TypeKey "character-fragment")) {tdDir = Just "characters"}

ex4Dialogue :: TypeDecl
ex4Dialogue = baseDecl (TypeKey "dialogue")
