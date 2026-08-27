-- | 改寫既有節點,與短 id 的配號(graph-core\/F008)。
--
-- 「建檔 \/ 增節 \/ 刪除」在 "Aapms.Store.Create",「Level 樹的純推導」在
-- "Aapms.Store.Node";三者共用的那條紀律(讀 → 樂觀鎖 → 純函式編輯 → 寫檔 →
-- 索引)在 "Aapms.Store.Edit",本模組不重寫一遍。
--
-- 檔案層主體與節走__同一組介面__:差別只在 'Aapms.Store.Edit.locAnchor' 是不是
-- 'Nothing',而那件事由 'Aapms.Store.Edit.locate' 回答,不必呼叫端指定。節改的是
-- 該節的 @```meta@ 區塊(只有那一段被重新序列化,ADR-010),主體改的是
-- frontmatter。
--
-- __本模組不做業務判斷__(契約卡「明確不做」):名稱是否全域唯一由 @service@
-- 在呼叫之前以 'Aapms.Store.Query.lookupByName' 查過;本模組只負責把值寫下去。
module Aapms.Store.Write
  ( -- * 結果(定義在內部模組 "Aapms.Store.Edit",由本模組帶進門面)
    WriteResult (..)

    -- * asset 的人給欄位
  , AssetPatch (..)

    -- * Meta
  , writeMeta
  , writeAssetFields

    -- * 正文
  , writeBody

    -- * 關聯
  , addLink
  , removeLink

    -- * 授權
  , upsertLicense

    -- * ID
  , allocateId
  ) where

import Data.List (find)
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime, utctDay)
import Database.SQLite.Simple (Only (..), query)
import Aapms.Core.Asset (Asset (..), LogicalName (..))
import Aapms.Core.Id (Id, IdPrefix (..), Ref, VaultId, newId, renderId)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..))
import Aapms.Core.Meta (Meta (..), Revision (..), Source (..), Status (..), TypeKey (..), bumpRevision)
import Aapms.Md.Document (DocKind (..), Document (..))
import Aapms.Md.Inherit (MetaOverride (..), applyOverride, overrideOf)
import Aapms.Md.Render
  ( NewAsset (..)
  , NewLicense (..)
  , NewSection (..)
  , NewSectionPayload (..)
  , appendSection
  , newDocument
  , payloadExtras
  , replacePreamble
  , updateFrontmatter
  , updateSection
  , updateSectionBody
  , updateSectionExtras
  )
import Aapms.Md.Parse (toLicenses)
import Aapms.Store.Edit
  ( Located (..)
  , WriteResult (..)
  , checkRevision
  , commit
  , currentAssetAt
  , currentMetaAt
  , ensureDir
  , locate
  , orMd
  , readDocument
  , sectionBodyRaw
  , (>>?)
  , (?>>)
  )
import Aapms.Store.Error (StoreError (..), trySqlite)
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..))

-- asset 的人給欄位 ---------------------------------------------------------------

-- | 'Aapms.Store.Write.writeAssetFields' 能改的__全部__欄位。
--
-- @sha256@ \/ @entry@ \/ @ext@ \/ @meta@ __不在這裡,而且是刻意的__:那四欄是
-- 掃描器(@asset-ingest@)從檔案本身算出來的事實,不是人給的意見。「拒絕改」
-- 因此不是一個執行期檢查,而是__型別上表達不出來__ ——檔案換了就是換了一筆
-- asset,要走 'Aapms.Store.Create.addSection' \/ 'Aapms.Store.Create.deleteNode'。
--
-- 每一欄的外層 'Maybe' 是「這次動不動它」,內層 'Maybe' 是「要設成什麼」:
-- @apName = Nothing@ 不動、@apName = Just Nothing@ 清空、
-- @apName = Just (Just n)@ 設成 @n@。兩層合在一起才表達得出「清空」,少一層就
-- 只能把「不動」與「清空」混為一談。
data AssetPatch = AssetPatch
  { apName :: Maybe (Maybe LogicalName)
  , apLicense :: Maybe (Maybe Ref)
  , apAuthor :: Maybe (Maybe Text)
  , apTags :: Maybe [Text]
  -- ^ @tags@ 住在 'Aapms.Core.Meta.Meta' 而不是 asset 專屬表,但它是人給欄位,
  -- 所以與另外三欄一起走這條路徑;@Just []@ = 清空
  }
  deriving stock (Show, Eq)

-- Meta ------------------------------------------------------------------------

-- | 修改既有節點的 'Aapms.Core.Meta.Meta'。節與檔案層主體都支援。
--
-- 第三個參數是呼叫端手上那份資料的 revision;與檔案裡的實際值不符就
-- 'Aapms.Store.Error.RevisionMismatch',__一個位元組都不寫__。
--
-- 修改函式吃 'MetaOverride' 而不是 'Meta':節的 meta 區塊本來就是「只寫與檔案層
-- 不同的欄位」,寫成完整的 'Meta' 會讓每次修改都把繼承來的欄位全部釘死在節上。
-- @id@ 與 @title@ 'MetaOverride' 表達不了,因此改不動。
--
-- 目標是 pack.md 的 asset 節或 licenses.md 的 license 節時,該節的專屬欄位
-- (@sha256@ \/ @entry@ \/ 八個授權維度……)__必須原樣保留__ ——它們與
-- 'MetaOverride' 住在同一個 @```meta@ 區塊裡,重新序列化時漏掉就是資料遺失。
writeMeta
  :: VaultHandle
  -> Id
  -> Revision
  -> (MetaOverride -> MetaOverride)
  -> IO (Either StoreError WriteResult)
