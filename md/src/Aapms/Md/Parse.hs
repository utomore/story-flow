-- | 兩階段解析的第二階段:把 'Document' 的原始切片解讀成核心型別
-- (graph-core/F004:四種文件共用一個分節引擎)。
--
-- @docKind@(檔案層 frontmatter 的 @type@)是判別依據:@level@ → 'LevelDoc'、
-- @asset-pack@ → 'PackDoc'、@asset-license@ → 'LicenseDoc',其餘一律
-- 'TopicDoc'。三個保留鍵由 F002 的 @validateRegistry@ 把關,本模組只認字面值。
--
-- 錯誤契約(graph-core/F004 待確認假設 A2):__只回報第一個錯誤__
-- (依節的文件順序,也就是行號由小到大)。這與舊版「一次列完全部」不同——
-- 契約 D 的每個函式簽名都是單一 'MdError',不是清單。
module Aapms.Md.Parse
  ( -- * 進入點
    parseDocument

    -- * 四種文件的解析
  , toTopic
  , toLevel
  , toPack
  , toLicenses
  ) where

import Data.Aeson (FromJSON (..), Value (..), withObject, (.:), (.:?), (.!=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Asset (Asset (..), LogicalName, Sha256)
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (..), Ref, idPrefix, parseId, renderIdPrefix)
import Aapms.Core.Json ()
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), LinkKind (Involves, References))
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Md.Document
import Aapms.Md.Error
import Aapms.Md.Inherit
import Aapms.Md.Lexer (lexDocument, metaBlockYaml)
import Aapms.Md.Yaml

-- | 切塊(見 "Aapms.Md.Lexer")+ 讀出檔案身分('DocKind')存進 'Document'。
--
-- 'docKind' 的判定要讀 frontmatter 的 YAML 才知道 @type@ 是什麼字串,而 YAML
-- 有可能解不開,所以__在這裡__(不是在 'Aapms.Md.Document.docKind' 存取器)
-- 把 frontmatter 解到能讀出 @type@ 為止:不需要驗證 'Meta' 的六個必填欄位
-- 全部到齊——那是語意層的事,留給 'toTopic' \/ 'toLevel' \/ 'toPack' \/
-- 'toLicenses' 各自檢查。
parseDocument :: Text -> Either MdError Document
parseDocument src = do
  doc0 <- lexDocument src
  kind <- resolveDocKind (docFrontRaw doc0)
  Right doc0 {docKind = kind}

resolveDocKind :: Text -> Either MdError DocKind
resolveDocKind raw = case decodeValue raw of
  Left (l, m) -> Left (mdError l (FrontmatterYaml m))
  Right (Object o) -> Right (kindFromType (KM.lookup "type" o))
  Right _ -> Right TopicDoc
  where
    kindFromType (Just (String "level")) = LevelDoc
    kindFromType (Just (String "asset-pack")) = PackDoc
    kindFromType (Just (String "asset-license")) = LicenseDoc
    kindFromType _ = TopicDoc

-- | frontmatter 的 aeson 'Value'。
--
-- 'docFrontRaw' 以開頭界線的行尾字元起始,所以 YAML 的第 n 行剛好就是檔案的
-- 第 n 行,行號不需要換算。
frontValue :: Document -> Either MdError Value
frontValue Document {..} = case decodeValue docFrontRaw of
  Left (l, m) -> Left (mdError l (FrontmatterYaml m))
  Right v -> Right v

-- | frontmatter 的 'Value' 與檔案層 'Meta'。缺必填欄位回報第一個缺的。
frontMeta :: Document -> Either MdError (Value, Meta)
frontMeta doc = do
  v <- frontValue doc
  case missingFields requiredFrontFields v of
    (f : _) -> Left (mdError 1 (RequiredFieldMissing f))
    [] -> case fromValue v of
      Left m -> Left (mdError 1 (FrontmatterYaml m))
      Right meta -> Right (v, meta)

