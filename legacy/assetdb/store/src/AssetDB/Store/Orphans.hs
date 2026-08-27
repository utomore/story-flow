-- | 核心型別與 SQLite 之間的橋接。
--
-- 這裡的 instance 是 orphan,而且**應該**是 orphan:
-- @assetdb-core@ 被遊戲本體依賴,不能為了持久化而拖進 @sqlite-simple@;
-- @sqlite-simple@ 也不可能知道我們的型別。這是 orphan instance 少數
-- 正當的使用時機 —— 兩個套件都不該擁有這段對應,而我們兩邊都擁有。
--
-- 因為只有這一個模組定義它們,重複 instance 的風險是零。
{-# OPTIONS_GHC -Wno-orphans #-}

module AssetDB.Store.Orphans () where

import AssetDB.Id (ULID, parseULID, renderULID)
import AssetDB.Naming (LogicalName, logicalNameText, renderNameError, validateLogicalName)
import AssetDB.Types
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable)
import Database.SQLite.Simple (SQLData)
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Ok (Ok)
import Database.SQLite.Simple.ToField

--------------------------------------------------------------------------------
-- 通用

-- 所有列舉都存**文字**而非序號。序號會在有人重新排列 Haskell 建構子時
-- 無聲損毀整個資料庫,而且 SELECT 出來人看不懂。
enumToField :: TextEnum a => a -> SQLData
enumToField = toField . toTextEnum

enumFromField :: forall a. (TextEnum a, Typeable a) => Field -> Ok a
enumFromField f = do
  t <- fromField f :: Ok Text
  case parseTextEnum t of
    Right a -> pure a
    Left err -> returnError ConversionFailed f (T.unpack err)

--------------------------------------------------------------------------------
-- 列舉

instance ToField AssetKind where toField = enumToField
instance FromField AssetKind where fromField = enumFromField

instance ToField KindPrefix where toField = enumToField
instance FromField KindPrefix where fromField = enumFromField

instance ToField AssetStatus where toField = enumToField
instance FromField AssetStatus where fromField = enumFromField

instance ToField CopyMode where toField = enumToField
instance FromField CopyMode where fromField = enumFromField

instance ToField TagSource where toField = enumToField
instance FromField TagSource where fromField = enumFromField

instance ToField EntityType where toField = enumToField
instance FromField EntityType where fromField = enumFromField

instance ToField LinkRel where toField = enumToField
instance FromField LinkRel where fromField = enumFromField

instance ToField NoteKind where toField = enumToField
instance FromField NoteKind where fromField = enumFromField

--------------------------------------------------------------------------------
-- 識別碼與名稱

instance ToField ULID where
  toField = toField . renderULID

instance FromField ULID where
  fromField f = do
    t <- fromField f :: Ok Text
    either (returnError ConversionFailed f . T.unpack) pure (parseULID t)

-- 從資料庫讀出來時仍然驗證。若有人手動 UPDATE 寫進不合法的名稱,
-- 應該在讀取的當下就發現,而不是等到它出現在某個專案的 manifest 裡。
instance ToField LogicalName where
  toField = toField . logicalNameText

instance FromField LogicalName where
  fromField f = do
    t <- fromField f :: Ok Text
    either (returnError ConversionFailed f . T.unpack . renderNameError) pure (validateLogicalName t)