writeMeta vh i expected f =
  locate vh i >>? \loc ->
    readDocument vh (locPath loc) >>? \doc ->
      currentMetaAt (locPath loc) (locKind loc) i (locAnchor loc) doc ?>> \curMeta ->
        checkRevision i expected (metaRevision curMeta) ?>> \() -> do
          today <- utctDay <$> getCurrentTime
          let bumped = bumpRevision today curMeta
              newRev = metaRevision bumped
              newUpdated = metaUpdated bumped
              docE = case locAnchor loc of
                Nothing ->
                  let edited = applyOverride (f (overrideOf curMeta)) curMeta
                   in orMd (locPath loc) (updateFrontmatter (const edited {metaRevision = newRev, metaUpdated = newUpdated}) doc)
                Just secId ->
                  orMd
                    (locPath loc)
                    (updateSection secId (\ov -> (f ov) {moRevision = Just newRev, moUpdated = Just newUpdated}) doc)
          case docE of
            Left e -> pure (Left e)
            Right doc' -> commit vh (locPath loc) doc' i newRev

-- | 改 asset 的人給欄位。目標不是 asset 時回 'Aapms.Store.Error.NotAnAsset'。
--
-- 只動 'AssetPatch' 指定的欄位;@sha256@ \/ @entry@ \/ @ext@ \/ @meta@ 與正文
-- 一律不變(見 'AssetPatch' 的說明)。
writeAssetFields
  :: VaultHandle
  -> Id
  -> Revision
  -> AssetPatch
  -> IO (Either StoreError WriteResult)
writeAssetFields vh i expected AssetPatch {..} =
  locate vh i >>? \loc -> case (locKind loc, locAnchor loc) of
    (PackDoc, Just _) ->
      readDocument vh (locPath loc) >>? \doc ->
        currentAssetAt (locPath loc) i doc ?>> \curAsset ->
          checkRevision i expected (metaRevision (astMeta curAsset)) ?>> \() -> do
            today <- utctDay <$> getCurrentTime
            let bumped = bumpRevision today (astMeta curAsset)
                newRev = metaRevision bumped
                newUpdated = metaUpdated bumped
                mergedAsset =
                  NewAsset
                    { naName = applyPatchField apName (astName curAsset)
                    , naSha256 = astSha256 curAsset
                    , naEntry = astEntry curAsset
                    , naExt = astExt curAsset
                    , naKindMeta = astKindMeta curAsset
                    , naLicense = applyPatchField apLicense (astLicense curAsset)
                    , naAuthor = applyPatchField apAuthor (astAuthor curAsset)
                    }
                newExtras = payloadExtras (NSAsset (overrideOf (astMeta curAsset)) mergedAsset)
            case orMd (locPath loc) (updateSectionExtras i (const newExtras) doc) of
              Left e -> pure (Left e)
              Right doc1 ->
                case orMd
                  (locPath loc)
                  ( updateSection
                      i
                      ( \ov ->
                          ov
                            { moRevision = Just newRev
                            , moUpdated = Just newUpdated
                            , moTags = maybe (moTags ov) Just apTags
                            }
                      )
                      doc1
                  ) of
                  Left e -> pure (Left e)
                  Right doc2 -> commit vh (locPath loc) doc2 i newRev
    _ -> pure (Left (NotAnAsset i))
  where
    applyPatchField :: Maybe (Maybe a) -> Maybe a -> Maybe a
    applyPatchField Nothing cur = cur
    applyPatchField (Just v) _ = v