-- | 節的 @```meta@ 區塊解成 'MetaOverride'。沒有區塊視為全部欄位未寫。
sectionOverride :: Section -> Either MdError MetaOverride
sectionOverride Section {..} = case secMetaRaw of
  Nothing -> Right emptyOverride
  Just raw ->
    let (off, yaml) = metaBlockYaml raw
     in case decodeMetaAt yaml of
          Left (l, m) -> Left (mdError (secLine + off + l) (SectionYaml secId m))
          Right ov -> Right ov

-- | 節的 @```meta@ 區塊解成原始 aeson 'Value'(供 'toPack' \/ 'toLicenses' 讀
-- 'MetaOverride' 管不到的專屬欄位)。
sectionValue :: Section -> Either MdError Value
sectionValue Section {..} = case secMetaRaw of
  Nothing -> Right (Object KM.empty)
  Just raw ->
    let (off, yaml) = metaBlockYaml raw
     in case decodeValue yaml of
          Left (l, m) -> Left (mdError (secLine + off + l) (SectionYaml secId m))
          Right v -> Right v

-- | 節 id 的前綴必須與檔案的身分相符。
prefixErrorsE :: IdPrefix -> Section -> Either MdError ()
prefixErrorsE want Section {..}
  | idPrefix secId /= want = Left (mdError secLine (IdPrefixMismatch secId (renderIdPrefix want)))
  | otherwise = Right ()

-- | 'inheritMeta' 的 'MdErrorKind' 補上行號,組成完整 'MdError'。
wrapMeta :: Int -> Either MdErrorKind a -> Either MdError a
wrapMeta line = either (Left . mdError line) Right

--------------------------------------------------------------------------------
-- 主題檔 / Level 檔

-- | 檔案層 frontmatter 描述主體 Entity,'docPreamble' 是它的 @body@;
-- 每個節是一個片段 Entity。
toTopic :: Document -> Either MdError (Entity, [Entity])
toTopic doc@Document {..} = do
  (_, front) <- frontMeta doc
  frags <- traverse (fragment front) docSections
  Right (Entity front (T.strip docPreamble), frags)
  where
    fragment front s@Section {..} = do
      prefixErrorsE PEnt s
      ov <- sectionOverride s
      meta <- wrapMeta secLine (inheritMeta True front secId secTitle ov)
      Right (Entity meta (T.strip secBodyRaw))

-- | 標題階層即樹(ADR-009):層級決定 @parent@,文件順序決定 @order@。
--
-- 本函式__不呼叫__ @buildTree@——結構合法性是 core 的職責,這裡只負責把文字
-- 變成 Node 清單。
toLevel :: Document -> Either MdError (Level, [Node])
toLevel doc@Document {..} = do
  (v, front) <- frontMeta doc
  placed <- structure docSections
  ns <- traverse (node front) placed
  root <- rootId doc v
  Right (Level front root, ns)
  where
    node front (s@Section {..}, parent, order) = do
      prefixErrorsE PNod s
      ov <- sectionOverride s
      case moKind ov of
        Nothing -> Left (mdError secLine (MissingNodeKind secId))
        Just k -> do
          meta <- wrapMeta secLine (inheritMeta True front secId secTitle ov)
          Right
            Node
              { nodMeta = meta
              , nodLevel = metaId front
              , nodParent = parent
              , nodOrder = order
              , nodKind = k
              , nodEntities = entitiesOf meta
              }

    -- Node 指向的 Entity 由 involves / references 推導,不另設 entities 欄位
    entitiesOf :: Meta -> [Ref]
    entitiesOf meta =
      nub [linkTarget l | l <- metaLinks meta, linkKind l `elem` [Involves, References]]

