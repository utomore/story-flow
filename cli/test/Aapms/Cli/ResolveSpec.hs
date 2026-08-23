-- | T6(service-and-interfaces/F002):id 直接用,標題精確比對,多筆命中列候選。
--
-- 標題比對__不做模糊比對__。猜錯然後改到別的片段,比找不到糟得多——後者使用者
-- 立刻知道,前者要等到下次讀那個片段才發現,而那時候已經沒有原本的內容了。
--
-- service-and-interfaces/F003 之後這一組跑在 'Backend' 上。這裡用的是 @Embedded@;同一批斷言在
-- 遠端後端上的版本在 "Aapms.Cli.RemoteResolveSpec"。
module Aapms.Cli.ResolveSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Cli.Backend
import Aapms.Cli.Error
import Aapms.Cli.Fixtures
import Aapms.Cli.Options (Selector (..), mkSelector)
import Aapms.Cli.Resolve
import Aapms.Core.Id (Id, parseId, renderId)
import Aapms.Core.Level (NodeKind (KScene))
import Aapms.Core.Meta (Meta (..), Source (Human), Status (Canon), emptyTimeline)
import Aapms.Service
import System.Directory (getCurrentDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Selector → Id(內嵌後端)" $ do
  it "id 格式直接當 id 用,不查索引" $ do
    r <- inVault $ \b -> resolveEntity b (SelById (idOf "ent-7f3a"))
    r `shouldBe` Right (idOf "ent-7f3a")

  it "唯一命中的標題回該 id" $ do
    r <- inVault $ \b -> do
      _ <- createEntityB b (newEntityReq "character" "琳達" "第七織手")
      resolveEntity b (mkSelector "琳達")
    fmap renderId r `shouldSatisfy` either (const False) (T.isPrefixOf "ent-")

  it "兩個同名 Entity → title_ambiguous,候選含兩者的 id 與 summary" $ do
    r <- inVault $ \b -> do
      _ <- createEntityB b (newEntityReq "character" "琳達" "第七織手")
      _ <- createEntityB b (newEntityReq "lore" "琳達" "同名的地名")
      resolveEntity b (mkSelector "琳達")
    case r of
      Left e@(CliResolve (Ambiguous SubEntity "琳達" ms)) -> do
        length ms `shouldBe` 2
        map metaSummary ms `shouldMatchList` ["第七織手", "同名的地名"]
        cliErrorCode e `shouldBe` "title_ambiguous"
        let msg = cliErrorMessage e
        mapM_ (\m -> msg `shouldContainT` renderId (metaId m)) ms
        msg `shouldContainT` "第七織手"
      other -> expectationFailure ("預期 Ambiguous,實際 " <> show other)

  it "不存在的標題 → title_not_found,訊息附上該查哪一條指令" $ do
    r <- inVault $ \b -> resolveEntity b (mkSelector "沒這個人")
    case r of
      Left e@(CliResolve (NotFound SubEntity "沒這個人")) -> do
        cliErrorCode e `shouldBe` "title_not_found"
        cliErrorMessage e `shouldContainT` "aapms entity list"
      other -> expectationFailure ("預期 NotFound,實際 " <> show other)

  it "Level 的定址走 listLevels,錯誤訊息指向 level list" $ do
    r <- inVault $ \b -> do
      _ <- createLevelB b (NewLevelReq "教室" "" "" "午後的教室" KScene Canon)
      resolveLevel b (mkSelector "走廊")
    case r of
      Left e -> cliErrorMessage e `shouldContainT` "aapms level list"
      other -> expectationFailure ("預期失敗,實際 " <> show other)

  it "節點定址回 (Level id, Node id)" $ do
    r <- inVault $ \b -> do
      v <- createLevelB b (NewLevelReq "教室" "" "" "午後的教室" KScene Canon)
      (,) <$> resolveNode b (mkSelector "午後的教室") <*> pure (lvId v)
    case r of
      Right ((lvl, _), expectLvl) -> lvl `shouldBe` expectLvl
      other -> expectationFailure ("預期找到節點,實際 " <> show other)

  it "節點多筆命中時提示去 level show 抄 id" $ do
    r <- inVault $ \b -> do
      _ <- createLevelB b (NewLevelReq "教室" "" "" "出場人物" KScene Canon)
      _ <- createLevelB b (NewLevelReq "走廊" "" "" "出場人物" KScene Canon)
      resolveNode b (mkSelector "出場人物")
    case r of
      Left e@(CliResolve (Ambiguous SubNode _ ms)) -> do
        length ms `shouldBe` 2
        cliErrorMessage e `shouldContainT` "aapms level show"
      other -> expectationFailure ("預期 Ambiguous,實際 " <> show other)

  it "currentRevision 依前綴決定去問 Entity 還是 Level" $ do
    r <- inVault $ \b -> do
      e <- createEntityB b (newEntityReq "character" "琳達" "第七織手")
      l <- createLevelB b (NewLevelReq "教室" "" "" "午後的教室" KScene Canon)
      (,) <$> currentRevision b (evId e) <*> currentRevision b (lvId l)
    r `shouldBe` Right (1, 1)

-- 底稿 -------------------------------------------------------------------------

-- | 在一個新的臨時 Vault 裡跑一段 'M',後端是 @Embedded@。
inVault :: (Backend -> M a) -> IO (Either CliError a)
inVault act = withCliVault $ \_ -> do
  cwd <- getCurrentDirectory
  openEnv (Just "liftgame") cwd >>= \case
    Left e -> fail (T.unpack (renderServiceError e))
    Right (env, _) -> do
      r <- runM (act (Embedded env))
      closeEnv env
      pure r

newEntityReq :: Text -> Text -> Text -> NewEntityReq
newEntityReq ty title summary =
  NewEntityReq
    { nerType = ty
    , nerTitle = title
    , nerSummary = summary
    , nerBody = ""
    , nerTags = []
    , nerAliases = []
    , nerStatus = Canon
    , nerTimeline = emptyTimeline
    , nerLinks = []
    , nerSource = Human
    }

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error (show e)