-- 正文 ------------------------------------------------------------------------

-- | 換掉正文:節換該節的正文切片,檔案層主體換 frontmatter 之後的 preamble。
--
-- 兩條路徑都會遞增 revision ——正文才是節真正的內容,改了它卻不動 revision,
-- 樂觀鎖就對「內容被改過」視而不見。
writeBody
  :: VaultHandle
  -> Id
  -> Revision
  -> Text
  -> IO (Either StoreError WriteResult)
writeBody vh i expected body =
  locate vh i >>? \loc ->
    readDocument vh (locPath loc) >>? \doc ->
      currentMetaAt (locPath loc) (locKind loc) i (locAnchor loc) doc ?>> \curMeta ->
        checkRevision i expected (metaRevision curMeta) ?>> \() -> do
          today <- utctDay <$> getCurrentTime
          let bumped = bumpRevision today curMeta
              newRev = metaRevision bumped
              newUpdated = metaUpdated bumped
              docE = case locAnchor loc of
                Nothing ->
                  let doc1 = replacePreamble body doc
                   in orMd (locPath loc) (updateFrontmatter (const bumped) doc1)
                Just secId ->
                  case updateSectionBody secId (sectionBodyRaw (docEnding doc) body) doc of
                    Left e -> Left (MdWriteFailed (locPath loc) e)
                    Right doc1 ->
                      orMd
                        (locPath loc)
                        (updateSection secId (\ov -> ov {moRevision = Just newRev, moUpdated = Just newUpdated}) doc1)
          case docE of
            Left e -> pure (Left e)
            Right doc' -> commit vh (locPath loc) doc' i newRev

-- 關聯 ------------------------------------------------------------------------

-- | 加一筆關聯。
--
-- 關聯__只存在來源端__(ADR-002),所以這是單邊、單檔操作:目標端的檔案一個
-- 位元組都不會被碰到。反向查詢由索引負責。
addLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)
addLink vh i expected link =
  locate vh i >>? \loc ->
    readDocument vh (locPath loc) >>? \doc ->
      currentMetaAt (locPath loc) (locKind loc) i (locAnchor loc) doc ?>> \curMeta ->
        checkRevision i expected (metaRevision curMeta) ?>> \() ->
          applyLinks vh loc doc curMeta i (metaLinks curMeta ++ [link])

-- | 刪一筆關聯,以整筆 'Link' 比對(@kind@ + @target@ + @note@ 皆相同才算命中);
-- 同一筆出現多次時全部刪掉。
--
-- __一筆都沒命中時回 'Aapms.Store.Error.LinkNotFound' 而不是靜默成功__:呼叫端
-- 以為刪掉了、實際上關聯還在,是最難查的那種錯,而且此時檔案__不會被寫__。
--
-- 比對的是__檔案裡寫的那個 'Aapms.Core.Id.Ref'__:作者寫
-- @vlt-a0c4e1f8:ent-7f3a@ 時要以同樣的形式來刪。
removeLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)
removeLink vh i expected link =
  locate vh i >>? \loc ->
    readDocument vh (locPath loc) >>? \doc ->
      currentMetaAt (locPath loc) (locKind loc) i (locAnchor loc) doc ?>> \curMeta ->
        checkRevision i expected (metaRevision curMeta) ?>> \() ->
          if link `notElem` metaLinks curMeta
            then pure (Left (LinkNotFound i link))
            else applyLinks vh loc doc curMeta i (filter (/= link) (metaLinks curMeta))

