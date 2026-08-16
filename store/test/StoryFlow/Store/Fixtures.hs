-- | 測試共用的臨時 Vault 與範例檔。
--
-- 落地層的測試一律在 'System.IO.Temp.withSystemTempDirectory' 建立的臨時 Vault
-- 裡跑(architecture.md 指定的作法),測完即刪,不碰使用者真正的 Vault 與
-- @~\/.config\/story-flow\/@。
--
-- 'lindaMd' 與 'classroomMd' 逐字取自 architecture.md;其餘幾份是為了湊出
-- 「3 Entity 檔 + 2 Level 檔」的重建情境與中文檢索情境而寫的。
module StoryFlow.Store.Fixtures
  ( -- * 臨時 Vault
    withTempVault
  , withEmptyVault
  , withSampleVault
  , writeVaultFile
  , readVaultFile
  , orDie

    -- * 索引
  , withVaultIndex
  , withSampleIndex
  , countRows
  , scalarInt
  , textsOf

    -- * 範例檔
  , sampleFiles
  , lindaMd
  , lindaOneFragmentMd
  , daoMd
  , loreMd
  , classroomMd
  , corridorMd
  , brokenMd
  , duplicateIdMd
  ) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import StoryFlow.Store.Error (StoreError, renderStoreError)
import StoryFlow.Store.Index (rebuildIndex)
import StoryFlow.Store.Schema (closeIndex, openIndex)
import StoryFlow.Store.Vault (Vault (..), initVault, vaultAbsPath)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

-- | 空的臨時目錄 + 'initVault' 建好的骨架。
withEmptyVault :: (Vault -> IO a) -> IO a
withEmptyVault act =
  withSystemTempDirectory "storyflow-vault" $ \dir -> do
    v <- orDie =<< initVault dir "liftgame"
    act v

-- | 骨架 + 'sampleFiles' 的五份範例檔。
withSampleVault :: (Vault -> IO a) -> IO a
withSampleVault act = withEmptyVault $ \v -> do
  mapM_ (uncurry (writeVaultFile v)) sampleFiles
  act v

-- | 只要一個臨時目錄(還沒有 Vault)時用。
withTempVault :: (FilePath -> IO a) -> IO a
withTempVault = withSystemTempDirectory "storyflow-plain"

-- | 以 UTF-8 寫入 Vault 內的相對路徑,必要時建目錄。
writeVaultFile :: Vault -> FilePath -> Text -> IO ()
writeVaultFile v rel txt = do
  let fp = vaultAbsPath v rel
  createDirectoryIfMissing True (takeDirectory fp)
  BS.writeFile fp (TE.encodeUtf8 txt)

readVaultFile :: Vault -> FilePath -> IO Text
readVaultFile v rel = TE.decodeUtf8 <$> BS.readFile (vaultAbsPath v rel)

-- | 測試裡的前置動作失敗時直接爆掉,並印出人看得懂的訊息。
orDie :: Either StoreError a -> IO a
orDie = either (fail . T.unpack . renderStoreError) pure

-- | 空 Vault + 開好的索引連線。
withVaultIndex :: (Vault -> Connection -> IO a) -> IO a
withVaultIndex act = withEmptyVault $ \v ->
  bracket (orDie =<< openIndex v) closeIndex (act v)

-- | 五份範例檔 + 已經重建完成的索引。
withSampleIndex :: (Vault -> Connection -> IO a) -> IO a
withSampleIndex act = withSampleVault $ \v ->
  bracket (orDie =<< openIndex v) closeIndex $ \conn -> do
    _ <- orDie =<< rebuildIndex conn v
    act v conn

countRows :: Connection -> Text -> IO Int
countRows conn table = scalarInt conn (Query ("SELECT count(*) FROM " <> table)) ()

scalarInt :: (ToRow q) => Connection -> Query -> q -> IO Int
scalarInt conn q args = do
  rows <- query conn q args :: IO [Only Int]
  pure $ case rows of
    (Only n : _) -> n
    [] -> 0

-- | 單欄字串查詢,排序後回傳。
textsOf :: (ToRow q) => Connection -> Query -> q -> IO [Text]
textsOf conn q args = do
  rows <- query conn q args :: IO [Only Text]
  pure (sort [t | Only t <- rows])

