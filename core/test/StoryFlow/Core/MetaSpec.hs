-- | func-0002 T2 的對照測試:統一 Meta 與其列舉。
module StoryFlow.Core.MetaSpec (spec) where

import Data.Time (fromGregorian)
import StoryFlow.Core.Fixtures (day0, metaOf)
import StoryFlow.Core.Meta
import Test.Hspec

spec :: Spec
spec = do
  describe "Status" $ do
    it "三個建構子的 render 與 parse 互為反函式" $
      mapM_
        (\s -> parseStatus (renderStatus s) `shouldBe` Right s)
        [minBound .. maxBound :: Status]

    it "渲染成 architecture.md 用的小寫字串" $
      map renderStatus [Draft, Canon, Deprecated]
        `shouldBe` ["draft", "canon", "deprecated"]

    it "不認得的字串回 UnknownStatus" $
      parseStatus "published" `shouldBe` Left (UnknownStatus "published")

  describe "Source" $ do
    it "render 與 parse 對三種來源互為反函式" $
      mapM_
        (\s -> parseSource (renderSource s) `shouldBe` Right s)
        [Human, Agent "claude-code", Agent "codex", Workshop "character"]

    it "渲染成 architecture.md 的字串形式" $ do
      renderSource Human `shouldBe` "human"
      renderSource (Agent "claude-code") `shouldBe` "agent:claude-code"
      renderSource (Workshop "character") `shouldBe` "workshop:character"

    it "冒號後為空時視為不合法" $
      parseSource "agent:" `shouldBe` Left (BadSource "agent:")

    it "不認得的前綴回 BadSource" $
      parseSource "robot:x" `shouldBe` Left (BadSource "robot:x")

  describe "Timeline" $ do
    it "兩欄皆 Nothing 即為空" $
      isEmptyTimeline emptyTimeline `shouldBe` True

    it "只填標籤也不算空" $
      isEmptyTimeline (Timeline (Just "埃提亞崩塌前") Nothing) `shouldBe` False

    it "只填順序也不算空" $
      isEmptyTimeline (Timeline Nothing (Just 3)) `shouldBe` False

  describe "bumpRevision" $ do
    it "revision 加一,updated 換成傳入的日期" $ do
      let m = metaOf "ent-7f3a" "琳達"
          today = fromGregorian 2026 9 1
          m' = bumpRevision today m
      metaRevision m' `shouldBe` metaRevision m + 1
      metaUpdated m' `shouldBe` today

    it "不動 created,也不動其他欄位" $ do
      let m = metaOf "ent-7f3a" "琳達"
          m' = bumpRevision (fromGregorian 2026 9 1) m
      metaCreated m' `shouldBe` day0
      metaId m' `shouldBe` metaId m
      metaTitle m' `shouldBe` metaTitle m

    it "連續呼叫兩次得 +2" $ do
      let m = metaOf "ent-7f3a" "琳達"
          m' = bumpRevision day0 (bumpRevision day0 m)
      metaRevision m' `shouldBe` metaRevision m + 2

  describe "isCanon" $ do
    it "只對 Canon 為真" $ do
      let m = metaOf "ent-7f3a" "琳達"
      isCanon m {metaStatus = Canon} `shouldBe` True
      isCanon m {metaStatus = Draft} `shouldBe` False
      isCanon m {metaStatus = Deprecated} `shouldBe` False

  describe "metaFieldNames" $ do
    it "涵蓋 architecture.md 欄位表的十四個欄位" $
      metaFieldNames
        `shouldBe` [ "id"
                   , "vault"
                   , "type"
                   , "title"
                   , "summary"
                   , "tags"
                   , "status"
                   , "timeline"
                   , "aliases"
                   , "links"
                   , "source"
                   , "revision"
                   , "created"
                   , "updated"
                   ]
