-- | 前端型別檔的漂移檢查(delivery/E005)。
--
-- 'AssetDB.Server.TsTypesSpec' 保證產生器與 @Api.hs@ 的 ToJSON 一致,
-- 但那管不到磁碟上 @web\/src\/api\/types.ts@ —— 前端實際編譯用的那份 ——
-- 有沒有重新產生。忘記跑 @--emit-types@ 時前端照樣編譯通過,型別卻已
-- 與後端脫鉤,問題拖到執行期才以 @undefined@ 欄位的形式浮現。
--
-- 這條檢查跑在 @cabal test all@ 裡,漂移在測試階段就會紅。
module AssetDB.Server.TsTypesDriftSpec (spec) where

import AssetDB.Server.TsTypes (tsDefinitions)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text.Encoding (encodeUtf8)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "web/src/api/types.ts 漂移檢查" $ do
  it "checked-in 的 types.ts 與產生器輸出一致" $ do
    -- cabal 以套件目錄(server/)為工作目錄執行測試。
    let path = ".." </> "web" </> "src" </> "api" </> "types.ts"
    ok <- doesFileExist path
    if not ok
      then expectationFailure ("找不到 " <> path <> " —— 前端型別檔應該要 checked-in")
      else do
        onDisk <- BS.readFile path
        unless (normalize onDisk == normalize (encodeUtf8 tsDefinitions)) $
          expectationFailure
            "web/src/api/types.ts 與型別產生器的輸出不一致。\n\
            \後端 API 型別改了但前端型別檔沒重新產生 —— 請執行:\n\
            \  cabal run assetdb-server -- --emit-types web/src/api/types.ts"

  it "內容被改動時偵測得到差異" $
    -- 驗證比對機制本身有效:多一個位元組就必須不相等。
    normalize (encodeUtf8 (tsDefinitions <> "\n// drift"))
      `shouldNotBe` normalize (encodeUtf8 tsDefinitions)

-- | 去掉 CR 再比對。@--emit-types@ 寫出的是 LF,但 git 的 autocrlf
-- 可能把簽出的檔案轉成 CRLF —— 那不是漂移,是行尾政策。
normalize :: BS.ByteString -> BS.ByteString
normalize = BC.filter (/= '\r')
