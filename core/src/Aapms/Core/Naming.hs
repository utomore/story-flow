-- | 命名文法(ADR-019)的**文法層**:分段、正規化、組合、解析、驗證。
--
-- @
-- \<kind\>_\<domain\>_\<subject\>[_\<variant\>][_\<state\>][_\<NNN\>]
-- @
--
-- 例:@ui_gui_travel-book-frame_01a@、@spr_char_hero_attack-01_up@、
-- @tex_ground_tileset-grass@。
--
-- == 2026-08-23 階段一閘門定案(取代舊的位置式演算法)
--
-- 契約 B 的 'parseLogicalName' __帶__ 'NamingVocab' 參數(design.md 的字面
-- 契約;先前把它誤判成「拿掉參數」是設計時筆誤,已由開發者訂正)。'NameParts'
-- 沿用 legacy 的形狀,語意區分 'npVariant'(開放,不查詞彙表)與
-- 'npState'(封閉,必須是 'nvStates' 成員)——不是位置式的 'npModifiers' 清單。
-- @kind@ 從封閉列舉 'AssetDB.Types.KindPrefix' 改成一般 'Segment',合法值改由
-- 外部注入的 'NamingVocab' 的 'nvKinds' 檢查。拆解只查一張表('nvStates'),
-- variant 天生開放,見 'parseLogicalName' 的文件。
--
-- == 資料層與文法層分家
--
-- 'Segment' \/ 'NameParts' \/ 'NamingVocab' \/ 'NameError' 這一組__純資料__(連同
-- 它們的 smart constructor 與 'renderNameError')住 "Aapms.Core.Name",本模組只
-- 留文法演算法(組合 \/ 解析 \/ 驗證)並__原樣 re-export__ 那些名字:註冊表宣告
-- ('Aapms.Core.Registry.TypeDecl' 的 @tdNameKinds@)只需要那組資料,不該為此
-- 依賴一個做推導的模組。匯出清單與既有呼叫端因此逐字不變。
module Aapms.Core.Naming
  ( -- * 型別(re-export 自 "Aapms.Core.Name")
    Segment
  , segmentText
  , mkSegment
  , NameParts (..)
  , NamingVocab (..)
  , NameError (..)
  , renderNameError

    -- * 建構與解析
  , mkLogicalName
  , parseLogicalName
  , validateLogicalName
  , renderParts

    -- * 數字部位(re-export 自 "Aapms.Core.Name")
  , indexSegment
  , isIndexShaped

    -- * 常數(re-export 自 "Aapms.Core.Name")
  , maxLogicalNameLength
  ) where

import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Meta (TypeKey)
import Aapms.Core.Name
import Data.Char (digitToInt, isAscii)
import Data.Text (Text)
import qualified Data.Text as T

--------------------------------------------------------------------------------
-- 建構

-- | 組出邏輯名稱。檢查 'npKind' 在 'nvKinds' 內、'npState'(若為 @Just@)在
-- 'nvStates' 內、渲染後長度不超過上限。
--
-- 允許呼叫端手工建構 'NameParts'(不必每次都經過 'parseLogicalName'),因此
-- 'npState' 可能是任意值——「封裝不變量」不能只靠 'parseLogicalName' 那一條
-- 路徑保證(F002 待確認假設 ASM-5)。
mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName
mkLogicalName vocab parts
  | npKind parts `notElem` nvKinds vocab =
      Left (UnknownKindPrefix (segmentText (npKind parts)))
  | Just st <- npState parts, st `notElem` nvStates vocab =
      Left (UnknownState (segmentText st))
  | otherwise = do
      txt <- renderParts parts
      let n = T.length txt
      if n > maxLogicalNameLength
        then Left (TooLong n txt)
        else Right (LogicalName txt)

-- | 方向沿用 legacy 順序:@kind_domain_subject@ 之後依序接 'npVariant'、
-- 'npState'(各自只在 @Just@ 時附加)、最後 'npIndex'(補零到三位)。
--
-- 契約只保證 @parse → render@ 方向的 round trip(F002 待確認假設 ASM-5):
-- render 之後重新 parse,拿回的字串會與原字串相同,但如果 'NameParts' 是
-- 手工建構、把一個剛好在 'nvStates' 內的詞放進 'npVariant',重新 parse 後
-- 那段文字會依規則被歸類成 'npState'——值不變,語意標籤變了,這不是本
-- 函式的契約義務。
renderParts :: NameParts -> Either NameError Text
renderParts NameParts {..} = do
  ixSeg <- traverse indexSegment npIndex
  let segs =
        [segmentText npKind, segmentText npDomain, segmentText npSubject]
          <> maybe [] (pure . segmentText) npVariant
          <> maybe [] (pure . segmentText) npState
          <> maybe [] (pure . segmentText) ixSeg
  Right (T.intercalate "_" segs)

