-- | 中樞 @config.toml@ 四段的解析與序列化,以及對 'Hub' 值的純增刪
-- (design.md「內部模組劃分」的 Hub)。
--
-- 擁有的事實(唯一真相來源):__中樞記了什麼__——@[[vaults]]@ \/ @[[projects]]@ \/
-- @[llm]@ \/ @[tools]@ 的檔案格式。
--
-- __vault 的身分不屬於本模組__:@id@ \/ @kind@ \/ @name@ \/ @refs@ 屬各 vault 的
-- marker(graph-core)。本模組存的是__快取__,'Aapms.Workspace.Discovery'
-- (F002)每次重讀真相。
--
-- __本模組是純的__:它只做「文字 ↔ 'Hub' 值」與對 'Hub' 值的增刪,不開檔、
-- 不讀環境變數、不 import 任何 IO 模組。碰檔案的那一半('Aapms.Workspace.Hub.File.loadHub' \/
-- 'Aapms.Workspace.Hub.File.saveHub')住 "Aapms.Workspace.Hub.File" ——
-- 它__不建立任何目錄或檔案__:@saveHub@ 只覆寫既有位置的 @config.toml@,中樞目錄
-- 與 @cache\/@ 的建立是 F004 的 @setupHub@。
module Aapms.Workspace.Hub
  ( -- * 文字 ↔ 'Hub' 值
    parseHubText
  , renderHub

    -- * 契約 B 的四個 getter(自 'Aapms.Workspace.Types' 轉出)
  , hubVaults
  , hubProjects
  , hubLlm
  , hubTools

    -- * 對 'Hub' 值的純增刪(design.md「模組間公開介面」:Lifecycle \/ Projects → Hub)
  , upsertVault
  , removeVault
  , upsertProject
  , removeProject

    -- * 觀察點(P-028-hub-config):依序套用增刪
  , applyHubEdits
  ) where

import Data.Char (toUpper)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified TOML
import Numeric (showHex)

import Aapms.Core.Id
  ( Id
  , IdPrefix (PPrj, PVlt)
  , VaultId (..)
  , parseId
  , renderId
  , renderIdPrefix
  )
