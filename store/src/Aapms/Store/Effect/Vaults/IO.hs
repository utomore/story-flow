{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | 'Aapms.Store.Effect.Vaults.Vaults' 的__真解譯器__,以及它跑在上面的
-- 'VaultSet'。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):簽名帶 'Effectful.IOE',
-- 效果真的發生在這裡。效果的__描述__住 effects 層
-- ("Aapms.Store.Effect.Vaults"),純解譯器
-- 'Aapms.Store.Simulate.runVaultsPure' 住 pure 層(ADR-023)。
--
-- == 為什麼 'VaultSet' 住在這裡
--
-- 'VaultSet' 是「本次生效的 vault 集合」的落地表示,而
-- 'Aapms.Store.Effect.Vaults.Vaults' 的真解譯器__就是__把效果跑在它上面的那段
-- 程式:兩者是同一件事的型別與行為。原本兩者分居
-- "Aapms.Store.MultiVault" 與本模組時,@searchAcross@ 要 import 本模組、本模組
-- 要 import 'VaultSet',是一個模組環。型別與生命週期(@openVaultSet@ \/
-- @closeVaultSet@ \/ @vaultSetIds@ \/ @maxAttachedVaults@)因此收在這裡,
-- "Aapms.Store.MultiVault" 原樣 re-export,__契約 E 的簽名與呼叫端逐字不變__;
-- 建構子與欄位仍然不匯出,'VaultSet' 對外依舊不透明。
module Aapms.Store.Effect.Vaults.IO
  ( -- * VaultSet
    VaultSet
  , maxAttachedVaults
  , openVaultSet
  , closeVaultSet
  , vaultSetIds

    -- * 內部存取(給 "Aapms.Store.MultiVault" 組 SQL 用)
  , vaultSetEntries
  , vaultSetConn
  , findHandle

    -- * 真解譯器
  , runVaultsIO
  ) where

import Control.Exception (onException)
import Data.List (nubBy)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection, Only (..), Query (..), close, execute, open)
import Effectful (Eff, IOE, inject, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)

import Aapms.Core.Id (VaultId)
import Aapms.Store.Effect.Index.Sqlite (runIndexSqlite)
import Aapms.Store.Effect.Vaults (Vaults (..))
import Aapms.Store.Error (StoreError (..), trySqlite)
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..), indexDbPath)

--------------------------------------------------------------------------------
-- VaultSet

-- | 一組被接成整體、__只供讀取__的 vault(契約 E 寫的是 @data VaultSet@,
-- 不透明)。
--
-- 三元組是 (vault id、把手、@ATTACH@ 進來的 schema 前綴含結尾的點),讓
-- 'Aapms.Store.MultiVault.listAcross' 組 SQL 時直接查得到每個 vault 的前綴;
-- 第二個欄位是本模組自己開的讀連線,所有 @ATTACH@ 都掛在它上面。
data VaultSet = VaultSet [(VaultId, VaultHandle, Text)] Connection

-- | 一個 'VaultSet' 最多接幾個 vault。
--
-- SQLite 的 @SQLITE_MAX_ATTACHED@ 預設是 10(main 之外可以再 @ATTACH@ 10 個),
-- 契約卡則寫「第 11 個 vault 回 'Aapms.Store.Types.TooManyVaults' 並列出 10」
-- ——以__契約卡__為準,上限是 10 個 vault。
maxAttachedVaults :: Int
maxAttachedVaults = 10

-- | 第 i 個 @ATTACH@ 進來的 vault 的 schema 名稱(不含點)。
schemaName :: Int -> Text
schemaName i = "v" <> T.pack (show i)

-- | 同上,含結尾的點,直接餵給 'Aapms.Store.Query.whereOfIn' \/
-- 'Aapms.Store.Query.baseFromIn'。
schemaPrefix :: Int -> Text
schemaPrefix i = schemaName i <> "."

vidOf :: VaultHandle -> VaultId
vidOf h = vmId (vhMarker h)

-- | 找出第一組「vid 相同、@vhRoot@ 不同」的把手對,依它們在清單中出現的先後。
findCollision :: [VaultHandle] -> Maybe (VaultId, FilePath, FilePath)
findCollision hs =
  listToMaybe
    [ (vidOf h1, vhRoot h1, vhRoot h2)
    | (i, h1) <- zip [0 :: Int ..] hs
    , (j, h2) <- zip [0 :: Int ..] hs
    , i < j
    , vidOf h1 == vidOf h2
    , vhRoot h1 /= vhRoot h2
    ]

