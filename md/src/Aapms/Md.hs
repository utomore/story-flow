-- | @aapms-md@ 的門面:Markdown 分節格式 ↔ 核心型別的雙向轉換。
--
-- 純函式,吃 'Data.Text.Text' 吐型別,__不做任何檔案 IO__(讀檔是
-- @aapms-store@ 的事)。Markdown 檔是唯一的真相來源(ADR-002),所以本套件的
-- 正確性直接等於資料的安全性:解析漏一個欄位就是設定遺失,寫回破壞排版就是
-- 作者的手稿被工具改壞。
--
-- 四種文件共用一個分節引擎(graph-core/F004):主題檔 / Level 檔 / pack.md /
-- licenses.md,由 'docKind' 判別身分。典型用法:
--
-- @
-- doc <- 'parseDocument' text               -- 第一階段:無損切塊 + 判別身分
-- case 'docKind' doc of
--   'TopicDoc' -> 'toTopic' doc              -- 第二階段:解讀成核心型別
--   ...
-- 'renderDocument' doc == text              -- 未修改時位元組相等
-- @
module Aapms.Md
  ( module Aapms.Md.Document
  , module Aapms.Md.Error
  , module Aapms.Md.Inherit
  , module Aapms.Md.Parse
  , module Aapms.Md.Render
  , module Aapms.Md.Yaml
  ) where

import Aapms.Md.Document
import Aapms.Md.Error
import Aapms.Md.Inherit
import Aapms.Md.Parse
import Aapms.Md.Render
import Aapms.Md.Yaml