import Aapms.Store.Types (parseVaultKind, renderVaultKind)
import Aapms.Workspace.Types
  ( Hub
  , HubEdit (..)
  , LlmSection (..)
  , ProjectEntry (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , WorkspaceError (..)
  , hubLlm
  , hubProjects
  , hubSourceText
  , hubTools
  , hubVaults
  , mkHub
  )
import System.FilePath (isAbsolute)

-- 解析 ---------------------------------------------------------------------

-- | @config.toml@ 的文字 → 'Hub' 的四段。第一個參數是這份文字的來源路徑,
-- 只用來組錯誤訊息。
--
-- * TOML 解不開 → @Left ('Aapms.Workspace.Types.HubUnreadable' fp _)@
-- * 解得開但欄位不合規 → @Left ('Aapms.Workspace.Types.HubMalformed' fp _)@
--
-- 成功時 'Aapms.Workspace.Types.hubSourceText' 帶著傳進來的原始檔案文字,
-- 'renderHub' 靠它保住註解與空白行。
parseHubText :: FilePath -> Text -> Either WorkspaceError Hub
parseHubText fp txt = case (TOML.decode txt :: Either TOML.TOMLError TOML.Value) of
  Left e -> Left (HubUnreadable fp (TOML.renderTOMLError e))
  Right (TOML.Table tbl) -> do
    vaults <- parseVaultsSection fp tbl
    projects <- parseProjectsSection fp tbl
    llm <- parseLlmSection fp tbl
    tools <- parseToolsSection fp tbl
    Right (mkHub vaults projects llm tools txt)
  Right _ -> Left (HubMalformed fp "檔案的最上層不是 TOML 表")

parseVaultsSection :: FilePath -> TOML.Table -> Either WorkspaceError [VaultEntry]
parseVaultsSection fp tbl = case M.lookup "vaults" tbl of
  Nothing -> Right []
  Just (TOML.Array items) -> do
    entries <- traverse (parseVaultEntry fp) items
    checkUniqueIds fp "vault" (map (unVaultId . veId) entries)
    Right entries
  Just _ -> Left (HubMalformed fp "鍵 `vaults` 必須是表的陣列")

parseVaultEntry :: FilePath -> TOML.Value -> Either WorkspaceError VaultEntry
parseVaultEntry fp (TOML.Table t) = do
  idText <- requiredString fp t "id"
  vid <- case parseId idText of
    Right (PVlt, i) -> Right (VaultId (renderId i))
    Right (other, _) ->
      Left
        ( HubMalformed
            fp
            ( "鍵 `id` 必須是 vlt- 開頭的 id,收到前綴 "
                <> renderIdPrefix other
                <> "(" <> idText <> ")"
            )
        )
    Left _ -> Left (HubMalformed fp ("鍵 `id` 不是合法的 vlt- id,收到 " <> idText))
  nameText <- requiredString fp t "name"
  if T.null (T.strip nameText)
    then Left (HubMalformed fp "鍵 `name` 不得為空")
    else Right ()
  kindText <- requiredString fp t "kind"
  kind <- case parseVaultKind kindText of
    Just k -> Right k
    Nothing -> Left (HubMalformed fp ("鍵 `kind` 必須是 asset 或 story,收到 " <> kindText))
  pathText <- requiredString fp t "path"
  if not (isAbsolute (T.unpack pathText))
    then Left (HubMalformed fp ("鍵 `path` 必須是絕對路徑,收到 " <> pathText))
    else Right ()
  Right (VaultEntry vid nameText kind (T.unpack pathText))
parseVaultEntry fp _ = Left (HubMalformed fp "鍵 `vaults` 必須是表的陣列")

parseProjectsSection :: FilePath -> TOML.Table -> Either WorkspaceError [ProjectEntry]
parseProjectsSection fp tbl = case M.lookup "projects" tbl of
  Nothing -> Right []
  Just (TOML.Array items) -> do
    entries <- traverse (parseProjectEntry fp) items
    checkUniqueIds fp "project" (map (renderId . peId) entries)
    Right entries
  Just _ -> Left (HubMalformed fp "鍵 `projects` 必須是表的陣列")

parseProjectEntry :: FilePath -> TOML.Value -> Either WorkspaceError ProjectEntry
parseProjectEntry fp (TOML.Table t) = do
  idText <- requiredString fp t "id"
  pid <- case parseId idText of
    Right (PPrj, i) -> Right i
    Right (other, _) ->
      Left
        ( HubMalformed
            fp
            ( "鍵 `id` 必須是 prj- 開頭的 id,收到前綴 "
                <> renderIdPrefix other
                <> "(" <> idText <> ")"
            )
        )
    Left _ -> Left (HubMalformed fp ("鍵 `id` 不是合法的 prj- id,收到 " <> idText))
  nameText <- requiredString fp t "name"
  if T.null (T.strip nameText)
    then Left (HubMalformed fp "鍵 `name` 不得為空")
    else Right ()
  pathText <- requiredString fp t "path"
  if not (isAbsolute (T.unpack pathText))
    then Left (HubMalformed fp ("鍵 `path` 必須是絕對路徑,收到 " <> pathText))
    else Right ()
  Right (ProjectEntry pid nameText (T.unpack pathText))
parseProjectEntry fp _ = Left (HubMalformed fp "鍵 `projects` 必須是表的陣列")

parseLlmSection :: FilePath -> TOML.Table -> Either WorkspaceError (Maybe LlmSection)
parseLlmSection fp tbl = case M.lookup "llm" tbl of
  Nothing -> Right Nothing
  Just (TOML.Table t) -> Right (Just (LlmSection t))
  Just _ -> Left (HubMalformed fp "鍵 `llm` 必須是表")

parseToolsSection :: FilePath -> TOML.Table -> Either WorkspaceError ToolsConfig
parseToolsSection fp tbl = case M.lookup "tools" tbl of
  Nothing -> Right (ToolsConfig Nothing)
  Just (TOML.Table t) -> case M.lookup "seven_zip" t of
    Nothing -> Right (ToolsConfig Nothing)
    Just (TOML.String s)
      | isAbsolute (T.unpack s) -> Right (ToolsConfig (Just (T.unpack s)))
      | otherwise -> Left (HubMalformed fp ("鍵 `seven_zip` 必須是絕對路徑,收到 " <> s))
    Just _ -> Left (HubMalformed fp "鍵 `seven_zip` 必須是字串")
  Just _ -> Left (HubMalformed fp "鍵 `tools` 必須是表")

requiredString :: FilePath -> TOML.Table -> Text -> Either WorkspaceError Text
requiredString fp t key = case M.lookup key t of
  Nothing -> Left (HubMalformed fp ("缺少必填鍵 `" <> key <> "`"))
  Just (TOML.String s) -> Right s
  Just _ -> Left (HubMalformed fp ("鍵 `" <> key <> "` 必須是字串"))

checkUniqueIds :: FilePath -> Text -> [Text] -> Either WorkspaceError ()
checkUniqueIds fp label ids = case findDuplicate ids of
  Just dup -> Left (HubMalformed fp (label <> " id " <> dup <> " 在中樞裡出現一次以上"))
  Nothing -> Right ()

findDuplicate :: [Text] -> Maybe Text
findDuplicate = go []
  where
    go _ [] = Nothing
    go seen (x : xs)
      | x `elem` seen = Just x
      | otherwise = go (x : seen) xs

unVaultId :: VaultId -> Text
unVaultId (VaultId t) = t

-- 底稿式序列化 ---------------------------------------------------------------
--
-- 'hubSourceText' 被切成一串「段落」('Segment'):檔案開頭到第一個表頭之前是
-- 前導段(comment、空白行),之後每個表頭(@[key]@ 或 @[[key]]@)開一個新段落,
-- 涵蓋到下一個表頭之前的所有行。__vaults__ \/ __projects__ 的段落被當成一排
-- 「槽」,第 i 個槽放清單的第 i 列('fillSlots');清單比槽多的追加在最後一個槽
-- 之後,槽比清單多的整段丟掉。@[llm]@ \/ @[tools]@ \/ 前導段 \/ 未知段落一律不動
-- ——本 feature 沒有任何函式會修改它們的內容。

data Segment = Segment
  { segKind :: Maybe (Bool, Text)
  -- ^ 'Nothing':前導段(第一個表頭之前)。@Just (True, key)@:@[[key]]@;
  -- @Just (False, key)@:@[key]@。
  , segLines :: [Text]
  -- ^ 這個段落涵蓋的原始行(含終止符),依序串接後與這段原文逐字相同。
  }

-- | 'Hub' → @config.toml@ 的完整文字。
--
-- __既有列的相對順序、使用者寫的註解與空白行原樣保留__(ADR-017 決策二的
-- 「可手寫」):序列化自己寫,不用泛型 encoder。
renderHub :: Hub -> Text
renderHub hub
  | sourceUnchanged = src
  | otherwise = T.concat (concatMap segLines finalSegs)
  where
    src = hubSourceText hub
    segs = segmentText src
    vaults = hubVaults hub
    projects = hubProjects hub

    -- 底稿本身就是「現在應該長什麼樣」時,__整份逐字沿用__,連切段都不必做:
    -- 沒有改過的快照(以及冪等的 upsert、刪不存在的 id 這種沒真的動到東西的
    -- 增刪)因此保證與讀進來的文字逐位元組相同。判準只比 @[[vaults]]@ 與
    -- @[[projects]]@:@[llm]@ \/ @[tools]@ \/ 未知段落沒有任何函式會改,切段那條
    -- 路徑對它們也只是原樣抄回,兩條路徑的輸出一致。
    sourceUnchanged = case parseHubText "" src of
      Right h0 -> hubVaults h0 == vaults && hubProjects h0 == projects
      Left _ -> False

    eol :: Text
    eol = if "\r\n" `T.isInfixOf` src then "\r\n" else "\n"

    isVaultsSeg, isProjectsSeg :: Segment -> Bool
    isVaultsSeg s = segKind s == Just (True, "vaults")
    isProjectsSeg s = segKind s == Just (True, "projects")

    afterVaults =
      fillSlots
        eol
        isVaultsSeg
        (renderVaultSeg eol)
        (segEntry parseVaultsSection)
        vaults
        segs
    finalSegs =
      fillSlots
        eol
        isProjectsSeg
        (renderProjectSeg eol)
        (segEntry parseProjectsSection)
        projects
        afterVaults

-- | 把整份原始文字切成段落,段落邊界只在「表頭行」(去頭尾空白後以 @[@ 開頭、
-- 以 @]@ 或 @]]@ 收尾、其餘只有選填的行內 comment 的那一行)。
segmentText :: Text -> [Segment]
segmentText txt = build (linesKeepEnds txt)
  where
    build [] = []
    build ls@(l : rest) = case classifyHeader l of
      Just hk ->
        let (body, after) = break isHeaderLine rest
        in Segment (Just hk) (l : body) : build after
      Nothing ->
        let (pre, after) = break isHeaderLine ls
        in Segment Nothing pre : build after

    isHeaderLine x = case classifyHeader x of
      Just _ -> True
      Nothing -> False

