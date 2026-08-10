-- | 產生每個素材包的 @pack.toml@。
--
-- 這個檔案讓**資料庫可以從磁碟完整重建**。素材庫是備份目標;
-- 如果災難復原時只剩下壓縮檔而沒有中繼資料,那些查證過的授權條款
-- 就得重新查一遍。
--
-- 手寫產生器而不是用 TOML 函式庫的序列化,理由是註解:
-- 這個檔案給人編輯,而註解會解釋每個欄位為什麼在那裡。
-- 序列化器不會產生註解。
module AssetDB.Reorg.PackToml (renderPackToml) where

import AssetDB.Reorg.Snapshot
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T

renderPackToml :: PackRow -> Text
renderPackToml pk =
  T.unlines $
    [ "# 由 assetdb 產生。可以手動編輯 —— 重新掃描不會覆蓋人工填寫的欄位。"
    , "#"
    , "# 這個檔案與壓縮檔放在一起,構成一個完整的溯源單位:"
    , "# 有了它,資料庫可以從磁碟重建。"
    , ""
    , "schema = 1"
    , kv "slug" (Just (prSlug pk))
    , kv "name" (Just (prName pk))
    ]
      <> catMaybes
        [ fmap (kv "vendor" . Just) (prVendor pk)
        , fmap (kv "author" . Just) (prAuthor pk)
        , fmap (kv "source_url" . Just) (prSourceUrl pk)
        , fmap (kv "version" . Just) (prVersion pk)
        ]
      <> [ kv "kind" (Just (prKind pk))
         , ""
         , "# unknown(還沒查)與 none(作者明確聲明未使用)意義不同。"
         , "# 發行前的稽核只接受 none —— Steam 等平台上架要求申報生成式 AI 使用。"
         , kv "ai_disclosure" (Just (prAi pk))
         , ""
         , "[archive]"
         , kv "file" (Just (leafOf (prArchiveRel pk)))
         , "sha256 = " <> quoted (prArchiveSha pk)
         , "bytes = " <> T.pack (show (prArchiveBytes pk))
         , "entries = " <> T.pack (show (prEntryCount pk))
         ]
      <> licenceSection
      <> statusSection
  where
    licenceSection =
      case prLicense pk of
        Nothing ->
          [ ""
          , "# ⚠ 授權未填。這個素材包不可用於建專案 —— 授權閘門會擋下。"
          , "# 填好之後把 status 改成 ready。"
          ]
        Just l ->
          [ ""
          , "[license]"
          , "# 授權的完整條款在資料庫的 licenses 表。這裡只引用名稱,"
          , "# 因為同一份授權常常涵蓋多個素材包。"
          , kv "name" (Just l)
          ]

    statusSection =
      [ ""
      , "# draft 的素材照樣入庫、算雜湊、產縮圖,只是不進搜尋預設結果、"
      , "# 不可用於建專案。授權缺漏因此是看得見的待辦,而不是看不見的風險。"
      , kv "status" (Just (prStatus pk))
      ]

    kv k v = maybe "" (\x -> k <> " = " <> quoted x) v

-- | TOML 的基本字串。反斜線與雙引號需要跳脫。
--
-- 素材包名稱含中文、方括號、撇號、@&@ —— 只有那兩個字元在 TOML 基本字串裡
-- 有特殊意義,其餘原樣放進去即可(TOML 檔案本身就是 UTF-8)。
quoted :: Text -> Text
quoted t = "\"" <> T.replace "\"" "\\\"" (T.replace "\\" "\\\\" t) <> "\""

leafOf :: Text -> Text
leafOf p = last ("" : T.splitOn "/" p)
