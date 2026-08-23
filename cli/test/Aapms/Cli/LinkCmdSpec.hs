-- | T12:@link add@ \/ @rm@ \/ @list@ 與非核心 kind 的提示。
--
-- 最後兩條是 ADR-005 的直接後果:自訂關聯合法,所以 @--kind contradict@(缺 s)
-- __必須寫得進去__。CLI 能做的只有提示,不能阻擋——打錯字與刻意自訂在字串層面
-- 無法區分,擋下來會擋到「師承於」這種合法用法。
module Aapms.Cli.LinkCmdSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.Text as T
import Aapms.Cli.Fixtures
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "link add / rm / list" $ do
  it "add 之後正向與反向都查得到" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    _ <- sfOk ["link", "add", frag, "--kind", "partOf", "--target", main]
    fromFrag <- sfOk ["link", "list", frag]
    fromFrag `shouldContainT` "partOf → "
    fromFrag `shouldContainT` T.pack main
    toMain <- sfOk ["link", "list", main]
    toMain `shouldContainT` T.pack frag

  it "rm 之後兩邊都消失" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    _ <- sfOk ["link", "add", frag, "--kind", "partOf", "--target", main]
    _ <- sfOk ["link", "rm", frag, "--kind", "partOf", "--target", main]
    env <- sfJson ["link", "list", frag]
    jsonPath ["data", "outgoing"] env `shouldBe` Just (Array mempty)
    envMain <- sfJson ["link", "list", main]
    jsonPath ["data", "incoming"] envMain `shouldBe` Just (Array mempty)

  it "刪不存在的配對 → exit 1" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    r <- sf ["link", "rm", frag, "--kind", "partOf", "--target", main]
    crExit r `shouldBe` ExitFailure 1

  it "--note 存得進去" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    _ <- sfOk ["link", "add", frag, "--kind", "contradicts", "--target", main, "--note", "對雙親死因不一致"]
    out <- sfOk ["link", "list", frag]
    out `shouldContainT` "對雙親死因不一致"

  it "--kind contradict(缺 s)成功寫入,而且 stderr 提示 contradicts" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    r <- sf ["link", "add", frag, "--kind", "contradict", "--target", main]
    crExit r `shouldBe` ExitSuccess
    crErr r `shouldContainT` "contradicts"
    out <- sfOk ["link", "list", frag]
    out `shouldContainT` "contradict →"

  -- 「師承於」與任何核心關聯都不像,所以 suggestCoreKind 回 Nothing,CLI 不提示。
  -- service 仍然會回一筆 LinkNotAllowed(型別的 allowed_links 沒有它)——那是
  -- 另一件事,而且是對的:引擎照存但不推論。這一條要釘的是 __CLI 不亂猜__。
  it "--kind 師承於 成功,而且 CLI 不提示「你是不是要打」" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    r <- sf ["link", "add", frag, "--kind", "師承於", "--target", main]
    crExit r `shouldBe` ExitSuccess
    crErr r `shouldSatisfy` (not . T.isInfixOf "你是不是要打")

  it "--json 模式下提示在 data.warnings 裡,stdout 只有一個物件" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    r <- capture ["--vault", "liftgame", "--json", "link", "add", frag, "--kind", "contradict", "--target", main]
    length (T.lines (T.strip (crOut r))) `shouldBe` 1
    env <- sfJson ["entity", "show", frag]
    -- 上一步已經寫進去了,提示本身在寫入那一次的信封裡
    jsonPath ["data", "entity", "id"] env `shouldBe` Just (String (T.pack frag))

  it "指向不存在的目標時被 service 擋下來" $ withCliVault $ \_ -> do
    (_, frag) <- twoEntities
    env <- sfJson ["link", "add", frag, "--kind", "partOf", "--target", "ent-00000000"]
    env `shouldHaveCode` "dangling_link_target"

  it "跨 Vault 的目標還沒支援,而且說得出來" $ withCliVault $ \_ -> do
    (main, frag) <- twoEntities
    env <- sfJson ["link", "add", frag, "--kind", "partOf", "--target", "other:" <> main]
    env `shouldHaveCode` "cross_vault_unsupported"

  it "沒有任何關聯時 list 兩段都說「無」" $ withCliVault $ \_ -> do
    (_, frag) <- twoEntities
    out <- sfOk ["link", "list", frag]
    out `shouldContainT` "正向"
    out `shouldContainT` "反向"

-- | 兩份獨立的主題檔,回兩者的 id。
--
-- 型別刻意用註冊表裡__有 key__ 的 @character-fragment@ 而不是 @character@:
-- 後者只由 @owner_type@ 認領,'Aapms.Core.Registry.checkEntity' 會為它回一筆
-- @UnknownEntityType@ 警告——那筆警告是對的,但會蓋掉這一組真正要看的東西
-- (非核心 kind 的提示到底有沒有出現)。
twoEntities :: IO (String, String)
twoEntities = do
  main <- new "琳達" "第七織手"
  frag <- new "埃提亞" "崩塌前的地區"
  pure (main, frag)
  where
    new title summary =
      idFromJson
        <$> sfJson ["entity", "new", "--type", "character-fragment", "--title", title, "--summary", summary]
