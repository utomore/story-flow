-- | lawful 測試:P-029-scope-resolve(qa 填入)。
--
-- 每條 law 一個 @describe "P-029#LAW-n"@ 的 property,每個 example 一個
-- @describe "P-029#EX-n"@。全部斷言都跑在 'Aapms.Workspace.Effect.Markers' 的
-- 純解譯器上('simulateScope'),__一行 IO 都沒有__。
--
-- 產生器只用 types 層的建構入口('mkHub'、'VaultEntry' \/ 'VaultMarker' \/
-- 'MarkerWorld' 的建構子)組值,尺寸全部有上限(vault ≤ 5、refs ⊆ 六個 id 的池、
-- 名稱與路徑取自固定池),每個項目另有 60 秒逾時。
--
-- __世界的合法性__(qa 自己決定,見回報):'MarkerWorld' 沒有 smart constructor,
-- 但 LAW-9 只拿 'worldMarker' 判「該不該降級」,而 @refOfEntry@ 依契約先看路徑在
-- 不在。兩者要對得起來,世界就必須滿足「路徑不是既存目錄 ⇒ 那個路徑的 marker 讀
-- 不到」。本模組的產生器與 example 的世界一律滿足這一條。
module Aapms.Lawful.P029Spec (spec) where

import Control.Exception (evaluate)
import Data.Either (isLeft, isRight)
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified System.Timeout as Timeout

import Test.Hspec
import Test.Hspec.Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import qualified TOML

import Aapms.Core.Id (Id, VaultId (..), parseId)
import Aapms.Store.Types (StoreError (..), VaultKind (..), VaultMarker (..))
import Aapms.Workspace.Effect.Markers (detectRoot)
import Aapms.Workspace.Resolve
  ( lookupSelector
  , refOfEntry
  , resolveScope
  , scopePipeline
  , scopeRead
  , scopeWrite
  )
import Aapms.Workspace.Resolve.Internal
  ( nearestRoot
  , reachable
  , readableIds
  , simulateScope
  )
