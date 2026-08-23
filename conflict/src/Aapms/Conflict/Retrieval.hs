-- | 衝突偵測第 2 層的__契約面__:關鍵詞候選撈取。
--
-- 這一層回答的是__哪些既有的 canon 片段和這段草稿有關__ ——注意是「有關」而不是
-- 「矛盾」。判斷矛盾是第 3 層的事(ADR-007)。
--
-- 實作在 "Aapms.Conflict.Retrieval.Internal";本模組只是一層 re-export。
--
-- __為什麼是逐項列舉而不是 @module X@ 整包 re-export__:整包 re-export 會讓公開面由
-- 「某個名字剛好被哪個內部模組匯出」決定,而不是由 @design.md@ 決定——@aapms-llm@
-- 的 @chatEndpoint@ 就是這樣穿透門面的(llm-workshop-mcp\/F001 的閘門為此裁決過一次)。
-- 代價是以後每加一個公開名字要改兩個地方;這是刻意付的,因為那一步正是「這個名字
-- 要不要進契約面」的決定點。
--
-- __為什麼這裡只有 10 個名字__(conflict-detection\/E001):契約卡寫著「候選撈取策略
-- 本身是本模組的內部抽象,對外只露『候選』這個結果」,而 ADR-007 把 embedding 語意
-- 檢索列為__被推遲而非被否決__的選項。「換一種候選策略不必動第 1、3 層」這個承諾要
-- 兌現,前提是那兩層從來沒碰過第 2 層的內部;而「碰了」__不會有任何測試變紅__,
-- 所以只能靠可見度本身把門關上。
--
-- 這 10 個名字的去處,一個不多一個不少:
--
-- * 門面四個 —— @Pipeline@ 與 @Judge@ 實際消費的結果型別
-- * 策略接縫三個 —— ADR-007 的 embedding 由 'retrieveCandidatesWith' 接入
-- * 輸出轉換兩個 —— @Pipeline@ 把候選變成 @context@ \/ @conflict check@ 的輸出
-- * 'metaSnippet' —— @Pipeline@ 與 @Judge@ 共用的片段摘要,已登記在 @design.md@
--   的「模組間公開介面與資料結構」表
--
-- 其餘 13 個(調校常數、純函式部件、'renderRetrievalReason')住在 Internal,
-- __只給同套件的測試觀測__。
module Aapms.Conflict.Retrieval
  ( -- * 門面
    retrieveCandidates
  , RetrievalResult (..)
  , Candidate (..)

    -- | 'Candidate' 的 @caOrigin@ 欄位型別。匯出 @Candidate (..)@ 卻不匯出它,
    -- 消費者拿得到欄位卻無法 pattern match。
  , CandidateOrigin (..)

    -- * 策略接縫
    --
    -- | ADR-007 的 embedding 語意檢索由這裡接入:多一個 'KeywordStrategy'
    -- 的實作、用 'retrieveCandidatesWith' 餵進去,第 1、3 層一行都不必改。
  , retrieveCandidatesWith
  , KeywordStrategy (..)
  , defaultKeywordStrategy

    -- * 輸出轉換
  , candidateContextHit
  , candidateConflictHit

    -- * 跨層共用
    --
    -- | @Conflict.Judge@ 組 prompt 時也用它(conflict-detection\/F005)。
    -- 這條跨層使用登記在 @design.md@ 的「模組間公開介面與資料結構」表,
    -- 不是漏出來的內部細節。
  , metaSnippet
  ) where

import Aapms.Conflict.Retrieval.Internal
  ( Candidate (..)
  , CandidateOrigin (..)
  , KeywordStrategy (..)
  , RetrievalResult (..)
  , candidateConflictHit
  , candidateContextHit
  , defaultKeywordStrategy
  , metaSnippet
  , retrieveCandidates
  , retrieveCandidatesWith
  )
