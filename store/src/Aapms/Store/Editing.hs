-- | 寫入路徑上__不碰 IO__ 的那一半(graph-core\/F008)。內部模組,不對外承諾
-- 介面,不經 "Aapms.Store" 門面 re-export。
--
-- 「讀 → 樂觀鎖 → 純函式編輯 → 寫檔 → 索引」這條線裡,樂觀鎖比對、錯誤翻譯、
-- 節的正文切片、從已解析的 'Aapms.Md.Document.Document' 取出目標目前的
-- 'Aapms.Core.Meta.Meta' \/ 'Aapms.Core.Asset.Asset'、檔名淨化與結果換型
-- __全部是純函式__ ——它們只吃已經讀進記憶體的值,不需要 'Aapms.Store.Marker.VaultHandle'、
-- 不開檔、不碰 SQLite。2026-09-06 退場波之後,舊的 @Aapms.Store.Edit@ \/
-- @Aapms.Store.Create@ 兩個直接 IO 模組已經退場,寫入的唯一 shell 進入點是
-- 'Aapms.Store.Write.applyWriteIO',而它跑的就是本模組的 'applyWrite'。
--
-- __依賴方向__:本模組只 import 型別層(@aapms-core@ 的值型別、"Aapms.Md.Document"、
-- "Aapms.Md.Error"、"Aapms.Store.Types")與純模組("Aapms.Md.Parse" \/
-- "Aapms.Md.Render"),__不 import 任何碰 IO 的 @Aapms.Store.*@__
-- (Write \/ Index \/ Query \/ Marker \/ Schema \/ Atomic \/
-- Walk \/ MultiVault \/ Error)。
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

    -- * 配號與寫入規劃(P-003-node-write)
  , allocateFreshId
  , planEdit
  , planCreate

    -- * 純的整條(P-003-node-write)
  , applyWrite
  ) where

import Control.Monad (foldM)
import Data.Char (isControl, isSpace)
import Data.List (find, isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, utctDay)
import Effectful (Eff, (:>))
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (..), VaultId, newId, renderId)
import Aapms.Core.Level (Level (..), Node (..))
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Meta (..), Revision (..), Source (..), Status (..), TypeKey (..), bumpRevision)
import Aapms.Core.Pack (Pack (..))
import Aapms.Core.Registry (TypeRegistry, lookupDir)
import Aapms.Md.Document (DocKind (..), Document (..), LineEnding, renderLineEnding, sectionIds)
import Aapms.Md.Error (MdError)
import Aapms.Md.Inherit (MetaOverride (..), applyOverride, emptyOverride, overrideOf)
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Md.Render
  ( NewAsset (..)
  , NewLicense (..)
  , NewNode (..)
  , NewPackFront (..)
  , NewSection (..)
  , NewSectionPayload (..)
  , appendSection
  , insertSection
  , newDocument
  , newDocumentWith
  , packFrontExtras
  , payloadExtras
  , removeSection
  , renderDocument
  , replacePreamble
  , updateFrontmatter
  , updateSection
  , updateSectionBody
  , updateSectionExtras
  )
import Aapms.Store.Effect.Clock (Clock, now)
import Aapms.Store.Effect.Index (Index, idTaken, locateId, referrers, removeFile)
import Aapms.Store.Effect.VaultFs (VaultFs, deleteMarkdown, fileExists, readMarkdown, writeMarkdown)
import Aapms.Store.Indexing (indexPath)
import Aapms.Store.Node (headingDepthFor, isRootNode, subtreeIds, validateLevelDoc)
import Aapms.Store.Types
  ( AssetPatch (..)
  , CreateResult (..)
  , DeleteMode (..)
  , DeleteResult (..)
  , IndexIssue
  , Located (..)
  , NewEntity (..)
  , NewLevel (..)
  , NewPack (..)
  , SectionPlacement (..)
  , StoreError (..)
  , WriteOp (..)
  , WriteOutcome (..)
  , WriteResult (..)
  , idsNeeded
  , opTarget
  , removedIds
  , renderStoreError
  )

-- 錯誤翻譯 ---------------------------------------------------------------------

-- | md 的編輯函式回的 'MdError' 包成 'StoreError'。
orMd :: FilePath -> Either MdError a -> Either StoreError a
orMd fp = either (Left . MdWriteFailed fp) Right

-- 樂觀鎖 -----------------------------------------------------------------------

