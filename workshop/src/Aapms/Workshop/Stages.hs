-- | 依型別註冊表 @stages@ 驅動的工作坊狀態機(llm-workshop-mcp/F002)。
--
-- __唯一呼叫 'chat' 的模組__:'startWorkshop' 建立一次工作坊、'stepWorkshop' 送
-- 一輪對話給模型並把回覆解析成片段草稿。定案(@commitStage@)是
-- workshop-emit(F003)的事,本模組完全不 import @createEntity@ \/ @addFragment@。
module Aapms.Workshop.Stages
  ( startWorkshop
  , stepWorkshop

    -- * 內部部件
    --
    -- 不是 Level 2 契約的一部分,只為測試而公開——與
    -- @aapms-conflict@ 的 "Aapms.Conflict.Judge" 同一個先例
    -- (@renderPairPrompt@ \/ @stripCodeFence@ 等一樣公開給測試)。
  , buildMessages
  , extractDrafts
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecodeStrictText)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, renderId)
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Registry (EntityTypeSpec (..), FieldSpec (..))
import Aapms.Llm (LlmClient, Message (..), Role (..), chat)
import Aapms.Service (EntityView (..), ServiceError (..), ServiceM, getEntity, listEntityTypes)
import Aapms.Workshop.Error (WorkshopError (..))
import Aapms.Workshop.Session (Session (..), StageDraft, newSessionId, saveSession)

-- startWorkshop ------------------------------------------------------------------

-- | 開一次新的工作坊。
--
-- 兩層失敗:__外層__(這裡走 'ServiceM' 原生的 'ServiceError',經 'throwError'
-- 或 'getEntity' 的既有行為)是業務層失敗(型別未知、硬約束 id 不存在);
-- __內層__(@Left WorkshopError@)是工作坊自己的失敗(空 stages、寫快照失敗)。
-- 兩者互不轉譯,各自原樣浮上去。
startWorkshop :: Text -> [Id] -> ServiceM (Either WorkshopError Session)
startWorkshop ty constraints = do
  specs <- listEntityTypes
  case find ((== ty) . etsKey) specs of
    Nothing -> throwError (UnknownType ty)
    Just spec
      | null (etsStages spec) -> pure (Left (WsNoStages ty))
      | otherwise -> do
          -- 逐一驗證硬約束存在:目標不存在時 'getEntity' 已經會丟
          -- 'StoreFailed (EntityNotFound _)',同樣走 'ServiceError' 通道,
          -- 不需要另外處理。及早失敗——講到一半才發現某個 id 打錯,比在
          -- 建立 session 的當下就發現代價更高。
          mapM_ getEntity constraints
          sid <- newSessionId ty constraints
          let session =
                Session
                  { wsId = sid
                  , wsType = ty
                  , wsConstraints = constraints
                  , wsStages = etsStages spec
                  , wsCurrent = 0
                  , wsHistory = []
                  , wsOwner = Nothing
                  , wsPending = []
                  , wsCommitted = []
                  }
          saved <- saveSession session
          pure $ case saved of
            Left werr -> Left werr
            Right () -> Right session

-- stepWorkshop --------------------------------------------------------------------

-- | 送一輪對話給模型,把回覆解析成片段草稿存進 'wsPending'。
stepWorkshop :: LlmClient -> Session -> Text -> ServiceM (Either WorkshopError (Session, Text))
stepWorkshop client session input
  | wsCurrent session >= length (wsStages session) =
      pure (Left (WsStagesExhausted (wsId session)))
  | otherwise = do
      -- 每次呼叫重新 listEntityTypes 找對應的 spec 取 etsFields:硬約束的
      -- summary 與型別的必填欄位都可能隨時間被改過,現讀現送比存一份舊的
      -- 更正確(見 F002 的待確認假設 A1 / A4)。'Session' 不快取 etsFields
      -- ——加第十個欄位就是偏離 Level 2 鎖定的九個欄位契約。
      specs <- listEntityTypes
      case find ((== wsType session) . etsKey) specs of
        Nothing -> throwError (UnknownType (wsType session))
        Just spec -> do
          constraintSummaries <- mapM constraintSummary (wsConstraints session)
          let messages = buildMessages session constraintSummaries (etsFields spec) input
          result <- liftIO (chat client messages)
          case result of
            -- 不寫快照、Session 不變:這一步什麼都沒發生,wsHistory 不該記
            -- 一輪沒有下文的失敗嘗試。
            Left e -> pure (Left (WsLlmFailed e))
            Right reply -> do
              let newHistory = wsHistory session ++ [Message User input, Message Assistant reply]
                  newPending = fromMaybe (wsPending session) (extractDrafts reply)
                  newSession = session {wsHistory = newHistory, wsPending = newPending}
              saved <- saveSession newSession
              pure $ case saved of
                Left werr -> Left werr
                Right () -> Right (newSession, reply)

-- | 硬約束 id → @(id, summary)@。__現讀現送,不快取__:與 'wsConstraints' 的
-- 存在性驗證(見 'startWorkshop')同一個 id 清單,但這裡只取 'metaSummary' 供
-- prompt 使用,只送 summary 不送 'entBody'(驗收標準 2)。
constraintSummary :: Id -> ServiceM (Id, Text)
constraintSummary i = do
  ev <- getEntity i
  pure (i, metaSummary (entMeta (evEntity ev)))

-- prompt 組裝 ----------------------------------------------------------------------

-- | 組出這一輪要送給 'chat' 的 @[Message]@。__欄位要求完全來自 @etsFields@__
-- (驗收標準 1 的後半):新增一個型別、或改它的必填欄位,都不改這段程式碼。
buildMessages :: Session -> [(Id, Text)] -> [FieldSpec] -> Text -> [Message]
buildMessages session constraints fields input =
  Message System (systemPrompt session constraints fields)
    : wsHistory session
    ++ [Message User input]