-- | 保留終止符的分行:串接 'linesKeepEnds' 的結果恒與原文逐字相同。
linesKeepEnds :: Text -> [Text]
linesKeepEnds t
  | T.null t = []
  | otherwise =
      let (line, rest) = T.breakOn "\n" t
      in case T.uncons rest of
          Nothing -> [line]
          Just (_, rest') -> (line <> "\n") : linesKeepEnds rest'

stripLineEnding :: Text -> Text
stripLineEnding = T.dropWhileEnd (\c -> c == '\n' || c == '\r')

-- | @Just (True, key)@:@[[key]]@;@Just (False, key)@:@[key]@;其餘(含空行、
-- comment、一般的 @key = value@ 行)一律 'Nothing'。
classifyHeader :: Text -> Maybe (Bool, Text)
classifyHeader raw =
  let content = T.strip (stripLineEnding raw)
  in if T.null content || T.head content /= '['
      then Nothing
      else
        if "[[" `T.isPrefixOf` content
          then extract 2 content
          else extract 1 content
  where
    extract :: Int -> Text -> Maybe (Bool, Text)
    extract n content =
      let closeTok = T.replicate n "]"
          body = T.drop n content
          (name, rest) = T.breakOn closeTok body
          tailText = T.strip (T.drop n rest)
      in if closeTok `T.isPrefixOf` rest
          && not (T.null (T.strip name))
          && T.all (\c -> c /= '[' && c /= ']') name
          && (T.null tailText || "#" `T.isPrefixOf` tailText)
          then Just (n == 2, T.strip name)
          else Nothing

-- | 讓某一類段落渲染出來的__順序等於清單的順序__(LAW-2「清單含順序」)。
--
-- 走訪底稿的段落:不屬於這一類的原位不動(LAW-11 \/ LAW-15);屬於這一類的每個
-- 段落算一個「槽」,第 @i@ 個槽放清單的第 @i@ 列。清單比槽多的追加在最後一個槽
-- 之後(沒有任何槽時追加到檔尾),槽比清單多的整段丟掉。
--
-- 一個槽要放的那一列怎麼寫回去,依序試三種:
--
-- 1. 槽原本裝的就是這一列(逐欄相等)→ __沿用它原本的段落文字__,使用者寫在
--    鍵後面的行內註解與段內空白行因此逐字保住(LAW-1、EX-13)。
-- 2. 這一列原本裝在__別的槽__裡(中間某一列被刪掉、或列被重排時會這樣)→ 把那
--    一段的原文搬過來,一樣保住它的註解。
-- 3. 都不是(欄位改了、或整列是新的)→ 重新序列化一段。
--
-- 舊寫法是「以 id 對應、照原檔位置保留」:一個 id 被 'removeProject' 掉又被
-- 'upsertProject' 加回來時,清單裡它已經在末尾,渲染出來卻還停在它原檔的位置,
-- 再解析的順序就與 'hubProjects' 不同(REV-2、EX-27)。槽的位置由清單決定、
-- 只有段落文字向底稿借,兩件事因此不再打架。
fillSlots
  :: Eq a
  => Text
  -> (Segment -> Bool)
  -> (a -> Segment)
  -> (Segment -> Maybe a)
  -> [a]
  -> [Segment]
  -> [Segment]
fillSlots eol isSlot render readSeg entries segs =
  insertAfterLastKind eol isSlot (map reuseOrRender leftover) filled
  where
    -- 每個段落只解析一次;不是這一類的段落連解析都不做。
    annotated = [(s, if isSlot s then readSeg s else Nothing) | s <- segs]
    originals = [(e, s) | (s, Just e) <- annotated]

    reuseOrRender e = maybe (render e) id (lookup e originals)

    (filled, leftover) = go entries annotated

    go rest [] = ([], rest)
    go rest ((s, mOrig) : ss)
      | isSlot s = case rest of
          [] -> go [] ss
          (e : es) ->
            let s' = if mOrig == Just e then s else reuseOrRender e
                (ss', extra) = go es ss
            in (s' : ss', extra)
      | otherwise =
          let (ss', extra) = go rest ss
          in (s : ss', extra)

-- | 把一個段落的原文單獨交給 __解析全檔用的同一組解析器__,取出它代表的那一列。
-- 段落不是合法 TOML、或那一段不是恰好一列時回 'Nothing'(呼叫端把它當「認不得,
-- 原樣留著」)。
--
-- 比對用的值必須走同一條解析路徑:另寫一個「找 @key = \"value\"@」的行掃描器,
-- 就會在逸出序列(@\\n@ \/ @\\uXXXX@)、單引號字串、多行字串、加引號的鍵上與解析器
-- 對不上,把__沒有變動__的段落誤判成變了而重新序列化——使用者夾在鍵之間的獨立
-- 註解行會因此消失,而未變動的段落要逐字沿用(LAW-1)。
segEntry :: (FilePath -> TOML.Table -> Either WorkspaceError [a]) -> Segment -> Maybe a
segEntry parseSection seg =
  case (TOML.decode (T.concat (segLines seg)) :: Either TOML.TOMLError TOML.Value) of
    Right (TOML.Table tbl) -> case parseSection "" tbl of
      Right [e] -> Just e
      _ -> Nothing
    _ -> Nothing

renderVaultSeg :: Text -> VaultEntry -> Segment
renderVaultSeg eol e =
  Segment
    (Just (True, "vaults"))
    [ "[[vaults]]" <> eol
    , "id = " <> quoteText (unVaultId (veId e)) <> eol
    , "name = " <> quoteText (veName e) <> eol
    , "kind = " <> quoteText (renderVaultKind (veKind e)) <> eol
    , "path = " <> quoteText (T.pack (vePath e)) <> eol
    , eol
    ]

renderProjectSeg :: Text -> ProjectEntry -> Segment
renderProjectSeg eol e =
  Segment
    (Just (True, "projects"))
    [ "[[projects]]" <> eol
    , "id = " <> quoteText (renderId (peId e)) <> eol
    , "name = " <> quoteText (peName e) <> eol
    , "path = " <> quoteText (T.pack (pePath e)) <> eol
    , eol
    ]

-- | TOML 基本字串的完整逸出:雙引號、反斜線、六個具名逸出序列,其餘
-- U+0000–U+001F 與 U+007F 一律 @\\uXXXX@(四位大寫十六進位)。__控制字元不逸出
-- 就是非法 TOML__——'Aapms.Workspace.Hub.File.saveHub' 寫出這種內容,下一次
-- 'Aapms.Workspace.Hub.File.loadHub' 會回
-- 'HubUnreadable',等於工具寫出一份自己讀不回來的中樞。
quoteText :: Text -> Text
quoteText t = "\"" <> T.concatMap esc t <> "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\b' = "\\b"
    esc '\t' = "\\t"
    esc '\n' = "\\n"
    esc '\f' = "\\f"
    esc '\r' = "\\r"
    esc c
      | c < '\x20' || c == '\x7F' = "\\u" <> hex4 (fromEnum c)
      | otherwise = T.singleton c

    hex4 :: Int -> Text
    hex4 n = T.justifyRight 4 '0' (T.pack (map toUpper (showHex n "")))

-- | 把 @newSegs@ 插到最後一個符合 @isTarget@ 的段落之後;完全沒有符合的段落時
-- 插到檔案最尾端。插入點若是原文最後一行且缺終止符,先補上,避免與新內容黏在
-- 同一行。
insertAfterLastKind :: Text -> (Segment -> Bool) -> [Segment] -> [Segment] -> [Segment]
insertAfterLastKind _ _ [] segs = segs
insertAfterLastKind eol isTarget newSegs segs
  | any isTarget segs =
      let idx = lastIndexWhere isTarget segs
          (before, after) = splitAt (idx + 1) segs
      in ensureTerminated eol before ++ newSegs ++ after
  | otherwise = ensureTerminated eol segs ++ newSegs

lastIndexWhere :: (a -> Bool) -> [a] -> Int
lastIndexWhere p xs = last [i | (i, x) <- zip [0 :: Int ..] xs, p x]

ensureTerminated :: Text -> [Segment] -> [Segment]
ensureTerminated eol segs = case reverse segs of
  [] -> segs
  (lastSeg : rest) -> reverse (fixSeg lastSeg : rest)
  where
    fixSeg s = case reverse (segLines s) of
      [] -> s
      (lastLine : ls)
        | "\n" `T.isSuffixOf` lastLine -> s
        | otherwise -> s {segLines = reverse ((lastLine <> eol) : ls)}

-- 純增刪 ---------------------------------------------------------------------

-- | 依 'Aapms.Workspace.Types.veId' 覆寫既有列;沒有該 id 時__追加到末尾__。
-- 純函式,不碰檔案。
upsertVault :: VaultEntry -> Hub -> Hub
upsertVault e h =
  mkHub
    (replaceOrAppend ((== veId e) . veId) e (hubVaults h))
    (hubProjects h)
    (hubLlm h)
    (hubTools h)
    (hubSourceText h)

-- | 依 'Aapms.Workspace.Types.veId' 刪整列;沒有該 id 時原樣回傳。純函式,不碰檔案。
removeVault :: VaultId -> Hub -> Hub
removeVault vid h =
  mkHub
    (filter ((/= vid) . veId) (hubVaults h))
    (hubProjects h)
    (hubLlm h)
    (hubTools h)
    (hubSourceText h)

-- | 依 'Aapms.Workspace.Types.peId' 覆寫既有列;沒有該 id 時__追加到末尾__。
-- 純函式,不碰檔案。
upsertProject :: ProjectEntry -> Hub -> Hub
upsertProject e h =
  mkHub
    (hubVaults h)
    (replaceOrAppend ((== peId e) . peId) e (hubProjects h))
    (hubLlm h)
    (hubTools h)
    (hubSourceText h)

-- | 依 'Aapms.Workspace.Types.peId' 刪整列;沒有該 id 時原樣回傳。純函式,不碰檔案。
removeProject :: Id -> Hub -> Hub
removeProject pid h =
  mkHub
    (hubVaults h)
    (filter ((/= pid) . peId) (hubProjects h))
    (hubLlm h)
    (hubTools h)
    (hubSourceText h)

replaceOrAppend :: (a -> Bool) -> a -> [a] -> [a]
replaceOrAppend p new xs
  | any p xs = map (\x -> if p x then new else x) xs
  | otherwise = xs ++ [new]

-- | 依序套用增刪(P-028-hub-config 的觀察點):對 'HubEdit' 清單依序
-- 'Prelude.foldl'',每個建構子轉呼叫對應的純增刪函式。
applyHubEdits :: [HubEdit] -> Hub -> Hub
applyHubEdits edits h0 = foldl' applyOne h0 edits
  where
    applyOne h (PutVault e) = upsertVault e h
    applyOne h (DropVault vid) = removeVault vid h
    applyOne h (PutProject p) = upsertProject p h
    applyOne h (DropProject pid) = removeProject pid h
