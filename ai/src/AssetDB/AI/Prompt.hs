-- | 提示詞與其對應的 JSON Schema。
--
-- 兩者放在同一個模組是刻意的:它們是同一份合約的兩半。prompt 說明每個
-- 分類是什麼意思,schema 決定模型能吐出哪些值 —— 兩邊都由同一個 'Vocab'
-- 產生,所以不可能一邊改了另一邊沒跟上。
--
-- 全部是純函式,沒有 IO。提示詞的迴歸因此可以直接用字串斷言測。
module AssetDB.AI.Prompt
  ( promptVersion

    -- * 叢集分類(純文字)
  , ClusterInfo (..)
  , clusterSystem
  , clusterUser
  , clusterSchema
  , ClusterVerdict (..)

    -- * 視覺標註(含圖)
  , VisionInfo (..)
  , visionSystem
  , visionUser
  , visionSchema
  , VisionVerdict (..)

    -- * 自然語句查詢
  , querySystem
  , queryUser
  , querySchema
  , QueryVerdict (..)
  ) where

import AssetDB.AI.Schema
import AssetDB.AI.Vocab
import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as T

-- | 提示詞版本。每次改動提示詞就手動加一。
--
-- 存進 @ai_runs.prompt_ver@,而每一筆建議都指回它的 run —— 於是「這個標籤
-- 是哪個模型、用哪一版提示詞產生的」永遠是一次 join 的距離,不必為此
-- 加寬 @blobs@ 這張最熱的表。
promptVersion :: Text
promptVersion = "v1"

unknown :: Text
unknown = "unknown"

--------------------------------------------------------------------------------
-- 共用

-- | 把詞彙表攤成給模型看的定義清單。
--
-- 這段文字與 schema 的列舉出自同一個 'Vocab',所以「prompt 裡講了但列舉
-- 裡沒有」或反過來的情況不會發生。
vocabBlock :: Vocab -> Text
vocabBlock v =
  T.intercalate "\n" (map top (vocabTop v))
  where
    top c =
      "- " <> catSlug c <> ":" <> catDefinition c <> leaves (catPath c)
    leaves p = case childrenOf v p of
      [] -> ""
      cs -> "\n    子分類:" <> T.intercalate "、" (map catPath cs)

commonRules :: Text
commonRules =
  T.intercalate
    "\n"
    [ "規則:"
    , "1. analysis 欄位先寫,用一兩句說明你依據什麼判斷。先想再答。"
    , "2. 不確定就填 " <> unknown <> "。猜錯比誠實說不知道更糟 —— 錯的分類會被寫進索引。"
    , "3. subcategory 必須是所選 category 底下的項目,格式是「父/子」。"
    , "4. 中文標籤請用繁體中文,而且要是真的會有人拿去搜尋的詞。"
    , "5. 只輸出 JSON。"
    ]

--------------------------------------------------------------------------------
-- 叢集分類

data ClusterInfo = ClusterInfo
  { ciPackName :: Text
  , ciPackSlug :: Text
  , ciShape :: Text
  , ciCount :: Int
  , ciSamples :: [Text]
  }
  deriving stock (Eq, Show)

clusterSystem :: Vocab -> Text
clusterSystem v =
  T.intercalate
    "\n"
    [ "你在替一個像素風遊戲素材庫做分類。"
    , ""
    , "分類詞彙表(只能用這些):"
    , vocabBlock v
    , ""
    , "這一次你看到的是一整個**叢集** —— 同一個素材包裡檔名結構相同的一群檔案。"
    , "整群共用同一個分類。你看不到圖,只能依檔名、路徑與素材包名稱判斷。"
    , ""
    , "style_tags 描述**畫風與規格**(如 pixel-art、32x32、outlined)。"
    , "theme_tags 描述**題材**(如 fantasy、medieval、food)。"
    , "兩者都是整群共用的性質。個別檔案畫的是什麼東西**不要**寫在這裡 ——"
    , "那由之後的逐張視覺標註負責。"
    , ""
    , commonRules
    ]

clusterUser :: ClusterInfo -> Text
clusterUser ClusterInfo {..} =
  T.intercalate
    "\n"
    ( [ "素材包:" <> ciPackName <> "(" <> ciPackSlug <> ")"
      , "叢集鍵:" <> ciShape
      , "成員數:" <> T.pack (show ciCount)
      , "檔名範例:"
      ]
        <> map ("  " <>) (take 8 ciSamples)
    )

clusterSchema :: Vocab -> Value
clusterSchema v =
  responseFormat "cluster_classification" $
    objectOf
      [ ("analysis", stringOf "一兩句判斷依據。先寫這一欄。")
      , ("category", enumOf "主分類" (topSlugs v <> [unknown]))
      , ("subcategory", enumOf "子分類,格式為 父/子" (leafPaths v <> [unknown]))
      , ("style_tags_en", tagArr "畫風與規格標籤(英文)")
      , ("style_tags_zh", tagArr "畫風與規格標籤(繁體中文)")
      , ("theme_tags_en", tagArr "題材標籤(英文)")
      , ("theme_tags_zh", tagArr "題材標籤(繁體中文)")
      , ("confidence", numberOf "0 到 1 的信心值")
      ]
  where
    tagArr d = arrayOf d 4 (stringOf "單一標籤")

data ClusterVerdict = ClusterVerdict
  { cvAnalysis :: Text
  , cvCategory :: Text
  , cvSubcategory :: Text
  , cvStyleEn :: [Text]
  , cvStyleZh :: [Text]
  , cvThemeEn :: [Text]
  , cvThemeZh :: [Text]
  , cvConfidence :: Double
  }
  deriving stock (Eq, Show)

