-- | 單一節點對其型別宣告的純檢查(ADR-005)。
--
-- 與 "Aapms.Core.Registry" 分家的判準是__型別層 vs 推導層__:那邊是宣告的形狀、
-- 錯誤語彙,以及 'Aapms.Core.Registry.TypeRegistry' 自己的 smart constructor
-- 'Aapms.Core.Registry.buildRegistry'(它只看宣告本身,不離開型別層);這邊是會讀
-- 'Aapms.Core.AnyNode.AnyNode' 與 'Aapms.Core.Meta.Meta' __內容__做判斷的規則,
-- 因此要往 @AnyNode@ \/ @Asset@ \/ @Link@ 依賴。方向是單向的——本模組 import
-- "Aapms.Core.Registry",反過來__不可以__。
--
-- 零 IO:規則都能在不碰檔案系統的情況下被單元測試。載入層見
-- "Aapms.Types.Loader"(它 re-export 本模組,既有呼叫端不必改 import)。
module Aapms.Core.Registry.Build
  ( checkMeta
  ) where

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName (..))
import Aapms.Core.Id (VaultId (..))
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta
  ( Meta (..)
  , MetaWarning (..)
  , Timeline (..)
  , TypeKey (..)
  )
import Aapms.Core.Name (segmentText)
import Aapms.Core.Registry
  ( FieldDecl (..)
  , TypeDecl (..)
  , TypeRegistry
  , lookupType
  )
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

-- | 檢查一個節點是否符合其型別宣告:必填欄位有值、關聯在 @allowed_links@ 內、
-- (僅 asset)命名第一段在 @name_kinds@ 內。__只回警告__,不決定要不要擋
-- (那是 service 的事)。
checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]
checkMeta reg node =
  case lookupType reg (metaType m) of
    Nothing -> [UnknownNodeType (metaType m)]
    Just decl -> missingFields decl ++ badLinks decl ++ badNameKind decl
  where
    m = anyMeta node

    missingFields decl =
      [ MissingRequiredField (tdKey decl) (fdName f)
      | f <- tdFields decl
      , fdRequired f
      , not (fieldPresent (fdName f) m)
      ]

    -- allowed_links 為空視為「未宣告限制」,不產生任何關聯警告。
    badLinks decl
      | null (tdAllowedLinks decl) = []
      | otherwise =
          [ LinkNotAllowed (tdKey decl) (renderLinkKind (linkKind l))
          | l <- metaLinks m
          , linkKind l `notElem` tdAllowedLinks decl
          ]

    -- 只對「有命名」的 asset 檢查;tdNameKinds 空清單比照 allowed_links 的
    -- 慣例視為「未宣告限制」(F002 待確認假設 ASM-3)。
    --
    -- 不呼叫完整 'Aapms.Core.Naming.parseLogicalName'(2026-08-23 階段一閘門後
    -- 它需要 'Aapms.Core.Name.NamingVocab' 參數,而 'checkMeta' 的契約簽名沒有
    -- 這個參數,見 F002 待確認假設 ASM-6)——直接切 'LogicalName' 文字第一個
    -- @_@ 之前的片段當 kind 文字用;'astName' 的建構子只經
    -- 'Aapms.Core.Naming.mkLogicalName' 取得,第一段合法性('nvKinds' 成員)已在
    -- 寫入時保證過,這裡只需要文字本身,不需要重新驗證。
    badNameKind decl = case node of
      NAsset Asset {astName = Just (LogicalName nm)}
        | not (null (tdNameKinds decl))
        , kindTxt <- T.takeWhile (/= '_') nm
        , kindTxt `notElem` map segmentText (tdNameKinds decl) ->
            [NameKindNotAllowed (tdKey decl) kindTxt]
      _ -> []

-- | 某個 'Meta' 欄位是否「有填」。
--
-- 對永遠有值的欄位(id / status / revision / 日期)一律為 'True'——把它們
-- 宣告成 required 沒有意義,但也不該因此產生假警告。
fieldPresent :: Text -> Meta -> Bool
fieldPresent name Meta {..} = case name of
  "id" -> True
  "vault" -> notBlank vaultText
  "type" -> notBlank typeText
  "title" -> notBlank metaTitle
  "summary" -> notBlank metaSummary
  "tags" -> not (null metaTags)
  "status" -> True
  "timeline" -> maybe False (\tl -> isJust (tlLabel tl) || isJust (tlOrder tl)) metaTimeline
  "aliases" -> not (null metaAliases)
  "links" -> not (null metaLinks)
  "source" -> True
  "revision" -> True
  "created" -> True
  "updated" -> True
  _ -> False
  where
    notBlank = not . T.null . T.strip
    vaultText = case metaVault of VaultId v -> v
    typeText = case metaType of TypeKey v -> v
