-- | T6:'EntityPatch' → 'MetaOverride' 的語意。
--
-- patch 的整個賣點是「沒給的欄位不要動」。這裡把它釘死:'emptyPatch' 疊上去
-- 之後每一欄都還是原樣,逐欄給值之後__只有那一欄__變。
--
-- 節層的 @Nothing@ 代表「繼承檔案層」,所以「不要動」不是「填成目前的值」
-- ——那會把繼承來的欄位偷偷釘死在節上。
module Aapms.Service.TypesSpec (spec) where

import Aapms.Core.Meta (Status (Deprecated), Timeline (..))
import Aapms.Md (MetaOverride (..), emptyOverride)
import Aapms.Service
import Test.Hspec

spec :: Spec
spec = describe "EntityPatch" $ do
  it "emptyPatch 不改任何欄位" $
    patchOverride emptyPatch emptyOverride `shouldBe` emptyOverride

  it "emptyPatch 也不會把既有的覆寫洗掉" $ do
    let ov = emptyOverride {moSummary = Just "原本的總結"}
    patchOverride emptyPatch ov `shouldBe` ov

  it "只給 summary 時只有 summary 變" $ do
    let ov = patchOverride emptyPatch {epSummary = Just "新的總結"} emptyOverride
    moSummary ov `shouldBe` Just "新的總結"
    ov {moSummary = Nothing} `shouldBe` emptyOverride

  it "逐欄給值,各自落在對應的覆寫欄位" $ do
    let tl = Timeline (Just "崩塌前") (Just 3)
        p =
          emptyPatch
            { epSummary = Just "總結"
            , epTags = Just ["外觀"]
            , epStatus = Just Deprecated
            , epTimeline = Just tl
            , epAliases = Just ["小琳"]
            }
        ov = patchOverride p emptyOverride
    moSummary ov `shouldBe` Just "總結"
    moTags ov `shouldBe` Just ["外觀"]
    moStatus ov `shouldBe` Just Deprecated
    moTimeline ov `shouldBe` Just tl
    moAliases ov `shouldBe` Just ["小琳"]

  it "patch 蓋過既有的覆寫" $ do
    let ov = emptyOverride {moSummary = Just "舊的"}
    moSummary (patchOverride emptyPatch {epSummary = Just "新的"} ov)
      `shouldBe` Just "新的"

  it "title 不經過 MetaOverride(它表達不了 title)" $ do
    let ov = patchOverride emptyPatch {epTitle = Just "新標題"} emptyOverride
    ov `shouldBe` emptyOverride
