-- | 寫入路徑上__不碰 IO__ 的那一半(graph-core\/F008)。內部模組,不對外承諾
-- 介面,不經 "Aapms.Store" 門面 re-export。
--
-- 「讀 → 樂觀鎖 → 純函式編輯 → 寫檔 → 索引」這條線裡,樂觀鎖比對、錯誤翻譯、
-- 節的正文切片、從已解析的 'Aapms.Md.Document.Document' 取出目標目前的
-- 'Aapms.Core.Meta.Meta' \/ 'Aapms.Core.Asset.Asset'、檔名淨化與結果換型
-- __全部是純函式__ ——它們只吃已經讀進記憶體的值,不需要 'Aapms.Store.Marker.VaultHandle'、
-- 不開檔、不碰 SQLite。集中在這裡之後,"Aapms.Store.Edit" 與 "Aapms.Store.Create"
-- 剩下的就只有 IO。
--
-- __依賴方向__:本模組只 import 型別層(@aapms-core@ 的值型別、"Aapms.Md.Document"、
-- "Aapms.Md.Error"、"Aapms.Store.Types")與純模組("Aapms.Md.Parse" \/
-- "Aapms.Md.Render"),__不 import 任何碰 IO 的 @Aapms.Store.*@__
-- (Edit \/ Create \/ Write \/ Index \/ Query \/ Marker \/ Schema \/ Atomic \/
-- Walk \/ MultiVault \/ Error)。"Aapms.Store.Edit" 與 "Aapms.Store.Create"
-- 原樣 re-export 自己那一份,匯出清單與既有呼叫端逐字不變。
module Aapms.Store.Editing
  ( -- * 錯誤翻譯
    orMd

    -- * 樂觀鎖
  , checkRevision

    -- * 切片
  , sectionBodyRaw

    -- * 共用:讀出目標目前的 Meta \/ Asset(供 Write \/ Create 使用)
  , currentMetaAt
  , currentAssetAt

    -- * 檔名
  , sanitizeFileName

    -- * 節的 payload 與文件種類
  , payloadMatchesDocKind

    -- * 結果換型
  , toCreateResult
  ) where

import Data.Char (isControl, isSpace)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id)
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Meta (Meta (..), Revision)
import Aapms.Core.Pack (Pack (..))
import Aapms.Md.Document (DocKind (..), Document, LineEnding, renderLineEnding)
import Aapms.Md.Error (MdError)
import Aapms.Md.Parse (toLevel, toLicenses, toPack, toTopic)
import Aapms.Md.Render (NewSectionPayload (..))
import Aapms.Store.Types
  ( CreateResult (..)
  , StoreError (..)
  , WriteResult (..)
  )

-- 錯誤翻譯 ---------------------------------------------------------------------

-- | md 的編輯函式回的 'MdError' 包成 'StoreError'。
orMd :: FilePath -> Either MdError a -> Either StoreError a
orMd fp = either (Left . MdWriteFailed fp) Right

-- 樂觀鎖 -----------------------------------------------------------------------

-- | 節點 id、呼叫端手上的 revision、檔案裡的實際 revision。
--
-- 不符即 'RevisionMismatch',而呼叫端在這之後才會碰到
-- 'Aapms.Store.Edit.commit' —— __一個位元組都不會被寫出去__
-- (system.md 全域錯誤處理策略第 6 條)。
checkRevision :: Id -> Revision -> Revision -> Either StoreError ()
checkRevision i expected actual
  | expected == actual = Right ()
  | otherwise = Left (RevisionMismatch i expected actual)

-- 切片 ------------------------------------------------------------------------