-- | 節點 id、呼叫端手上的 revision、檔案裡的實際 revision。
--
-- 不符即 'RevisionMismatch',而呼叫端在這之後才會碰到
-- 寫檔那一步('Aapms.Store.Effect.VaultFs.writeMarkdown')—— __一個位元組都不會被寫出去__
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
-- 'planEdit' 的改寫類請求都需要「目標目前真正的 Meta」
-- 才能做樂觀鎖比對(不可逆決定 2:來源是重讀的檔案,不是索引)。四種文件的
-- 檔案層主體與節分別由 'toTopic' \/ 'toLevel' \/ 'toPack' \/ 'toLicenses' 解讀,
-- 派送邏輯集中在這裡,每一種請求都不用各自重寫一份。

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

-- 配號與寫入規劃(P-003-node-write)----------------------------------------------

-- | 同一個 @t@ 之下以 salt 遞增重試到不撞號;碰撞查詢失敗即失敗。
--
-- 候選 id 恆為 @'Aapms.Core.Id.newId' pre c t salt@,@salt@ 從 @0@ 起遞增
-- (ADR-014;salt 遞增是唯一機制,LAW-17)。時間是明碼參數:呼叫端先取
-- 'Aapms.Store.Effect.Clock.now' 再傳進來,測試才造得出碰撞。
--
-- 失敗通道保留給真解譯器:記憶體索引的碰撞查詢不會失敗,所以純側恆為 'Right'。
allocateFreshId :: Index :> es => IdPrefix -> Text -> UTCTime -> Eff es (Either StoreError Id)
allocateFreshId pre c t = go (0 :: Int)
  where
    go salt = do
      let candidate = newId pre c t salt
      taken <- idTaken candidate
      if taken then go (salt + 1) else pure (Right candidate)

-- | 一次配好一批新 id(依序,任一個失敗就整批失敗)。本模組私有。
--
-- 每一個都走 'allocateFreshId',所以__每一個都經過 'idTaken'__(P-003 REV-2)。
-- 批次內兩兩相異靠前綴:'Aapms.Core.Id.newId' 把前綴寫進 id 本身,而同一批的
-- 各項前綴互異('CreateLevel' 是 @PLvl@ 與 @PNod@),所以不必在批次之間先把
-- 配好的號寫進索引。
allocateIds :: Index :> es => UTCTime -> [(IdPrefix, Text)] -> Eff es (Either StoreError [Id])
allocateIds t = go []
  where
    go acc [] = pure (Right (reverse acc))
    go acc ((pre, c) : rest) =
      allocateFreshId pre c t >>= \case
        Left e -> pure (Left e)
        Right i -> go (i : acc) rest