--------------------------------------------------------------------------------
-- 解析

-- | 由右往左剝,只查 'nvStates' 一張表(design.md「命名文法的拆解規則」
-- 段落逐字):
--
-- 1. 全域檢查:純 ASCII、長度上限
-- 2. @rawSegs = splitOn "_" full@;至少 @kind_domain_subject@ 三段,否則
--    'TooFewSegments'
-- 3. 逐段以 'mkSegment' 驗證(@kindTxt@ 同樣只過語法,'nvKinds' 成員檢查
--    留給 'mkLogicalName' \/ 'validateLogicalName')
-- 4. 若 @rest@ 的最後一段 'isIndexShaped'(剛好三位純數字,純語法、不查
--    表),剝掉當 'npIndex'
-- 5. __guard__:僅當剝掉 index 後剩下的段落數 @>= 2@(剝掉後還留得下至少
--    一段給 subject)__且__最後一段 @∈ nvStates@ 時,才剝掉當 'npState';
--    否則 'npState' 為 @Nothing@(這個 guard 沿用 legacy @peel@「不剝到
--    清空」的保護,見 F002 待確認假設 ASM-4——沒有它,單獨一段又剛好撞見
--    state 詞的主體〔如 @spr_char_up@〕會被誤剝成「沒有 subject」而報錯)
-- 6. 剩下的段落依長度分派:@[s]@ → 只有 'npSubject';@[s, v]@ → 'npSubject'
--    加 'npVariant'(__開放,不查表__);@[]@ → 'TooFewSegments';更長 →
--    'AmbiguousTrailing'
parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts
parseLogicalName vocab full
  | not (T.all isAscii full) = Left (NoAsciiContent full)
  | T.length full > maxLogicalNameLength = Left (TooLong (T.length full) full)
  | otherwise = case rawSegs of
      (kindTxt : domainTxt : rest@(_ : _)) -> do
        kind <- mkSegment kindTxt
        domain <- mkSegment domainTxt
        restSegs <- traverse mkSegment rest
        let (mIndexSeg, afterIndex) = peelIndex restSegs
            (mStateSeg, afterState) = peelState afterIndex
        case afterState of
          [] -> Left (TooFewSegments (length rawSegs) full)
          [subj] ->
            Right
              NameParts
                { npKind = kind
                , npDomain = domain
                , npSubject = subj
                , npVariant = Nothing
                , npState = mStateSeg
                , npIndex = fmap readIndex mIndexSeg
                }
          [subj, var] ->
            Right
              NameParts
                { npKind = kind
                , npDomain = domain
                , npSubject = subj
                , npVariant = Just var
                , npState = mStateSeg
                , npIndex = fmap readIndex mIndexSeg
                }
          more -> Left (AmbiguousTrailing (map segmentText more) full)
      _ -> Left (TooFewSegments (length rawSegs) full)
  where
    rawSegs = T.splitOn "_" full

    -- 只有在最後一段長得像 index 時才剝;剝了之後剩下什麼交給下一步判斷。
    peelIndex :: [Segment] -> (Maybe Segment, [Segment])
    peelIndex segs = case reverse segs of
      (lastSeg : others) | isIndexShaped (segmentText lastSeg) ->
        (Just lastSeg, reverse others)
      _ -> (Nothing, segs)

    -- guard:剝掉後至少留一段給 subject,且候選段落要在 nvStates 內。
    peelState :: [Segment] -> (Maybe Segment, [Segment])
    peelState segs
      | length segs >= 2
      , (lastSeg : others) <- reverse segs
      , lastSeg `elem` nvStates vocab =
          (Just lastSeg, reverse others)
      | otherwise = (Nothing, segs)

    -- 'isIndexShaped' 已保證剛好三位數字,直接讀成 'Int'。
    readIndex :: Segment -> Int
    readIndex s = T.foldl' (\acc c -> acc * 10 + digitToInt c) 0 (segmentText s)

-- | 只檢查形狀合不合法、'npKind' 是否為詞彙表成員,不拆解給呼叫端。
--
-- 'TypeKey' 參數__不參與判斷邏輯__(F002 待確認假設 ASM-2):型別專屬的
-- @name_kinds@ 檢查交給 'Aapms.Core.Registry.checkMeta'(只回警告),
-- 這裡只做與型別無關的檢查,避免同一件事一邊硬擋一邊只警告。
validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()
validateLogicalName vocab _typeKey (LogicalName t) = do
  parts <- parseLogicalName vocab t
  if npKind parts `notElem` nvKinds vocab
    then Left (UnknownKindPrefix (segmentText (npKind parts)))
    else Right ()