import Aapms.Workspace.Types
  ( Hub
  , LlmSection (..)
  , MarkerWorld (..)
  , PipelineScope (..)
  , ProjectEntry (..)
  , ReadScope (..)
  , Scope
  , ScopeIssue (..)
  , ScopeKind (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , VaultRef (..)
  , WorkspaceError (..)
  , WriteScope (..)
  , hubVaults
  , isRefNotRegistered
  , mkHub
  , refIds
  , scopeIssues
  , scopeRefs
  , selectorHits
  , worldMarker
  )

-- 進入點 ---------------------------------------------------------------------

spec :: Spec
spec = modifyMaxSuccess (const 100) $ around_ withItemTimeout $ do
  lawsSpec
  examplesSpec

-- | 整個模組的逾時上限:每個項目 60 秒。產生器的尺寸全部有界,正常情況遠低於此。
withItemTimeout :: IO () -> IO ()
withItemTimeout act = do
  r <- Timeout.timeout itemTimeoutMicros act
  case r of
    Just () -> pure ()
    Nothing ->
      expectationFailure
        ("P-029 測試項目超過 " <> show (itemTimeoutMicros `div` 1000000) <> " 秒未結束")

itemTimeoutMicros :: Int
itemTimeoutMicros = 60 * 1000 * 1000

--------------------------------------------------------------------------------
-- Laws
--------------------------------------------------------------------------------

lawsSpec :: Spec
lawsSpec = do
  describe "P-029#LAW-1" $
    it "invariant:三種 scope 的 vault 清單以 marker id 保序去重" $
      hedgehog $ do
        s <- forAll genScenarioOk
        k <- forAll genScopeKind
        sel <- forAll (genGoodSel s)
        start <- forAll (genOkStart s)
        let w = scWorld s
            h = scHub s
            r = simulateScope w (resolveScope h k sel start) :: Either WorkspaceError Scope
        cover 20 "裁決解得開" (isRight r)
        case r of
          Left _ -> success
          Right sc -> nub (refIds (scopeRefs sc)) === refIds (scopeRefs sc)

  describe "P-029#LAW-2" $
    it "relation:清單裡每個 ref 的 marker 逐欄等於世界裡那個路徑的讀數" $
      hedgehog $ do
        s <- forAll genScenarioOk
        k <- forAll genScopeKind
        sel <- forAll (genGoodSel s)
        start <- forAll (genOkStart s)
        let w = scWorld s
            h = scHub s
            r = simulateScope w (resolveScope h k sel start) :: Either WorkspaceError Scope
        cover 20 "裁決解得開" (isRight r)
        case r of
          Left _ -> success
          Right sc -> do
            annotateShow (scopeIssues sc)
            mapM_
              (\ref -> worldMarker w (vrPath ref) === Just (Right (vrMarker ref)))
              (scopeRefs sc)

  describe "P-029#LAW-3" $
    it "relation:selector 先比 id 再比 name,id 命中時 name 不算數" $
      hedgehog $ do
        s <- forAll genScenario
        let h = scHub s
        e <- forAll (Gen.element (hubVaults h))
        let sel = idText (veId e)
        -- given:e 在中樞裡、且它的 id 就是 sel(產生器直接建構,不過濾)。
        assert (e `elem` hubVaults h)
        veId e === VaultId sel
        annotateShow (lookupSelector h sel)
        assert (either (const True) ((== VaultId sel) . veId) (lookupSelector h sel))

  describe "P-029#LAW-4" $
    it "relation:命中集合恰一個回它、兩個以上回 Ambiguous 並逐列列出、都沒有回 NotFound" $
      hedgehog $ do
        s <- forAll genScenario
        sel <- forAll (genAnySelText s)
        let h = scHub s
            hits = selectorHits h sel
        annotateShow hits
        annotateShow (lookupSelector h sel)
        assert ((length hits == 0) == (lookupSelector h sel == Left (VaultSelectorNotFound sel)))
        assert ((length hits == 1) == (lookupSelector h sel == Right (head hits)))
        assert ((length hits >= 2) == (lookupSelector h sel == Left (VaultSelectorAmbiguous sel hits)))

  describe "P-029#LAW-5" $
    it "invariant:selector 逐字精確,結果裡的列 id 字串或 name 逐字等於 s" $
      hedgehog $ do
        s <- forAll genScenario
        sel <- forAll (genAnySelText s)
        let r = lookupSelector (scHub s) sel
        cover 20 "selector 解得開" (isRight r)
        case r of
          Left _ -> success
          Right e -> assert (veId e == VaultId sel || veName e == sel)

  describe "P-029#LAW-6" $
    it "relation:selector 只看 [[vaults]],換掉 projects / llm / tools / 原文結果不變" $
      hedgehog $ do
        slots <- forAll (genSlots Nothing)
        sel <- forAll (genAnySelText (scenarioOf slots))
        let vs = map entryOf slots
            h = mkHub vs [] Nothing (ToolsConfig Nothing) ""
            h2 =
              mkHub
                vs
                [ProjectEntry samplePid "Circle" "D:/games/Circle"]
                (Just (LlmSection (M.fromList [("model", TOML.String "claude")])))
                (ToolsConfig (Just "C:/Program Files/7-Zip/7z.exe"))
                "# 完全不同的底稿\n"
        -- given:兩個中樞的 [[vaults]] 逐欄相同(產生器直接建構)。
        assert (hubVaults h == hubVaults h2)
        lookupSelector h sel === lookupSelector h2 sel

  describe "P-029#LAW-7" $
    it "equiv:向上探測命中最近一層,到根都沒有就是 Nothing" $
      hedgehog $ do
        s <- forAll genScenario
        d <- forAll (genAnyStart s)
        let w = scWorld s
        simulateScope w (detectRoot d) === nearestRoot w d

  describe "P-029#LAW-8" $
    it "identity:探測命中的那一層自己再探測還是它" $
      hedgehog $ do
        s <- forAll genScenario
        d <- forAll (genAnyStart s)
        let w = scWorld s
            r = simulateScope w (detectRoot d)
        cover 20 "探測命中" (isJust r)
        case r of
          Nothing -> success
          Just p -> simulateScope w (detectRoot p) === Just p

  describe "P-029#LAW-9" $
    it "relation:重讀 marker 的三種降級互斥且依序,路徑不見、marker 壞、id 漂移" $
      hedgehog $ do
        s <- forAll genScenario
        e <- forAll (genAnyEntry s)
        let w = scWorld s
            r = simulateScope w (refOfEntry e)
        annotateShow r
        annotateShow (worldMarker w (vePath e))
        assert (either (const True) ((== veId e) . vmId . vrMarker) r)
        isLeft r === maybe True (either (const True) ((/= veId e) . vmId)) (worldMarker w (vePath e))

  describe "P-029#LAW-10" $
    it "relation:無 selector 的讀取範圍是中樞順序下讀得到且 id 相符的列,與起點無關" $
      hedgehog $ do
        s <- forAll genScenario
        start <- forAll (genAnyStart s)
        start2 <- forAll (genAnyStart s)
        let w = scWorld s
            h = scHub s
            r = simulateScope w (scopeRead h Nothing)
        cover 40 "無 selector 的讀取範圍解得開" (isRight r)
        case r of
          Left _ -> success
          Right rs -> do
            refIds (rsVaults rs) === readableIds w h
            simulateScope w (resolveScope h ForRead Nothing start)
              === simulateScope w (resolveScope h ForRead Nothing start2)
            assert (all (not . isRefNotRegistered) (rsIssues rs))

  describe "P-029#LAW-11" $
    it "equiv:有 selector 的讀取範圍是種子沿 refs 的遞移閉包,BFS 首次入隊序" $
      hedgehog $ do
        s <- forAll genScenarioOk
        let w = scWorld s
            h = scHub s
            sel = idText (slotId (firstSlot s))
        e <- expectRight "lookupSelector 對第一格的 id" (lookupSelector h sel)
        -- given:isRight (simulateScope w (refOfEntry e))(產生器把第一格建成可讀)。
        seedRef <- expectRight "refOfEntry(前提)" (simulateScope w (refOfEntry e))
        annotateShow seedRef
        rs <- expectRight "scopeRead" (simulateScope w (scopeRead h (Just sel)))
        refIds (rsVaults rs) === reachable w h (veId e)

  describe "P-029#LAW-12" $
    it "relation:selector 解不開就是硬錯,原樣透傳" $
      hedgehog $ do
        s <- forAll genScenario
        sel <- forAll (genLeftSelText s)
        let w = scWorld s
            h = scHub s
        -- given:isLeft (lookupSelector h sel)(產生器直接建構)。
        annotateShow (lookupSelector h sel)
        assert (isLeft (lookupSelector h sel))
        fmap (const ()) (simulateScope w (scopeRead h (Just sel)))
          === fmap (const ()) (lookupSelector h sel)

  describe "P-029#LAW-13" $
    it "relation:種子自己不可達仍是 Right,空清單、恰好那一則 issue、不展開" $
      hedgehog $ do
        s <- forAll (Gen.element [SMissing, SBroken, SDrift] >>= genScenarioWith)
        let w = scWorld s
            h = scHub s
            sel = idText (slotId (firstSlot s))
        e <- expectRight "lookupSelector 對第一格的 id" (lookupSelector h sel)
        iss <- expectLeft "refOfEntry(前提:種子不可達)" (simulateScope w (refOfEntry e))
        simulateScope w (scopeRead h (Just sel)) === Right (ReadScope [] [iss])

  describe "P-029#LAW-14" $
    it "relation:寫入目標恒不來自 refs,有 selector 是它命中的列,沒有是探測命中那一層" $
      hedgehog $ do
        s <- forAll genScenarioOk
        start <- forAll (genOkStart s)
        let w = scWorld s
            h = scHub s
            sel = idText (slotId (firstSlot s))
        e <- expectRight "lookupSelector" (lookupSelector h sel)
        ws <- expectRight "scopeWrite(有 selector)" (simulateScope w (scopeWrite h (Just sel) start))
        ws2 <- expectRight "scopeWrite(無 selector)" (simulateScope w (scopeWrite h Nothing start))
        p <- expectJust "nearestRoot(起點在第一格底下)" (nearestRoot w start)
        m <- expectReadable "探測到的根的 marker" (worldMarker w p)
        vmId (vrMarker (wsTarget ws)) === veId e
        vmId (vrMarker (wsTarget ws2)) === vmId m

  describe "P-029#LAW-15" $
    it "relation:寫入的讀取範圍是目標排第一,其餘與對同一個種子做讀取展開相同" $
      hedgehog $ do
        s <- forAll genScenarioOk
        start <- forAll (genOkStart s)
        sel <- forAll (Gen.element [Nothing, Just (idText (slotId (firstSlot s)))])
        let w = scWorld s
            h = scHub s
        ws <- expectRight "scopeWrite" (simulateScope w (scopeWrite h sel start))
        head (refIds (wsRead ws)) === vmId (vrMarker (wsTarget ws))
        refIds (wsRead ws) === reachable w h (vmId (vrMarker (wsTarget ws)))

  describe "P-029#LAW-16" $
    it "relation:沒有 selector 且探測不到就是 NoWriteTarget,帶起點" $
      hedgehog $ do
        s <- forAll genScenario
        start <- forAll (Gen.element ["T2", "T2/x"])
        let w = scWorld s
            h = scHub s
        -- given:isNothing (nearestRoot w start)(產生器只挑沒有 .aapms 祖先的起點)。
        assert (isNothing (nearestRoot w start))
        simulateScope w (scopeWrite h Nothing start) === Left (NoWriteTarget start)

  describe "P-029#LAW-17" $
    it "relation:寫入目標的 marker 讀不到是硬錯 MarkerUnreadable,不是降級" $
      hedgehog $ do
        s <- forAll (Gen.element [SMissing, SBroken] >>= genScenarioWith)
        start <- forAll (genAnyStart s)
        let w = scWorld s
            h = scHub s
            sel = idText (slotId (firstSlot s))
        e <- expectRight "lookupSelector 對第一格的 id" (lookupSelector h sel)
        err <- expectUnreadable "第一格的 marker 讀數(前提)" (worldMarker w (vePath e))
        simulateScope w (scopeWrite h (Just sel) start)
          === Left (MarkerUnreadable (vePath e) err)

  describe "P-029#LAW-18" $
    it "relation:探測命中一個中樞沒有的 vault 仍可寫,vrEntry 是 Nothing 且它排第一" $
      hedgehog $ do
        s <- forAll genScenario
        start <- forAll (Gen.element [unregPath, unregPath <> "/x"])
        let w = scWorld s
            h = scHub s
        p <- expectJust "nearestRoot(未註冊的 vault 根)" (nearestRoot w start)
        m <- expectReadable "未註冊 vault 的 marker" (worldMarker w p)
        -- given:notElem (vmId m) (map veId (hubVaults h))(產生器讓它永不進中樞)。
        assert (notElem (vmId m) (map veId (hubVaults h)))
        ws <- expectRight "scopeWrite" (simulateScope w (scopeWrite h Nothing start))
        vrEntry (wsTarget ws) === Nothing
        head (refIds (wsRead ws)) === vmId m

  describe "P-029#LAW-19" $
    it "invariant:selector 勝過探測,有 selector 時結果與起點無關" $
      hedgehog $ do
        s <- forAll genScenario
        sel <- forAll (genAnySelText s)
        start <- forAll (genAnyStart s)
        start2 <- forAll (genAnyStart s)
        let w = scWorld s
            h = scHub s
        simulateScope w (scopeWrite h (Just sel) start)
          === simulateScope w (scopeWrite h (Just sel) start2)

  describe "P-029#LAW-20" $
    it "relation:無 selector 的管線範圍是讀取範圍裡 kind 相符的,issues 逐欄相同" $
      hedgehog $ do
        s <- forAll genScenario
        k <- forAll genKind
        let w = scWorld s
            h = scHub s
            rp = simulateScope w (scopePipeline h k Nothing)
            rr = simulateScope w (scopeRead h Nothing)
        cover 40 "兩種範圍都解得開" (isRight rp && isRight rr)
        case (rp, rr) of
          (Right ps, Right rs) -> do
            psRuns ps === filter ((== k) . vmKind . vrMarker) (rsVaults rs)
            psIssues ps === rsIssues rs
          _ -> success

  describe "P-029#LAW-21" $
    it "relation:有 selector 的管線範圍恰好一個不展開,kind 不符回 VaultKindMismatch" $
      hedgehog $ do
        s <- forAll genScenarioOk
        k <- forAll genKind
        let w = scWorld s
            h = scHub s
            sel = idText (slotId (firstSlot s))
        e <- expectRight "lookupSelector 對第一格的 id" (lookupSelector h sel)
        r <- expectRight "refOfEntry(前提)" (simulateScope w (refOfEntry e))
        annotateShow (simulateScope w (scopePipeline h k (Just sel)))
        assert
          ( (vmKind (vrMarker r) == k)
              `implies` (simulateScope w (scopePipeline h k (Just sel)) == Right (PipelineScope [r] []))
          )
        assert
          ( (vmKind (vrMarker r) /= k)
              `implies` ( simulateScope w (scopePipeline h k (Just sel))
                            == Left (VaultKindMismatch (vmId (vrMarker r)) k (vmKind (vrMarker r)))
                        )
          )

  describe "P-029#LAW-22" $
    it "relation:有 selector 但不可達,管線範圍是 Right 加一則 issue,不是 VaultKindMismatch" $
      hedgehog $ do
        s <- forAll (Gen.element [SMissing, SBroken, SDrift] >>= genScenarioWith)
        k <- forAll genKind
        let w = scWorld s
            h = scHub s
            sel = idText (slotId (firstSlot s))
        e <- expectRight "lookupSelector 對第一格的 id" (lookupSelector h sel)
        iss <- expectLeft "refOfEntry(前提:種子不可達)" (simulateScope w (refOfEntry e))
        simulateScope w (scopePipeline h k (Just sel)) === Right (PipelineScope [] [iss])

  describe "P-029#LAW-23" $
    it "invariant:未註冊的 refs 目標降級為一則 RefVaultNotRegistered,同一個目標只一則" $
      hedgehog $ do
        s <- forAll genScenario
        sel <- forAll (genAnySelText s)
        let w = scWorld s
            h = scHub s
            r = simulateScope w (scopeRead h (Just sel))
        cover 20 "有 selector 的讀取範圍解得開" (isRight r)
        case r of
          Left _ -> success
          Right rs -> do
            annotateShow (rsIssues rs)
            let bad = filter isRefNotRegistered (rsIssues rs)
            nub bad === bad

  describe "P-029#LAW-24" $
    it "invariant:不判 ATTACH 上限,讀得到幾個就回幾個,沒有數量相關的錯誤" $
      hedgehog $ do
        s <- forAll genScenario
        let w = scWorld s
            h = scHub s
            r = simulateScope w (scopeRead h Nothing)
        annotateShow r
        assert (isRight r)
        length (readableIds w h)
          === length (maybe [] rsVaults (either (const Nothing) Just r))

  describe "P-029#LAW-25" $
    it "total:對任何世界與輸入裁決都有值、都終止" $
      hedgehog $ do
        s <- forAll genWildScenario
        k <- forAll genScopeKind
        sel <- forAll (genAnySel s)
        start <- forAll (genAnyStart s)
        -- total:求值到正規形不拋例外(show 走遍整個結構)。
        n <-
          evalIO
            (evaluate (length (show (simulateScope (scWorld s) (resolveScope (scHub s) k sel start)))))
        assert (n >= 0)

--------------------------------------------------------------------------------
-- Examples
--------------------------------------------------------------------------------

examplesSpec :: Spec
examplesSpec = do
  describe "P-029#EX-1" $
    it "中樞 A B C D M(壞) P(不見) Z(漂移),無 selector 的讀取範圍只留前四個" $
      case simulateScope exWorld (scopeRead exHub Nothing) of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right rs -> do
          refIds (rsVaults rs) `shouldBe` [idA, idB, idC, idD]
          rsIssues rs
            `shouldBe` [ VaultMarkerBroken eM errM
                       , VaultPathMissing eP "T/p"
                       , VaultIdDrift eZ idDrift
                       ]

  describe "P-029#EX-2" $
    it "A → B → C → A 成環,展開仍終止且不重複" $
      case simulateScope cycWorld (scopeRead cycHub (Just "a")) of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right rs -> do
          refIds (rsVaults rs) `shouldBe` [idA, idB, idC]
          rsIssues rs `shouldBe` []

  describe "P-029#EX-3" $
    it "菱形 A → B C、B → D、C → D,D 只出現一次" $
      case simulateScope diaWorld (scopeRead diaHub (Just "a")) of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right rs -> refIds (rsVaults rs) `shouldBe` [idA, idB, idC, idD]

  describe "P-029#EX-4" $
    it "用 id 與用 name 查同一列,結果逐欄相同" $
      simulateScope exWorld (scopeRead exHub (Just (idText idA)))
        `shouldBe` simulateScope exWorld (scopeRead exHub (Just "a"))

  describe "P-029#EX-5" $ do
    it "兩列同名 dup 是 Ambiguous 並列出兩列" $
      lookupSelector dupHub "dup"
        `shouldBe` Left (VaultSelectorAmbiguous "dup" [dupEntry1, dupEntry2])
    it "前置空白的「 dup」是 NotFound(不 trim)" $
      lookupSelector dupHub " dup" `shouldBe` Left (VaultSelectorNotFound " dup")
    it "大寫的 DUP 是 NotFound(不忽略大小寫)" $
      lookupSelector dupHub "DUP" `shouldBe` Left (VaultSelectorNotFound "DUP")

  describe "P-029#EX-6" $
    it "換掉 projects / llm / tools / 原文,同一個 selector 結果不變" $
      mapM_
        (\sel -> lookupSelector exHub sel `shouldBe` lookupSelector exHubOtherSections sel)
        ["a", "b", idText idA, "nope", "z"]

  describe "P-029#EX-7" $ do
    it "T/a/.aapms 與 T/a/deep/.aapms 都在時,深處的起點命中最近一層" $
      simulateScope probeWorld (detectRoot "T/a/deep/deeper") `shouldBe` Just "T/a/deep"
    it "沒有任何 .aapms 祖先的起點是 Nothing" $
      simulateScope probeWorld (detectRoot "T2") `shouldBe` Nothing
    it "命中的那一層自己再探測還是它" $
      simulateScope probeWorld (detectRoot "T/a/deep") `shouldBe` Just "T/a/deep"

  describe "P-029#EX-8" $
    it "selector 比不到任何列是 VaultSelectorNotFound,不是空範圍" $
      simulateScope exWorld (scopeRead exHub (Just "nope"))
        `shouldBe` Left (VaultSelectorNotFound "nope")

  describe "P-029#EX-9" $
    it "種子的 marker 壞掉仍是 Right:空清單加一則降級" $
      simulateScope exWorld (scopeRead exHub (Just "m"))
        `shouldBe` Right (ReadScope [] [VaultMarkerBroken eM errM])

  describe "P-029#EX-10" $
    it "無 selector 從 T/a/deep/deeper 寫入,目標是 A,讀取範圍依序 A B C" $
      case simulateScope exWorld (scopeWrite exHub Nothing "T/a/deep/deeper") of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right ws -> do
          vmId (vrMarker (wsTarget ws)) `shouldBe` idA
          refIds (wsRead ws) `shouldBe` [idA, idB, idC]
          wsIssues ws `shouldBe` []

  describe "P-029#EX-11" $
    it "無 selector 且探測不到,是 NoWriteTarget 帶起點" $
      simulateScope exWorld (scopeWrite exHub Nothing "T2")
        `shouldBe` Left (NoWriteTarget "T2")

  describe "P-029#EX-12" $
    it "selector 指到 marker 讀不到的那一列,寫入是硬錯 MarkerUnreadable" $
      simulateScope exWorld (scopeWrite exHub (Just "p") "T/a")
        `shouldBe` Left (MarkerUnreadable "T/p" errP)

  describe "P-029#EX-13" $
    it "探測命中一個中樞沒有的 vault 仍可寫,vrEntry 是 Nothing 且它排第一" $
      case simulateScope exWorld (scopeWrite exHub Nothing "T/e/x") of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right ws -> do
          vrEntry (wsTarget ws) `shouldBe` Nothing
          head (refIds (wsRead ws)) `shouldBe` idE

  describe "P-029#EX-14" $ do
    it "有 selector 時換起點結果逐欄相同" $
      simulateScope exWorld (scopeWrite exHub (Just "b") "T/a/deep")
        `shouldBe` simulateScope exWorld (scopeWrite exHub (Just "b") "T2")
    it "目標是 B,A 只以唯讀身分經 refs 進來" $
      case simulateScope exWorld (scopeWrite exHub (Just "b") "T/a/deep") of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right ws -> do
          vmId (vrMarker (wsTarget ws)) `shouldBe` idB
          refIds (wsRead ws) `shouldBe` [idB, idA, idC]

  describe "P-029#EX-15" $
    it "無 selector 的管線範圍只留 kind 相符的 A C D,issues 與 EX-1 相同" $
      case simulateScope exWorld (scopePipeline exHub AssetVault Nothing) of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right ps -> do
          refIds (psRuns ps) `shouldBe` [idA, idC, idD]
          psIssues ps
            `shouldBe` [ VaultMarkerBroken eM errM
                       , VaultPathMissing eP "T/p"
                       , VaultIdDrift eZ idDrift
                       ]

  describe "P-029#EX-16" $ do
    it "kind 相符的 selector 回恰好一個、不展開" $
      simulateScope exWorld (scopePipeline exHub AssetVault (Just "a"))
        `shouldBe` Right (PipelineScope [refA] [])
    it "kind 不符回 VaultKindMismatch 三個值" $
      simulateScope exWorld (scopePipeline exHub AssetVault (Just "b"))
        `shouldBe` Left (VaultKindMismatch idB AssetVault StoryVault)
    it "種子不可達是 Right 加一則 issue,不是 VaultKindMismatch" $
      simulateScope exWorld (scopePipeline exHub AssetVault (Just "m"))
        `shouldBe` Right (PipelineScope [] [VaultMarkerBroken eM errM])

  describe "P-029#EX-17" $
    it "兩個來源都指同一個未註冊的 refs 目標,issues 只有一則" $
      case simulateScope unregWorld (scopeRead unregHub (Just "a")) of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right rs -> do
          refIds (rsVaults rs) `shouldBe` [idA, idB]
          filter isRefNotRegistered (rsIssues rs)
            `shouldBe` [RefVaultNotRegistered idA missingRefId]

  describe "P-029#EX-18" $
    it "11 個都讀得到的 vault:Right、長度 11、沒有錯誤" $
      case simulateScope elevenWorld (scopeRead elevenHub Nothing) of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right rs -> do
          length (rsVaults rs) `shouldBe` 11
          rsIssues rs `shouldBe` []

  describe "P-029#EX-19" $
    it "任意亂造的世界與中樞:求值到底不拋例外、終止" $
      mapM_
        ( \(w, h, k, sel, start) -> do
            n <- evaluate (length (show (simulateScope w (resolveScope h k sel start))))
            n `shouldSatisfy` (>= (0 :: Int))
        )
        chaosCases

--------------------------------------------------------------------------------
-- Example 的固定值
--------------------------------------------------------------------------------

idA, idB, idC, idD, idM, idP, idZ, idDrift, idE, missingRefId :: VaultId
idA = VaultId "vlt-aaaa1111"
idB = VaultId "vlt-bbbb2222"
idC = VaultId "vlt-cccc3333"
idD = VaultId "vlt-dddd4444"
idM = VaultId "vlt-ee005555"
idP = VaultId "vlt-ff006666"
idZ = VaultId "vlt-0a0a7777"
idDrift = VaultId "vlt-99998888"
idE = VaultId "vlt-eeee0000"
missingRefId = VaultId "vlt-ffff0000"

eA, eB, eC, eD, eM, eP, eZ :: VaultEntry
eA = VaultEntry idA "a" AssetVault "T/a"
eB = VaultEntry idB "b" StoryVault "T/b"
eC = VaultEntry idC "c" AssetVault "T/c"
eD = VaultEntry idD "d" AssetVault "T/d"
eM = VaultEntry idM "m" AssetVault "T/m"
eP = VaultEntry idP "p" AssetVault "T/p"
eZ = VaultEntry idZ "z" AssetVault "T/z"

errM, errP :: StoreError
errM = VaultMarkerInvalid "T/m" "marker 的 id 欄位不合法"
errP = VaultMarkerMissing "T/p"

mA, mB, mC, mD, mZ, mE :: VaultMarker
mA = VaultMarker idA AssetVault "a" [idB]
mB = VaultMarker idB StoryVault "b" [idA, idC]
mC = VaultMarker idC AssetVault "c" []
mD = VaultMarker idD AssetVault "d" []
mZ = VaultMarker idDrift AssetVault "z" []
mE = VaultMarker idE AssetVault "e" []

refA :: VaultRef
refA = VaultRef (Just eA) "T/a" mA

-- | EX-1 \/ EX-4 \/ EX-8..EX-16 共用的世界。
--
-- 「路徑不是既存目錄 ⇒ marker 讀不到」:@T\/p@ 不在 'worldDirs' 裡,它的 marker
-- 讀數是 @Left@(EX-1 因此是 'VaultPathMissing',EX-12 的寫入目標則是硬錯)。
exWorld :: MarkerWorld
exWorld =
  MarkerWorld
    { mwMarkers =
        M.fromList
          [ ("T/a", Right mA)
          , ("T/b", Right mB)
          , ("T/c", Right mC)
          , ("T/d", Right mD)
          , ("T/m", Left errM)
          , ("T/p", Left errP)
          , ("T/z", Right mZ)
          , ("T/e", Right mE)
          ]
    , worldDirs =
        [ "T"
        , "T2"
        , "T/a"
        , "T/a/.aapms"
        , "T/a/deep"
        , "T/a/deep/deeper"
        , "T/b"
        , "T/b/.aapms"
        , "T/b/deep"
        , "T/c"
        , "T/c/.aapms"
        , "T/d"
        , "T/d/.aapms"
        , "T/m"
        , "T/m/.aapms"
        , "T/z"
        , "T/z/.aapms"
        , "T/e"
        , "T/e/.aapms"
        , "T/e/x"
        ]
    }

exHub :: Hub
exHub = mkHub [eA, eB, eC, eD, eM, eP, eZ] [] Nothing (ToolsConfig Nothing) ""

-- | EX-6:同一批 @[[vaults]]@,其餘三段與底稿全部換掉。
exHubOtherSections :: Hub
exHubOtherSections =
  mkHub
    [eA, eB, eC, eD, eM, eP, eZ]
    [ProjectEntry samplePid "Circle" "D:/games/Circle"]
    (Just (LlmSection (M.fromList [("model", TOML.String "claude")])))
    (ToolsConfig (Just "C:/Program Files/7-Zip/7z.exe"))
    "# 完全不同的底稿\n"

-- | EX-2:A → B → C → A。
cycWorld :: MarkerWorld
cycWorld = threeVaultWorld [idB] [idC] [idA]

cycHub :: Hub
cycHub = mkHub [eA, eB', eC] [] Nothing (ToolsConfig Nothing) ""
  where
    eB' = VaultEntry idB "b" AssetVault "T/b"

-- | EX-3:菱形 A → B、C;B → D;C → D。
diaWorld :: MarkerWorld
diaWorld =
  MarkerWorld
    { mwMarkers =
        M.fromList
          [ ("T/a", Right (VaultMarker idA AssetVault "a" [idB, idC]))
          , ("T/b", Right (VaultMarker idB AssetVault "b" [idD]))
          , ("T/c", Right (VaultMarker idC AssetVault "c" [idD]))
          , ("T/d", Right (VaultMarker idD AssetVault "d" []))
          ]
    , worldDirs = "T" : concatMap markerDirPair ["T/a", "T/b", "T/c", "T/d"]
    }

diaHub :: Hub
diaHub =
  mkHub
    [eA, VaultEntry idB "b" AssetVault "T/b", eC, eD]
    []
    Nothing
    (ToolsConfig Nothing)
    ""

-- | EX-17:A 的 refs 指 B 與一個未註冊的 id,B 也指同一個未註冊的 id。
unregWorld :: MarkerWorld
unregWorld =
  MarkerWorld
    { mwMarkers =
        M.fromList
          [ ("T/a", Right (VaultMarker idA AssetVault "a" [idB, missingRefId]))
          , ("T/b", Right (VaultMarker idB AssetVault "b" [missingRefId]))
          ]
    , worldDirs = "T" : concatMap markerDirPair ["T/a", "T/b"]
    }

unregHub :: Hub
unregHub =
  mkHub [eA, VaultEntry idB "b" AssetVault "T/b"] [] Nothing (ToolsConfig Nothing) ""

-- | EX-18:11 個都讀得到的 vault。
elevenIds :: [VaultId]
elevenIds = map (\c -> VaultId (T.pack ("vlt-0000000" <> [c]))) "0123456789a"

elevenEntries :: [VaultEntry]
elevenEntries =
  [ VaultEntry v (T.pack ("v" <> show i)) AssetVault ("T/w" <> show i)
  | (i, v) <- zip [(0 :: Int) ..] elevenIds
  ]

elevenWorld :: MarkerWorld
elevenWorld =
  MarkerWorld
    { mwMarkers =
        M.fromList
          [ (vePath e, Right (VaultMarker (veId e) AssetVault (veName e) []))
          | e <- elevenEntries
          ]
    , worldDirs = "T" : concatMap (markerDirPair . vePath) elevenEntries
    }

elevenHub :: Hub
elevenHub = mkHub elevenEntries [] Nothing (ToolsConfig Nothing) ""

-- | EX-5:兩列同名。
dupEntry1, dupEntry2 :: VaultEntry
dupEntry1 = VaultEntry idA "dup" AssetVault "T/a"
dupEntry2 = VaultEntry idB "dup" StoryVault "T/b"

dupHub :: Hub
dupHub = mkHub [dupEntry1, dupEntry2] [] Nothing (ToolsConfig Nothing) ""

-- | EX-7:@T\/a@ 與 @T\/a\/deep@ 都是 vault 根。
probeWorld :: MarkerWorld
probeWorld =
  MarkerWorld
    { mwMarkers =
        M.fromList
          [ ("T/a", Right mA)
          , ("T/a/deep", Right (VaultMarker idB AssetVault "deep" []))
          ]
    , worldDirs =
        ["T", "T2", "T/a", "T/a/.aapms", "T/a/deep", "T/a/deep/.aapms", "T/a/deep/deeper"]
    }

-- | EX-19:亂造的世界與中樞。
chaosCases :: [(MarkerWorld, Hub, ScopeKind, Maybe Text, FilePath)]
chaosCases =
  [ (mempty, mkHub [] [] Nothing (ToolsConfig Nothing) "", ForRead, Nothing, "")
  , (mempty, exHub, ForWrite, Just "a", "T/a/deep")
  , (exWorld, mkHub [] [] Nothing (ToolsConfig Nothing) "", ForWrite, Nothing, "T/e/x")
  , (exWorld, exHub, ForPipeline StoryVault, Just "", "")
  , (exWorld, exHub, ForWrite, Just "dup", "T2/x")
  , (cycWorld, exHub, ForRead, Just (idText idDrift), "T/a")
  , (unregWorld, unregHub, ForPipeline AssetVault, Just "b", "T/b/deep")
  , (probeWorld, elevenHub, ForWrite, Nothing, "T/a/deep/deeper")
  ]

-- | 三個 vault、refs 由參數給的世界。
threeVaultWorld :: [VaultId] -> [VaultId] -> [VaultId] -> MarkerWorld
threeVaultWorld ra rb rc =
  MarkerWorld
    { mwMarkers =
        M.fromList
          [ ("T/a", Right (VaultMarker idA AssetVault "a" ra))
          , ("T/b", Right (VaultMarker idB AssetVault "b" rb))
          , ("T/c", Right (VaultMarker idC AssetVault "c" rc))
          ]
    , worldDirs = "T" : concatMap markerDirPair ["T/a", "T/b", "T/c"]
    }

markerDirPair :: FilePath -> [FilePath]
markerDirPair p = [p, p <> "/.aapms"]

samplePid :: Id
samplePid = case parseId "prj-91c0aa12" of
  Right (_, i) -> i
  Left e -> error ("P-029 測試的專案 id 字面值不合法:" <> show e)

--------------------------------------------------------------------------------
-- 產生器
--------------------------------------------------------------------------------

-- | 中樞裡一列 vault 的四種狀態。__SMissing 同時代表「路徑不是既存目錄」與
-- 「那個路徑的 marker 讀不到」__(見模組頭的世界合法性)。
data SlotState = SOk | SMissing | SBroken | SDrift
  deriving stock (Show, Eq)

data Slot = Slot
  { slotIndex :: Int
  , slotId :: VaultId
  , slotName :: Text
  , slotKind :: VaultKind
  , slotPath :: FilePath
  , slotState :: SlotState
  , slotRefs :: [VaultId]
  }
  deriving stock (Show, Eq)

data Scenario = Scenario
  { scSlots :: [Slot]
  , scWorld :: MarkerWorld
  , scHub :: Hub
  }
  deriving stock (Show, Eq)

-- | 產生器用的 id 池(五個,對應五格);中樞裡的 id 因此逐列唯一。
idPool :: [VaultId]
idPool =
  map
    (VaultId . ("vlt-" <>))
    ["aaaa1111", "bbbb2222", "cccc3333", "dddd4444", "ee005555"]

-- | 永不進中樞的 id:未註冊的 refs 目標,同時也是 @T\/u@ 那個未註冊 vault 的身分。
unregId :: VaultId
unregId = VaultId "vlt-ffff0000"

unregPath :: FilePath
unregPath = "T/u"

slotPaths :: [FilePath]
slotPaths = ["T/v0", "T/v1", "T/v2", "T/v3", "T/v4"]

namePool :: [Text]
namePool = ["a", "b", "dup", "shared", "x"]

bogusSelectors :: [Text]
bogusSelectors = ["nope", "", "ZZZ", " a"]

genKind :: Gen VaultKind
genKind = Gen.element [AssetVault, StoryVault]

genScopeKind :: Gen ScopeKind
genScopeKind =
  Gen.frequency [(2, pure ForRead), (1, pure ForWrite), (1, ForPipeline <$> genKind)]

-- | 一到五格;'Just' 時把第一格固定成該狀態(給有前提的 law 直接建構定義域)。
genSlots :: Maybe SlotState -> Gen [Slot]
genSlots forced = do
  n <- Gen.int (Range.linear 1 5)
  slots <- traverse genSlot (zip3 [0 ..] (take n idPool) (take n slotPaths))
  pure $ case (forced, slots) of
    (Just st, s0 : rest) -> s0 {slotState = st} : rest
    _ -> slots

genSlot :: (Int, VaultId, FilePath) -> Gen Slot
genSlot (i, vid, p) = do
  nm <- Gen.element namePool
  kd <- genKind
  st <- Gen.frequency [(6, pure SOk), (1, pure SMissing), (1, pure SBroken), (1, pure SDrift)]
  rs <- Gen.subsequence (idPool <> [unregId])
  pure (Slot i vid nm kd p st rs)

driftIdOf :: Slot -> VaultId
driftIdOf s = VaultId ("vlt-dd00000" <> T.pack (show (slotIndex s)))

entryOf :: Slot -> VaultEntry
entryOf s = VaultEntry (slotId s) (slotName s) (slotKind s) (slotPath s)

scenarioOf :: [Slot] -> Scenario
scenarioOf slots = Scenario slots world hub
  where
    world =
      MarkerWorld
        { mwMarkers = M.fromList (concatMap markerRow slots <> [(unregPath, Right unregMarker)])
        , worldDirs =
            ["T", "T2", "T2/x"]
              <> concatMap slotDirs slots
              <> [unregPath, unregPath <> "/.aapms", unregPath <> "/x"]
        }
    hub = mkHub (map entryOf slots) [] Nothing (ToolsConfig Nothing) ""
    unregMarker = VaultMarker unregId AssetVault "u" []
    markerRow s = case slotState s of
      SOk -> [(slotPath s, Right (VaultMarker (slotId s) (slotKind s) (slotName s) (slotRefs s)))]
      SMissing -> [(slotPath s, Left (VaultMarkerMissing (slotPath s)))]
      SBroken -> [(slotPath s, Left (VaultMarkerInvalid (slotPath s) "marker 欄位不合法"))]
      SDrift ->
        [(slotPath s, Right (VaultMarker (driftIdOf s) (slotKind s) (slotName s) (slotRefs s)))]
    slotDirs s
      | slotState s == SMissing = []
      | otherwise =
          [ slotPath s
          , slotPath s <> "/.aapms"
          , slotPath s <> "/deep"
          , slotPath s <> "/deep/deeper"
          ]

genScenario :: Gen Scenario
genScenario = scenarioOf <$> genSlots Nothing

genScenarioWith :: SlotState -> Gen Scenario
genScenarioWith st = scenarioOf <$> genSlots (Just st)

-- | 第一格保證讀得到且 id 相符。
genScenarioOk :: Gen Scenario
genScenarioOk = genScenarioWith SOk

-- | LAW-25 的定義域:含空世界與整批不可達的世界。
genWildScenario :: Gen Scenario
genWildScenario =
  Gen.frequency
    [ (4, genScenario)
    , (1, pure (Scenario [] mempty (mkHub [] [] Nothing (ToolsConfig Nothing) "")))
    , (1, genScenarioWith SMissing)
    , (1, genScenarioWith SDrift)
    ]

firstSlot :: Scenario -> Slot
firstSlot s = case scSlots s of
  (s0 : _) -> s0
  [] -> error "P-029 測試:呼叫端保證 scSlots 非空"

startsUnder :: Slot -> [FilePath]
startsUnder s = [slotPath s, slotPath s <> "/deep", slotPath s <> "/deep/deeper"]

genAnyStart :: Scenario -> Gen FilePath
genAnyStart s =
  Gen.element
    ( concatMap startsUnder (scSlots s)
        <> ["T", "T2", "T2/x", unregPath, unregPath <> "/x", "T/nowhere"]
    )

-- | 起點一定落在第一格底下(呼叫端保證第一格是 'SOk')。
genOkStart :: Scenario -> Gen FilePath
genOkStart s = Gen.element (startsUnder (firstSlot s))

idText :: VaultId -> Text
idText (VaultId t) = t

genAnySelText :: Scenario -> Gen Text
genAnySelText s =
  Gen.element
    (map (idText . slotId) (scSlots s) <> map slotName (scSlots s) <> bogusSelectors)

genAnySel :: Scenario -> Gen (Maybe Text)
genAnySel s = Gen.frequency [(2, pure Nothing), (3, Just <$> genAnySelText s)]

-- | 偏向解得開的 selector:多數指向第一格(呼叫端保證是 'SOk')。
genGoodSel :: Scenario -> Gen (Maybe Text)
genGoodSel s =
  Gen.frequency
    [ (2, pure Nothing)
    , (3, pure (Just (idText (slotId (firstSlot s)))))
    , (1, Just <$> Gen.element bogusSelectors)
    ]

-- | LAW-12 的定義域:'lookupSelector' 一定 'Left' 的 selector(查無或撞名)。
genLeftSelText :: Scenario -> Gen Text
genLeftSelText s = Gen.element (bogusSelectors <> dupNames)
  where
    names = map slotName (scSlots s)
    dupNames = [n | n <- nub names, length (filter (== n) names) >= 2]

-- | LAW-9 的定義域:中樞裡的列,外加一批中樞外亂造的列。
genAnyEntry :: Scenario -> Gen VaultEntry
genAnyEntry s =
  Gen.frequency
    [ (4, Gen.element (hubVaults (scHub s)))
    , (1, genStrayEntry s)
    ]

genStrayEntry :: Scenario -> Gen VaultEntry
genStrayEntry s =
  VaultEntry
    <$> Gen.element (idPool <> [unregId])
    <*> Gen.element namePool
    <*> genKind
    <*> Gen.element ([unregPath, "T/nowhere", "T2", "T"] <> map slotPath (scSlots s))

--------------------------------------------------------------------------------
-- 斷言輔助
--------------------------------------------------------------------------------

implies :: Bool -> Bool -> Bool
implies a b = not a || b

expectRight :: Show e => String -> Either e a -> PropertyT IO a
expectRight what r = case r of
  Right a -> pure a
  Left e -> do
    annotate ("預期 Right:" <> what)
    annotateShow e
    failure

expectLeft :: Show a => String -> Either e a -> PropertyT IO e
expectLeft what r = case r of
  Left e -> pure e
  Right a -> do
    annotate ("預期 Left:" <> what)
    annotateShow a
    failure

expectJust :: String -> Maybe a -> PropertyT IO a
expectJust what r = case r of
  Just a -> pure a
  Nothing -> do
    annotate ("預期 Just:" <> what)
    failure

-- | 世界裡那個路徑讀得到 marker。
expectReadable :: String -> Maybe (Either StoreError VaultMarker) -> PropertyT IO VaultMarker
expectReadable what r = case r of
  Just (Right m) -> pure m
  other -> do
    annotate ("預期讀得到 marker:" <> what)
    annotateShow other
    failure

-- | 世界裡那個路徑讀不到 marker(LAW-17 的前提)。
expectUnreadable :: String -> Maybe (Either StoreError VaultMarker) -> PropertyT IO StoreError
expectUnreadable what r = case r of
  Just (Left e) -> pure e
  other -> do
    annotate ("預期 marker 讀不到:" <> what)
    annotateShow other
    failure