-- | 既有檔的純核心:樂觀鎖 → 讀出目前的 Meta \/ Asset → 編輯那一節 →
-- 新 'Document' 與結果;失敗即 'Left',文件不動。
--
-- __樂觀鎖排在最前面__(LAW-1):帶 expected revision 的請求一律先
-- 'currentMetaAt' + 'checkRevision',再做該請求自己的前置檢查(是不是 asset、
-- 那一筆關聯在不在)。反過來的話「對非 asset 的節點改 asset 欄位而且 revision
-- 也不符」會回 'NotAnAsset' 而不是 'RevisionMismatch'。
--
-- __刪除是例外__:根 Node 的判定排在樂觀鎖之前(LAW-16 要求兩種模式、
-- 不論 revision 都回 'CannotDeleteRootNode')。
--
-- 刪除的「被引用檢查」不在這裡:它要查索引,是效果,由 'applyWrite' 補上
-- ('drBrokenLinks' 在本函式先留空)。
planEdit :: TypeRegistry -> UTCTime -> Located -> Document -> WriteOp -> Either StoreError (Document, WriteOutcome)
planEdit _reg t loc doc op = case op of
  WriteMeta i expected ov -> withLocked i expected $ \curMeta -> do
    let (newRev, newUpdated) = stampsOf curMeta
    doc' <- case anchor of
      Nothing ->
        let edited = applyOverride ov curMeta
         in orMd path (updateFrontmatter (const edited {metaRevision = newRev, metaUpdated = newUpdated}) doc)
      Just sid ->
        orMd path (updateSection sid (\ov0 -> stamp newRev newUpdated (mergeOverride ov ov0)) doc)
    pure (doc', Written (WriteResult i path newRev []))
  WriteAssetFields i expected patch -> withLocked i expected $ \_curMeta ->
    case (kind, anchor) of
      (PackDoc, Just _) -> do
        curAsset <- currentAssetAt path i doc
        let (newRev, newUpdated) = stampsOf (astMeta curAsset)
            merged =
              NewAsset
                { naName = applyPatchField (apName patch) (astName curAsset)
                , naSha256 = astSha256 curAsset
                , naEntry = astEntry curAsset
                , naExt = astExt curAsset
                , naKindMeta = astKindMeta curAsset
                , naLicense = applyPatchField (apLicense patch) (astLicense curAsset)
                , naAuthor = applyPatchField (apAuthor patch) (astAuthor curAsset)
                }
            newExtras = payloadExtras (NSAsset (overrideOf (astMeta curAsset)) merged)
        doc1 <- orMd path (updateSectionExtras i (const newExtras) doc)
        doc2 <-
          orMd
            path
            ( updateSection
                i
                (\ov0 -> (stamp newRev newUpdated ov0) {moTags = maybe (moTags ov0) Just (apTags patch)})
                doc1
            )
        pure (doc2, Written (WriteResult i path newRev []))
      _ -> Left (NotAnAsset i)
  WriteBody i expected body -> withLocked i expected $ \curMeta -> do
    let (newRev, newUpdated) = stampsOf curMeta
    doc' <- case anchor of
      Nothing ->
        let doc1 = replacePreamble body doc
         in orMd path (updateFrontmatter (const curMeta {metaRevision = newRev, metaUpdated = newUpdated}) doc1)
      Just sid -> do
        doc1 <- orMd path (updateSectionBody sid (sectionBodyRaw (docEnding doc) body) doc)
        orMd path (updateSection sid (stamp newRev newUpdated) doc1)
    pure (doc', Written (WriteResult i path newRev []))
  AddLink i expected link -> withLocked i expected $ \curMeta ->
    applyLinks i curMeta (metaLinks curMeta ++ [link])
  RemoveLink i expected link -> withLocked i expected $ \curMeta ->
    if link `notElem` metaLinks curMeta
      then Left (LinkNotFound i link)
      else applyLinks i curMeta (filter (/= link) (metaLinks curMeta))
  UpsertLicense lic -> planUpsertLicense t path doc lic
  AddSection i placement sec -> planAddSection t loc doc i placement sec
  DeleteNode i expected mode -> planDelete loc doc i expected mode
  -- 建檔類不走這裡('applyWrite' 分派到 'planCreate');簽名要求一個
  -- 'Either',所以給一個說得通的失敗而不是拋例外(LAW-25:全函數)。
  CreateTopic _ -> Left notAnEditOp
  CreateLevel _ -> Left notAnEditOp
  CreatePack _ _ -> Left notAnEditOp
  where
    path = locPath loc
    kind = locKind loc
    anchor = locAnchor loc
    today = utctDay t

    notAnEditOp = FileWriteFailed path "P-003:建檔請求不經過 planEdit"

    -- 樂觀鎖那一段:讀出目標目前的 Meta、比對 revision,再做請求自己的事。
    withLocked i expected k = do
      curMeta <- currentMetaAt path kind i anchor doc
      checkRevision i expected (metaRevision curMeta)
      k curMeta

    stampsOf curMeta =
      let bumped = bumpRevision today curMeta
       in (metaRevision bumped, metaUpdated bumped)

    stamp newRev newUpdated ov0 = ov0 {moRevision = Just newRev, moUpdated = Just newUpdated}

    applyPatchField :: Maybe (Maybe a) -> Maybe a -> Maybe a
    applyPatchField Nothing cur = cur
    applyPatchField (Just v) _ = v

    -- 'AddLink' / 'RemoveLink' 共用:算好的新關聯清單寫回,revision +1。
    applyLinks i curMeta newLinks = do
      let (newRev, newUpdated) = stampsOf curMeta
      doc' <- case anchor of
        Nothing ->
          orMd
            path
            ( updateFrontmatter
                (const curMeta {metaLinks = newLinks, metaRevision = newRev, metaUpdated = newUpdated})
                doc
            )
        Just sid ->
          orMd
            path
            -- 清空之後不留 `links: []` 這一行——沒有連結就是沒有這個鍵,
            -- 與「原本就沒寫過」不可區分,LAW-6 要求的往返恆等才成立。
            ( updateSection
                sid
                (\ov0 -> (stamp newRev newUpdated ov0) {moLinks = if null newLinks then Nothing else Just newLinks})
                doc
            )
      pure (doc', Written (WriteResult i path newRev []))

-- | 'MetaOverride' 的合併:@new@ 寫了的欄位覆蓋 @old@,沒寫的沿用
-- (P-003 的決定:'WriteMeta' 帶值而不是函數,語意是「'Just' 的欄位覆蓋」)。
mergeOverride :: MetaOverride -> MetaOverride -> MetaOverride
mergeOverride new old =
  MetaOverride
    { moKind = pick moKind
    , moType = pick moType
    , moVault = pick moVault
    , moSummary = pick moSummary
    , moTags = pick moTags
    , moStatus = pick moStatus
    , moTimeline = pick moTimeline
    , moAliases = pick moAliases
    , moLinks = pick moLinks
    , moSource = pick moSource
    , moRevision = pick moRevision
    , moCreated = pick moCreated
    , moUpdated = pick moUpdated
    }
  where
    pick :: (MetaOverride -> Maybe a) -> Maybe a
    pick f = maybe (f old) Just (f new)

-- | @licenses.md@ 的 upsert:同 id 的節在就整節改寫,不在就追加一節。
--
-- 兩條路徑都把 revision +1(LAW-2:帶 expected revision 的請求成功後恰好加一,
-- 而 'Aapms.Store.Types.opRevision' 對 'UpsertLicense' 回的正是傳入 'License'
-- 自己的 revision)。
planUpsertLicense :: UTCTime -> FilePath -> Document -> License -> Either StoreError (Document, WriteOutcome)
planUpsertLicense t path doc lic = do
  lics <- orMd path (toLicenses doc)
  let targetId = metaId (licMeta lic)
      bumped = bumpRevision (utctDay t) (licMeta lic)
      newRev = metaRevision bumped
      payload = licensePayloadOf lic
  doc' <- case find ((== targetId) . metaId . licMeta) lics of
    Just curLic -> do
      checkRevision targetId (metaRevision (licMeta lic)) (metaRevision (licMeta curLic))
      doc1 <-
        orMd path (updateSectionExtras targetId (const (payloadExtras (NSLicense (overrideOf bumped) payload))) doc)
      orMd path (updateSection targetId (const (overrideOf bumped)) doc1)
    Nothing ->
      orMd
        path
        ( appendSection
            NewSection
              { nsId = targetId
              , nsLevel = 2
              , nsTitle = metaTitle (licMeta lic)
              , nsBody = ""
              , nsPayload = NSLicense (overrideOf bumped) payload
              }
            doc
        )
  pure (doc', Written (WriteResult targetId path newRev []))

licensePayloadOf :: License -> NewLicense
licensePayloadOf lic =
  NewLicense
    { nlcCommercial = licCommercial lic
    , nlcAttributionRequired = licAttributionRequired lic
    , nlcCreditText = licCreditText lic
    , nlcModificationAllowed = licModificationAllowed lic
    , nlcRedistributionAllowed = licRedistributionAllowed lic
    , nlcResaleAllowed = licResaleAllowed lic
    , nlcNftAllowed = licNftAllowed lic
    , nlcSourceUrl = licSourceUrl lic
    }

-- | 往既有檔加一個節。
--
-- @UnderParent@ 的層級由 'headingDepthFor' 推導,__而且它的失敗排在最前面__
-- (LAW-14:父不在檔裡回 'SectionMissing'、父已在第 6 層回 'NodeDepthExceeded',
-- 兩者都不寫檔)。之後才檢查 payload 與檔案種類相不相容、第二個參數是不是檔案
-- 層主體的 id。
planAddSection
  :: UTCTime -> Located -> Document -> Id -> SectionPlacement -> NewSection -> Either StoreError (Document, WriteOutcome)
planAddSection t loc doc targetId placement sec = do
  (sec', insertFn) <- case placement of
    AtEnd
      | nsLevel sec < 1 || nsLevel sec > 6 ->
          -- Markdown 只有六級標題:@#######@ 不是標題,'Aapms.Md.Render.appendSection'
          -- 照寫出去之後那一節__再也解析不回來__(整段被併進前一節的正文)。
          -- @UnderParent@ 由 'headingDepthFor' 擋掉同一件事,@AtEnd@ 的層級由呼叫端
          -- 給,所以在這裡擋(impl 決定,已列進回報)。
          Left (NodeDepthExceeded (nsId sec) (nsLevel sec))
      | otherwise -> Right (sec, appendSection)
    UnderParent p -> do
      depth <- headingDepthFor path doc p
      Right (sec {nsLevel = depth}, insertSection p)
  if not (payloadMatchesDocKind (nsPayload sec) kind)
    then Left (BadSectionPayload (nsId sec) kind)
    else
      if kind /= LicenseDoc && locAnchor loc /= Nothing
        then Left (BadSectionPayload (nsId sec) kind)
        else do
          doc1 <- orMd path (insertFn sec' doc)
          -- licenses.md 的檔案層是容器,不是索引裡的節點,沒有可比對的
          -- revision 可 bump;另外三種文件的檔案層主體本來就是 targetId 本身。
          (doc2, newRev) <-
            if kind == LicenseDoc
              then Right (doc1, Revision 1)
              else do
                curMeta <- currentMetaAt path kind targetId (locAnchor loc) doc
                let bumped = bumpRevision (utctDay t) curMeta
                doc2 <- orMd path (updateFrontmatter (const bumped) doc1)
                Right (doc2, metaRevision bumped)
          case kind of
            LevelDoc -> validateLevelDoc path doc2
            _ -> Right ()
          pure (doc2, Created (CreateResult (nsId sec) path newRev []))
  where
    path = locPath loc
    kind = locKind loc

-- | 刪一個節點。
--
-- 三種規模:檔案層主體 → 整份檔(消失的 id 是它自己加檔內全部節);Level 檔的
-- Node → 它與整棵子樹;其餘節 → 'subtreeIds' 算出來的那一段。
--
-- 「這一節是不是根」的判定__只對 @LevelDoc@ 做__:'CannotDeleteRootNode' 講的是
-- 「Level 的根 Node 刪不得(刪了就解析不出 @root@)」,別種文件的第一節沒有這個
-- 性質。LAW-16 的 given 沒有寫出 @LevelDoc@ 這個前提,但 LAW-1 要求「revision
-- 不符即拒」對任何非插入請求都成立 —— 兩條在「主題檔的第一個片段 + revision
-- 不符」這一格互斥,依 'CannotDeleteRootNode' 的語意取 @LevelDoc@ 這一邊。
--
-- 根的判定排在樂觀鎖之前(LAW-16 不限定 revision 相符)。檔案層主體
-- (@locAnchor@ 是 'Nothing')不是任何一節,不走這個判定。
planDelete
  :: Located -> Document -> Id -> Revision -> DeleteMode -> Either StoreError (Document, WriteOutcome)
planDelete loc doc i expected _mode = do
  isRoot <- case (locKind loc, locAnchor loc) of
    (LevelDoc, Just _) -> isRootNode path doc i
    _ -> Right False
  if isRoot
    then Left (CannotDeleteRootNode i)
    else do
      curMeta <- currentMetaAt path (locKind loc) i (locAnchor loc) doc
      checkRevision i expected (metaRevision curMeta)
      let victims = case locAnchor loc of
            Nothing -> i : sectionIds doc
            Just _ -> subtreeIds doc i
      doc' <- case locAnchor loc of
        Nothing -> Right doc
        Just _ -> orMd path (foldM (flip removeSection) doc victims)
      pure (doc', Deleted (DeleteResult path victims [] []))
  where
    path = locPath loc

-- | 建新檔的純核心:落點目錄 → 檔名 → @newDocument@;Level 檔含唯一根 Node。
--
-- 回的 'FilePath' 是__推導出來的落點__;撞名遞增與「明確指定卻已存在」要探測
-- 檔案系統,由 'applyWrite' 補上(它拿到最後的路徑之後會把結果的路徑欄換掉)。
--
-- __第四個參數是配好的新 id 清單__(P-003 REV-2):長度為
-- 'Aapms.Store.Types.idsNeeded' @op@,每一個都由 'allocateFreshId' 經過碰撞查詢
-- 配出來(ADR-014:唯一性由建構保證)。第一個是新檔的檔案層主體;
-- 'CreateLevel' 的__第二個是根 Node__ ——它也是一個節點,不能靠 @newId … 0@
-- 碰運氣。長度不足時回 'Left'(見 @tooFewIds@),一個位元組都不寫。
planCreate :: TypeRegistry -> VaultId -> UTCTime -> [Id] -> WriteOp -> Either StoreError (FilePath, Document, WriteOutcome)
planCreate reg vid t ids op = case op of
  CreateTopic ne -> case ids of
    (fresh : _) -> case lookupDir reg (neType ne) of
      Nothing -> Left (RegistryDirUnknown (neType ne))
      Just dir -> do
        let path = derivedPath fresh dir (neTitle ne)
            meta =
              (baseMeta fresh (neType ne) (neTitle ne))
                { metaSummary = neSummary ne
                , metaTags = neTags ne
                , metaStatus = neStatus ne
                , metaTimeline = neTimeline ne
                , metaAliases = neAliases ne
                , metaLinks = neLinks ne
                , metaSource = neSource ne
                }
        pure (path, newDocument TopicDoc meta (neBody ne), created fresh path)
    _ -> Left tooFewIds
  CreateLevel nl -> case ids of
    (fresh : rootId : _) -> do
      let path = derivedPath fresh "levels" (nlTitle nl)
          meta =
            (baseMeta fresh (TypeKey "level") (nlTitle nl))
              { metaSummary = nlSummary nl
              , metaStatus = nlStatus nl
              , metaSource = nlSource nl
              }
          rootSection =
            NewSection
              { nsId = rootId
              , nsLevel = 2
              , nsTitle = nlRootTitle nl
              , nsBody = ""
              , nsPayload = NSNode emptyOverride (NewNode (nlRootKind nl))
              }
      doc <- orMd path (appendSection rootSection (newDocument LevelDoc meta (nlBody nl)))
      pure (path, doc, created fresh path)
    _ -> Left tooFewIds
  CreatePack np sections -> case ids of
    (fresh : _) -> case find (not . isAssetPayload . nsPayload) sections of
      Just bad -> Left (BadSectionPayload (nsId bad) PackDoc)
      Nothing -> do
        let path = npDir np <> "/pack.md"
            meta =
              (baseMeta fresh (TypeKey "asset-pack") (npTitle np))
                { metaSummary = npSummary np
                , metaTags = npTags np
                , metaStatus = npStatus np
                , metaSource = npSource np
                }
            front =
              NewPackFront
                { npfVendor = npVendor np
                , npfArchive = npArchive np
                , npfSha256 = npSha256 np
                , npfLicense = npLicense np
                , npfAuthor = npAuthor np
                , npfSourceUrl = npSourceUrl np
                , npfAiDisclosure = npAiDisclosure np
                }
            doc0 = newDocumentWith PackDoc meta (packFrontExtras front) (npBody np)
        doc <- orMd path (foldM (flip appendSection) doc0 sections)
        pure (path, doc, created fresh path)
    _ -> Left tooFewIds
  -- 改既有檔的請求不走這裡('applyWrite' 分派到 'planEdit')。
  _ -> Left notACreateOp
  where
    today = utctDay t
    -- 建檔請求收到的 id 少於 'idsNeeded':呼叫端用錯了,不是使用者的錯。
    -- 'StoreError' 沒有「內部不變量被打破」的建構子,借 'FileWriteFailed'
    -- ——它是「檔案沒寫成」這件事本身,而這裡確實一個位元組都沒寫出去
    -- (impl 決定,已列進回報)。路徑還沒推導出來,所以是空字串。
    tooFewIds =
      FileWriteFailed
        ""
        ( "P-003:建檔需要 "
            <> T.pack (show (idsNeeded op))
            <> " 個配好的新 id,只收到 "
            <> T.pack (show (length ids))
            <> ";請確認呼叫端先跑過 allocateFreshId"
        )
    notACreateOp = FileWriteFailed "" "P-003:改既有檔的請求不經過 planCreate"
    created fresh path = Created (CreateResult fresh path (Revision 1) [])
    derivedPath fresh dir title = dir <> "/" <> T.unpack (sanitizeFileName title (renderId fresh)) <> ".md"
    isAssetPayload = \case
      NSAsset _ _ -> True
      _ -> False
    baseMeta fresh ty title =
      Meta
        { metaId = fresh
        , metaVault = vid
        , metaType = ty
        , metaTitle = title
        , metaSummary = ""
        , metaTags = []
        , metaStatus = Draft
        , metaTimeline = Nothing
        , metaAliases = []
        , metaLinks = []
        , metaSource = Human
        , metaRevision = Revision 1
        , metaCreated = today
        , metaUpdated = today
        }

-- 純的整條(P-003-node-write)-----------------------------------------------------

-- | 定位 → 重讀 → 解析 → 規劃(改既有檔)或配號後規劃(建新檔)→ 寫檔前驗證 →
-- 寫檔 \/ 刪檔 → 單檔重索引。
--
-- 順序固定「檔案 → 索引」(P-003 的決定):索引是衍生物,而且寫鎖不得跨檔案 IO
-- (ADR-022)。索引那一步失敗時檔案__已經落地__,所以回
-- 'IndexUpdateFailed' 而不是檔案錯誤。純解譯器上索引不會失敗,所以「失敗就是
-- 檔案與索引都沒動」(LAW-18)。
applyWrite :: (VaultFs :> es, Index :> es, Clock :> es) => TypeRegistry -> VaultId -> WriteOp -> Eff es (Either StoreError WriteOutcome)
applyWrite reg vid op = case op of
  CreateTopic ne -> create [(PEnt, neTitle ne)]
  -- Level 檔要兩個號:Level 自己與它的根 Node,兩個都經 'idTaken'(REV-2)。
  CreateLevel nl -> create [(PLvl, nlTitle nl), (PNod, nlRootTitle nl)]
  CreatePack np _ -> create [(PPck, npTitle np)]
  UpsertLicense lic -> upsertLicenseFlow lic
  _ -> edit
  where
    -- 建檔:取時間 → 配 'idsNeeded' 個號 → 純規劃 → 解出真正的落點 → 寫檔 →
    -- 單檔重索引。
    --
    -- @specs@ 的長度就是 'idsNeeded' @op@;'take' 只是把這件事寫在程式碼裡,
    -- 讓「配幾個」的唯一真相留在 'idsNeeded'。
    create specs = do
      t <- now
      allocateIds t (take (idsNeeded op) specs) >>= \case
        Left e -> pure (Left e)
        Right ids -> case planCreate reg vid t ids op of
          Left e -> pure (Left e)
          Right (derived, doc, outcome) ->
            resolveCreatePath op derived >>= \case
              Left e -> pure (Left e)
              Right path -> finishWrite reg vid path doc outcome

    -- 改既有檔:定位 → 重讀 → 解析 → 純規劃 → 寫檔 / 刪檔 → 單檔重索引。
    edit = case opTarget op of
      Nothing -> pure (Left (SqliteError "P-003:這個請求沒有目標節點"))
      Just i ->
        locateId i >>= \case
          Nothing -> pure (Left (NodeNotFound i))
          Just loc -> withDocument (locPath loc) $ \doc -> do
            t <- now
            case planEdit reg t loc doc op of
              Left e -> pure (Left e)
              Right (doc', outcome) -> land loc doc' outcome

    -- @licenses.md@ 不必先在索引裡查得到(第一次 upsert 時整份檔都還不存在),
    -- 所以它自己一條路:找得到節點就用它所在的檔,否則用固定路徑。
    upsertLicenseFlow lic = do
      t <- now
      path <- licensePathFor (metaId (licMeta lic))
      readMarkdown path >>= \case
        Left _ -> go t path (newDocument LicenseDoc (freshLicensesContainerMeta vid t) "")
        Right txt -> case orMd path (parseDocument txt) of
          Left e -> pure (Left e)
          Right doc -> go t path doc
      where
        go t path doc = case planUpsertLicense t path doc lic of
          Left e -> pure (Left e)
          Right (doc', outcome) -> finishWrite reg vid path doc' outcome

    licensePathFor i =
      locateId i >>= \case
        Just loc | locKind loc == LicenseDoc -> pure (locPath loc)
        _ -> pure licensesPath

    withDocument path k =
      readMarkdown path >>= \case
        Left e -> pure (Left e)
        Right txt -> case orMd path (parseDocument txt) of
          Left e -> pure (Left e)
          Right doc -> k doc

    -- 刪除的被引用檢查要查索引,所以留在效果這一層;'planEdit' 只算出消失的 id。
    land loc doc' outcome = case op of
      DeleteNode i _ mode -> do
        refs <- referrers (removedIds outcome)
        case mode of
          DeleteSafe | not (null refs) -> pure (Left (ReferencedBy i refs))
          _ -> case locAnchor loc of
            Nothing -> finishDelete (locPath loc) (withBroken refs outcome)
            Just _ -> finishWrite reg vid (locPath loc) doc' (withBroken refs outcome)
      _ -> finishWrite reg vid (locPath loc) doc' outcome

-- | @library\/licenses.md@ 是唯一固定路徑(system.md 的目錄配置)。
licensesPath :: FilePath
licensesPath = "library/licenses.md"

-- | @licenses.md@ 的容器 frontmatter。容器本身不是節點,從不進索引,'metaId'
-- 只是型別上必要的佔位。
freshLicensesContainerMeta :: VaultId -> UTCTime -> Meta
freshLicensesContainerMeta vid t =
  Meta
    { metaId = newId PLic "licenses" t 0
    , metaVault = vid
    , metaType = TypeKey "asset-license"
    , metaTitle = "Licenses"
    , metaSummary = ""
    , metaTags = []
    , metaStatus = Canon
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = Revision 1
    , metaCreated = utctDay t
    , metaUpdated = utctDay t
    }

-- | 寫檔 → 單檔重索引 → 把最後的路徑與索引問題填回結果。
finishWrite
  :: (VaultFs :> es, Index :> es)
  => TypeRegistry
  -> VaultId
  -> FilePath
  -> Document
  -> WriteOutcome
  -> Eff es (Either StoreError WriteOutcome)
finishWrite reg vid path doc outcome =
  writeMarkdown path (renderDocument doc) >>= \case
    Left e -> pure (Left e)
    Right () ->
      indexPath reg vid path >>= \case
        Left e -> pure (Left (IndexUpdateFailed path (renderStoreError e)))
        Right issues -> pure (Right (withIssues issues (withPath path outcome)))

-- | 刪整份檔 → 移除它的索引記錄。順序與寫入時一致:檔案是真相,索引跟著走。
finishDelete
  :: (VaultFs :> es, Index :> es) => FilePath -> WriteOutcome -> Eff es (Either StoreError WriteOutcome)
finishDelete path outcome =
  deleteMarkdown path >>= \case
    Left e -> pure (Left e)
    Right () -> do
      removeFile path
      pure (Right (withPath path outcome))

-- | 一份新檔真正的落點。
--
-- 呼叫端明確給了路徑就照給的用(已存在則 'FileAlreadyExists' —— 那是指定,不是
-- 推導,不該悄悄換掉);否則從推導出來的檔名開始探測,撞名就在主幹後面加
-- @-2@ \/ @-3@……。@pack.md@ 的路徑由 'npDir' 決定,不探測。
resolveCreatePath :: VaultFs :> es => WriteOp -> FilePath -> Eff es (Either StoreError FilePath)
resolveCreatePath op derived = case op of
  CreateTopic ne | Just p <- nePath ne -> mustBeFree p
  CreateLevel nl | Just p <- nlPath nl -> mustBeFree p
  CreatePack _ _ -> pure (Right derived)
  _ -> findFree 0
  where
    mustBeFree p =
      fileExists p >>= \taken -> pure (if taken then Left (FileAlreadyExists p) else Right p)
    findFree n = do
      let candidate = suffixed derived n
      taken <- fileExists candidate
      if taken then findFree (n + 1) else pure (Right candidate)

-- | @dir\/base.md@ 的第 @n@ 個候選:@n == 0@ 原樣,之後是 @dir\/base-2.md@……
suffixed :: FilePath -> Int -> FilePath
suffixed p 0 = p
suffixed p n = stem <> "-" <> show (n + 1) <> ".md"
  where
    stem = if ".md" `isSuffixOf` p then take (length p - 3) p else p

-- | 換掉結果裡的路徑(建檔的落點在探測之後才定案)。
withPath :: FilePath -> WriteOutcome -> WriteOutcome
withPath p = \case
  Created cr -> Created cr {crPath = p}
  Written wr -> Written wr {wrPath = p}
  Deleted dr -> Deleted dr {drPath = p}

-- | 填上單檔重索引回報的問題。
withIssues :: [IndexIssue] -> WriteOutcome -> WriteOutcome
withIssues is = \case
  Created cr -> Created cr {crIssues = is}
  Written wr -> Written wr {wrIssues = is}
  Deleted dr -> Deleted dr {drIssues = is}

-- | 填上 'DeleteForce' 打斷的關聯。
withBroken :: [(Id, Link)] -> WriteOutcome -> WriteOutcome
withBroken refs = \case
  Deleted dr -> Deleted dr {drBrokenLinks = refs}
  other -> other