systemPrompt :: Session -> [(Id, Text)] -> [FieldSpec] -> Text
systemPrompt session constraints fields =
  T.unlines $
    openingLine session
      : constraintsBlock constraints
      ++ fieldsBlock fields
      ++ formatBlock fields

openingLine :: Session -> Text
openingLine Session {..} =
  "你正在引導使用者完成『"
    <> wsType
    <> "』的第 "
    <> T.pack (show (wsCurrent + 1))
    <> "/"
    <> T.pack (show (length wsStages))
    <> " 個階段:『"
    <> currentStageName
    <> "』。"
  where
    currentStageName
      | wsCurrent >= 0 && wsCurrent < length wsStages = wsStages !! wsCurrent
      | otherwise = ""

-- | 硬約束以 @summary@ 進 prompt(驗收標準 2)。呈現方式與
-- @Conflict.Judge.renderPairPrompt@ 同一個「id + 內容」的作法,但這裡明講
-- 「只有 summary」,不留給讀者猜是不是完整正文。
constraintsBlock :: [(Id, Text)] -> [Text]
constraintsBlock [] = []
constraintsBlock cs = "" : map render cs
  where
    render (i, summary) = "【既有設定 " <> renderId i <> "(只有 summary)】" <> summary

-- | 逐條「- {fsName}({必填 或 選填}):{fsHint}」——三個子項全部原樣取自
-- @etsFields@,不重寫、不篩選、不寫死任何欄位名。
fieldsBlock :: [FieldSpec] -> [Text]
fieldsBlock [] = []
fieldsBlock fields = "" : "這個型別的欄位要求:" : map render fields
  where
    render FieldSpec {..} =
      "- " <> fsName <> "(" <> (if fsRequired then "必填" else "選填") <> "):" <> fsHint

-- | 格式指示:要求模型在自然語言回覆之外,另外用一個 ```json 圍起來的區塊附上
-- 目前這個階段可以定案的片段草稿。
formatBlock :: [FieldSpec] -> [Text]
formatBlock fields =
  [ ""
  , "除了對使用者的自然語言回覆之外,請另外用一個 ```json 圍起來的區塊附上目前"
      <> "這個階段可以定案的片段草稿,陣列形狀:"
  , "[{\"title\":…, \"summary\":…, \"body\":…, \"tags\":[…], \"timeline\":{\"label\":…, \"order\":…}}]"
  , "`timeline` 整個鍵可省略,`label` / `order` 兩鍵也各自可省略;沒有想清楚就附 []"
      <> ";可以附多個。"
  ]
    ++ ["這個階段的必填欄位裡有 `timeline`,請盡量附上。" | requiresTimeline fields]

requiresTimeline :: [FieldSpec] -> Bool
requiresTimeline = any (\f -> fsName f == "timeline" && fsRequired f)

-- JSON 擷取 -------------------------------------------------------------------------

-- | 從模型回覆解析出 @[StageDraft]@。__不捏假資料__:兩次嘗試都失敗回
-- 'Nothing',呼叫端('stepWorkshop')在 'Nothing' 時原樣保留舊的 'wsPending'。
-- 解出空陣列 @[]@ __算成功__——那是 @newPending = []@,不是「保留舊值」。
extractDrafts :: Text -> Maybe [StageDraft]
extractDrafts raw =
  case tryDecode content of
    Right ds -> Just ds
    Left _ -> sliceBrackets content >>= either (const Nothing) Just . tryDecode
  where
    content = stripFence raw
    tryDecode :: Text -> Either String [StageDraft]
    tryDecode = eitherDecodeStrictText

-- | 剝除 markdown code fence,邏輯與 @Conflict.Judge.stripCodeFence@ 同構
-- (獨立實作,本套件不依賴 @aapms-conflict@,只重用做法):
--
-- 1. 內容裡存在一段 @```@ 圍起來的區塊 → 取第一個區塊的內容(語言標記行整行丟掉)
-- 2. 找不到 fence → 原樣回傳(已去空白)
stripFence :: Text -> Text
stripFence raw =
  let s = T.strip raw
   in maybe s T.strip (locateFence s)

locateFence :: Text -> Maybe Text
locateFence s =
  let (_, after) = T.breakOn fence s
   in if T.null after
        then Nothing
        else
          let body = dropLangTagLine (T.drop (T.length fence) after)
              (inner, closing) = T.breakOn fence body
           in if T.null closing then Nothing else Just inner
  where
    fence = "```"

-- | fence 標記後的第一行若「看起來像語言標記」(短、不含 @[@)就整行丟掉;
-- 否則原樣回傳,代表內容緊接在標記之後。
dropLangTagLine :: Text -> Text
dropLangTagLine t =
  let (tag, rest) = T.breakOn "\n" t
   in if not (T.null rest) && T.length (T.strip tag) <= 12 && not ("[" `T.isInfixOf` tag)
        then T.drop 1 rest
        else t

-- | 失敗時退回「第一個 @[@ 到最後一個 @]@」的切片再 decode 一次。
sliceBrackets :: Text -> Maybe Text
sliceBrackets t = do
  i <- T.findIndex (== '[') t
  j <- lastIndexOf ']' t
  if j >= i then Just (T.take (j - i + 1) (T.drop i t)) else Nothing

lastIndexOf :: Char -> Text -> Maybe Int
lastIndexOf c t = case T.findIndex (== c) (T.reverse t) of
  Nothing -> Nothing
  Just k -> Just (T.length t - 1 - k)