-- | 3 份 Entity 檔 + 2 份 Level 檔。重建與查詢測試的共同底稿。
sampleFiles :: [(FilePath, Text)]
sampleFiles =
  [ ("characters/琳達.md", lindaMd)
  , ("items/織紋刀.md", daoMd)
  , ("lore/埃提亞崩塌.md", loreMd)
  , ("levels/教室.md", classroomMd)
  , ("levels/走廊.md", corridorMd)
  ]

-- | architecture.md 的琳達範例檔:主體 + 2 個片段。
lindaMd :: Text
lindaMd =
  T.unlines
    [ "---"
    , "id: ent-7f3a"
    , "vault: liftgame"
    , "type: character"
    , "title: 琳達"
    , "summary: 埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
    , "status: canon"
    , "aliases: [小琳, 第七織手]"
    , "source: human"
    , "revision: 3"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 琳達"
    , ""
    , "角色主體的概述寫在這裡。"
    , ""
    , "## 外貌 {#ent-7f3b}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: 銀灰短髮,左眼下方有織紋刺青"
    , "tags: [外觀]"
    , "revision: 1"
    , "links:"
    , "  - {kind: partOf, target: ent-7f3a}"
    , "```"
    , ""
    , "銀灰短髮剪到耳際……"
    , ""
    , "## 與塔主的過節 {#ent-7f3c}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: 十四歲時因塔主徵召失去雙親,自此對議會抱持敵意"
    , "tags: [動機, 仇恨]"
    , "timeline: 埃提亞崩塌前"
    , "revision: 4"
    , "links:"
    , "  - {kind: partOf, target: ent-7f3a}"
    , "  - {kind: occursIn, target: ent-c41d}"
    , "  - {kind: contradicts, target: ent-91cc, note: 對雙親死因的敘述不一致}"
    , "```"
    , ""
    , "那年她十四歲……"
    ]

-- | 同一份琳達檔,但只剩第一個片段。用於驗證單檔重新索引是整檔替換。
lindaOneFragmentMd :: Text
lindaOneFragmentMd =
  T.unlines
    [ "---"
    , "id: ent-7f3a"
    , "vault: liftgame"
    , "type: character"
    , "title: 琳達"
    , "summary: 埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
    , "status: canon"
    , "aliases: [小琳, 第七織手]"
    , "source: human"
    , "revision: 3"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 琳達"
    , ""
    , "角色主體的概述寫在這裡。"
    , ""
    , "## 外貌 {#ent-7f3b}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: 銀灰短髮,左眼下方有織紋刺青"
    , "tags: [外觀]"
    , "revision: 1"
    , "links:"
    , "  - {kind: partOf, target: ent-7f3a}"
    , "```"
    , ""
    , "銀灰短髮剪到耳際……"
    ]

-- | 道具檔。'searchEntities' 的「織紋」→「織紋刀」子字串命中靠它。
daoMd :: Text
daoMd =
  T.unlines
    [ "---"
    , "id: ent-1001"
    , "vault: liftgame"
    , "type: item"
    , "title: 織紋刀"
    , "summary: 第七織手的佩刀,刀身鑄有織紋"
    , "tags: [道具]"
    , "status: canon"
    , "aliases: [銀織刃]"
    , "source: human"
    , "revision: 2"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 織紋刀"
    , ""
    , "刀身鑄有織紋的短刀。"
    , ""
    , "## 刀身 {#ent-1002}"
    , ""
    , "```meta"
    , "type: item-fragment"
    , "summary: 刀身鑄有舊時的織紋"
    , "tags: [外觀]"
    , "links:"
    , "  - {kind: partOf, target: ent-1001}"
    , "  - {kind: occursIn, target: ent-c41d}"
    , "```"
    , ""
    , "這把刀的織紋在埃提亞崩塌之後就沒有人能再鑄出來了。"
    ]

