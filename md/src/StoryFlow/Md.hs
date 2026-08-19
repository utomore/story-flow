-- | @storyflow-md@ 的門面:Markdown 分節格式 ↔ 核心型別的雙向轉換。
--
-- 純函式,吃 'Data.Text.Text' 吐型別,__不做任何檔案 IO__(讀檔是 entity-graph-core/F004
-- 的事)。Markdown 檔是唯一的真相來源(ADR-002),所以本套件的正確性直接
-- 等於資料的安全性:解析漏一個欄位就是設定遺失,寫回破壞排版就是作者的手稿
-- 被工具改壞。
--
-- 典型用法:
--
-- @
-- doc <- 'parseDocument' path text          -- 第一階段:無損切塊
-- kind <- 'documentKind' doc                -- frontmatter 的 type: level 判別
-- (ef, warns) <- 'parseEntityFile' doc      -- 第二階段:解讀成核心型別
-- 'renderDocument' doc == text              -- 未修改時位元組相等
-- @
module StoryFlow.Md
  ( module StoryFlow.Md.Document
  , module StoryFlow.Md.Error
  , module StoryFlow.Md.Inherit
  , module StoryFlow.Md.Parse
  , module StoryFlow.Md.Render
  , module StoryFlow.Md.Yaml
  ) where

import StoryFlow.Md.Document
import StoryFlow.Md.Error
import StoryFlow.Md.Inherit
import StoryFlow.Md.Parse
import StoryFlow.Md.Render
import StoryFlow.Md.Yaml
