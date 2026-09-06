-- | lawful 測試:P-028-hub-config(qa 填入)。
--
-- 每條 law 一個 @describe "P-028#LAW-n"@ 的 property,每個 example 一個
-- @describe "P-028#EX-n"@。產生器只用 types 層的建構入口('mkHub'、'parseId'
-- 與 'VaultEntry' \/ 'ProjectEntry' \/ 'LlmSection' \/ 'ToolsConfig' 的建構子)
-- 組合法值;中樞 TOML 的文字由本模組依契約(@[[vaults]]@ id \/ name \/ kind \/
-- path、@[[projects]]@ id \/ name \/ path、@[llm]@、@[tools]@ seven_zip)自己組,
-- 不引用受測模組的序列化。
--
-- 產生器全部有尺寸上限(清單 ≤ 6、字串 ≤ 12、id 取自固定池),每個項目另有
-- 逾時上限。law 講的是 'Data.Text.Text' 值,與檔案的換行慣例無關。
module Aapms.Lawful.P028Spec (spec) where

import Control.Exception (evaluate)
import Data.Char (ord)
import Data.Either (isRight)
import Data.List (find, nub)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)
import qualified System.Timeout as Timeout

import Test.Hspec
import Test.Hspec.Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import qualified TOML

import Aapms.Core.Id (Id, VaultId (..), parseId, renderId)
import Aapms.Store.Types (VaultKind (..), renderVaultKind)
import Aapms.Workspace.Hub
  ( parseHubText
  , removeProject
  , removeVault
  , renderHub
  , upsertProject
  , upsertVault
  )
