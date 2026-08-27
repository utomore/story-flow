-- | 解析錯誤(graph-core/F004)。
--
-- 原則(entity-graph-core/F003,graph-core/F004 沿用):__任何無法還原資料的情況是錯誤__。
-- 品質警告(缺 summary、自訂關聯……)已經整組移除('MdWarning' 通道退場,見
-- F004 待確認假設 A1)——graph-core design.md 的讀取管線明寫警告的唯一來源是
-- 'Aapms.Core.Meta.MetaWarning'(F002 的 @checkMeta@)。
--
-- 所有錯誤都帶行號,'renderMdError' 輸出 @第 <line> 行:<msg>@。graph-core/F004
-- 拿掉了 __檔名__('errPath'):契約 D 的每一個函式簽名都沒有 'FilePath' 的
-- 位置,@aapms-store@ 知道檔案路徑,要顯示給使用者時自己接上即可。
module Aapms.Md.Error
  ( -- * 錯誤
    MdError (..)
  , MdErrorKind (..)
  , mdError
  , renderMdError
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id, renderId)

data MdError = MdError
  { errLine :: Int
  , errKind :: MdErrorKind
  }
  deriving stock (Show, Eq)

-- | 建構子的參數順序常用形式。
mdError :: Int -> MdErrorKind -> MdError
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
  | -- | 父節點層級, 算出來的層級。插入一個節時算出來的標題層級超過 Markdown 的
    -- 六級上限(graph-core/F004,2026-08-25 裁決 A8)。
    --
    -- 與 'HeadingSkip' 分開是因為__性質不同__:'HeadingSkip' 在
    -- 'Aapms.Md.Render.insertSection' 上只會由呼叫端算錯 @nsLevel@ 造成
    -- (契約 E 明訂 @nsLevel@ 由 store 的 @headingDepthFor@ 推導),那是程式
    -- 的 bug;而層級超過 6 是__真實的作者情境__——Level 的章節樹夠深就會撞到,
    -- 而且有明確的下一步可以講。
    HeadingTooDeep Int Int
  | UnterminatedMetaBlock
  | MissingNodeKind Id
  | -- | frontmatter 宣告的 root, 實際的第一個節
    RootMismatch Id Id
  | -- | 檔案層缺必填欄位
    RequiredFieldMissing Text
  | -- | 節缺少必填欄位(graph-core/F004:pack.md 的 @type@、licenses.md 的
    -- @commercial@ / @attribution_required@)。節 id, 缺少的欄位名
    SectionFieldMissing Id Text
  | -- | 編輯操作指定了不存在的節(entity-graph-core/F003 實作備註 5)
    UnknownSectionId Id
  deriving stock (Show, Eq)

-- | @第 <line> 行:<訊息>@。
renderMdError :: MdError -> Text
renderMdError MdError {..} =
  "第 " <> T.pack (show errLine) <> " 行:" <> renderMdErrorKind errKind

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
  -- 訊息原文是規格,寫在 F004 的 L39 / E21——spec 寫一次、impl 轉錄一次,兩次
  -- 獨立轉錄才驗得到東西。(建骨架時這裡刻意留 undefined 好讓那條逐字斷言有真正
  -- 的紅綠;F004 交付後已填實,見下。)
  HeadingTooDeep parent cur ->
    "標題層級 "
      <> hashes cur
      <> "(第 "
      <> T.pack (show cur)
      <> " 級)超過 Markdown 的六級上限,父節點 "
      <> hashes parent
      <> " 已經在第 "
      <> T.pack (show parent)
      <> " 級,底下加不了子節點了:請改插到較淺的父節點底下,或先把這條分支中間的層級壓平"
  UnterminatedMetaBlock ->
    "```meta 區塊沒有結尾的 ```"
  MissingNodeKind i ->
    "節 " <> renderId i <> " 的 meta 區塊缺少必填的 kind"
  RootMismatch declared actual ->
    "frontmatter 宣告的 root " <> renderId declared <> " 與第一個節 " <> renderId actual <> " 不符"
  RequiredFieldMissing f ->
    "frontmatter 缺少必填欄位 " <> f
  SectionFieldMissing i f ->
    "節 " <> renderId i <> " 缺少必填欄位 " <> f
  UnknownSectionId i ->
    "找不到節 " <> renderId i

hashes :: Int -> Text
hashes n = T.replicate n "#"
