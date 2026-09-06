{-# OPTIONS_GHC -Wno-orphans #-}

-- | 核心型別 ↔ SQLite 資料列的轉換裡__碰 sqlite__ 的那一半(graph-core\/F006)。
-- 內部模組,不對外承諾介面,不經 "Aapms.Store" 門面 re-export。
--
-- 這裡放的東西一律需要 @Database.SQLite.Simple@ 在場:@SQLData@ 建構子、
-- @Query@ 拼裝、'hydrateMeta' 的 @Connection@,以及六個列型別的 @FromRow@ 實例。
-- 列型別本身與所有純轉換住 "Aapms.Store.Row" ——那一層不 import 任何 IO 模組,
-- 才有辦法被純層的模組使用。
--
-- __六個 @FromRow@ 是 orphan 實例__,而且是刻意的:列型別的宣告要跟著純轉換走
-- (它們是同一組欄位規則的兩面),@FromRow@ 卻只有 sqlite-simple 在場才寫得出來。
-- 兩者只能分開,而分開就必然有一邊是 orphan。放這一邊的代價最小:本模組是
-- @aapms-store@ 的內部模組,凡是拿這些列型別去查資料庫的呼叫端
-- ("Aapms.Store.Index" \/ "Aapms.Store.Query" \/ "Aapms.Store.MultiVault")本來
-- 就都要 import 它。
module Aapms.Store.Row.Sql
  ( -- * nodes 欄位
    nodeFields
  , hydrateMeta

    -- * SQLData 輔助
  , sText
  , sInt
  , sMaybeText
  , sMaybeInt
  , sBool
  , sMaybeBool

    -- * SQL 拼裝輔助
  , insertSql
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
  ( Connection
  , FromRow (..)
  , Only (..)
  , Query (..)
  , SQLData (..)
  , field
  , query
  )
import Aapms.Core.Id (Id, IdPrefix, VaultId, renderId, renderIdPrefix)
import Aapms.Core.Meta
import Aapms.Store.Row
  ( AssetRow (..)
  , LevelRow (..)
  , LicenseRow (..)
  , LinkRow (..)
  , NodeRow (..)
  , PackRow (..)
  , TreeNodeRow (..)
  , dayText
  , rowToMeta
  , toLink
  )

--------------------------------------------------------------------------------
-- nodes

-- | 一個 'Meta' + 它的 prefix + 檔案路徑 + section anchor(@Nothing@ = 檔案層
-- 容器)+ owner 轉成一列。@metaVault@ 不落地(見 "Aapms.Store.Row" 頂端的
-- 待確認假設 ASM-10)。
nodeFields :: Meta -> IdPrefix -> FilePath -> Maybe Text -> Maybe Id -> [SQLData]
nodeFields Meta {..} prefix filePath anchor owner =
  [ sText (renderId metaId)
  , sText (renderIdPrefix prefix)
  , sText (unTypeKey metaType)
  , sText metaTitle
  , sText metaSummary
  , sText (renderStatus metaStatus)
  , sMaybeText (metaTimeline >>= tlLabel)
  , sMaybeInt (metaTimeline >>= tlOrder)
  , sText (renderSource metaSource)
  , sInt (unRevision metaRevision)
  , sText (dayText metaCreated)
  , sText (dayText metaUpdated)
  , sText (T.pack filePath)
  , sMaybeText anchor
  , sMaybeText (renderId <$> owner)
  ]
  where
    unTypeKey (TypeKey t) = t
    unRevision (Revision n) = n

instance FromRow NodeRow where
  fromRow =
    NodeRow
      <$> field -- id
      <*> field -- prefix
      <*> field -- type
      <*> field -- title
      <*> field -- summary
      <*> field -- status
      <*> field -- timeline
      <*> field -- timeline_order
      <*> field -- source
      <*> field -- revision
      <*> field -- created
      <*> field -- updated
      <*> field -- file_path
      <*> field -- section_anchor
      <*> field -- owner

-- | IO 版本:自己查 'Aapms.Store.Row.nrId' 的
-- @node_aliases@\/@node_tags@\/@links@(同一個節點
-- 只查一次,避免 N+1)。索引列毀損(不該發生)時直接 'fail',呼叫端不必處理
-- 這種情況——那代表本套件自己寫壞了資料,不是使用者輸入的問題。
hydrateMeta :: VaultId -> Connection -> NodeRow -> IO Meta
hydrateMeta vid conn nr@NodeRow {..} = do
  aliases <- col "SELECT alias FROM node_aliases WHERE node_id = ? ORDER BY rowid"
  tags <- col "SELECT tag FROM node_tags WHERE node_id = ? ORDER BY rowid"
  linkRows <-
    query
      conn
      "SELECT src, dst_vault, dst, kind, note FROM links WHERE src = ? ORDER BY rowid"
      (Only nrId) ::
      IO [LinkRow]
  case rowToMeta vid nr aliases tags (map snd (mapMaybeToLink linkRows)) of
    Just m -> pure m
    Nothing -> fail ("hydrateMeta: 索引列毀損,id=" <> T.unpack nrId)
  where
    col sql = do
      rows <- query conn (Query sql) (Only nrId) :: IO [Only Text]
      pure (map fromOnly rows)
    mapMaybeToLink = foldr (\r acc -> maybe acc (: acc) (toLink r)) []

--------------------------------------------------------------------------------
-- 六個專屬表的 FromRow

instance FromRow AssetRow where
  fromRow = AssetRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field

instance FromRow PackRow where
  fromRow =
    PackRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

instance FromRow LicenseRow where
  fromRow =
    LicenseRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

instance FromRow LevelRow where
  fromRow = LevelRow <$> field

instance FromRow TreeNodeRow where
  fromRow = TreeNodeRow <$> field <*> field <*> field <*> field

instance FromRow LinkRow where
  fromRow = LinkRow <$> field <*> field <*> field <*> field <*> field

--------------------------------------------------------------------------------
-- SQLData 輔助

sText :: Text -> SQLData
sText = SQLText

sInt :: Int -> SQLData
sInt = SQLInteger . fromIntegral

sMaybeText :: Maybe Text -> SQLData
sMaybeText = maybe SQLNull SQLText

sMaybeInt :: Maybe Int -> SQLData
sMaybeInt = maybe SQLNull sInt

sBool :: Bool -> SQLData
sBool True = SQLInteger 1
sBool False = SQLInteger 0

sMaybeBool :: Maybe Bool -> SQLData
sMaybeBool = maybe SQLNull sBool

--------------------------------------------------------------------------------
-- SQL 拼裝輔助

insertSql :: Text -> [Text] -> Query
insertSql table cols =
  Query $
    "INSERT INTO "
      <> table
      <> "("
      <> T.intercalate ", " cols
      <> ") VALUES ("
      <> T.intercalate ", " (replicate (length cols) "?")
      <> ")"
