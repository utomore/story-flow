-- | 中樞 @config.toml@ 四段的解析與序列化、原子寫入,以及對 'Hub' 值的純增刪
-- (design.md「內部模組劃分」的 Hub)。
--
-- 擁有的事實(唯一真相來源):__中樞記了什麼__——@[[vaults]]@ \/ @[[projects]]@ \/
-- @[llm]@ \/ @[tools]@ 的檔案格式。
--
-- __vault 的身分不屬於本模組__:@id@ \/ @kind@ \/ @name@ \/ @refs@ 屬各 vault 的
-- marker(graph-core)。本模組存的是__快取__,'Aapms.Workspace.Discovery'
-- (F002)每次重讀真相。
--
-- __不建立任何目錄或檔案__:'saveHub' 只覆寫既有位置的 @config.toml@,中樞目錄
-- 與 @cache\/@ 的建立是 F004 的 @setupHub@。
module Aapms.Workspace.Hub
  ( -- * 載入與寫回
    loadHub
  , saveHub

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
  ) where

import Data.List (find)
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified TOML

import Aapms.Core.Id
  ( Id
  , IdPrefix (PPrj, PVlt)
  , VaultId (..)
  , parseId
  , renderId
  , renderIdPrefix
  )
import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Error (renderStoreError)
import Aapms.Store.Schema (parseVaultKind, renderVaultKind)
import Aapms.Workspace.Location (configPath)
import Aapms.Workspace.Types
  ( Hub
  , HubLocation
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
import System.Directory (doesFileExist)
import System.FilePath (isAbsolute)

-- 讀 -----------------------------------------------------------------------

-- | 讀 @\<hlPath\>\/config.toml@ 並解析四段。
--
-- * 檔案不存在 → @Left ('Aapms.Workspace.Types.HubNotFound' fp)@,
--   __不回空中樞__(system.md 全域錯誤策略第 3 條)
-- * 讀不進來或 TOML 解不開 → @Left ('Aapms.Workspace.Types.HubUnreadable' fp _)@
-- * 解得開但欄位不合規 → @Left ('Aapms.Workspace.Types.HubMalformed' fp _)@
--
-- 成功時 'Aapms.Workspace.Types.hubSourceText' 帶著這次讀到的原始檔案文字,
-- 'saveHub' 靠它保住註解與空白行。
loadHub :: HubLocation -> IO (Either WorkspaceError Hub)
loadHub loc = do
  let fp = configPath loc
  exists <- doesFileExist fp
  if not exists
    then pure (Left (HubNotFound fp))
    else do
      txtR <- readTextFile fp
      case txtR of
        Left e -> pure (Left (HubUnreadable fp (renderStoreError e)))
        Right txt -> pure (parseHub fp txt)

parseHub :: FilePath -> Text -> Either WorkspaceError Hub
parseHub fp txt = case (TOML.decode txt :: Either TOML.TOMLError TOML.Value) of
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

-- 寫 -----------------------------------------------------------------------

-- | 把 'Hub' 原子寫回 @\<hlPath\>\/config.toml@(沿用
-- 'Aapms.Store.Atomic.atomicWriteText',__不另寫一份__)。
--
-- __既有列的相對順序、使用者寫的註解與空白行原樣保留__(ADR-017 決策二的
-- 「可手寫」):序列化自己寫,不用泛型 encoder。寫入失敗回
-- @Left ('Aapms.Workspace.Types.HubWriteFailed' fp _)@。
saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())
saveHub loc hub = do
  let fp = configPath loc
  r <- atomicWriteText fp (renderHub hub)
  pure $ case r of
    Left e -> Left (HubWriteFailed fp (renderStoreError e))
    Right () -> Right ()

-- 底稿式序列化 ---------------------------------------------------------------
--
-- 'hubSourceText' 被切成一串「段落」('Segment'):檔案開頭到第一個表頭之前是
-- 前導段(comment、空白行),之後每個表頭(@[key]@ 或 @[[key]]@)開一個新段落,
-- 涵蓋到下一個表頭之前的所有行。__vaults__ \/ __projects__ 段落逐一比對現在的
-- 'hubVaults' \/ 'hubProjects':id 還在且欄位沒變 → 原樣沿用;id 還在但欄位變了
-- → 重新產生那一段;id 不在了 → 整段刪除。原本不存在的新 id 被追加到對應段落的
-- 最後一段之後。@[llm]@ \/ @[tools]@ \/ 前導段 \/ 未知段落一律不動——本 feature
-- 沒有任何函式會修改它們的內容。

data Segment = Segment
  { segKind :: Maybe (Bool, Text)
  -- ^ 'Nothing':前導段(第一個表頭之前)。@Just (True, key)@:@[[key]]@;
  -- @Just (False, key)@:@[key]@。
  , segLines :: [Text]
  -- ^ 這個段落涵蓋的原始行(含終止符),依序串接後與這段原文逐字相同。
  }