-- | 把一組已經開好的 vault 把手接成一個 'VaultSet'。
--
-- __檢查順序:先撞號、再保序去重、最後上限__(P-002-search 的決定)。撞號時任何
-- 'Aapms.Core.Id.Ref' 解析都不確定,先叫使用者收窄範圍等於叫他繞過去。
--
-- __同一個 'Aapms.Store.Types.vmId' 出現兩次有兩種成因,處置不同__(契約 G):
--
-- * 兩筆的 'Aapms.Store.Marker.vhRoot' __相同__(同一個路徑被傳兩次)——無害的
--   呼叫端疏忽(預設 vault 又被顯式指定一次),__保序去重、只留第一個__,
--   上限也以去重後的數量計。
-- * 兩筆的 'Aapms.Store.Marker.vhRoot' __不同__——依 ADR-017,vault 的身分就是
--   marker 裡的 id,撞號代表有人複製了整個 vault 目錄,回
--   'Aapms.Store.Types.VaultIdCollision' 並列出__兩個路徑__。
--
-- __不接管把手的生命週期__:'closeVaultSet' 不會關掉任何一個
-- 'Aapms.Store.Marker.VaultHandle'。
openVaultSet :: [VaultHandle] -> IO (Either StoreError VaultSet)
openVaultSet hs = case findCollision hs of
  Just (vid, p1, p2) -> pure (Left (VaultIdCollision vid p1 p2))
  Nothing ->
    let ks = nubBy (\a b -> vidOf a == vidOf b) hs
     in if length ks > maxAttachedVaults
          then pure (Left (TooManyVaults (length ks) maxAttachedVaults))
          else trySqlite $ do
            conn <- open ":memory:"
            let aliased = [(vidOf h, h, schemaPrefix i) | (i, h) <- zip [0 :: Int ..] ks]
                attachOne (i, h) =
                  execute
                    conn
                    (Query ("ATTACH DATABASE ? AS " <> schemaName i))
                    (Only (T.pack (indexDbPath (vhRoot h))))
            mapM_ attachOne (zip [0 :: Int ..] ks) `onException` close conn
            pure (VaultSet aliased conn)

-- | 釋放 'VaultSet' 自己持有的資源(它自己的讀連線),__不__關閉任何
-- 'Aapms.Store.Marker.VaultHandle'。
closeVaultSet :: VaultSet -> IO ()
closeVaultSet (VaultSet _ conn) = close conn

-- | 這個 'VaultSet' 實際涵蓋哪些 vault,依 'openVaultSet' 收到的順序、已去重。
vaultSetIds :: VaultSet -> [VaultId]
vaultSetIds (VaultSet aliased _) = [v | (v, _, _) <- aliased]

-- | (vault id, 把手, schema 前綴) 三元組,依集合順序。
vaultSetEntries :: VaultSet -> [(VaultId, VaultHandle, Text)]
vaultSetEntries (VaultSet aliased _) = aliased

-- | 'VaultSet' 自己的讀連線(全部 @ATTACH@ 都掛在它上面)。
vaultSetConn :: VaultSet -> Connection
vaultSetConn (VaultSet _ conn) = conn

-- | 依 'Aapms.Core.Id.VaultId' 找出這個 'VaultSet' 裡對應的把手,找不到就是這個
-- vault 不在集合裡。
findHandle :: VaultSet -> VaultId -> Maybe VaultHandle
findHandle (VaultSet aliased _) v = listToMaybe [h | (v', h, _) <- aliased, v' == v]

--------------------------------------------------------------------------------
-- 真解譯器

-- | 以一組已經接好的 vault 跑 'Vaults'。
--
-- * @VaultIds@ 依 'VaultSet' 的順序('openVaultSet' 收到的順序、已去重),與
--   'vaultSetIds' 同一份。
-- * @InVault@ 拿該 vault 自己的把手連線跑
--   'Aapms.Store.Effect.Index.Sqlite.runIndexSqlite';不在集合裡回 'Nothing'
--   (P-002-search#LAW-13)。內層程式是具體的 @Eff '[Index] a@,借不到外層的
--   能力,所以先 'Effectful.inject' 到帶得動 'Effectful.IOE' 的效果列再跑。
--
-- __跑在把手的連線上,不是 'VaultSet' 自己那條 @ATTACH@ 連線__:每個 vault 的
-- 查詢各自獨立(合併在 Haskell 做,P-002-search 的決定),用把手的連線就不必
-- 給每一句 SQL 加 schema 前綴,而且與單一 vault 的
-- 'Aapms.Store.Query.search' 走同一條路、同一份 bm25。
runVaultsIO :: IOE :> es => VaultSet -> Eff (Vaults : es) a -> Eff es a
runVaultsIO vs = interpret $ \_ op -> case op of
  VaultIds -> pure (vaultSetIds vs)
  InVault v act -> case findHandle vs v of
    Nothing -> pure Nothing
    Just h -> Just <$> liftIO (runEff (runIndexSqlite (vhConn h) (inject act)))