instance FromJSON ClusterVerdict where
  parseJSON = withObject "ClusterVerdict" $ \o ->
    ClusterVerdict
      <$> o .:? "analysis" .!= ""
      <*> o .:? "category" .!= unknown
      <*> o .:? "subcategory" .!= unknown
      <*> o .:? "style_tags_en" .!= []
      <*> o .:? "style_tags_zh" .!= []
      <*> o .:? "theme_tags_en" .!= []
      <*> o .:? "theme_tags_zh" .!= []
      <*> o .:? "confidence" .!= 0

--------------------------------------------------------------------------------
-- 視覺標註

data VisionInfo = VisionInfo
  { viOriginalName :: Text
  , viPath :: Text
  , viPackName :: Text
  }
  deriving stock (Eq, Show)

visionSystem :: Vocab -> Text
visionSystem v =
  T.intercalate
    "\n"
    [ "你在替一個像素風遊戲素材庫做內容標註。使用者會給你一張素材縮圖。"
    , ""
    , "分類詞彙表(只能用這些):"
    , vocabBlock v
    , ""
    , "subject 是「這張圖畫的是什麼」,寫一個簡短的名詞詞組,英文與中文各一。"
    , "tags 是可以拿來搜尋的具體詞:物件本身、材質、顏色、用途。"
    , "中文標籤特別重要 —— 這個素材庫的檔名全是英文,中文標籤是中文搜尋"
    , "唯一的入口。"
    , ""
    , "檔名與路徑只是輔助。**以圖為準** —— 檔名經常是無意義的流水號。"
    , ""
    , commonRules
    ]

visionUser :: VisionInfo -> Text
visionUser VisionInfo {..} =
  T.intercalate
    "\n"
    [ "素材包:" <> viPackName
    , "原始檔名:" <> viOriginalName
    , "路徑:" <> viPath
    ]

visionSchema :: Vocab -> Value
visionSchema v =
  responseFormat "vision_tagging" $
    objectOf
      [ ("analysis", stringOf "一兩句描述你在圖上看到什麼。先寫這一欄。")
      , ("category", enumOf "主分類" (topSlugs v <> [unknown]))
      , ("subcategory", enumOf "子分類,格式為 父/子" (leafPaths v <> [unknown]))
      , ("confidence", numberOf "0 到 1 的信心值")
      , ("subject_en", stringOf "這張圖畫的是什麼,英文簡短名詞詞組")
      , ("subject_zh", stringOf "這張圖畫的是什麼,繁體中文簡短名詞詞組")
      , ("tags_en", arrayOf "英文搜尋標籤" 6 (stringOf "單一標籤"))
      , ("tags_zh", arrayOf "繁體中文搜尋標籤" 6 (stringOf "單一標籤"))
      ]

data VisionVerdict = VisionVerdict
  { vvAnalysis :: Text
  , vvCategory :: Text
  , vvSubcategory :: Text
  , vvConfidence :: Double
  , vvSubjectEn :: Text
  , vvSubjectZh :: Text
  , vvTagsEn :: [Text]
  , vvTagsZh :: [Text]
  }
  deriving stock (Eq, Show)

instance FromJSON VisionVerdict where
  parseJSON = withObject "VisionVerdict" $ \o ->
    VisionVerdict
      <$> o .:? "analysis" .!= ""
      <*> o .:? "category" .!= unknown
      <*> o .:? "subcategory" .!= unknown
      <*> o .:? "confidence" .!= 0
      <*> o .:? "subject_en" .!= ""
      <*> o .:? "subject_zh" .!= ""
      <*> o .:? "tags_en" .!= []
      <*> o .:? "tags_zh" .!= []

--------------------------------------------------------------------------------
-- 自然語句查詢

querySystem :: Vocab -> Text
querySystem v =
  T.intercalate
    "\n"
    [ "你要把使用者的自然語句轉成素材庫的搜尋條件。"
    , ""
    , "可用的分類:" <> T.intercalate "、" (topSlugs v)
    , ""
    , "keywords 是要丟進全文搜尋的詞。使用者說中文時,**中英文都要給** ——"
    , "素材的原始檔名是英文,但庫裡也有 AI 產生的中文標籤,兩邊都要搜。"
    , "不要把「我想要」「幫我找」這種話寫進 keywords。"
    , ""
    , "只輸出 JSON。"
    ]

queryUser :: Text -> Text
queryUser q = "使用者輸入:" <> q

querySchema :: Vocab -> Value
querySchema v =
  responseFormat "query_translation" $
    objectOf
      [ ("analysis", stringOf "一句話說明你怎麼理解這個查詢。先寫這一欄。")
      , ("category", enumOf "最相關的主分類,判斷不出來就填 unknown" (topSlugs v <> [unknown]))
      , ("keywords", arrayOf "搜尋關鍵字,中英文混合" 8 (stringOf "單一關鍵字"))
      ]

data QueryVerdict = QueryVerdict
  { qvAnalysis :: Text
  , qvCategory :: Text
  , qvKeywords :: [Text]
  }
  deriving stock (Eq, Show)

instance FromJSON QueryVerdict where
  parseJSON = withObject "QueryVerdict" $ \o ->
    QueryVerdict
      <$> o .:? "analysis" .!= ""
      <*> o .:? "category" .!= unknown
      <*> o .:? "keywords" .!= []