-- | 節的正文切片:@```meta@ 區塊(或標題行)之後隔一個空行,結尾補行尾。
--
-- 新節與改正文走同一個形狀,不然同一份檔案裡兩種節的排版會不一樣。
sectionBodyRaw :: LineEnding -> Text -> Text
sectionBodyRaw le t = nl <> T.strip t <> nl
  where
    nl = renderLineEnding le

-- 共用:讀出目標目前的 Meta / Asset ---------------------------------------------
--
-- 'Aapms.Store.Write' 與 'Aapms.Store.Create' 都需要「目標目前真正的 Meta」
-- 才能做樂觀鎖比對(不可逆決定 2:來源是重讀的檔案,不是索引)。四種文件的
-- 檔案層主體與節分別由 'toTopic' \/ 'toLevel' \/ 'toPack' \/ 'toLicenses' 解讀,
-- 派送邏輯集中在這裡,'Write' 與 'Create' 都不用各自重寫一份。

-- | @path@、目標所在文件的種類、目標 id、'Aapms.Store.Types.locAnchor'(定位
-- 結果)→ 目標目前的 'Meta'。找不到回 'SectionMissing'。
currentMetaAt :: FilePath -> DocKind -> Id -> Maybe Id -> Document -> Either StoreError Meta
currentMetaAt path kind target anchor doc = case kind of
  TopicDoc -> do
    (mainE, frags) <- orMd path (toTopic doc)
    case anchor of
      Nothing -> Right (entMeta mainE)
      Just _ -> maybe (Left (SectionMissing path target)) (Right . entMeta) (find ((== target) . metaId . entMeta) frags)
  LevelDoc -> do
    (lvl, nodes) <- orMd path (toLevel doc)
    case anchor of
      Nothing -> Right (lvlMeta lvl)
      Just _ -> maybe (Left (SectionMissing path target)) (Right . nodMeta) (find ((== target) . metaId . nodMeta) nodes)
  PackDoc -> do
    (pck, assets) <- orMd path (toPack doc)
    case anchor of
      Nothing -> Right (pckMeta pck)
      Just _ -> maybe (Left (SectionMissing path target)) (Right . astMeta) (find ((== target) . metaId . astMeta) assets)
  LicenseDoc -> do
    lics <- orMd path (toLicenses doc)
    maybe (Left (SectionMissing path target)) (Right . licMeta) (find ((== target) . metaId . licMeta) lics)

-- | 同 'currentMetaAt',但回傳完整的 'Asset'(供 @writeAssetFields@ 保留唯讀
-- 欄位用)。目標必須落在 @pack.md@ 裡。
currentAssetAt :: FilePath -> Id -> Document -> Either StoreError Asset
currentAssetAt path target doc = do
  (_, assets) <- orMd path (toPack doc)
  maybe (Left (SectionMissing path target)) Right (find ((== target) . metaId . astMeta) assets)

-- 檔名 ------------------------------------------------------------------------

-- | 檔名淨化:標題 → 檔名主幹。
--
-- __保留中文原字元__(vault 是給人看的 git repo)。只把檔案系統不接受的
-- @\<\>:\"\/\\|?*@ 與控制字元換成 @-@,去掉頭尾空白與句點(Windows 不接受以句點
-- 結尾的檔名);全部被清掉時退回第二個參數(慣例上是該節點的短 id)。
sanitizeFileName :: Text -> Text -> Text
sanitizeFileName t fb =
  let replaced = T.map replaceChar t
      trimmed = T.dropWhileEnd trimChar (T.dropWhile trimChar replaced)
   in if T.null trimmed then fb else trimmed
  where
    trimChar c = isSpace c || c == '.'
    replaceChar c
      | c `elem` ("<>:\"/\\|?*" :: String) = '-'
      | isControl c = '-'
      | otherwise = c

-- 節的 payload 與文件種類 ---------------------------------------------------------

-- | 一個新節的內容種類與目標檔案的 'DocKind' 是否相容
-- (@TopicDoc@↔@NSFragment@、@PackDoc@↔@NSAsset@、@LicenseDoc@↔@NSLicense@、
-- @LevelDoc@↔@NSNode@)。
payloadMatchesDocKind :: NewSectionPayload -> DocKind -> Bool
payloadMatchesDocKind (NSFragment _) TopicDoc = True
payloadMatchesDocKind (NSAsset _ _) PackDoc = True
payloadMatchesDocKind (NSLicense _ _) LicenseDoc = True
payloadMatchesDocKind (NSNode _ _) LevelDoc = True
payloadMatchesDocKind _ _ = False

-- 結果換型 ---------------------------------------------------------------------

-- | 'WriteResult' → 'CreateResult'。同樣四個欄位,只是建檔路徑回的是後者。
toCreateResult :: WriteResult -> CreateResult
toCreateResult wr = CreateResult (wrId wr) (wrPath wr) (wrRevision wr) (wrIssues wr)
