-- | @7z l -slt@ 輸出解析的測試。
--
-- fixture 是**真實輸出**,逐字取自對 Kibyra 的 book-icons.zip 執行的結果
-- (7-Zip 26.02)。自己編造的樣本會漏掉真正會咬人的細節:
-- 兩種不同的分隔線、空值欄位、目錄項目的表示方式、反斜線路徑。
module AssetDB.Archive.SidecarSpec (spec) where

import AssetDB.Archive.Sidecar
import AssetDB.Archive.Types
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "parseListing" $ do
    let es = parseListing realOutput

    it "只取檔案清單,不把壓縮檔自己的屬性當成項目" $ do
      -- 輸出的前半段有一個 `--` 區塊描述壓縮檔本身,裡面同樣有 `Path =`。
      -- 沒處理好的話會多出一筆項目,而且路徑是壓縮檔的絕對路徑。
      map aePath es
        `shouldBe` [ "Books"
                   , "Books/book-icons.png"
                   , "Books/Books/book1.png"
                   , "Books/readme.txt"
                   ]

    it "認得目錄" $
      map aeIsDir es `shouldBe` [True, False, False, False]

    it "反斜線路徑正規化" $
      filter (T.isInfixOf "\\") (map aePath es) `shouldBe` []

    it "讀出大小" $
      map aeSize es `shouldBe` [0, 37362, 457, 296]

    it "讀出 CRC32,空值是 Nothing 而不是 0" $
      -- 目錄沒有 CRC。當成 0 會讓「CRC 相同」的前濾邏輯誤判成相等。
      map aeCrc32 es `shouldBe` [Nothing, Just 0xC3B7A1D2, Just 0xD9B4C0F2, Nothing]

    it "讀出修改時間" $
      length (filter (/= Nothing) (map aeModified es)) `shouldBe` 4

    it "空輸入不會爆炸" $ do
      parseListing "" `shouldBe` []
      parseListing "沒有分隔線的垃圾" `shouldBe` []

  describe "parseListing 的邊界" $ do
    it "檔名裡有 ' = ' 時只切第一個" $ do
      let out = separator <> "Path = weird = name.png\nSize = 10\n"
      map aePath (parseListing out) `shouldBe` ["weird = name.png"]

    it "中文路徑保持完整" $ do
      let out = separator <> "Path = 金門建築\\IMG_1342.HEIC\nSize = 3386811\n"
      map aePath (parseListing out) `shouldBe` ["金門建築/IMG_1342.HEIC"]
      map aeSize (parseListing out) `shouldBe` [3386811]

    it "CRLF 換行" $ do
      -- 7-Zip 在 Windows 上輸出 CRLF。沒處理的話每個值都會多一個 \r,
      -- 數字解析全部失敗而且路徑尾端多一個看不見的字元。
      let out = T.replace "\n" "\r\n" (separator <> "Path = a.png\nSize = 5\n")
      map aePath (parseListing out) `shouldBe` ["a.png"]
      map aeSize (parseListing out) `shouldBe` [5]

  describe "findSevenZip" $ do
    it "候選位置涵蓋 Windows 的預設安裝路徑" $
      -- 這不是防禦性程式設計:開發機上 7-Zip 就是裝在這裡且不在 PATH。
      -- 只查 PATH 會誤報「未安裝」,使用者會去裝第二次。
      sevenZipCandidates `shouldSatisfy` elem "C:\\Program Files\\7-Zip\\7z.exe"

    it "候選位置也涵蓋 Unix" $
      sevenZipCandidates `shouldSatisfy` any (T.isPrefixOf "/usr/" . T.pack)

--------------------------------------------------------------------------------

separator :: Text
separator = "----------\n"

-- | 逐字取自 @7z l -slt -sccUTF-8@(7-Zip 26.02)的真實輸出,
-- 為了測試長度只保留四個項目。CRC 值是為了測試可讀性而改寫的。
realOutput :: Text
realOutput =
  T.unlines
    [ "7-Zip 26.02 (x64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-06-25"
    , ""
    , "Scanning the drive for archives:"
    , "1 file, 2151552 bytes (2102 KiB)"
    , ""
    , "Listing archive: C:\\Raw壓縮檔\\Kibyra\\book-icons.zip"
    , ""
    , "--"
    , "Path = C:\\Raw壓縮檔\\Kibyra\\book-icons.zip"
    , "Type = zip"
    , "Physical Size = 2151552"
    , ""
    , "----------"
    , "Path = Books"
    , "Folder = +"
    , "Size = 0"
    , "Packed Size = 0"
    , "Modified = 2026-05-25 07:40:52"
    , "Created = "
    , "Accessed = "
    , "Attributes = D drwxrwxrwx"
    , "Encrypted = -"
    , "Comment = "
    , "CRC = "
    , "Method = Store"
    , "Host OS = Unix"
    , ""
    , "Path = Books\\book-icons.png"
    , "Folder = -"
    , "Size = 37362"
    , "Packed Size = 36980"
    , "Modified = 2026-05-25 07:40:52"
    , "Attributes = _ -rw-rw-rw-"
    , "CRC = C3B7A1D2"
    , "Method = Deflate"
    , ""
    , "Path = Books\\Books\\book1.png"
    , "Folder = -"
    , "Size = 457"
    , "Packed Size = 420"
    , "Modified = 2026-05-25 07:40:52"
    , "Attributes = _ -rw-rw-rw-"
    , "CRC = D9B4C0F2"
    , "Method = Deflate"
    , ""
    , "Path = Books\\readme.txt"
    , "Folder = -"
    , "Size = 296"
    , "Packed Size = 210"
    , "Modified = 2026-05-25 07:40:52"
    , "Attributes = _ -rw-rw-rw-"
    , "CRC = "
    , "Method = Deflate"
    ]