-- | 世界觀檔。片段層覆寫 @status@ 為 @draft@,供檢索的狀態過濾測試使用。
loreMd :: Text
loreMd =
  T.unlines
    [ "---"
    , "id: ent-c41d"
    , "vault: liftgame"
    , "type: lore"
    , "title: 埃提亞崩塌"
    , "summary: 埃提亞在崩塌前後的樣貌"
    , "tags: [世界觀]"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 埃提亞崩塌"
    , ""
    , "崩塌之前的織城。"
    , ""
    , "## 崩塌前的樣貌 {#ent-c41e}"
    , ""
    , "```meta"
    , "type: lore-fragment"
    , "summary: 崩塌前的浮空織城"
    , "tags: [地理]"
    , "timeline: {label: 埃提亞崩塌前, order: 1}"
    , "links:"
    , "  - {kind: partOf, target: ent-c41d}"
    , "  - {kind: supersedes, target: ent-91cc}"
    , "```"
    , ""
    , "那時候的埃提亞還浮在雲上,沒有人聽過塔主這個稱呼。"
    , ""
    , "## 崩塌後的傳聞 {#ent-c41f}"
    , ""
    , "```meta"
    , "type: lore-fragment"
    , "summary: 崩塌後關於織手的種種傳聞"
    , "tags: [傳聞]"
    , "status: draft"
    , "links:"
    , "  - {kind: references, target: ent-7f3a}"
    , "```"
    , ""
    , "有人說埃提亞的第七織手還活著。"
    ]

-- | architecture.md 的教室 Level 範例檔。
classroomMd :: Text
classroomMd =
  T.unlines
    [ "---"
    , "id: lvl-3a01"
    , "vault: liftgame"
    , "type: level"
    , "title: 教室"
    , "summary: 崩塌後的午後教室,琳達與塔主的第一次對峙"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "場景整體的說明寫在這裡(對應 Level 的 body,不進 Node)。"
    , ""
    , "## 午後的教室 {#nod-0001}"
    , ""
    , "```meta"
    , "kind: scene"
    , "summary: 午後的教室,窗外是崩塌後的天際線"
    , "links:"
    , "  - {kind: involves, target: ent-c41d}"
    , "```"
    , ""
    , "### 出場人物 {#nod-0002}"
    , ""
    , "```meta"
    , "kind: cast"
    , "links:"
    , "  - {kind: involves, target: ent-7f3a}"
    , "  - {kind: involves, target: ent-8b20}"
    , "```"
    , ""
    , "#### 琳達走向講台 {#nod-0004}"
    , ""
    , "```meta"
    , "kind: interaction"
    , "```"
    , ""
    , "### 鏡頭 {#nod-0003}"
    , ""
    , "```meta"
    , "kind: camera"
    , "summary: 自窗外緩推至講台,焦段 35mm"
    , "```"
    ]

-- | 第二份 Level 檔,湊出重建測試要的 5 份檔案。
corridorMd :: Text
corridorMd =
  T.unlines
    [ "---"
    , "id: lvl-3a02"
    , "vault: liftgame"
    , "type: level"
    , "title: 走廊"
    , "summary: 教室外的走廊"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "走廊的說明。"
    , ""
    , "## 走廊 {#nod-0100}"
    , ""
    , "```meta"
    , "kind: scene"
    , "summary: 崩塌後的走廊"
    , "links:"
    , "  - {kind: involves, target: ent-7f3a}"
    , "```"
    , ""
    , "### 鏡頭 {#nod-0101}"
    , ""
    , "```meta"
    , "kind: camera"
    , "summary: 由走廊盡頭推向教室門口"
    , "```"
    ]

-- | frontmatter 的 YAML 壞掉(流式序列沒收尾)。重建時單檔失敗不中斷的樣本。
brokenMd :: Text
brokenMd =
  T.unlines
    [ "---"
    , "id: ent-bad1"
    , "vault: liftgame"
    , "type: lore"
    , "title: 壞掉的檔"
    , "summary: [沒有收尾的流式序列"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "內容。"
    ]

-- | 與 'daoMd' 撞 id 的另一份檔。用於驗證 transaction 中途失敗會整批回滾。
duplicateIdMd :: Text
duplicateIdMd =
  T.unlines
    [ "---"
    , "id: ent-9001"
    , "vault: liftgame"
    , "type: item"
    , "title: 撞號的檔"
    , "summary: 第二個片段刻意與織紋刀的主體同 id"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "# 撞號的檔"
    , ""
    , "主體本身不撞號。"
    , ""
    , "## 沒問題的片段 {#ent-9002}"
    , ""
    , "```meta"
    , "type: item-fragment"
    , "summary: 這一節可以正常寫入"
    , "```"
    , ""
    , "正文。"
    , ""
    , "## 撞號的片段 {#ent-1001}"
    , ""
    , "```meta"
    , "type: item-fragment"
    , "summary: 這一節的 id 與織紋刀主體相同"
    , "```"
    , ""
    , "正文。"
    ]