-- | 'addLink' \/ 'removeLink' 共用:把算好的新關聯清單寫回,並讓 revision +1。
applyLinks
  :: VaultHandle -> Located -> Document -> Meta -> Id -> [Link] -> IO (Either StoreError WriteResult)
applyLinks vh loc doc curMeta i newLinks = do
  today <- utctDay <$> getCurrentTime
  let bumped = bumpRevision today curMeta
      newRev = metaRevision bumped
      newUpdated = metaUpdated bumped
      docE = case locAnchor loc of
        Nothing -> orMd (locPath loc) (updateFrontmatter (const bumped {metaLinks = newLinks}) doc)
        Just secId ->
          orMd
            (locPath loc)
            ( updateSection
                secId
                -- 清空之後不留 `links: []` 這一行——沒有連結就是沒有這個鍵,
                -- 與「原本就沒寫過」不可區分,L6 要求的往返恆等才成立。
                ( \ov ->
                    ov
                      { moRevision = Just newRev
                      , moUpdated = Just newUpdated
                      , moLinks = if null newLinks then Nothing else Just newLinks
                      }
                )
                doc
            )
  case docE of
    Left e -> pure (Left e)
    Right doc' -> commit vh (locPath loc) doc' i newRev

-- 授權 ------------------------------------------------------------------------

-- | 把一種授權寫進該 vault 的 @licenses.md@:同 id 的節已存在就整節改寫,
-- 不存在就追加一節。
--
-- 吃完整的 'License' 而不是覆寫函式:授權的八個維度是一組互相牽動的宣告
-- (可商用但要求署名、可改作但不可轉售……),逐欄 patch 會讓「這份授權到底
-- 允許什麼」散落在多次呼叫裡。'Aapms.Core.License.licFullText' 不寫進節層
-- (@licenses.md@ 的節不重複貼授權全文,'Aapms.Md.Parse.toLicenses' 解出來
-- 恆為 'Nothing')。
--
-- 樂觀鎖的 expected revision 取自傳入的 'License' 自己的
-- 'Aapms.Core.Meta.metaRevision' ——契約 E 的簽名沒有獨立的 revision 參數,而
-- 完整的 'License' 本來就帶著它。節不存在(新增)時不比對。
upsertLicense :: VaultHandle -> License -> IO (Either StoreError WriteResult)
upsertLicense vh lic = do
  let path = licensesPath
  docR <- readDocument vh path
  case docR of
    Left (FileReadFailed _ _) -> do
      -- library/licenses.md 還不存在:先建一份空的容器檔
      ensureDir vh path
      t <- getCurrentTime
      let containerMeta = freshLicensesContainerMeta (vmId (vhMarker vh)) t
      upsertInto vh path (newDocument LicenseDoc containerMeta "") lic
    Left e -> pure (Left e)
    Right doc -> upsertInto vh path doc lic

-- | @library\/licenses.md@ 是唯一固定路徑(system.md 的目錄配置);容器本身
-- 不是節點,從不進索引,'metaId' 因此只是型別上必要的佔位,不會被任何查詢用到。
licensesPath :: FilePath
licensesPath = "library/licenses.md"

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

upsertInto :: VaultHandle -> FilePath -> Document -> License -> IO (Either StoreError WriteResult)
upsertInto vh path doc lic = case orMd path (toLicenses doc) of
  Left e -> pure (Left e)
  Right lics ->
    let targetId = metaId (licMeta lic)
     in case find ((== targetId) . metaId . licMeta) lics of
          Just curLic -> case checkRevision targetId (metaRevision (licMeta lic)) (metaRevision (licMeta curLic)) of
            Left e -> pure (Left e)
            Right () -> overwriteLicense vh path doc targetId lic
          Nothing -> appendLicense vh path doc lic

