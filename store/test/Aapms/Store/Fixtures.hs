-- | 測試共用的臨時目錄與小工具(graph-core\/F005 起瘦身)。
--
-- 落地層的測試一律在 'System.IO.Temp.withSystemTempDirectory' 建立的臨時目錄
-- 裡跑,測完即刪,不碰使用者真正的 vault。
--
-- 本檔曾經有一整組「臨時 Vault + 範例 Markdown」的輔助函式,相依已移出本
-- feature 範圍的舊 @Vault@\/@Registry@ API(graph-core\/F006\/F008 的重寫範圍);
-- 依委派決策記錄 D8 全數移除,只留下與 marker\/schema 無關、任何 feature 都會
-- 用到的最小共用工具。
module Aapms.Store.Fixtures
  ( withTempVault
  , orDie
  , idOf
  , refOf
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id, Ref, parseId, parseRef)
import Aapms.Store.Error (StoreError, renderStoreError)
import System.IO.Temp (withSystemTempDirectory)

-- | 一個還沒有任何 marker 的臨時目錄。
withTempVault :: (FilePath -> IO a) -> IO a
withTempVault = withSystemTempDirectory "aapms-vault"

-- | 測試裡的前置動作失敗時直接爆掉,並印出人看得懂的訊息。
orDie :: Either StoreError a -> IO a
orDie = either (fail . T.unpack . renderStoreError) pure

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("測試裡的 ref 不合法:" <> show e)
