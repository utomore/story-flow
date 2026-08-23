-- | 'Document' / 'Section' —— 原檔的忠實表示。
--
-- ADR-010 要求「未經修改的區塊逐字保留原始位元組」,因此本模組的型別只存
-- __原始文字切片__,不存解讀後的 'Aapms.Core.Meta.Meta'。解讀是
-- "Aapms.Md.Parse" 的事,可重複呼叫;'Document' 因此永遠等於原檔。
--
-- == 切片的界線(entity-graph-core/F003 實作備註 4)
--
-- 每一段切片都__含自己結尾的行尾字元__,而且 frontmatter 的兩條 @---@ 界線
-- __只有 @---@ 這三個字元本身__由 'Aapms.Md.Render.renderDocument' 重生:
--
-- * 'docFrontRaw' 由開頭界線的行尾字元起算,到結尾界線的 @---@ 之前為止
-- * 'docPreamble' 由結尾界線的行尾字元起算,到第一個節標題之前為止
-- * 'secHeadingRaw' / 'secMetaRaw' / 'secBodyRaw' 同理,依序接起來就是該節的原文
--
-- 這樣連「frontmatter 界線用 LF、正文用 CRLF」的混合檔,位元組相等也是
-- __結構上保證__的,而不是靠 'docEnding' 猜。代價是界線行只接受剛好 @---@。
--
-- == 檔案身分('DocKind',graph-core/F004)
--
-- 四種文件(主題檔 / Level 檔 / pack.md / licenses.md)共用同一個 'Document'
-- 型別,身分由檔案層 frontmatter 的 @type@ 判別('Aapms.Md.Parse.parseDocument'
-- 在解析階段就算好存進 'docKind',見該函式的說明)。'Document' 因此__不再含__
-- @docPath@——graph-core/F004 契約 D 的所有函式都沒有 'FilePath' 的位置,
-- 檔名由呼叫端('aapms-store')自行接上。
module Aapms.Md.Document
  ( -- * 行尾
    LineEnding (..)
  , renderLineEnding
  , detectLineEnding

    -- * 檔案身分
  , DocKind (..)

    -- * 文件
  , Document (..)
  , Section (..)
  , sectionById
  , sectionIds
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id)

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

-- | 檔案的四種身分,由檔案層 frontmatter 的 @type@ 判別
-- ('Aapms.Md.Parse.parseDocument' 的說明):@level@ → 'LevelDoc'、
-- @asset-pack@ → 'PackDoc'、@asset-license@ → 'LicenseDoc',其餘一律 'TopicDoc'。
data DocKind = TopicDoc | LevelDoc | PackDoc | LicenseDoc
  deriving stock (Show, Eq)

data Document = Document
  { docFrontRaw :: Text
  -- ^ frontmatter 原始內容(不含 @---@ 界線本身,含其行尾字元)
  , docPreamble :: Text
  -- ^ frontmatter 之後、第一個節標題之前的原始文字
  , docSections :: [Section]
  , docEnding :: LineEnding
  -- ^ 全檔行尾風格,新產生的行沿用
  , docFinalNL :: Bool
  -- ^ 原檔是否以換行結尾。'Aapms.Md.Render.appendSection' 在檔尾補節時需要
  , docKind :: DocKind
  -- ^ 檔案身分的內部快取(graph-core/F004):由 'Aapms.Md.Parse.parseDocument'
  -- 算好存入,不會、也不需要重新解析——這個欄位__就是__公開介面的
  -- @docKind :: Document -> DocKind@ 存取器
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
  -- 前導空行也在裡面,重新序列化時原樣保留(entity-graph-core/F003 實作備註 3)
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