licensePayloadOf :: License -> NewLicense
licensePayloadOf License {..} =
  NewLicense
    { nlcCommercial = licCommercial
    , nlcAttributionRequired = licAttributionRequired
    , nlcCreditText = licCreditText
    , nlcModificationAllowed = licModificationAllowed
    , nlcRedistributionAllowed = licRedistributionAllowed
    , nlcResaleAllowed = licResaleAllowed
    , nlcNftAllowed = licNftAllowed
    , nlcSourceUrl = licSourceUrl
    }

overwriteLicense :: VaultHandle -> FilePath -> Document -> Id -> License -> IO (Either StoreError WriteResult)
overwriteLicense vh path doc targetId lic = do
  today <- utctDay <$> getCurrentTime
  let bumped = bumpRevision today (licMeta lic)
      payload = licensePayloadOf lic
  case orMd path (updateSectionExtras targetId (const (payloadExtras (NSLicense (overrideOf bumped) payload))) doc) of
    Left e -> pure (Left e)
    Right doc1 -> case orMd path (updateSection targetId (const (overrideOf bumped)) doc1) of
      Left e -> pure (Left e)
      Right doc2 -> commit vh path doc2 targetId (metaRevision bumped)

appendLicense :: VaultHandle -> FilePath -> Document -> License -> IO (Either StoreError WriteResult)
appendLicense vh path doc lic = do
  let targetId = metaId (licMeta lic)
      payload = licensePayloadOf lic
      newSection =
        NewSection
          { nsId = targetId
          , nsLevel = 2
          , nsTitle = metaTitle (licMeta lic)
          , nsBody = ""
          , nsPayload = NSLicense (overrideOf (licMeta lic)) payload
          }
  case orMd path (appendSection newSection doc) of
    Left e -> pure (Left e)
    Right doc1 -> commit vh path doc1 targetId (metaRevision (licMeta lic))

-- ID ---------------------------------------------------------------------------

-- | 產生一個索引裡還沒有人用的 ID(ADR-014)。
--
-- 'Aapms.Core.Id.newId' 是純函式,唯一性只有持有索引的這一層做得到:撞了就
-- @salt + 1@ 重算,直到不撞。候選 id 恆為 @newId p c t salt@,@salt@ 從 @0@ 起遞增。
--
-- __時間是明碼參數__(第四個參數,2026-08-25 G8 裁決,契約 E):與
-- 'Aapms.Core.Id.newId' 一致。藏在函式內部取樣的話,呼叫端就無法預先造出碰撞,
-- salt 重試迴圈也就永遠測不到 ——而碰撞在正常情況下幾乎不發生,那段程式碼可能永遠
-- 是錯的而沒人知道。取當下時間的責任因此落在呼叫端:
-- 'Aapms.Store.Create.createTopicFile' \/ 'Aapms.Store.Create.createLevelFile' \/
-- 'Aapms.Store.Create.createPackFile' \/ 'Aapms.Store.Create.addSection' 自己取
-- 'Data.Time.getCurrentTime' 再傳進來,__它們的對外簽名不變__。
--
-- __碰撞查詢失敗即失敗,不靜默照發__(2026-08-25 裁決,契約 E):查詢出錯時
-- 「照發當前候選」等於把一個__未經碰撞檢查的 id__ 寫進 Markdown,而依 ADR-013
-- 檔案是真相 ——重複的身分就這樣落地了,事後只能以「'Aapms.Store.Index.rebuildIndex'
-- 撞 @nodes.id@ 主鍵」的形式發現,修復要人工改檔案裡的 id 與所有指向它的關聯。
-- 因此簽名帶失敗通道:查詢失敗回 'Aapms.Store.Error.SqliteError'。
allocateId :: VaultHandle -> IdPrefix -> Text -> UTCTime -> IO (Either StoreError Id)
allocateId vh p c t = tryAlloc 0
  where
    tryAlloc :: Int -> IO (Either StoreError Id)
    tryAlloc salt = do
      let candidate = newId p c t salt
      existsR <-
        trySqlite
          ( query (vhConn vh) "SELECT count(*) FROM nodes WHERE id = ?" (Only (renderId candidate)) ::
              IO [Only Int]
          )
      case existsR of
        Left e -> pure (Left e)
        Right (Only n : _) | n > 0 -> tryAlloc (salt + 1)
        Right _ -> pure (Right candidate)
