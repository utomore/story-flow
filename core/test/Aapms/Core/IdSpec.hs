-- | graph-core/F001 T1 的對照測試:ID 生成、解析、渲染與跨 Vault 定址
-- (ADR-014:八種前綴、vault 段落本身是短 id)。
module Aapms.Core.IdSpec (spec) where

import Data.Char (isDigit)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Aapms.Core.Fixtures (time0)
import Aapms.Core.Id
import Test.Hspec

later :: UTCTime
later = UTCTime (fromGregorian 2026 8 17) (secondsToDiffTime 3600)

nub' :: (Eq a) => [a] -> [a]
nub' = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

allPrefixes :: [IdPrefix]
allPrefixes = [minBound .. maxBound]

spec :: Spec
spec = do
  describe "newId —— 相同輸入穩定、不同輸入分散" $ do
    it "相同的 (prefix, 內容, 時間, salt) 得到相同 ID" $
      newId PEnt "琳達" time0 0 `shouldBe` newId PEnt "琳達" time0 0

    it "內容不同則 ID 不同" $
      newId PEnt "琳達" time0 0 `shouldNotBe` newId PEnt "塔主" time0 0

    it "時間不同則 ID 不同" $
      newId PEnt "琳達" time0 0 `shouldNotBe` newId PEnt "琳達" later 0

    it "salt 不同則 ID 不同 —— 這是碰撞重試的基礎" $
      newId PEnt "琳達" time0 0 `shouldNotBe` newId PEnt "琳達" time0 1

    it "salt 連續遞增可產生一整串相異 ID" $
      length (nub' [newId PEnt "琳達" time0 s | s <- [0 .. 9]]) `shouldBe` 10

    it "前綴不同則 ID 不同" $
      newId PEnt "琳達" time0 0 `shouldNotBe` newId PNod "琳達" time0 0

  describe "newId 的輸出格式" $ do
    it "一律是 <prefix>-<8 位小寫十六進位>" $
      let t = renderId (newId PEnt "埃提亞崩塌前的織紋刀" time0 0)
          (p, rest) = T.breakOn "-" t
          hex = T.drop 1 rest
       in do
            p `shouldBe` "ent"
            T.length hex `shouldBe` 8
            T.all isHexLower hex `shouldBe` True

    it "八種前綴都渲染成對應的三個字母(ADR-012 擴充後的節點種類)" $
      map renderIdPrefix [PEnt, PAst, PPck, PLic, PLvl, PNod, PVlt, PPrj]
        `shouldBe` ["ent", "ast", "pck", "lic", "lvl", "nod", "vlt", "prj"]

    it "恰好八種前綴" $
      length allPrefixes `shouldBe` 8

    it "各種內容都固定產生 8 位十六進位,不會因為雜湊值小而變短" $
      let lens =
            [ T.length (T.drop 4 (renderId (newId PEnt (T.pack (show n)) time0 n)))
            | n <- [0 .. 200 :: Int]
            ]
       in nub' lens `shouldBe` [8]

  describe "parseId" $ do
    it "解析得回前綴與原字串" $
      fmap (fmap renderId) (parseId "ent-7f3a1c92")
        `shouldBe` Right (PEnt, "ent-7f3a1c92")

    it "newId 的輸出一定解析得回來" $
      let i = newId PLvl "教室" time0 0
       in fmap snd (parseId (renderId i)) `shouldBe` Right i

    it "接受 system.md 範例的短寫 id" $
      fmap fst (parseId "nod-0001") `shouldBe` Right PNod

    it "八種前綴都能解析回來" $
      mapM_
        (\p -> fmap fst (parseId (renderIdPrefix p <> "-00000001")) `shouldBe` Right p)
        allPrefixes

    it "不認得的前綴回 UnknownIdPrefix" $
      parseId "xyz-7f3a" `shouldBe` Left (UnknownIdPrefix "xyz")

    it "沒有連字號的字串回 BadIdFormat" $
      parseId "ent7f3a" `shouldBe` Left (BadIdFormat "ent7f3a")

    it "十六進位部分超過 8 位回 BadIdFormat" $
      parseId "ent-7f3a1c92f" `shouldBe` Left (BadIdFormat "ent-7f3a1c92f")

    it "十六進位部分有非法字元回 BadIdFormat" $
      parseId "ent-7g3a" `shouldBe` Left (BadIdFormat "ent-7g3a")

    it "空的十六進位部分回 BadIdFormat" $
      parseId "ent-" `shouldBe` Left (BadIdFormat "ent-")

  describe "Ref —— 跨 Vault 定址(ADR-014:vault 段落本身是短 id)" $ do
    it "\"vlt-a0c4e1f8:ent-7f3b2a91\" 解析為指定 Vault 的參照" $
      fmap refVault (parseRef "vlt-a0c4e1f8:ent-7f3b2a91")
        `shouldBe` Right (Just (VaultId "vlt-a0c4e1f8"))

    it "\"ent-7f3b2a91\" 的 refVault 為 Nothing,表示本 Vault" $
      fmap refVault (parseRef "ent-7f3b2a91") `shouldBe` Right Nothing

    it "render . parse 對兩種形式都是恆等" $ do
      fmap renderRef (parseRef "vlt-a0c4e1f8:ent-7f3b2a91")
        `shouldBe` Right "vlt-a0c4e1f8:ent-7f3b2a91"
      fmap renderRef (parseRef "ent-7f3b2a91") `shouldBe` Right "ent-7f3b2a91"

    it "localRef 產生本 Vault 參照" $
      refVault (localRef (newId PEnt "琳達" time0 0)) `shouldBe` Nothing

    it "vault 段落為空回 BadRefFormat" $
      parseRef ":ent-7f3a" `shouldBe` Left (BadRefFormat ":ent-7f3a")

    it "超過一個冒號回 BadRefFormat" $
      parseRef "a:b:ent-7f3a" `shouldBe` Left (BadRefFormat "a:b:ent-7f3a")

    it "vault 段落前綴不是 vlt 時回 BadRefFormat" $
      parseRef "ent-00000000:ent-7f3a" `shouldBe` Left (BadRefFormat "ent-00000000:ent-7f3a")

    it "id 部分不合法時把 IdError 傳出來" $
      parseRef "vlt-a0c4e1f8:xyz-7f3a"
        `shouldBe` Left (UnknownIdPrefix "xyz")

  describe "fnv1a64" $
    it "對已知輸入產生教科書上的 FNV-1a 64-bit 值" $ do
      fnv1a64 "" `shouldBe` 0xcbf29ce484222325
      fnv1a64 "a" `shouldBe` 0xaf63dc4c8601ec8c

isHexLower :: Char -> Bool
isHexLower c = isDigit c || (c >= 'a' && c <= 'f')
