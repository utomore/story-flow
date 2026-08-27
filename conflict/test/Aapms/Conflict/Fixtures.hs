-- | 測試共用的資料。
--
-- 這個套件零 IO、也不碰 Vault,所以 fixture 只需要「合法的 Id / Ref / Meta」
-- 三樣東西。刻意不從 core 的測試 fixture 搬過來:那是另一個套件的 test suite,
-- 不對外 expose,抄三個小函式比為此拆一個共用套件划算。
module Aapms.Conflict.Fixtures
  ( idOf
  , refOf
  , metaOf
  , graphEvidence
  , retrievalHit
  , judgeHit
  ) where

import Data.Text (Text)
import Data.Time (fromGregorian)
import Aapms.Conflict.Types
import Aapms.Core.Id
import Aapms.Core.Link (LinkKind (Contradicts))
import Aapms.Core.Meta

-- | 由已知合法的字面值取得 'Id'。只給測試用,格式寫錯就讓測試直接爆掉。
idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("fixture 的 ref 不合法:" <> show e)

-- | 最小可用的 'Meta':給 id 與標題,其餘取預設。
metaOf :: Text -> Text -> Meta
metaOf i title =
  Meta
    { metaId = idOf i
    , metaVault = "liftgame"
    , metaType = "plot-fragment"
    , metaTitle = title
    , metaSummary = title
    , metaTags = []
    , metaStatus = Canon
    , metaTimeline = emptyTimeline
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = 1
    , metaCreated = fromGregorian 2026 8 18
    , metaUpdated = fromGregorian 2026 8 18
    }

-- | 第 1 層的命中:@ent-7f3c contradicts ent-91cc@。
graphEvidence :: GraphEvidence
graphEvidence = GraphEvidence (idOf "ent-7f3c") Contradicts (refOf "ent-91cc")

-- | 第 2 / 第 3 層的命中,只差一個分數。
retrievalHit, judgeHit :: Double -> Text -> ConflictHit
retrievalHit s i = ConflictHit (idOf i) (ByRetrieval s) "關鍵詞高度重疊" (Just "……織紋……")
judgeHit c i = ConflictHit (idOf i) (ByJudge c) "兩段對徵召的結果描述不一致" (Just "……徵召……")
