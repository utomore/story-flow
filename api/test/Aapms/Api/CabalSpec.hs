-- | T1:API 套件不依賴任何實作端。
--
-- 這個套件存在的唯一理由是「server 與 cli --remote 共用同一份契約」。它一旦
-- 依賴其中一端,另一端就得跟著把整套東西拖進來——CLI 會因此被迫帶著 @warp@。
-- 用測試釘住 @build-depends@,不是靠 code review 記得。
module Aapms.Api.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "套件邊界" $ do
  it "build-depends 不含任何實作端" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  it "build-depends 含它真正需要的契約套件" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, True)) required

-- | 兩個消費端各自的東西,加上落地層。出現在這裡就是架構違規。
forbidden :: [String]
forbidden =
  [ "servant-server"
  , "servant-client"
  , "warp"
  , "aapms-store"
  , "aapms-md"
  , "sqlite-simple"
  , "direct-sqlite"
  ]

-- | conflict-detection/F004:@aapms-conflict@ 加進這張表而不是留白。
--
-- @POST \/conflict\/context@ 的 body 與回應型別(@Draft@ \/ @ConflictOpts@ \/
-- @ContextHit@)住在那個套件裡,契約套件當然要認得它。它不進 'forbidden' 的理由是
-- 它__不是實作端__:它沒有 servant handler、沒有 client、沒有落地層,與
-- @aapms-service@ 同一種性質。
--
-- llm-workshop-mcp/F004:@aapms-workshop@ 同一個理由加進來——@WorkshopAPI@
-- 的 @Session@ 型別住在那裡。@aapms-llm@ 是實作時才發現的必要補充:
-- @Session@ 的 @wsHistory@ 元素型別 @Message@ \/ @Role@ 的 @ToSchema@ 定義在
-- "Aapms.Api.Instances",那兩個型別本身住在 @aapms-llm@。兩者都不是
-- 實作端,與 @aapms-conflict@ 同一種性質。
required :: [String]
required =
  [ "servant"
  , "openapi3"
  , "aapms-core"
  , "aapms-service"
  , "aapms-conflict"
  , "aapms-workshop"
  , "aapms-llm"
  ]

readCabal :: IO String
readCabal = go ["aapms-api.cabal", "api/aapms-api.cabal"]
  where
    go [] = fail "找不到 aapms-api.cabal"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then T.unpack . TE.decodeUtf8 <$> BS.readFile c else go rest

-- | 只看以逗號開頭的行:本檔案的 .cabal 註解就正好提到了 servant-server。
--
-- 注意 @servant-openapi3@ 這一行含有子字串 @servant@,所以「不含 servant-server」
-- 與「含 servant」兩條斷言都是子字串比對——前者不會被 @servant-openapi3@ 誤傷
-- (它不含 @servant-server@),後者則會被它滿足,而那正確:這個套件確實依賴 servant。
dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False
