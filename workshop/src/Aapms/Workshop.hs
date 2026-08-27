-- | @aapms-workshop@ 的門面:地端模型引導出的每一階段定案,寫成圖譜裡的
-- 多個片段 Entity。
--
-- 與 "Aapms.Llm" \/ "Aapms.Service" 同一種形狀——消費者只 import 一個
-- 名字,不必知道套件內部分了幾個模組('Workshop.Session' \/ 'Workshop.Stages' \/
-- 'Workshop.Emit')。
--
-- 典型用法:
--
-- @
-- Right session0 <- 'Aapms.Service.runService' env ('startWorkshop' \"character-fragment\" [])
-- Right (session1, reply) <- 'Aapms.Service.runService' env ('stepWorkshop' client session0 使用者輸入)
-- Right (session2, views) <- 'Aapms.Service.runService' env ('commitStage' session1)
-- @
--
-- __為什麼是逐項列舉而不是 @module X@ 整包 re-export__:與 "Aapms.Llm" 同
-- 一個理由(llm-workshop-mcp\/F001 的閘門裁決)——這份清單就等於各設計文檔
-- 「新增的介面」章節列的名字,一個不多一個不少;整包 re-export 會讓套件內部
-- 為了避免反向 import 而拆出來的私有函式一併穿透門面。代價是__以後每加一個
-- 公開名字要改兩個地方__(內部模組的匯出清單,以及這裡);這是刻意付的。
module Aapms.Workshop
  ( -- * Session
    Session (..)
  , StageDraft (..)

    -- * 工作坊操作
  , startWorkshop
  , loadSession
  , stepWorkshop
  , commitStage

    -- * 錯誤
  , WorkshopError (..)
  , renderWorkshopError
  , workshopErrorCode
  ) where

import Aapms.Workshop.Emit (commitStage)
import Aapms.Workshop.Error (WorkshopError (..), renderWorkshopError, workshopErrorCode)
import Aapms.Workshop.Session (Session (..), StageDraft (..), loadSession)
import Aapms.Workshop.Stages (startWorkshop, stepWorkshop)
