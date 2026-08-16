-- | 解析錯誤與品質警告。
--
-- 原則(func-0003):__任何無法還原資料的情況是錯誤,任何品質問題是警告__。
-- 作者手寫時漏一句 @summary@ 不該讓整個檔案讀不出來,但工具要講出來。
--
-- 所有錯誤都帶檔名與行號,'renderMdError' 輸出 @檔案:行號: 訊息@ ——
-- 與編譯器/linter 的慣例一致,編輯器可直接跳轉。
module StoryFlow.Md.Error
  ( -- * 錯誤
    MdError (..)
  , MdErrorKind (..)
  , mdError
  , renderMdError

    -- * 警告
  , MdWarning (..)
  , renderMdWarning
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, renderId)
import StoryFlow.Core.Link (renderLinkKind, suggestCoreKind)

data MdError = MdError
  { errPath :: FilePath
  , errLine :: Int
  , errKind :: MdErrorKind
  }
  deriving stock (Show, Eq)

-- | 建構子的參數順序常用形式。
mdError :: FilePath -> Int -> MdErrorKind -> MdError
mdError = MdError

data MdErrorKind
  = -- | 檔案開頭不是 @---@
    NoFrontmatter
  | -- | 只有開頭界線,找不到結尾
    UnterminatedFrontmatter
  | -- | HsYAML 的訊息
    FrontmatterYaml Text
  | -- | 節 id, HsYAML 或 aeson 的訊息
    SectionYaml Id Text
  | -- | 標題文字。缺 @{#id}@ 或 @{#id}@ 不是合法 ID 都算
    HeadingWithoutId Text
  | DuplicateSectionId Id
  | -- | 實際 id, 期望的前綴
    IdPrefixMismatch Id Text
  | -- | 前一個層級, 這一個層級
    HeadingSkip Int Int
  | -- | 根層級, 這一個層級
    HeadingAboveRoot Int Int
  | UnterminatedMetaBlock
  | MissingNodeKind Id
  | -- | frontmatter 宣告的 root, 實際的第一個節
    RootMismatch Id Id
  | -- | 檔案層缺必填欄位
    RequiredFieldMissing Text
  | -- | 編輯操作指定了不存在的節(func-0003 實作備註 5)
    UnknownSectionId Id
  deriving stock (Show, Eq)

-- | @檔案:行號: 訊息@。
renderMdError :: MdError -> Text
renderMdError MdError {..} =
  T.pack errPath <> ":" <> T.pack (show errLine) <> ": " <> renderMdErrorKind errKind

renderMdErrorKind :: MdErrorKind -> Text
renderMdErrorKind = \case
  NoFrontmatter ->
    "檔案開頭缺少 --- frontmatter 界線"
  UnterminatedFrontmatter ->
    "frontmatter 只有開頭的 ---,找不到結尾的 ---"
  FrontmatterYaml m ->
    "frontmatter 的 YAML 無法解析:" <> m
  SectionYaml i m ->
    "節 " <> renderId i <> " 的 meta 區塊 YAML 無法解析:" <> m
  HeadingWithoutId t ->
    "標題「" <> t <> "」缺少合法的 {#id} 屬性"
  DuplicateSectionId i ->
    "節 id " <> renderId i <> " 在同一份檔案中重複"
  IdPrefixMismatch i p ->
    "節 id " <> renderId i <> " 的前綴不是 " <> p <> "-"
  HeadingSkip prev cur ->
    "標題層級跳級:" <> hashes prev <> " 之後不能直接接 " <> hashes cur
  HeadingAboveRoot root cur ->
    "標題層級 " <> hashes cur <> " 比根層級 " <> hashes root <> " 還淺"
  UnterminatedMetaBlock ->
    "```meta 區塊沒有結尾的 ```"
  MissingNodeKind i ->
    "節 " <> renderId i <> " 的 meta 區塊缺少必填的 kind"
  RootMismatch declared actual ->
    "frontmatter 宣告的 root " <> renderId declared <> " 與第一個節 " <> renderId actual <> " 不符"
  RequiredFieldMissing f ->
    "frontmatter 缺少必填欄位 " <> f
  UnknownSectionId i ->
    "找不到節 " <> renderId i

hashes :: Int -> Text
hashes n = T.replicate n "#"

data MdWarning
  = MissingSummary Id
  | -- | 節 id, 自訂關聯字串
    CustomLinkKind Id Text
  | EmptyBody Id
  deriving stock (Show, Eq)

renderMdWarning :: MdWarning -> Text
renderMdWarning = \case
  MissingSummary i ->
    "節 " <> renderId i <> " 沒有寫 summary;衝突偵測撈 context 會少一個主要輸入"
  CustomLinkKind i k ->
    "節 " <> renderId i <> " 使用了自訂關聯「" <> k <> "」,引擎不會對它做推論"
      <> maybe "" (\c -> ";是否想寫 " <> renderLinkKind c <> "?") (suggestCoreKind k)
  EmptyBody i ->
    "節 " <> renderId i <> " 沒有正文"
