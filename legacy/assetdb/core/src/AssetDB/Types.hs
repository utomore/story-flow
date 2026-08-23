-- | 系統的核心列舉與小型值型別。
--
-- 設計原則(對應計畫「原則 3」):核心模型**不認識「圖片」**。
-- 'AssetKind' 是一個開放到足以涵蓋未來音效、影片、3D 的分類軸,
-- 而 kind 專屬的 metadata 一律走 JSON,不進核心資料表。
-- 加入音效時,這個檔案唯一需要的改動是 'KAudio' 已經在這裡了 —— 也就是不需要改動。
module AssetDB.Types
  ( -- * 文字編碼
    TextEnum (..)
  , textEnumValues
  , parseTextEnum

    -- * 資源型別
  , AssetKind (..)
  , KindPrefix (..)
  , prefixKind
  , kindPrefixes
  , kindDefaultDir

    -- * 狀態
  , AssetStatus (..)
  , PackStatus (..)
  , CopyMode (..)
  , TagSource (..)

    -- * 素材包中繼資料
  , AiDisclosure (..)

    -- * 關聯圖
  , EntityType (..)
  , LinkRel (..)
  , NoteKind (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T

--------------------------------------------------------------------------------
-- 文字編碼

-- | 所有列舉都以**穩定的小寫文字**存入 SQLite 與 JSON,而非序號。
--
-- 理由:序號會在有人重新排列建構子時無聲損毀整個資料庫。
-- 文字慢一點點,但 `SELECT * FROM assets WHERE kind='audio'` 人看得懂,
-- 而且新增建構子永遠是相容變更。
class (Eq a, Enum a, Bounded a, Show a) => TextEnum a where
  toTextEnum :: a -> Text

textEnumValues :: forall a. TextEnum a => [a]
textEnumValues = [minBound .. maxBound]

parseTextEnum :: forall a. TextEnum a => Text -> Either Text a
parseTextEnum t =
  case find ((== t) . toTextEnum) (textEnumValues @a) of
    Just a -> Right a
    Nothing ->
      Left $
        "未知的值 " <> T.pack (show t) <> ",可用值:"
          <> T.intercalate ", " (map toTextEnum (textEnumValues @a))

--------------------------------------------------------------------------------
-- 資源型別

-- | 儲存層分類。決定**哪個格式處理器負責**、metadata 長什麼樣、預設放進專案的哪個資料夾。
--
-- 這條軸線刻意保持粗粒度。細分類(GUI / Ground / Book)是 @categories@ 表的工作,
-- 那是使用者可編輯的資料;這裡是程式碼的排程軸。
data AssetKind
  = KImage
  | KAudio
  | KFont
  | KLevel     -- ^ LDtk @.ldtk@
  | KShader
  | KDoc       -- ^ Markdown / PDF,會餵進 @notes@
  | KSource    -- ^ @.aseprite@ / @.psd@ 等可編輯原始檔,不進遊戲
  | KArchive   -- ^ @.zip@ / @.rar@ / @.7z@,只記錄不解壓
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum AssetKind where
  toTextEnum = \case
    KImage   -> "image"
    KAudio   -> "audio"
    KFont    -> "font"
    KLevel   -> "level"
    KShader  -> "shader"
    KDoc     -> "doc"
    KSource  -> "source"
    KArchive -> "archive"

-- | 專案 @assets/@ 底下的預設落點。
kindDefaultDir :: AssetKind -> Text
kindDefaultDir = \case
  KImage   -> "sprites"
  KAudio   -> "audio"
  KFont    -> "fonts"
  KLevel   -> "levels"
  KShader  -> "shaders"
  KDoc     -> "docs"
  KSource  -> "source"
  KArchive -> "source"

-- | 邏輯名稱的第一段。
--
-- 注意這**不等於** 'AssetKind':@spr@ / @tex@ / @ui@ / @atlas@ 都對應到 'KImage',
-- 但在檔名上分開,是因為字典序排序時人想看到它們分堆。
data KindPrefix
  = PSpr    -- ^ 角色 / 物件 sprite
  | PTex    -- ^ tileset / 貼圖
  | PAtlas  -- ^ 打包圖集
  | PUi     -- ^ 介面元件
  | PFnt    -- ^ 字型與字符圖
  | PSfx    -- ^ 音效
  | PBgm    -- ^ 背景音樂
  | PVo     -- ^ 語音
  | PLvl    -- ^ 關卡
  | PShd    -- ^ shader
  | PSrc    -- ^ 可編輯原始檔
  | PDoc    -- ^ 文件
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum KindPrefix where
  toTextEnum = \case
    PSpr -> "spr"; PTex -> "tex"; PAtlas -> "atlas"; PUi  -> "ui"
    PFnt -> "fnt"; PSfx -> "sfx"; PBgm   -> "bgm";   PVo  -> "vo"
    PLvl -> "lvl"; PShd -> "shd"; PSrc   -> "src";   PDoc -> "doc"

-- | 前綴 → 儲存層分類。多對一。
prefixKind :: KindPrefix -> AssetKind
prefixKind = \case
  PSpr -> KImage; PTex -> KImage; PAtlas -> KImage; PUi -> KImage
  PFnt -> KFont
  PSfx -> KAudio; PBgm -> KAudio; PVo -> KAudio
  PLvl -> KLevel
  PShd -> KShader
  PSrc -> KSource
  PDoc -> KDoc

-- | 某個 'AssetKind' 合理的前綴集合。掃描時用來把自動推導限縮在正確的子集。
kindPrefixes :: AssetKind -> [KindPrefix]
kindPrefixes k = [p | p <- textEnumValues, prefixKind p == k]

--------------------------------------------------------------------------------
-- 狀態

data AssetStatus
  = StActive     -- ^ 正常,可搜尋可使用
  | StExcluded   -- ^ 規則判定為非素材(宣傳圖、預覽圖),索引但不出現在搜尋預設結果
  | StMissing    -- ^ 曾經存在,現在磁碟上找不到
  | StArchived   -- ^ 手動封存,不再使用但保留紀錄
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum AssetStatus where
  toTextEnum = \case
    StActive -> "active"; StExcluded -> "excluded"
    StMissing -> "missing"; StArchived -> "archived"

-- | 素材包的完備狀態。
--
-- 匯入一個素材包時,授權與作者資訊未必當場查得到 —— 廠商的壓縮檔裡常常
-- 什麼都沒有(現有素材庫的四個 Effects 包就是如此),得回賣場頁翻。
-- 強迫當場填完會讓匯入卡住,乾脆不填又會讓授權風險靜靜累積。
--
-- 折衷是 'PkDraft':素材照樣入庫、照樣算雜湊與縮圖,但**不進搜尋預設結果、
-- 不可用於建專案**。資訊補齊後才升級為 'PkReady'。
-- 授權缺漏因此是一個看得見的待辦,而不是一個看不見的風險。
data PackStatus
  = PkDraft
  | PkReady
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum PackStatus where
  toTextEnum = \case PkDraft -> "draft"; PkReady -> "ready"

-- | 生成式 AI 使用揭露。
--
-- itch.io 已經把這個做成商品頁的必填欄位,Steam 上架也要求申報。
-- 現有素材庫裡 Kibyra 的 11 包標示為 AI Assisted,Cainos 與 BDragon1727
-- 標示為未使用 —— 這個差異在資料夾結構裡完全看不出來,但發行時要交代。
--
-- 'AiUnknown' 與 'AiNone' 是**不同**的:前者是我們還沒查,
-- 後者是作者明確聲明。發行前的稽核只接受後者。
data AiDisclosure
  = AiUnknown
  | AiNone
  | AiAssisted
  | AiGenerated
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum AiDisclosure where
  toTextEnum = \case
    AiUnknown -> "unknown"; AiNone -> "none"
    AiAssisted -> "assisted"; AiGenerated -> "generated"

-- | 素材進專案的方式。
data CopyMode
  = CmCopy      -- ^ 實體複製。預設,遊戲 repo 需要自足
  | CmHardlink  -- ^ 硬連結。同磁碟區省空間,但改到就會動到素材庫原檔
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum CopyMode where
  toTextEnum = \case CmCopy -> "copy"; CmHardlink -> "hardlink"

-- | 標記來源。決定衝突時誰贏:@manual@ 永遠勝過 @rule@。
data TagSource
  = TsManual
  | TsRule
  | TsInferred  -- ^ 由內容推導(色數、尺寸、phash 聚類)
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum TagSource where
  toTextEnum = \case
    TsManual -> "manual"; TsRule -> "rule"; TsInferred -> "inferred"

--------------------------------------------------------------------------------
-- 關聯圖
--
-- 知識庫與行銷資訊不需要自己的子系統,它們是這張圖上的節點。

data EntityType
  = EAsset
  | EProject
  | ENote
  | ECollection
  | EPack
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum EntityType where
  toTextEnum = \case
    EAsset -> "asset"; EProject -> "project"; ENote -> "note"
    ECollection -> "collection"; EPack -> "pack"

data LinkRel
  = RelUses         -- ^ 關卡使用 tileset、專案使用素材
  | RelDerivesFrom  -- ^ 改色版本 ← 原始素材
  | RelVariantOf    -- ^ 同組不同狀態
  | RelSimilarTo    -- ^ phash 相近,系統推導
  | RelDocuments    -- ^ 筆記描述某素材/專案
  | RelPromotes     -- ^ 行銷素材宣傳某專案
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum LinkRel where
  toTextEnum = \case
    RelUses -> "uses"; RelDerivesFrom -> "derives-from"
    RelVariantOf -> "variant-of"; RelSimilarTo -> "similar-to"
    RelDocuments -> "documents"; RelPromotes -> "promotes"

data NoteKind
  = NkKnowledge
  | NkMarketing
  | NkDecision   -- ^ ADR
  | NkReference
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum NoteKind where
  toTextEnum = \case
    NkKnowledge -> "knowledge"; NkMarketing -> "marketing"
    NkDecision -> "decision"; NkReference -> "reference"

--------------------------------------------------------------------------------
-- JSON

-- 這些 instance 全部走 'TextEnum',所以 JSON 表示與 SQLite 表示保證一致。
-- 只有一個真相來源。

instance ToJSON AssetKind   where toJSON = toJSON . toTextEnum
instance ToJSON KindPrefix  where toJSON = toJSON . toTextEnum
instance ToJSON AssetStatus where toJSON = toJSON . toTextEnum
instance ToJSON PackStatus  where toJSON = toJSON . toTextEnum
instance ToJSON AiDisclosure where toJSON = toJSON . toTextEnum
instance ToJSON CopyMode    where toJSON = toJSON . toTextEnum
instance ToJSON TagSource   where toJSON = toJSON . toTextEnum
instance ToJSON EntityType  where toJSON = toJSON . toTextEnum
instance ToJSON LinkRel     where toJSON = toJSON . toTextEnum
instance ToJSON NoteKind    where toJSON = toJSON . toTextEnum

instance FromJSON AssetKind   where parseJSON = withText "AssetKind"   jsonTextEnum
instance FromJSON KindPrefix  where parseJSON = withText "KindPrefix"  jsonTextEnum
instance FromJSON AssetStatus where parseJSON = withText "AssetStatus" jsonTextEnum
instance FromJSON PackStatus  where parseJSON = withText "PackStatus"  jsonTextEnum
instance FromJSON AiDisclosure where parseJSON = withText "AiDisclosure" jsonTextEnum
instance FromJSON CopyMode    where parseJSON = withText "CopyMode"    jsonTextEnum
instance FromJSON TagSource   where parseJSON = withText "TagSource"   jsonTextEnum
instance FromJSON EntityType  where parseJSON = withText "EntityType"  jsonTextEnum
instance FromJSON LinkRel     where parseJSON = withText "LinkRel"     jsonTextEnum
instance FromJSON NoteKind    where parseJSON = withText "NoteKind"    jsonTextEnum

jsonTextEnum :: forall a m. (TextEnum a, MonadFail m) => Text -> m a
jsonTextEnum t = either (fail . T.unpack) pure (parseTextEnum @a t)
