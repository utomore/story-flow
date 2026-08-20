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
module StoryFlow.Llm
  ( module StoryFlow.Llm.Client
  , module StoryFlow.Llm.Config
  , module StoryFlow.Llm.Error
  ) where

import StoryFlow.Llm.Client
import StoryFlow.Llm.Config
import StoryFlow.Llm.Error
