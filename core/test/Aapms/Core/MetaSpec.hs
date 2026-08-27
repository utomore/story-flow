-- | graph-core/F001 T2 的對照測試:統一 Meta 與其列舉的擴充版
-- (Status 加 Missing、Source 加 Scan/Ai、Timeline 改由 Meta 的 Maybe 承載)。
module Aapms.Core.MetaSpec (spec) where

import Data.Time (fromGregorian)
import Aapms.Core.Fixtures (day0, metaOf)
import Aapms.Core.Meta
import Test.Hspec

spec :: Spec
spec = do
  describe "Status —— 擴充成四值(加 Missing)" $ do
    it "四個建構子的 render 與 parse 互為反函式" $
      mapM_
        (\s -> parseStatus (renderStatus s) `shouldBe` Right s)
        [minBound .. maxBound :: Status]

    it "渲染成小寫字串" $
      map renderStatus [Draft, Canon, Deprecated, Missing]
        `shouldBe` ["draft", "canon", "deprecated", "missing"]

    it "不認得的字串回 UnknownStatus" $
      parseStatus "published" `shouldBe` Left (UnknownStatus "published")

  describe "Source —— 擴充成五值(加 Scan/Ai)" $ do
    it "render 與 parse 對五種來源互為反函式" $
      mapM_
        (\s -> parseSource (renderSource s) `shouldBe` Right s)
        [Human, Agent "claude-code", Agent "codex", Workshop "character", Scan, Ai "gpt-5"]

    it "渲染成字串形式" $ do
      renderSource Human `shouldBe` "human"
      renderSource (Agent "claude-code") `shouldBe` "agent:claude-code"
      renderSource (Workshop "character") `shouldBe` "workshop:character"
      renderSource Scan `shouldBe` "scan"
      renderSource (Ai "gpt-5") `shouldBe` "ai:gpt-5"

    it "冒號後為空時視為不合法" $ do
      parseSource "agent:" `shouldBe` Left (BadSource "agent:")
      parseSource "ai:" `shouldBe` Left (BadSource "ai:")

    it "不認得的前綴回 BadSource" $
      parseSource "robot:x" `shouldBe` Left (BadSource "robot:x")

  describe "Timeline —— 型別本身不變,哨兵語意移到 Meta 的 Maybe" $
    it "兩個時間軸各自可建構、欄位可讀" $ do
      tlLabel (Timeline (Just "埃提亞崩塌前") Nothing) `shouldBe` Just "埃提亞崩塌前"
      tlOrder (Timeline Nothing (Just 3)) `shouldBe` Just 3

  describe "bumpRevision" $ do
    it "revision 加一,updated 換成傳入的日期" $ do
      let m = metaOf "ent-7f3a" "琳達"
          today = fromGregorian 2026 9 1
          m' = bumpRevision today m
      metaRevision m `shouldBe` Revision 1
      metaRevision m' `shouldBe` Revision 2
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
      metaRevision m' `shouldBe` Revision 3

  describe "isCanon" $
    it "只對 Canon 為真" $ do
      let m = metaOf "ent-7f3a" "琳達"
      isCanon m {metaStatus = Canon} `shouldBe` True
      isCanon m {metaStatus = Draft} `shouldBe` False
      isCanon m {metaStatus = Deprecated} `shouldBe` False
      isCanon m {metaStatus = Missing} `shouldBe` False

  describe "metaFieldNames" $
    it "涵蓋欄位表的十四個欄位" $
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
