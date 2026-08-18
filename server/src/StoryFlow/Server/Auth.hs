-- | @Authorization: Bearer \<token\>@ 驗證。
--
-- __作法是 WAI middleware,不是 servant 的 @AuthProtect@__。
--
-- func-0008 原本寫的是「以 'AuthProtect' 搭配一個 @Context@,未啟用時裝一個永遠
-- 放行的檢查器——路由型別因此在兩種模式下相同」。目標(路由型別只有一份)是對的,
-- 但 @AuthProtect@ 達不到:它會出現在 @StoryFlowAPI@ 的型別裡,於是
-- @servant-client@ 那邊要多一個 @AuthClientData@ 實例與 @AuthenticatedRequest@ 包裝,
-- OpenAPI 也會多一個沒人看得懂的安全定義。
--
-- middleware 把同一件事做得更徹底:__路由型別裡根本沒有認證__,client 只要在
-- @Manager@ 上掛一個 @managerModifyRequest@ 加 header 就行,而 API 契約完全不知道
-- 有這回事。認證是傳輸層的關切,本來就不屬於業務契約。
module StoryFlow.Server.Auth
  ( bearerAuth
  , constantTimeEq
  ) where

import Data.Aeson (encode)
import Data.Bits (xor, (.|.))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (hAuthorization, hContentType, status401)
import Network.Wai (Application, Middleware, requestHeaders, responseLBS)
import StoryFlow.Server.Error (errorBody)

-- | 有設 token 時檢查 header;沒設就原樣放行。
--
-- 「沒設 token 就不驗證」在綁 loopback 時是合理的預設(只有本機能連上),而綁
-- 非 loopback 卻沒設 token 的情況根本啟動不了——那道關卡在
-- 'StoryFlow.Server.validateServeOpts',不在這裡。
bearerAuth :: Maybe Text -> Middleware
bearerAuth Nothing app = app
bearerAuth (Just token) app = guarded
  where
    guarded :: Application
    guarded req respond
      | presented req `matches` token = app req respond
      | otherwise = respond unauthorized
    matches (Just given) expected = constantTimeEq given expected
    matches Nothing _ = False

    presented req = do
      raw <- lookup hAuthorization (requestHeaders req)
      bearer <- BS.stripPrefix "Bearer " raw
      either (const Nothing) Just (TE.decodeUtf8' bearer)

    -- body 走 aeson 的 encode,__不寫成 ByteString 字面值__:
    -- OverloadedStrings 給 ByteString 的實例是逐字元截成 8 bit,繁中會被切爛成
    -- 不合法的 UTF-8,客戶端於是解不出這個信封、把「token 錯了」誤報成
    -- 「對面不是 story-flow 伺服器」。
    unauthorized =
      responseLBS
        status401
        [(hContentType, "application/json;charset=utf-8")]
        (encode (errorBody "unauthorized" "缺少或錯誤的 Authorization: Bearer <token>"))

-- | 定時比較。
--
-- __不用 @(==)@__:'Data.Text' 的相等比較會在第一個不同的位元組就短路,而那個
-- 時間差洩漏的是「你猜對了幾個字元」——攻擊者因此能一個字元一個字元地把 token
-- 試出來,而不必窮舉整個空間。
--
-- 長度不同時仍然把兩邊都走完(拿較長的那個當長度,短的補 0),否則長度本身
-- 又變成一個旁通道。
constantTimeEq :: Text -> Text -> Bool
constantTimeEq a b = lengthsMatch && diff == 0
  where
    xs = TE.encodeUtf8 a
    ys = TE.encodeUtf8 b
    n = max (BS.length xs) (BS.length ys)
    lengthsMatch = BS.length xs == BS.length ys
    at s i = if i < BS.length s then BS.index s i else 0
    diff = foldr (\i acc -> acc .|. (at xs i `xor` at ys i)) 0 [0 .. n - 1]
