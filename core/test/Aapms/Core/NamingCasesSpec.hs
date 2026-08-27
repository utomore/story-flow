-- | graph-core/F002 T10:讀 @contract/fixtures/naming-cases.txt@(契約卡的驗收
-- 輸入),逐行以新 'parseLogicalName' + 'mkLogicalName' 驗證。
--
-- @contract@ 套件本身凍結(D:「contract 套件本身已凍結,不要改它」),
-- 'Aapms.Contract.NamingGrammarSpec' 的第三個 @it@ 仍是 @pendingWith@;
-- 本檔是它註解裡說的「等 F002 落地後改為逐行呼叫 aapms 驗證」的落地位置,
-- 只是落在 @aapms-core@ 而非 @contract@(D 的凍結範圍)。
module Aapms.Core.NamingCasesSpec (spec) where

import Aapms.Core.Naming
import Data.Char (isSpace)
import qualified Data.ByteString as BS
import Data.Either (isLeft, rights)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Test.Hspec

-- | 從 @core/@(cabal test 的 cwd)看過去的相對路徑。
casesPath :: FilePath
casesPath = "../contract/fixtures/naming-cases.txt"

data Case = Ok T.Text | Bad T.Text deriving stock (Show, Eq)

-- | __注意__:名稱本身可能含空白(那正是某些 @bad@ 案例要測的東西,如
-- 「ui_gui_travel book frame」),所以不能用 'T.words' 只取第一個詞——那樣會
-- 把空白之後的內容連同「這裡有空白」這個事實一起丟掉。改用
-- 'T.stripPrefix' 取 @ok @\/@bad @ 之後的整段(去掉行尾註解與空白)當名稱。
parseCases :: T.Text -> Either String [Case]
parseCases = traverse one . filter keep . map trimComment . T.lines
  where
    keep l = not (T.null (trim l)) && not ("#" `T.isPrefixOf` trim l)
    one l
      | Just rest <- T.stripPrefix "ok " l = Right (Ok (trim rest))
      | Just rest <- T.stripPrefix "bad " l = Right (Bad (trim rest))
      | otherwise = Left ("看不懂的行:" <> T.unpack l)
    trimComment l = fst (T.breakOn " #" l)
    trim = T.dropWhileEnd isSpace . T.dropWhile isSpace

-- | 與 @types/registry/naming.toml@ 一致的 12 個 kind、37 個 state。
vocab :: NamingVocab
vocab =
  NamingVocab
    { nvKinds =
        rights (map mkSegment ["spr", "tex", "atlas", "ui", "fnt", "sfx", "bgm", "vo", "lvl", "shd", "src", "doc"])
    , nvDomains = []
    , nvStates =
        rights
          ( map
              mkSegment
              [ "idle", "hover", "pressed", "disabled", "active", "selected", "focus"
              , "open", "closed", "empty", "full", "on", "off"
              , "walk", "run", "attack", "dash", "death", "hurt", "cast"
              , "up", "down", "left", "right", "front", "back", "north", "south", "east", "west"
              , "day", "night", "dawn", "dusk", "intro", "loop", "outro"
              ]
          )
    }

readUtf8 :: FilePath -> IO T.Text
readUtf8 p = TE.decodeUtf8 <$> BS.readFile p

spec :: Spec
spec = describe "T10 test_naming_cases_fixture" $ do
  it "naming-cases.txt 全部 ok 案例以 naming.toml 詞彙(含 states)驗證通過" $ do
    src <- readUtf8 casesPath
    case parseCases src of
      Left e -> expectationFailure e
      Right cs ->
        mapM_
          ( \name -> case parseLogicalName vocab name >>= mkLogicalName vocab of
              Right _ -> pure ()
              Left e -> expectationFailure (T.unpack name <> " 應合法,卻得到:" <> show e)
          )
          [n | Ok n <- cs]

  it "spr_char_hero_attack-01_up 額外斷言 npVariant / npState 拆分正確" $
    case parseLogicalName vocab "spr_char_hero_attack-01_up" of
      Right p -> do
        fmap segmentText (npVariant p) `shouldBe` Just "attack-01"
        fmap segmentText (npState p) `shouldBe` Just "up"
      Left e -> expectationFailure (show e)

  it "naming-cases.txt 全部 bad 案例被對應 NameError 拒絕" $ do
    src <- readUtf8 casesPath
    case parseCases src of
      Left e -> expectationFailure e
      Right cs ->
        mapM_
          ( \name ->
              (parseLogicalName vocab name >>= mkLogicalName vocab)
                `shouldSatisfy` isLeft
          )
          [n | Bad n <- cs]