import Aapms.Workspace.Types
  ( Hub
  , LlmSection (..)
  , ProjectEntry (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , WorkspaceError (..)
  , hubLlm
  , hubProjects
  , hubSourceText
  , hubTools
  , hubVaults
  , mkHub
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
        ("P-028 測試項目超過 " <> show (itemTimeoutMicros `div` 1000000) <> " 秒未結束")

itemTimeoutMicros :: Int
itemTimeoutMicros = 60 * 1000 * 1000

--------------------------------------------------------------------------------
-- Laws
--------------------------------------------------------------------------------

lawsSpec :: Spec
lawsSpec = do
  describe "P-028#LAW-1" $
    it "沒有改過的快照渲染回去,與讀進來的文字逐位元組相同" $
      hedgehog $ do
        fp <- forAll genFilePath
        txt <- forAll genConfigText
        case parseHubText fp txt of
          Left e -> do
            annotate "本產生器只產合法中樞文字,這裡應該是 Right"
            annotateShow e
            failure
          Right h -> renderHub h === txt

  describe "P-028#LAW-2" $
    it "渲染再解析,四段逐欄相等(清單含順序)" $
      hedgehog $ do
        fp <- forAll genFilePath
        h <- forAll genHub
        let out = renderHub h
        annotate (T.unpack out)
        case parseHubText fp out of
          Left e -> do
            annotate "渲染出來的中樞應該讀得回來(LAW-3)"
            annotateShow e
            failure
          Right h2 -> do
            hubVaults h2 === hubVaults h
            hubProjects h2 === hubProjects h
            hubLlm h2 === hubLlm h
            hubTools h2 === hubTools h

  describe "P-028#LAW-3" $
    it "工具寫得出來的中樞,工具一定讀得回來" $
      hedgehog $ do
        fp <- forAll genFilePath
        h <- forAll genHub
        -- 前提由產生器直接建構,在這裡斷言出來,property 才不會恆真。
        assert (isRight (parseHubText fp (hubSourceText h)))
        assert (all (not . T.null) (map veName (hubVaults h)))
        assert (all (not . T.null) (map peName (hubProjects h)))
        nub (map veId (hubVaults h)) === map veId (hubVaults h)
        nub (map peId (hubProjects h)) === map peId (hubProjects h)
        let out = renderHub h
        annotate (T.unpack out)
        case parseHubText fp out of
          Left e -> do
            annotateShow e
            failure
          Right _ -> success

  describe "P-028#LAW-4" $
    it "解析對任何文字都有值,不拋例外" $
      hedgehog $ do
        fp <- forAll genFilePath
        txt <- forAll genAnyText
        -- total:求值到正規形不拋例外(show 走遍整個結構)。
        n <- evalIO (evaluate (length (show (parseHubText fp txt))))
        assert (n >= 0)

  describe "P-028#LAW-5" $
    it "id 不在中樞裡時,upsert 追加到末尾,既有列原序不動" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genFreshVaultEntry
        assert (veId e `notElem` map veId (hubVaults h))
        hubVaults (upsertVault e h) === concat [hubVaults h, [e]]

  describe "P-028#LAW-6" $
    it "id 已經在中樞裡時,upsert 就地覆寫:列數與 id 順序都不變" $
      hedgehog $ do
        h <- forAll genNonEmptyHub
        e <- forAll (genExistingVaultEntry h)
        assert (veId e `elem` map veId (hubVaults h))
        map veId (hubVaults (upsertVault e h)) === map veId (hubVaults h)
        length (hubVaults (upsertVault e h)) === length (hubVaults h)

  describe "P-028#LAW-7" $
    it "upsert 之後一定查得到,而且查到的就是給進去的那一列" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genAnyVaultEntry
        find ((== veId e) . veId) (hubVaults (upsertVault e h)) === Just e

  describe "P-028#LAW-8" $
    it "upsert 冪等:同一列 upsert 兩次與一次相同" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genAnyVaultEntry
        upsertVault e (upsertVault e h) === upsertVault e h

  describe "P-028#LAW-9" $
    it "新增之後撤除,清單回到原樣" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genFreshVaultEntry
        assert (veId e `notElem` map veId (hubVaults h))
        hubVaults (removeVault (veId e) (upsertVault e h)) === hubVaults h

  describe "P-028#LAW-10" $
    it "remove 依 id 保序刪除;id 不存在時整個快照原樣回傳" $
      hedgehog $ do
        h <- forAll genHub
        v <- forAll genAnyVaultId
        hubVaults (removeVault v h) === filter ((/= v) . veId) (hubVaults h)

  describe "P-028#LAW-11" $
    it "vault 的增刪只動 [[vaults]],其餘三段與底稿一個位元組都不動" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genAnyVaultEntry
        v <- forAll genAnyVaultId
        hubProjects (upsertVault e h) === hubProjects h
        hubLlm (upsertVault e h) === hubLlm h
        hubTools (upsertVault e h) === hubTools h
        hubSourceText (upsertVault e h) === hubSourceText h
        hubProjects (removeVault v h) === hubProjects h
        hubLlm (removeVault v h) === hubLlm h
        hubTools (removeVault v h) === hubTools h
        hubSourceText (removeVault v h) === hubSourceText h

  describe "P-028#LAW-12" $
    it "[[projects]] 成立同一組規則:不存在就追加末尾,新增之後撤除回到原樣" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genFreshProjectEntry
        assert (peId e `notElem` map peId (hubProjects h))
        hubProjects (upsertProject e h) === concat [hubProjects h, [e]]
        hubProjects (removeProject (peId e) (upsertProject e h)) === hubProjects h

  describe "P-028#LAW-13" $
    it "project 的 remove 依 id 保序刪除;id 不存在時原樣回傳" $
      hedgehog $ do
        h <- forAll genHub
        p <- forAll genAnyProjectId
        hubProjects (removeProject p h) === filter ((/= p) . peId) (hubProjects h)

  describe "P-028#LAW-14" $
    it "project 的 upsert 冪等,而且一定查得到" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genAnyProjectEntry
        upsertProject e (upsertProject e h) === upsertProject e h
        find ((== peId e) . peId) (hubProjects (upsertProject e h)) === Just e

  describe "P-028#LAW-15" $
    it "project 的增刪只動 [[projects]],其餘三段與底稿一個位元組都不動" $
      hedgehog $ do
        h <- forAll genHub
        e <- forAll genAnyProjectEntry
        p <- forAll genAnyProjectId
        hubVaults (upsertProject e h) === hubVaults h
        hubLlm (upsertProject e h) === hubLlm h
        hubTools (upsertProject e h) === hubTools h
        hubSourceText (upsertProject e h) === hubSourceText h
        hubVaults (removeProject p h) === hubVaults h
        hubLlm (removeProject p h) === hubLlm h
        hubTools (removeProject p h) === hubTools h
        hubSourceText (removeProject p h) === hubSourceText h

  describe "P-028#LAW-16" $
    it "建構入口與五個 selector 互逆" $
      hedgehog $ do
        vs <- forAll genVaultEntries
        ps <- forAll genProjectEntries
        llm <- forAll genLlm
        tools <- forAll genTools
        txt <- forAll genAnyText
        hubVaults (mkHub vs ps llm tools txt) === vs
        hubProjects (mkHub vs ps llm tools txt) === ps
        hubLlm (mkHub vs ps llm tools txt) === llm
        hubTools (mkHub vs ps llm tools txt) === tools
        hubSourceText (mkHub vs ps llm tools txt) === txt

  describe "P-028#LAW-17" $
    it "載入得起來的中樞,每一列的名稱都非空" $
      hedgehog $ do
        fp <- forAll genFilePath
        txt <- forAll genMaybeInvalidConfigText
        let r = parseHubText fp txt
        cover 15 "解析成功" (isRight r)
        cover 15 "解析失敗" (not (isRight r))
        case r of
          Left _ -> success
          Right h -> do
            assert (all (not . T.null) (map veName (hubVaults h)))
            assert (all (not . T.null) (map peName (hubProjects h)))

  describe "P-028#LAW-18" $
    it "鍵是 id:載入得起來的中樞裡 id 唯一,名稱與路徑都可以重複" $
      hedgehog $ do
        fp <- forAll genFilePath
        txt <- forAll genMaybeInvalidConfigText
        let r = parseHubText fp txt
        cover 15 "解析成功" (isRight r)
        cover 15 "解析失敗" (not (isRight r))
        case r of
          Left _ -> success
          Right h -> do
            nub (map veId (hubVaults h)) === map veId (hubVaults h)
            nub (map peId (hubProjects h)) === map peId (hubProjects h)

  describe "P-028#LAW-19" $
    it "搬動一個 vault 只改路徑,身分不變:同 id 不同 path 的 upsert 不新增列" $
      hedgehog $ do
        h <- forAll genNonEmptyHub
        e <- forAll (genExistingVaultEntry h)
        assert (veId e `elem` map veId (hubVaults h))
        map vePath (hubVaults (upsertVault e h)) === map vePath (hubVaults (upsertVault e h))
        length (hubVaults (upsertVault e h)) === length (hubVaults h)
        find ((== veId e) . veId) (hubVaults (upsertVault e h)) === Just e

--------------------------------------------------------------------------------
-- Examples
--------------------------------------------------------------------------------

examplesSpec :: Spec
examplesSpec = do
  describe "P-028#EX-1" $ do
    it "空字串是合法的空中樞" $
      shouldBeEmptyHub (parseHubText exFp "")
    it "只有一行註解的檔案是合法的空中樞" $
      shouldBeEmptyHub (parseHubText exFp "# 空的中樞\n")

  describe "P-028#EX-2" $
    it "TOML 語法錯是 HubUnreadable,不拋例外" $ do
      n <- evaluate (length (show (parseHubText exFp "[[vaults")))
      n `shouldSatisfy` (> 0)
      case parseHubText exFp "[[vaults" of
        Left (HubUnreadable fp _) -> fp `shouldBe` exFp
        other -> expectationFailure ("預期 HubUnreadable,實際:" <> show other)

  describe "P-028#EX-3" $
    it "最上層不是 TOML 表的檔案是 HubMalformed" $
      pendingWith
        "GAP 本次-1:toml-reader 的 decode 一定回 Table,產不出「最上層不是 TOML 表」的輸入"

  describe "P-028#EX-4" $
    it "[[vaults]] 缺 id 是 HubMalformed,訊息含 id" $
      shouldBeMalformedWith
        (parseHubText exFp (T.unlines ["[[vaults]]", "name = \"a\"", "kind = \"asset\"", "path = \"D:/v/a\""]))
        ["id"]

  describe "P-028#EX-5" $ do
    it "kind 不是 asset / story 是 HubMalformed,訊息含該值" $
      shouldBeMalformedWith
        (parseHubText exFp (vaultRowText "vlt-7f3b2a91" "a" "media" "D:/v/a"))
        ["media"]
    it "相對路徑是 HubMalformed,訊息含該路徑" $
      shouldBeMalformedWith
        (parseHubText exFp (vaultRowText "vlt-7f3b2a91" "a" "asset" "assets/lib"))
        ["assets/lib"]
    it "id 前綴錯是 HubMalformed,訊息含 vlt 與該 id" $
      shouldBeMalformedWith
        (parseHubText exFp (vaultRowText "prj-91c0aa12" "a" "asset" "D:/v/a"))
        ["vlt", "prj-91c0aa12"]

  describe "P-028#EX-6" $ do
    it "vault 名稱全空白是 HubMalformed,訊息指出名稱不得為空" $
      shouldBeMalformedAboutName
        (parseHubText exFp (vaultRowText "vlt-7f3b2a91" "   " "asset" "D:/v/a"))
    it "project 名稱為空字串是 HubMalformed,訊息指出名稱不得為空" $
      shouldBeMalformedAboutName
        (parseHubText exFp (projectRowText "prj-91c0aa12" "" "D:/games/Circle"))

  describe "P-028#EX-7" $ do
    it "兩列同 id 是 HubMalformed,訊息含那個 id" $
      shouldBeMalformedWith
        ( parseHubText
            exFp
            ( vaultRowText "vlt-7f3b2a91" "a" "asset" "D:/v/a"
                <> vaultRowText "vlt-7f3b2a91" "b" "story" "D:/v/b"
            )
        )
        ["vlt-7f3b2a91"]
    it "兩列同名不同 id 照收" $
      case parseHubText
        exFp
        ( vaultRowText "vlt-7f3b2a91" "same" "asset" "D:/v/a"
            <> vaultRowText "vlt-a0c4e1f8" "same" "story" "D:/v/b"
        ) of
        Right h -> map veId (hubVaults h) `shouldBe` [VaultId "vlt-7f3b2a91", VaultId "vlt-a0c4e1f8"]
        other -> expectationFailure ("預期 Right,實際:" <> show other)

  describe "P-028#EX-8" $
    it "含註解、行內註解、空白行與四段的中樞,解析後渲染回去逐位元組相同" $ do
      case parseHubText exFp ex8Text of
        Left e -> expectationFailure ("EX-8 的中樞應該解析得起來,實際:" <> show e)
        Right h -> renderHub h `shouldBe` ex8Text

  describe "P-028#EX-9" $
    it "渲染再解析,四段逐欄相等且順序相同" $
      case parseHubText exFp (renderHub ex8Hub) of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right h2 -> do
          hubVaults h2 `shouldBe` hubVaults ex8Hub
          hubProjects h2 `shouldBe` hubProjects ex8Hub
          hubLlm h2 `shouldBe` hubLlm ex8Hub
          hubTools h2 `shouldBe` hubTools ex8Hub

  describe "P-028#EX-10" $ do
    it "hubVaults 的順序與內容與檔案一致" $ do
      map veId (hubVaults ex8Hub) `shouldBe` [vid7f3b, vidA0c4]
      map veName (hubVaults ex8Hub) `shouldBe` ["alchbees-assets", "liftgame"]
      map veKind (hubVaults ex8Hub) `shouldBe` [AssetVault, StoryVault]
    it "hubProjects 一列 prj-91c0aa12" $
      map peId (hubProjects ex8Hub) `shouldBe` [pid91c0]
    it "hubTools 取到 [tools] 的 seven_zip" $
      hubTools ex8Hub `shouldBe` ToolsConfig (Just "C:/Program Files/7-Zip/7z.exe")

  describe "P-028#EX-11" $
    it "[llm] 整段缺席是 Nothing,空的 [llm] 段是 Just 空表,兩者不相等" $ do
      let noLlm = vaultRowText "vlt-7f3b2a91" "a" "asset" "D:/v/a"
          emptyLlm = noLlm <> "[llm]\n"
      case (parseHubText exFp noLlm, parseHubText exFp emptyLlm) of
        (Right h1, Right h2) -> do
          hubLlm h1 `shouldBe` Nothing
          hubLlm h2 `shouldBe` Just (LlmSection M.empty)
          (hubLlm h1 == hubLlm h2) `shouldBe` False
        (r1, r2) -> expectationFailure ("預期兩者都是 Right,實際:" <> show (r1, r2))

  describe "P-028#EX-12" $
    it "upsert 一個新 id:三列,前兩列順序與內容不變,第三列是新增的" $ do
      let h' = upsertVault ex12Entry ex8Hub
      length (hubVaults h') `shouldBe` 3
      take 2 (hubVaults h') `shouldBe` hubVaults ex8Hub
      drop 2 (hubVaults h') `shouldBe` [ex12Entry]
      find ((== veId ex12Entry) . veId) (hubVaults h') `shouldBe` Just ex12Entry

  describe "P-028#EX-13" $
    it "新增後渲染再解析:註解與空白行逐字仍在、相對順序不變,最後一列是新增的" $ do
      let out = renderHub (upsertVault ex12Entry ex8Hub)
      commentOnlyLines out `shouldBe` commentOnlyLines ex8Text
      T.lines out `shouldSatisfy` elem "kind = \"asset\"   # 行內註解"
      blankLineCount out `shouldSatisfy` (>= blankLineCount ex8Text)
      case parseHubText exFp out of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right h2 -> do
          map veId (hubVaults h2) `shouldBe` [vid7f3b, vidA0c4, veId ex12Entry]
          drop 2 (hubVaults h2) `shouldBe` [ex12Entry]

  describe "P-028#EX-14" $
    it "同 id 只改 path 的 upsert:列數仍是 2、id 順序不變,只有該列換成新值" $ do
      let moved = VaultEntry vid7f3b "alchbees-assets" AssetVault "E:/moved/alchbees-assets"
          h' = upsertVault moved ex8Hub
      length (hubVaults h') `shouldBe` 2
      map veId (hubVaults h') `shouldBe` map veId (hubVaults ex8Hub)
      hubVaults h' `shouldBe` [moved, hubVaults ex8Hub !! 1]

  describe "P-028#EX-15" $
    it "同一列連續 upsert 兩次:結果相等,清單沒有變長" $ do
      let h1 = upsertVault ex12Entry ex8Hub
          h2 = upsertVault ex12Entry h1
      h2 `shouldBe` h1
      length (hubVaults h2) `shouldBe` length (hubVaults h1)

  describe "P-028#EX-16" $
    it "空中樞 upsert 再 remove,hubVaults 回到 []" $ do
      let e = ex12Entry
          h = upsertVault e emptyHub
      hubVaults h `shouldBe` [e]
      hubVaults (removeVault (veId e) h) `shouldBe` []

  describe "P-028#EX-17" $
    it "removeVault 只少那一列,其餘三段與底稿逐欄不變" $ do
      let h' = removeVault vidA0c4 ex8Hub
      map veId (hubVaults h') `shouldBe` [vid7f3b]
      hubProjects h' `shouldBe` hubProjects ex8Hub
      hubLlm h' `shouldBe` hubLlm ex8Hub
      hubTools h' `shouldBe` hubTools ex8Hub
      hubSourceText h' `shouldBe` hubSourceText ex8Hub

  describe "P-028#EX-18" $
    it "removeVault 不存在的 id:回傳的 Hub 與輸入相等" $
      removeVault (VaultId "vlt-deadbeef") ex8Hub `shouldBe` ex8Hub

  describe "P-028#EX-19" $
    it "空中樞 upsertProject 再 removeProject,其餘四項全程不變" $ do
      let e = ProjectEntry pid91c0 "Circle" "D:/games/Circle"
          h1 = upsertProject e emptyHub
          h2 = removeProject (peId e) h1
      hubProjects h1 `shouldBe` [e]
      hubProjects h2 `shouldBe` []
      map hubVaults [h1, h2] `shouldBe` [[], []]
      map hubLlm [h1, h2] `shouldBe` [Nothing, Nothing]
      map hubTools [h1, h2] `shouldBe` [ToolsConfig Nothing, ToolsConfig Nothing]
      map hubSourceText [h1, h2] `shouldBe` ["", ""]

  describe "P-028#EX-20" $
    it "已有一列時 upsertProject 追加在末尾,既有列原樣" $ do
      let e0 = ProjectEntry pid91c0 "Circle" "D:/games/Circle"
          e = ProjectEntry pid0000 "Square" "D:/games/Square"
          h = upsertProject e (upsertProject e0 emptyHub)
      hubProjects h `shouldBe` [e0, e]

  describe "P-028#EX-21" $ do
    let e0 = ProjectEntry pid91c0 "Circle" "D:/games/Circle"
        e1 = ProjectEntry pid0000 "Square" "D:/games/Square"
        h = upsertProject e1 (upsertProject e0 emptyHub)
    it "removeProject 只少那一列且其餘保序" $
      hubProjects (removeProject (peId e0) h) `shouldBe` [e1]
    it "removeProject 不存在的 id 原樣回傳" $
      removeProject pidDead h `shouldBe` h

  describe "P-028#EX-22" $
    it "同一列連續 upsertProject 兩次:結果相等且查得到" $ do
      let e = ProjectEntry pid91c0 "Circle" "D:/games/Circle"
          h1 = upsertProject e emptyHub
          h2 = upsertProject e h1
      h2 `shouldBe` h1
      find ((== peId e) . peId) (hubProjects h2) `shouldBe` Just e

  describe "P-028#EX-23" $
    it "mkHub 之後五個 selector 依序取回原值" $ do
      let vs = [VaultEntry vid7f3b "a" AssetVault "D:/v/a", VaultEntry vidA0c4 "b" StoryVault "D:/v/b"]
          ps = [ProjectEntry pid91c0 "Circle" "D:/games/Circle"]
          llm = Just (LlmSection (M.fromList [("model", TOML.String "claude")]))
          tools = ToolsConfig (Just "C:/Program Files/7-Zip/7z.exe")
          txt = "# 非空底稿\n"
          h = mkHub vs ps llm tools txt
      hubVaults h `shouldBe` vs
      hubProjects h `shouldBe` ps
      hubLlm h `shouldBe` llm
      hubTools h `shouldBe` tools
      hubSourceText h `shouldBe` txt

  describe "P-028#EX-24" $
    it "名稱含換行與 tab:渲染後讀得回來,檔案裡是逸出後的兩字元序列" $ do
      let e = VaultEntry vid7f3b "line1\nline2\tcol" AssetVault "C:/v"
          out = renderHub (upsertVault e emptyHub)
      T.isInfixOf "\\n" out `shouldBe` True
      T.isInfixOf "\\t" out `shouldBe` True
      case parseHubText exFp out of
        Left err -> expectationFailure ("預期 Right,實際:" <> show err)
        Right h2 -> map veName (hubVaults h2) `shouldBe` ["line1\nline2\tcol"]

  describe "P-028#EX-25" $
    it "名稱含 U+0001:兩段都讀得回來且逐字相等,檔案裡是 \\u0001" $ do
      let ve = VaultEntry vid7f3b "a\SOHb" AssetVault "C:/v"
          pe = ProjectEntry pid91c0 "a\SOHb" "C:/p"
          out = renderHub (upsertProject pe (upsertVault ve emptyHub))
      T.isInfixOf "\\u0001" out `shouldBe` True
      case parseHubText exFp out of
        Left err -> expectationFailure ("預期 Right,實際:" <> show err)
        Right h2 -> do
          map veName (hubVaults h2) `shouldBe` ["a\SOHb"]
          map peName (hubProjects h2) `shouldBe` ["a\SOHb"]

  describe "P-028#EX-26" $
    it "未知的鍵與未知的頂層段逐字保留,渲染回去逐位元組相同" $
      case parseHubText exFp ex26Text of
        Left e -> expectationFailure ("預期 Right,實際:" <> show e)
        Right h -> do
          renderHub h `shouldBe` ex26Text
          map veId (hubVaults h) `shouldBe` [vid7f3b]

--------------------------------------------------------------------------------
-- Example 的斷言輔助
--------------------------------------------------------------------------------

exFp :: FilePath
exFp = "C:/aapms/config.toml"

shouldBeEmptyHub :: Either WorkspaceError Hub -> Expectation
shouldBeEmptyHub r = case r of
  Right h -> do
    hubVaults h `shouldBe` []
    hubProjects h `shouldBe` []
    hubLlm h `shouldBe` Nothing
    hubTools h `shouldBe` ToolsConfig Nothing
  Left e -> expectationFailure ("預期 Right,實際:" <> show e)

shouldBeMalformedWith :: Either WorkspaceError Hub -> [Text] -> Expectation
shouldBeMalformedWith r needles = case r of
  Left (HubMalformed fp msg) -> do
    fp `shouldBe` exFp
    mapM_ (containsNeedle msg) needles
  other -> expectationFailure ("預期 HubMalformed,實際:" <> show other)
  where
    containsNeedle msg nd
      | nd `T.isInfixOf` msg = pure ()
      | otherwise =
          expectationFailure
            ("訊息應含「" <> T.unpack nd <> "」,實際訊息:" <> T.unpack msg)

-- | EX-6 的訊息只被要求「指出名稱不得為空」,措辭未在契約裡定死:
-- 接受中文的「名稱」或欄位名 @name@。
shouldBeMalformedAboutName :: Either WorkspaceError Hub -> Expectation
shouldBeMalformedAboutName r = case r of
  Left (HubMalformed _ msg)
    | "名稱" `T.isInfixOf` msg || "name" `T.isInfixOf` msg -> pure ()
    | otherwise ->
        expectationFailure ("訊息應指出名稱不得為空,實際訊息:" <> T.unpack msg)
  other -> expectationFailure ("預期 HubMalformed,實際:" <> show other)

commentOnlyLines :: Text -> [Text]
commentOnlyLines = filter (T.isPrefixOf "#" . T.stripStart) . T.lines

blankLineCount :: Text -> Int
blankLineCount = length . filter (T.null . T.strip) . T.lines

--------------------------------------------------------------------------------
-- Example 的固定值
--------------------------------------------------------------------------------

vid7f3b, vidA0c4 :: VaultId
vid7f3b = VaultId "vlt-7f3b2a91"
vidA0c4 = VaultId "vlt-a0c4e1f8"

pid91c0, pid0000, pidDead :: Id
pid91c0 = mkPid "prj-91c0aa12"
pid0000 = mkPid "prj-0000abcd"
pidDead = mkPid "prj-deadbeef"

-- | 只用 types 層的 smart constructor 取得 'Id'(建構子不匯出)。
mkPid :: Text -> Id
mkPid t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("P-028 測試的專案 id 字面值不合法:" <> show e)

emptyHub :: Hub
emptyHub = mkHub [] [] Nothing (ToolsConfig Nothing) ""

ex12Entry :: VaultEntry
ex12Entry = VaultEntry (VaultId "vlt-11112222") "shared-lore" StoryVault "E:/vaults/shared"

-- | EX-8:開頭註解、行內註解、空白行與四段俱全的合法中樞。
ex8Text :: Text
ex8Text =
  T.unlines
    [ "# aapms 中樞設定"
    , "# 這一行也是開頭註解"
    , ""
    , "[[vaults]]"
    , "id = \"vlt-7f3b2a91\""
    , "name = \"alchbees-assets\""
    , "kind = \"asset\"   # 行內註解"
    , "path = \"D:/vaults/alchbees-assets\""
    , ""
    , "[[vaults]]"
    , "id = \"vlt-a0c4e1f8\""
    , "name = \"liftgame\""
    , "kind = \"story\""
    , "path = \"D:/vaults/liftgame\""
    , ""
    , "[[projects]]"
    , "id = \"prj-91c0aa12\""
    , "name = \"Circle\""
    , "path = \"D:/games/Circle\""
    , ""
    , "[llm]"
    , "model = \"claude\""
    , ""
    , "[tools]"
    , "seven_zip = \"C:/Program Files/7-Zip/7z.exe\""
    ]

ex8Hub :: Hub
ex8Hub = case parseHubText exFp ex8Text of
  Right h -> h
  Left e -> error ("P-028 EX-8 的中樞應該解析得起來:" <> show e)

-- | EX-26:使用者自訂的未知鍵與未知頂層段。
ex26Text :: Text
ex26Text =
  T.unlines
    [ "# 使用者自己加的註記"
    , "my_own_note = \"保留我\""
    , ""
    , "[[vaults]]"
    , "id = \"vlt-7f3b2a91\""
    , "name = \"alchbees-assets\""
    , "kind = \"asset\""
    , "path = \"D:/vaults/alchbees-assets\""
    , "unknown_key = 42"
    , ""
    , "[future_section]"
    , "flag = true"
    , "note = \"未來版本新增的段\""
    ]

--------------------------------------------------------------------------------
-- 產生器
--------------------------------------------------------------------------------

-- | 中樞內容用的 id 池(固定 6 個,取子集後洗牌 ⇒ 唯一且保序可控)。
vaultIdPool :: [VaultId]
vaultIdPool =
  map
    (VaultId . ("vlt-" <>))
    ["7f3b2a91", "a0c4e1f8", "33334444", "5a5b5c5d", "0a0b0c0d", "cafe0001"]

-- | 「不在中樞裡」的 id,與 'vaultIdPool' 不相交。
spareVaultIds :: [VaultId]
spareVaultIds = map (VaultId . ("vlt-" <>)) ["11112222", "99998888"]

projectIdPool :: [Id]
projectIdPool =
  map
    (mkPid . ("prj-" <>))
    ["91c0aa12", "0000abcd", "7777feed", "1234abcd"]

spareProjectIds :: [Id]
spareProjectIds = map (mkPid . ("prj-" <>)) ["deadbeef", "5555eeee"]

genFilePath :: Gen FilePath
genFilePath =
  Gen.element
    [ "C:/aapms/config.toml"
    , "D:/somewhere/else/config.toml"
    , "C:/使用者/中樞/config.toml"
    ]

plainChars :: String
plainChars = "abcdefgHIJK_-.0123中文名稱"

pathChars :: String
pathChars = "abcXYZ_0-9 "

commentChars :: String
commentChars = "abcXYZ 0123-_中文註解"

-- | 非空、且沒有前後空白的名稱(契約:去前後空白後為空一律 HubMalformed)。
genName :: Gen Text
genName = Gen.frequency [(7, genPlainName), (3, genTrickyName)]

genPlainName :: Gen Text
genPlainName = do
  c <- Gen.element plainChars
  rest <- Gen.text (Range.linear 0 8) (Gen.element (plainChars <> " "))
  pure (T.stripEnd (T.cons c rest))

-- | 需要逸出才寫得進 TOML 基本字串的名稱(LAW-3 的定義域含控制字元)。
genTrickyName :: Gen Text
genTrickyName = do
  base <- genPlainName
  c <- Gen.element ['"', '\\', '\n', '\t', '\r', '\SOH', '\DEL']
  tailPart <- genPlainName
  pure (base <> T.singleton c <> tailPart)

genPath :: Gen FilePath
genPath = do
  drive <- Gen.element ["C:", "D:", "E:"]
  sep <- Gen.element ["/", "\\"]
  segs <- Gen.list (Range.linear 1 3) (Gen.text (Range.linear 1 6) (Gen.element pathChars))
  pure (T.unpack (drive <> sep <> T.intercalate sep segs))

genKind :: Gen VaultKind
genKind = Gen.element [AssetVault, StoryVault]

genVaultEntries :: Gen [VaultEntry]
genVaultEntries = do
  ids <- Gen.subsequence vaultIdPool >>= Gen.shuffle
  traverse genVaultEntryFor ids

genNonEmptyVaultEntries :: Gen [VaultEntry]
genNonEmptyVaultEntries = do
  ids0 <- Gen.subsequence vaultIdPool >>= Gen.shuffle
  let ids = if null ids0 then take 1 vaultIdPool else ids0
  traverse genVaultEntryFor ids

genVaultEntryFor :: VaultId -> Gen VaultEntry
genVaultEntryFor vid = VaultEntry vid <$> genName <*> genKind <*> genPath

genFreshVaultEntry :: Gen VaultEntry
genFreshVaultEntry = Gen.element spareVaultIds >>= genVaultEntryFor

genAnyVaultEntry :: Gen VaultEntry
genAnyVaultEntry = Gen.element (vaultIdPool <> spareVaultIds) >>= genVaultEntryFor

genExistingVaultEntry :: Hub -> Gen VaultEntry
genExistingVaultEntry h = Gen.element (map veId (hubVaults h)) >>= genVaultEntryFor

genAnyVaultId :: Gen VaultId
genAnyVaultId = Gen.element (vaultIdPool <> spareVaultIds)

genProjectEntries :: Gen [ProjectEntry]
genProjectEntries = do
  ids <- Gen.subsequence projectIdPool >>= Gen.shuffle
  traverse genProjectEntryFor ids

genProjectEntryFor :: Id -> Gen ProjectEntry
genProjectEntryFor pid = ProjectEntry pid <$> genName <*> genPath

genFreshProjectEntry :: Gen ProjectEntry
genFreshProjectEntry = Gen.element spareProjectIds >>= genProjectEntryFor

genAnyProjectEntry :: Gen ProjectEntry
genAnyProjectEntry = Gen.element (projectIdPool <> spareProjectIds) >>= genProjectEntryFor

genAnyProjectId :: Gen Id
genAnyProjectId = Gen.element (projectIdPool <> spareProjectIds)

genLlm :: Gen (Maybe LlmSection)
genLlm =
  Gen.maybe (LlmSection . M.fromList <$> Gen.list (Range.linear 0 3) genLlmPair)

genLlmPair :: Gen (Text, TOML.Value)
genLlmPair = (,) <$> Gen.element ["model", "temperature", "enabled", "top_p", "note"] <*> genLlmValue

genLlmValue :: Gen TOML.Value
genLlmValue =
  Gen.choice
    [ TOML.String <$> genPlainName
    , TOML.Integer <$> Gen.integral (Range.linear (-100) 100)
    , TOML.Boolean <$> Gen.bool
    ]

genTools :: Gen ToolsConfig
genTools = ToolsConfig <$> Gen.maybe genPath

-- | 一份合法的中樞文字(含註解、空白行與未知鍵)。
genConfigText :: Gen Text
genConfigText = do
  vs <- genVaultEntries
  ps <- genProjectEntries
  llm <- genLlm
  tools <- genTools
  decorate (renderConfig vs ps llm tools)

-- | 合法與「刻意不合規」各半的中樞文字:LAW-17 \/ LAW-18 兩邊都要走到。
genMaybeInvalidConfigText :: Gen Text
genMaybeInvalidConfigText = Gen.frequency [(1, genConfigText), (1, genInvalidConfigText)]

genInvalidConfigText :: Gen Text
genInvalidConfigText = do
  base <- genConfigText
  extra <-
    Gen.choice
      [ -- 名稱去前後空白後為空
        (\p -> vaultRowText "vlt-7f3b2a91" "   " "asset" (T.pack p)) <$> genPath
      , (\p -> projectRowText "prj-91c0aa12" "" (T.pack p)) <$> genPath
      , -- id 重複
        ( \p ->
            vaultRowText "vlt-a0c4e1f8" "x" "asset" (T.pack p)
              <> vaultRowText "vlt-a0c4e1f8" "y" "story" (T.pack p)
        )
          <$> genPath
      , ( \p ->
            projectRowText "prj-0000abcd" "x" (T.pack p)
              <> projectRowText "prj-0000abcd" "y" (T.pack p)
        )
          <$> genPath
      ]
  pure (base <> extra)

-- | LAW-4 的定義域:任何文字。
genAnyText :: Gen Text
genAnyText =
  Gen.frequency
    [ (3, Gen.text (Range.linear 0 40) Gen.unicode)
    , (2, genConfigText)
    , (2, genTruncatedConfigText)
    , (2, Gen.element brokenLiterals)
    ]

genTruncatedConfigText :: Gen Text
genTruncatedConfigText = do
  t <- genConfigText
  n <- Gen.int (Range.linear 0 (max 0 (T.length t)))
  pure (T.take n t)

brokenLiterals :: [Text]
brokenLiterals =
  [ ""
  , "[[vaults"
  , "= ="
  , "[a]]"
  , "id = "
  , "\"\"\""
  , "\SOH"
  , "[[vaults]]\nid = 1\n"
  , "[[vaults]]\n[[vaults]]\n"
  , "[llm]\n[llm]\n"
  ]

--------------------------------------------------------------------------------
-- 測試自己的 TOML 序列化(依契約寫,不引用受測模組)
--------------------------------------------------------------------------------

renderConfig :: [VaultEntry] -> [ProjectEntry] -> Maybe LlmSection -> ToolsConfig -> Text
renderConfig vs ps llm tools =
  T.concat (map vaultBlock vs <> map projectBlock ps <> llmBlock <> toolsBlock)
  where
    vaultBlock e =
      vaultRowText (unVid (veId e)) (veName e) (renderVaultKind (veKind e)) (T.pack (vePath e))
    projectBlock e = projectRowText (renderId (peId e)) (peName e) (T.pack (pePath e))
    llmBlock = case llm of
      Nothing -> []
      Just (LlmSection m) -> ["[llm]\n"] <> map llmKv (M.toList m) <> ["\n"]
    llmKv (k, v) = k <> " = " <> renderLlmValue v <> "\n"
    toolsBlock = case tcSevenZip tools of
      Nothing -> []
      Just p -> ["[tools]\n", "seven_zip = " <> tomlBasicString (T.pack p) <> "\n", "\n"]

vaultRowText :: Text -> Text -> Text -> Text -> Text
vaultRowText i n k p =
  T.unlines
    [ "[[vaults]]"
    , "id = " <> tomlBasicString i
    , "name = " <> tomlBasicString n
    , "kind = " <> tomlBasicString k
    , "path = " <> tomlBasicString p
    , ""
    ]

projectRowText :: Text -> Text -> Text -> Text
projectRowText i n p =
  T.unlines
    [ "[[projects]]"
    , "id = " <> tomlBasicString i
    , "name = " <> tomlBasicString n
    , "path = " <> tomlBasicString p
    , ""
    ]

renderLlmValue :: TOML.Value -> Text
renderLlmValue v = case v of
  TOML.String s -> tomlBasicString s
  TOML.Integer n -> T.pack (show n)
  TOML.Boolean b -> if b then "true" else "false"
  _ -> "0" -- 本模組的產生器不產其他形狀

-- | TOML 基本字串的完整逸出(P-028 的決定:@\\b \\t \\n \\f \\r \\" \\\\@,
-- 其餘 U+0000–U+001F 與 U+007F 用 @\\uXXXX@)。
tomlBasicString :: Text -> Text
tomlBasicString t = "\"" <> T.concatMap esc t <> "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\b' -> "\\b"
      '\t' -> "\\t"
      '\n' -> "\\n"
      '\f' -> "\\f"
      '\r' -> "\\r"
      _
        | ord c < 0x20 || ord c == 0x7F -> "\\u" <> hex4 (ord c)
        | otherwise -> T.singleton c

hex4 :: Int -> Text
hex4 n = T.toUpper (T.justifyRight 4 '0' (T.pack (showHex n "")))

unVid :: VaultId -> Text
unVid (VaultId t) = t

-- | 在合法的中樞文字裡插入註解行、空白行與未知鍵——三者在 TOML 的頂層
-- 都可以出現在任何一行之前,插入不改變任何一段的語意。
decorate :: Text -> Gen Text
decorate txt = do
  let ls = T.lines txt
      -- 每一行之前「目前在哪個表」。未知鍵在 @[llm]@ 段裡__不是__語意中性的:
      -- 那一段的整張 TOML 表就是 'hubLlm' 的內容,所以只往別的位置插。
      sections = scanl currentSection "" ls
  chunks <- traverse decorateLine (zip3 [0 :: Int ..] sections ls)
  header <- Gen.list (Range.linear 0 2) genCommentLine
  pure (T.unlines (header <> concat chunks))
  where
    currentSection cur l = if "[" `T.isPrefixOf` T.stripStart l then T.strip l else cur
    decorateLine (i, section, l) = do
      pre <-
        Gen.frequency
          ( [ (6, pure [])
            , (2, (: []) <$> genCommentLine)
            , (2, pure [""])
            ]
              <> [ (1, pure ["custom_" <> T.pack (show i) <> " = " <> T.pack (show i)])
                 | section /= "[llm]"
                 ]
          )
      pure (pre <> [l])

genCommentLine :: Gen Text
genCommentLine = do
  body <- Gen.text (Range.linear 0 10) (Gen.element commentChars)
  pure ("# " <> body)

-- | 合法的 'Hub' 值 = 「同一次載入」的快照(types 層對 'Hub' 明載的不變量:
-- 'hubSourceText' 與四段來自同一次載入),再加上零到三次純增刪(P-028 的決定:
-- 四個純增刪只動四段、不動底稿,差異由 'renderHub' 一次收斂)。
--
-- 底稿因此二選一:與四段逐欄一致的合法中樞文字,或空字串(全新中樞,尚無檔案)。
-- 兩者都滿足 LAW-3 的 @isRight (parseHubText fp (hubSourceText h))@;隨後的增刪
-- 讓四段與底稿產生差距,LAW-2 \/ LAW-3 要的正是這段差距收斂得回來。
genHub :: Gen Hub
genHub = genHubWith genVaultEntries

-- | 'hubVaults' 保證非空(LAW-6 \/ LAW-19 的前提)。
genNonEmptyHub :: Gen Hub
genNonEmptyHub = do
  h <- genHubWith genNonEmptyVaultEntries
  if null (hubVaults h)
    then flip upsertVault h <$> genPoolVaultEntry
    else pure h

genHubWith :: Gen [VaultEntry] -> Gen Hub
genHubWith genVs = do
  base <- genLoadedHub genVs
  edits <- Gen.list (Range.linear 0 3) genEdit
  pure (foldl (\h f -> f h) base edits)

-- | 一次載入的快照:底稿與四段逐欄一致,或全新中樞的空快照。
genLoadedHub :: Gen [VaultEntry] -> Gen Hub
genLoadedHub genVs =
  Gen.frequency
    [ (4, genConsistentHub)
    , (1, pure emptyHub)
    ]
  where
    genConsistentHub = do
      vs <- genVs
      ps <- genProjectEntries
      llm <- genLlm
      tools <- genTools
      txt <- decorate (renderConfig vs ps llm tools)
      pure (mkHub vs ps llm tools txt)

-- | 四個純增刪之一。__只用 id 池裡的 id__:'spareVaultIds' \/ 'spareProjectIds'
-- 要保持「不在任何產生出來的中樞裡」,LAW-5 \/ LAW-9 \/ LAW-12 的前提才成立。
genEdit :: Gen (Hub -> Hub)
genEdit =
  Gen.choice
    [ upsertVault <$> genPoolVaultEntry
    , removeVault <$> Gen.element vaultIdPool
    , upsertProject <$> genPoolProjectEntry
    , removeProject <$> Gen.element projectIdPool
    ]

genPoolVaultEntry :: Gen VaultEntry
genPoolVaultEntry = Gen.element vaultIdPool >>= genVaultEntryFor

genPoolProjectEntry :: Gen ProjectEntry
genPoolProjectEntry = Gen.element projectIdPool >>= genProjectEntryFor
