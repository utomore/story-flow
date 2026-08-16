-- | 'Document' / 'Section' —— 原檔的忠實表示。
--
-- ADR-0010 要求「未經修改的區塊逐字保留原始位元組」,因此本模組的型別只存
-- __原始文字切片__,不存解讀後的 'StoryFlow.Core.Meta.Meta'。解讀是
-- "StoryFlow.Md.Parse" 的事,可重複呼叫;'Document' 因此永遠等於原檔。
--
-- == 切片的界線(func-0003 實作備註 4)
--
-- 每一段切片都__含自己結尾的行尾字元__,而且 frontmatter 的兩條 @---@ 界線
-- __只有 @---@ 這三個字元本身__由 'StoryFlow.Md.Render.renderDocument' 重生:
--
-- * 'docFrontRaw' 由開頭界線的行尾字元起算,到結尾界線的 @---@ 之前為止
-- * 'docPreamble' 由結尾界線的行尾字元起算,到第一個節標題之前為止
-- * 'secHeadingRaw' / 'secMetaRaw' / 'secBodyRaw' 同理,依序接起來就是該節的原文
--
-- 這樣連「frontmatter 界線用 LF、正文用 CRLF」的混合檔,位元組相等也是
-- __結構上保證__的,而不是靠 'docEnding' 猜。代價是界線行只接受剛好 @---@。
module StoryFlow.Md.Document
  ( -- * 行尾
    LineEnding (..)
  , renderLineEnding
  , detectLineEnding

    -- * 文件
  , Document (..)
  , Section (..)
  , sectionById
  , sectionIds
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id)

-- | 全檔行尾風格。混合行尾取多數;平手時取 'LF'。
data LineEnding = LF | CRLF
  deriving stock (Show, Eq)

renderLineEnding :: LineEnding -> Text
renderLineEnding = \case
  LF -> "\n"
  CRLF -> "\r\n"

-- | 多數決。只在__新產生__的行(重新序列化的 meta 區塊、插入的節)上使用;
-- 既有的每一段都保留自己原本的行尾。
detectLineEnding :: Text -> LineEnding
detectLineEnding t
  | crlf > lf = CRLF
  | otherwise = LF
  where
    crlf = T.count "\r\n" t
    lf = T.count "\n" t - crlf

data Document = Document
  { docPath :: FilePath
  -- ^ 僅用於錯誤訊息
  , docFrontRaw :: Text
  -- ^ frontmatter 原始內容(不含 @---@ 界線本身,含其行尾字元)
  , docPreamble :: Text
  -- ^ frontmatter 之後、第一個節標題之前的原始文字
  , docSections :: [Section]
  , docEnding :: LineEnding
  -- ^ 全檔行尾風格,新產生的行沿用
  , docFinalNL :: Bool
  -- ^ 原檔是否以換行結尾。'StoryFlow.Md.Render.insertSection' 在檔尾補節時需要
  }
  deriving stock (Show, Eq)

data Section = Section
  { secLevel :: Int
  -- ^ 標題層級,@##@ = 2
  , secHeadingRaw :: Text
  -- ^ 原始標題行,含 @{#id}@ 與行尾
  , secTitle :: Text
  -- ^ 去掉 @{#id}@ 與 @#@ 後的標題文字
  , secId :: Id
  , secMetaRaw :: Maybe Text
  -- ^ 標題行之後到 @```meta@ 區塊結尾 fence 行(含)的原始切片。
  -- 前導空行也在裡面,重新序列化時原樣保留(func-0003 實作備註 3)
  , secBodyRaw :: Text
  -- ^ meta 區塊之後到下一個節標題之前的原始文字
  , secLine :: Int
  -- ^ 標題行在原檔的行號(1 起算),錯誤訊息用
  }
  deriving stock (Show, Eq)

sectionById :: Id -> Document -> Maybe Section
sectionById i doc = case filter ((== i) . secId) (docSections doc) of
  (s : _) -> Just s
  [] -> Nothing

sectionIds :: Document -> [Id]
sectionIds = map secId . docSections