renderHub :: Hub -> Text
renderHub hub = T.concat (concatMap segLines finalSegs)
  where
    src = hubSourceText hub
    segs = segmentText src
    vaults = hubVaults hub
    projects = hubProjects hub

    eol :: Text
    eol = if "\r\n" `T.isInfixOf` src then "\r\n" else "\n"

    isVaultsSeg, isProjectsSeg :: Segment -> Bool
    isVaultsSeg s = segKind s == Just (True, "vaults")
    isProjectsSeg s = segKind s == Just (True, "projects")

    (afterVaults, vaultIdsSeen) =
      mapAccumSegs isVaultsSeg (matchVault eol vaults) segs
    (afterProjects, projectIdsSeen) =
      mapAccumSegs isProjectsSeg (matchProject eol projects) afterVaults

    newVaults = filter (\e -> veId e `notElem` vaultIdsSeen) vaults
    newProjects = filter (\e -> peId e `notElem` projectIdsSeen) projects

    withNewVaults =
      insertAfterLastKind eol isVaultsSeg (map (renderVaultSeg eol) newVaults) afterProjects
    finalSegs =
      insertAfterLastKind eol isProjectsSeg (map (renderProjectSeg eol) newProjects) withNewVaults

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

-- | 在符合 'isTarget' 的段落上跑 @f@,不符合的段落原樣通過。@f@ 回傳
-- @(Nothing, _)@ 代表整段刪除;@Just seg'@ 代表沿用或替換成 @seg'@。第二個回傳值
-- 收集每個「仍然存在」的段落所帶的識別碼(給呼叫端算出「新出現的」)。
mapAccumSegs
  :: (Segment -> Bool)
  -> (Segment -> (Maybe Segment, Maybe a))
  -> [Segment]
  -> ([Segment], [a])
mapAccumSegs isTarget f = foldr step ([], [])
  where
    step s (accSegs, accIds)
      | isTarget s =
          let (mSeg, mId) = f s
          in (maybe accSegs (: accSegs) mSeg, maybe accIds (: accIds) mId)
      | otherwise = (s : accSegs, accIds)

matchVault :: Text -> [VaultEntry] -> Segment -> (Maybe Segment, Maybe VaultId)
matchVault eol current seg = case findStringField "id" (segLines seg) of
  Nothing -> (Just seg, Nothing)
  Just idText ->
    let vid = VaultId idText
    in case find ((== vid) . veId) current of
        Nothing -> (Nothing, Nothing)
        Just e
          | segMatchesVault seg e -> (Just seg, Just vid)
          | otherwise -> (Just (renderVaultSeg eol e), Just vid)

matchProject :: Text -> [ProjectEntry] -> Segment -> (Maybe Segment, Maybe Id)
matchProject eol current seg = case findStringField "id" (segLines seg) of
  Nothing -> (Just seg, Nothing)
  Just idText -> case parseId idText of
    Left _ -> (Just seg, Nothing)
    Right (_, pid) -> case find ((== pid) . peId) current of
      Nothing -> (Nothing, Nothing)
      Just e
        | segMatchesProject seg e -> (Just seg, Just pid)
        | otherwise -> (Just (renderProjectSeg eol e), Just pid)

segMatchesVault :: Segment -> VaultEntry -> Bool
segMatchesVault seg e =
  findStringField "name" (segLines seg) == Just (veName e)
    && findStringField "kind" (segLines seg) == Just (renderVaultKind (veKind e))
    && findStringField "path" (segLines seg) == Just (T.pack (vePath e))

segMatchesProject :: Segment -> ProjectEntry -> Bool
segMatchesProject seg e =
  findStringField "name" (segLines seg) == Just (peName e)
    && findStringField "path" (segLines seg) == Just (T.pack (pePath e))

-- | 在一段行裡找 @key = "value"@ 這種指定,回傳去引號、去逸出後的值。只認雙引號
-- 字串,忽略值後面的行內 comment。找不到、或值不是雙引號字串時回 'Nothing'。
findStringField :: Text -> [Text] -> Maybe Text
findStringField key ls = listToMaybe (mapMaybe matchLine ls)
  where
    matchLine l =
      let content = T.stripStart (stripLineEnding l)
      in case T.stripPrefix key content of
          Just afterKey -> do
            afterEq <- eatEq (T.stripStart afterKey)
            case T.uncons (T.stripStart afterEq) of
              Just ('"', afterQuote) -> Just (fst (unquote afterQuote))
              _ -> Nothing
          Nothing -> Nothing

    eatEq t = case T.uncons t of
      Just ('=', rest) -> Just rest
      _ -> Nothing

    unquote = go []
      where
        go acc t = case T.uncons t of
          Nothing -> (T.pack (reverse acc), T.empty)
          Just ('"', rest) -> (T.pack (reverse acc), rest)
          Just ('\\', rest) -> case T.uncons rest of
            Just ('"', rest') -> go ('"' : acc) rest'
            Just ('\\', rest') -> go ('\\' : acc) rest'
            Just (c, rest') -> go (c : acc) rest'
            Nothing -> (T.pack (reverse acc), T.empty)
          Just (c, rest) -> go (c : acc) rest

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

quoteText :: Text -> Text
quoteText t = "\"" <> T.concatMap esc t <> "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc c = T.singleton c

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
