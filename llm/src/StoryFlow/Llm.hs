-- | @storyflow-llm@ 的門面:__地端與雲端共用的同一組型別與呼叫路徑__。
--
-- 與 "StoryFlow.Store" \/ "StoryFlow.Service" 同一種形狀——消費者只 import 一個
-- 名字,不必知道套件內部分了幾個模組。
--
-- 典型用法:
--
-- @
-- Right cfg <- 'StoryFlow.Service.runService' env 'llmConfig'
-- client <- 'newLlmClient' cfg
-- 'chat' client ['Message' 'System' \"你是設定編輯助手\", 'Message' 'User' 草稿]
-- @
--
-- 地端(llama.cpp \/ Ollama)與雲端的差別__只有 'lcBaseUrl' 與 'lcApiKey' 兩個
-- 值__:上面這段程式碼一個字都不必改。
--
-- 明確__不做__的:不組 prompt(那是消費者的事)、不做串流、不引入重量級 LLM
-- SDK、不定義 CLI 與 REST 出口。
--
-- __為什麼是逐項列舉而不是 @module X@ 整包 re-export__:這份清單__就等於__
-- 設計文檔 @llm-workshop-mcp\/F001@「新增的介面」那一章列的名字,一個不多一個
-- 不少。整包 re-export 會讓套件內部為了避免反向 import 而拆出來的推導函式
-- (例如 "StoryFlow.Llm.Config" 的 @chatEndpoint@)一併穿透門面,公開面就不再
-- 由文檔決定,而是由「某個名字剛好被哪個內部模組匯出」決定。代價是__以後每加
-- 一個公開名字要改兩個地方__(內部模組的匯出清單,以及這裡);這是刻意付的,
-- 因為那一步正是「這個名字要不要進公開面」的決定點。
module StoryFlow.Llm
  ( -- * 訊息
    Role (..)
  , Message (..)

    -- * 客戶端
  , LlmClient
  , newLlmClient
  , chat

    -- * 設定
  , LlmConfig (..)
  , defaultLlmTimeoutMs
  , defaultLlmRetries
  , parseLlmConfig
  , llmConfig

    -- * 錯誤
  , LlmError (..)
  , renderLlmError
  , llmErrorCode
  ) where

import StoryFlow.Llm.Client
import StoryFlow.Llm.Config
import StoryFlow.Llm.Error