-- | frontmatter 的 @root@:寫了就要與第一個節相符,沒寫就以第一個節填入。
rootId :: Document -> Value -> Either MdError Id
rootId Document {..} v = case (declared, docSections) of
  (Nothing, s : _) -> Right (secId s)
  (Nothing, []) -> Left (mdError 1 (RequiredFieldMissing "root"))
  (Just d, s : _)
    | d /= secId s -> Left (mdError 1 (RootMismatch d (secId s)))
    | otherwise -> Right d
  (Just d, []) -> Right d
  where
    declared = case v of
      Object o -> case KM.lookup "root" o of
        Just (String s) -> either (const Nothing) (Just . snd) (parseId s)
        _ -> Nothing
      _ -> Nothing

-- | 由標題層級算出每個節的 @parent@ 與 @order@,並回報跳級/越級
-- (回報第一個遇到的,依文件順序)。
structure :: [Section] -> Either MdError [(Section, Maybe Id, Int)]
structure [] = Right []
structure (s0 : rest) = go [] M.empty rootLevel (s0 : rest)
  where
    rootLevel = secLevel s0

    go :: [(Int, Id)] -> M.Map (Maybe Id) Int -> Int -> [Section] -> Either MdError [(Section, Maybe Id, Int)]
    go _ _ _ [] = Right []
    go stack orders prev (s : more)
      | lvl < rootLevel = Left (mdError (secLine s) (HeadingAboveRoot rootLevel lvl))
      | lvl > prev + 1 = Left (mdError (secLine s) (HeadingSkip prev lvl))
      | otherwise = do
          restResult <- go ((lvl, secId s) : stack') (M.insert parent order orders) lvl more
          Right ((s, parent, order) : restResult)
      where
        lvl = secLevel s
        stack' = dropWhile ((>= lvl) . fst) stack
        parent = case stack' of
          ((_, p) : _) -> Just p
          [] -> Nothing
        order = M.findWithDefault 0 parent orders + 1

--------------------------------------------------------------------------------
-- pack.md

-- | 素材專屬欄位,從節的 meta YAML 另外解一次(不在 'MetaOverride' 裡——那個
-- DTO 只管 'Meta' 的欄位)。@sha256@ \/ @entry@ 缺漏是錯誤(對應 'Asset' 的非
-- 'Maybe' 欄位),其餘缺漏是 'Nothing' \/ 'Null',與 "Aapms.Core.Json" 的
-- @FromJSON Asset@ 實例規則一致。
data AssetFields = AssetFields
  { afName :: Maybe LogicalName
  , afSha256 :: Sha256
  , afEntry :: Text
  , afExt :: Maybe Text
  , afMeta :: Value
  , afLicense :: Maybe Ref
  , afAuthor :: Maybe Text
  }

instance FromJSON AssetFields where
  parseJSON = withObject "AssetFields" $ \o ->
    AssetFields
      <$> o .:? "name"
      <*> o .: "sha256"
      <*> o .: "entry"
      <*> o .:? "ext"
      <*> o .:? "meta" .!= Null
      <*> o .:? "license"
      <*> o .:? "author"

-- | 檔案層 pack.md 的 frontmatter 直接解成 'Pack'(不是先解成 'Meta' 再另外
-- 處理 pack 專屬欄位)——"Aapms.Core.Json" 的 @FromJSON Pack@ 實例本來就是把
-- 'Meta' 的欄位與 pack 專屬欄位攤平在同一層物件解出來。
--
-- 每一節:@type@ __不繼承__——asset 的型別一定不是 @asset-pack@,缺漏是
-- 'SectionFieldMissing'(由 'inheritMeta' 的 @typeInherits = False@ 產生)。
toPack :: Document -> Either MdError (Pack, [Asset])
toPack doc@Document {..} = do
  v <- frontValue doc
  case missingFields requiredFrontFields v of
    (f : _) -> Left (mdError 1 (RequiredFieldMissing f))
    [] -> do
      pack0 <- either (Left . mdError 1 . FrontmatterYaml) Right (fromValue v :: Either Text Pack)
      -- frontmatter 的 Value 沒有 "body" 鍵(那是 docPreamble,不在 YAML 裡),
      -- FromJSON Pack 因此把它解成預設的空字串;用 docPreamble 蓋回去,
      -- 跟 toTopic 對 Entity 的 body 處理方式一致
      let pack = pack0 {pckBody = T.strip docPreamble}
      assets <- traverse (asset (pckMeta pack)) docSections
      Right (pack, assets)
  where
    asset front s@Section {..} = do
      prefixErrorsE PAst s
      ov <- sectionOverride s
      meta <- wrapMeta secLine (inheritMeta False front secId secTitle ov)
      av <- sectionValue s
      af <- either (Left . mdError secLine . SectionYaml secId) Right (fromValue av :: Either Text AssetFields)
      Right
        Asset
          { astMeta = meta
          , astName = afName af
          , astSha256 = afSha256 af
          , astEntry = afEntry af
          , astExt = afExt af
          , astKindMeta = afMeta af
          , astLicense = afLicense af
          , astAuthor = afAuthor af
          , astBody = T.strip secBodyRaw
          }

--------------------------------------------------------------------------------
-- licenses.md

-- | 授權八維度中,節層 meta 直接管的那一組(不含 @full_text@——那是全域授權
-- 登記用,節層不重複貼授權全文)。
data LicenseFields = LicenseFields
  { lfCommercial :: Bool
  , lfAttributionRequired :: Bool
  , lfCreditText :: Maybe Text
  , lfModificationAllowed :: Maybe Bool
  , lfRedistributionAllowed :: Maybe Bool
  , lfResaleAllowed :: Maybe Bool
  , lfNftAllowed :: Maybe Bool
  , lfSourceUrl :: Maybe Text
  }

instance FromJSON LicenseFields where
  parseJSON = withObject "LicenseFields" $ \o ->
    LicenseFields
      <$> o .: "commercial"
      <*> o .: "attribution_required"
      <*> o .:? "credit_text"
      <*> o .:? "modification_allowed"
      <*> o .:? "redistribution_allowed"
      <*> o .:? "resale_allowed"
      <*> o .:? "nft_allowed"
      <*> o .:? "source_url"

-- | @commercial@ \/ @attribution_required@ 缺漏要回 'SectionFieldMissing'(不是
-- aeson 的通用錯誤訊息),所以先各自檢查鍵是否存在,存在才交給 'fromValue'。
licenseFieldsOf :: Id -> Int -> Value -> Either MdError LicenseFields
licenseFieldsOf secId secLine v = do
  checkKey "commercial"
  checkKey "attribution_required"
  either (Left . mdError secLine . SectionYaml secId) Right (fromValue v :: Either Text LicenseFields)
  where
    checkKey k = case v of
      Object o | KM.member (K.fromText k) o -> Right ()
      _ -> Left (mdError secLine (SectionFieldMissing secId k))

-- | @licenses.md@ 的檔案層是容器不是節點——只解到 'Meta'(供節層繼承),不出現
-- 在回傳值裡。每一節:@type@ __繼承__(design.md「節層繼承規則」表格,
-- licenses.md 併入「主題檔 / Level 檔」那一欄)。
toLicenses :: Document -> Either MdError [License]
toLicenses doc@Document {..} = do
  (_, front) <- frontMeta doc
  traverse (license front) docSections
  where
    license front s@Section {..} = do
      prefixErrorsE PLic s
      ov <- sectionOverride s
      meta <- wrapMeta secLine (inheritMeta True front secId secTitle ov)
      lv <- sectionValue s
      lf <- licenseFieldsOf secId secLine lv
      Right
        License
          { licMeta = meta
          , licCommercial = lfCommercial lf
          , licAttributionRequired = lfAttributionRequired lf
          , licCreditText = lfCreditText lf
          , licModificationAllowed = lfModificationAllowed lf
          , licRedistributionAllowed = lfRedistributionAllowed lf
          , licResaleAllowed = lfResaleAllowed lf
          , licNftAllowed = lfNftAllowed lf
          , licSourceUrl = lfSourceUrl lf
          , licFullText = Nothing
          }
