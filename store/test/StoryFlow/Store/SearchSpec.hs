-- | T11:FTS5 trigram 中文檢索。
--
-- 「以『織紋』命中『織紋刀』」是驗收標準裡明寫的一條,而 trigram 以三字元為
-- 索引單位,二字詞 MATCH 一定不命中(func-0001 已驗證)。這一節因此同時是
-- 「二字詞走 LIKE 掃描」這個補救措施的驗收。
module StoryFlow.Store.SearchSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (renderId)
import StoryFlow.Core.Meta (Meta (..), Status (..))
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Query
import Test.Hspec

spec :: Spec
spec = describe "T11 searchEntities" $ do
  it "以「織紋」命中「織紋刀」(二字詞的子字串檢索)" $
    withSampleIndex $ \_ conn -> do
      hits <- searchEntities conn "織紋" emptyFilter
      map ident hits `shouldContain` ["ent-1001"]

  it "以「埃提亞」命中正文中段的出現(trigram 生效的證明)" $
    withSampleIndex $ \_ conn -> do
      hits <- searchEntities conn "埃提亞" emptyFilter
      -- ent-1002 只有正文提到埃提亞,標題與總結都沒有
      map ident hits `shouldContain` ["ent-1002"]

  it "回傳的片段含命中詞" $
    withSampleIndex $ \_ conn -> do
      hits <- searchEntities conn "埃提亞崩塌" emptyFilter
      let snips = map snd hits
      snips `shouldSatisfy` any (T.isInfixOf "埃提亞崩塌")
      snips `shouldSatisfy` all (not . T.null)

  it "查詢字串裡的 FTS 語法被跳脫為字面" $
    withSampleIndex $ \_ conn -> do
      -- OR / NEAR / * / " 都不該被當成語法,而且不該讓查詢爆掉
      searchEntities conn "織紋 OR 埃提亞" emptyFilter `shouldReturn` []
      searchEntities conn "\"埃提亞\"" emptyFilter `shouldReturn` []
      searchEntities conn "埃提亞*" emptyFilter `shouldReturn` []
      searchEntities conn "NEAR(埃提亞 織紋)" emptyFilter `shouldReturn` []

  it "與 EntityFilter 併用:status = canon 時 draft 片段不出現" $
    withSampleIndex $ \_ conn -> do
      withDraft <- searchEntities conn "埃提亞" emptyFilter
      map ident withDraft `shouldContain` ["ent-c41f"]
      canonOnly <- searchEntities conn "埃提亞" emptyFilter {efStatus = Just Canon}
      map ident canonOnly `shouldNotContain` ["ent-c41f"]
      map (metaStatus . fst) canonOnly `shouldSatisfy` all (== Canon)

  it "二字詞也吃得到 EntityFilter 與 limit" $
    withSampleIndex $ \_ conn -> do
      hits <- searchEntities conn "織紋" emptyFilter {efType = Just "item"}
      map ident hits `shouldBe` ["ent-1001"]
      limited <- searchEntities conn "織紋" emptyFilter {efLimit = Just 1}
      length limited `shouldBe` 1

  it "沒有結果時回空清單而不是錯誤" $
    withSampleIndex $ \_ conn -> do
      searchEntities conn "這串字不存在於任何片段" emptyFilter `shouldReturn` []
      searchEntities conn "" emptyFilter `shouldReturn` []

ident :: (Meta, Text) -> Text
ident = renderId . metaId . fst
