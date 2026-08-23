-- | 契約 3:索引等價(ADR-002、ADR-013)。
--
-- @rm index.db@ → @index rebuild@ 之後,所有查詢的結果與刪除前__相同__。
-- 這條是「檔案是真相、索引可丟」的可執行版本:重建期間 schema 怎麼改都無所謂,
-- 只要刪掉索引後查得回同一份答案。
module Aapms.Contract.IndexEquivalenceSpec (spec) where

import Aapms.Contract.Harness
import Control.Monad (forM)
import Data.Aeson (Value)
import qualified Data.Text as T
import System.Directory (removeFile)
import Test.Hspec

-- | 一次把所有會查索引的出口拍下來。
snapshot :: Vault -> [String] -> [String] -> IO [Value]
snapshot v entityIds levelIds =
  sequence $
    [ aapmsJson v ["entity", "list"]
    , aapmsJson v ["entity", "list", "--type", "character-fragment"]
    , aapmsJson v ["search", "琳達"]
    , aapmsJson v ["search", "織紋刀"]
    , aapmsJson v ["level", "list"]
    , aapmsJson v ["vault", "info"]
    ]
      <> [aapmsJson v ["entity", "show", i] | i <- entityIds]
      <> [aapmsJson v ["link", "list", i] | i <- entityIds]
      <> [aapmsJson v ["level", "show", l] | l <- levelIds]

spec :: Spec
spec = describe "索引等價" $
  it "rm index.db → index rebuild 後,全部查詢結果與刪除前相同" $ withVault $ \v -> do
    -- 建一個小而完整的圖:三個 Entity(含片段、別名、標籤)、兩條關聯、一份 Level 與子節點
    linda <- newEntity v ["--type", "character-fragment", "--title", "琳達", "--summary", "主角", "--alias", "小琳", "--tag", "主角"]
    motive <- aapmsJson v ["entity", "add", "琳達", "--title", "動機", "--summary", "想回家", "--status", "canon"]
    motiveId <- T.unpack <$> jsonText ["data", "anchor"] motive
    blade <- newEntity v ["--type", "item-fragment", "--title", "織紋刀", "--summary", "刻著紋路的刀", "--tag", "武器"]
    lore <- newEntity v ["--type", "lore-fragment", "--title", "崩塌", "--summary", "城市崩塌的那一天", "--timeline", "崩塌前"]
    _ <- aapmsOk v ["link", "add", motiveId, "--kind", "references", "--target", blade]
    _ <- aapmsOk v ["link", "add", lore, "--kind", "involves", "--target", linda, "--note", "她在場"]
    lvl <- aapmsJson v ["level", "new", "--title", "序章", "--root-title", "起點", "--root-kind", "scene"]
    lvlId <- T.unpack <$> jsonText ["data", "level", "id"] lvl
    rootId <- T.unpack <$> jsonText ["data", "level", "root"] lvl
    _ <- aapmsOk v ["node", "add", rootId, "--title", "對話", "--kind", "dialogue"]

    let entityIds = [linda, motiveId, blade, lore]
    before <- snapshot v entityIds [lvlId]

    db <- findIndexDb v
    removeFile db
    _ <- aapmsOk v ["index", "rebuild"]
    after <- snapshot v entityIds [lvlId]

    length after `shouldBe` length before
    _ <- forM (zip3 [1 :: Int ..] before after) $ \(i, b, a) ->
      if a == b
        then pure ()
        else expectationFailure ("第 " <> show i <> " 個查詢在重建後不同:\n重建前 " <> show b <> "\n重建後 " <> show a)
    pure ()
  where
    newEntity v args = do
      env <- aapmsJson v ("entity" : "new" : args)
      T.unpack <$> jsonText ["data", "entity", "id"] env
