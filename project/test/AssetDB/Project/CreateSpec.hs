-- | 授權閘門。
--
-- 這是 @pack.toml@ 的 @commercial@ 欄位唯一有實際效果的地方,也是整個系統裡
-- 少數「寫錯會有法律後果」的判斷。它先前完全沒有測試(enhance-0013 T3)。
--
-- 測試的重點只有一個:**未查證的授權(NULL)必須與明確禁止(0)同樣被擋下**。
-- 這是三值邏輯最容易被寫錯的地方 —— @l.commercial = 0@ 對 NULL 求值是 NULL
-- 而不是 true,少寫一個 @IS NULL@ 分支就會讓授權不明的素材靜靜地進到商業專案。
module AssetDB.Project.CreateSpec (spec) where

import AssetDB.Project.Create (nonCommercialPacks)
import AssetDB.Store
import Data.List (sort)
import Data.Text (Text)
import Database.SQLite.Simple
import Test.Hspec

spec :: Spec
spec = describe "nonCommercialPacks" $ do
  it "擋下 license_id 為 NULL 的素材包" $ withPacks $ \conn ->
    nonCommercialPacks conn ["unlicensed"] `shouldReturn` ["unlicensed"]

  it "擋下明確標記不可商用的素材包" $ withPacks $ \conn ->
    nonCommercialPacks conn ["noncomm"] `shouldReturn` ["noncomm"]

  it "放行可商用的素材包" $ withPacks $ \conn ->
    nonCommercialPacks conn ["comm"] `shouldReturn` []

  it "混合輸入時只回傳擋下的那些" $ withPacks $ \conn -> do
    blocked <- nonCommercialPacks conn ["comm", "noncomm", "unlicensed"]
    sort blocked `shouldBe` ["noncomm", "unlicensed"]

  -- 授權未查證與明確禁止在資料庫層是兩件事(NULL vs 0,見 SchemaSpec),
  -- 但在閘門這一側必須是同一件事:兩者都不放行。
  it "NULL 與 0 在閘門這一側等價" $ withPacks $ \conn -> do
    a <- nonCommercialPacks conn ["unlicensed"]
    b <- nonCommercialPacks conn ["noncomm"]
    length a `shouldBe` length b

  it "空清單直接回空,不查資料庫" $ withPacks $ \conn ->
    nonCommercialPacks conn [] `shouldReturn` []

  it "重複的 slug 不會讓同一包被擋兩次以上而改變語意" $ withPacks $ \conn -> do
    -- 呼叫端已經先 nub 過,但這裡不依賴那件事:重複輸入時結果仍然是
    -- 「這一包被擋下」,而不是某種數量相關的行為。
    blocked <- nonCommercialPacks conn ["noncomm", "noncomm"]
    blocked `shouldSatisfy` all (== "noncomm")
    blocked `shouldSatisfy` (not . null)

--------------------------------------------------------------------------------

-- | 三個素材包,涵蓋授權的三種狀態:可商用、明確不可商用、未指定授權。
withPacks :: (Connection -> IO a) -> IO a
withPacks f = do
  st <- openStoreInMemory
  _ <- initSchema st
  let conn = storeConn st
  execute_ conn "INSERT INTO roots (id, path, label, kind) VALUES (1, '/tmp/lib', 'lib', 'packs')"
  -- 900 起跳:migration 001 已經種了八筆查證過的授權(id 1..8),
  -- 固定資料要避開它們。
  execute_
    conn
    "INSERT INTO licenses (id, name, commercial, attribution_required) VALUES \
    \  (901, 'Commercial OK', 1, 0), \
    \  (902, 'Non-Commercial', 0, 0)"
  mapM_ (insertPack conn) packFixtures
  r <- f conn
  close conn
  pure r

-- | (slug, license_id)。@Nothing@ 代表授權欄位留空 —— 匯入了但還沒查證。
packFixtures :: [(Text, Maybe Int)]
packFixtures =
  [ ("comm", Just 901)
  , ("noncomm", Just 902)
  , ("unlicensed", Nothing)
  ]

insertPack :: Connection -> (Text, Maybe Int) -> IO ()
insertPack conn (slug, licenseId) =
  execute
    conn
    "INSERT INTO packs (ulid, slug, name, root_id, rel_dir, license_id, created_at, updated_at) \
    \VALUES (?, ?, ?, 1, ?, ?, 't', 't')"
    ("01" <> slug, slug, slug, "vendor/" <> slug, licenseId)
