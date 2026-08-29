-- | F001 測試共用的臨時目錄、環境變數、hedgehog 產生器與範例中樞檔案。
--
-- 落地層(涉及 'loadHub' \/ 'saveHub')的測試一律在 'System.IO.Temp.withSystemTempDirectory'
-- 建立的臨時目錄裡跑,測完即刪;讀寫 @AAPMS_HOME@ 的測試一律用 'withEnv' 存回原值,
-- 不污染跑測試那台機器的真實環境。
module Aapms.Workspace.Fixtures
  ( -- * 臨時目錄與環境變數
    withTempHubDir
  , locAt
  , withEnv

    -- * 讀骨架原始碼(L17\/F002 L18 用)
  , readWorkspaceSource

    -- * 中樞檔案的讀寫(「數據」節「中樞路徑常數」表:@<hlPath>/config.toml@)
  , hubConfigFile
  , writeHubConfig
  , readHubConfigText

    -- * F002:vault marker 檔案的讀寫、目錄樹快照
  , vaultMarkerConfigFile
  , writeVaultMarker
  , markerTomlText
  , snapshotTree

    -- * F003:spec「數據」節「測試素材:一組固定的 vault 佈局」
  , ScopeVaults (..)
  , withScopeVaults

  , -- * id / 值 helper
    idOf
  , vaultIdText
  , orDie

    -- * 「數據」節的範例中樞檔案(X11–X17 用)
  , sampleHubText
  , sampleVault1
  , sampleVault2
  , sampleProject1
  , sampleLlmKeys
  , sampleTools

    -- * hedgehog 產生器
  , genHexChar
  , genHex8
  , genHex64
  , genName
  , genC0OrDelChar
  , genNameWithControlChars
  , genAbsPath
  , genVaultId
  , genProjectId
  , genVaultKind
  , genVaultEntry
  , genProjectEntry
  , genTomlValue
  , genLlmSection
  , genToolsConfig
  , genHubSourceText
  , genNonBlankEnvValue
  , genBlankEnvValue
  , genPaddedNonBlank
  , genRefIds
  ) where

import Control.Exception (bracket)
import qualified Data.Map.Strict as Map
import Data.List (intercalate, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified TOML

import Aapms.Core.Id (Id, VaultId (..), parseId)
import Aapms.Store.Schema (VaultKind (..))
import Aapms.Workspace.Types
  ( Hub
  , HubLocation (..)
  , HubSource (..)
  , LlmSection (..)
  , ProjectEntry (..)
  , ToolsConfig (..)
  , VaultEntry (..)
  , mkHub
  )

import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO
  ( IOMode (ReadMode, WriteMode)
  , hSetEncoding
  , hSetNewlineMode
  , noNewlineTranslation
  , utf8
  , withFile
  )
import System.IO.Temp (withSystemTempDirectory)

-- | 以顯式 UTF-8、__不做任何換行轉換__讀一個文字檔(對照 memory 的
-- 「hedgehog 在 cp950 下會蓋掉真正的失敗」——不能信任 handle 的預設編碼)。
readUtf8NoTranslate :: FilePath -> IO Text
readUtf8NoTranslate fp = withFile fp ReadMode $ \h -> do
  hSetEncoding h utf8
  hSetNewlineMode h noNewlineTranslation
  txt <- TIO.hGetContents h
  T.length txt `seq` pure txt

-- | 以顯式 UTF-8、__不加 BOM、不做任何換行轉換__寫一個文字檔;逐位元組對應
-- 'Text' 的內容,是 L8「位元組恆等」測試的基礎。
writeUtf8NoTranslate :: FilePath -> Text -> IO ()
writeUtf8NoTranslate fp content = withFile fp WriteMode $ \h -> do
  hSetEncoding h utf8
  hSetNewlineMode h noNewlineTranslation
  TIO.hPutStr h content

--------------------------------------------------------------------------------
-- 臨時目錄與環境變數

-- | 一個還沒有任何 @config.toml@ 的臨時目錄,測完自動刪除。
withTempHubDir :: (FilePath -> IO a) -> IO a
withTempHubDir = withSystemTempDirectory "aapms-hub"

-- | 把一個目錄包成 'HubLocation'。'hlSource' 對本檔的 'loadHub' \/ 'saveHub'
-- 測試不重要,固定填 'FromEnv'。
locAt :: FilePath -> HubLocation
locAt dir = HubLocation dir FromEnv

-- | 設定(或取消)一批環境變數跑一段動作,結束後還原成原本的值
-- (沒設過就還原成沒設)。@Nothing@ 表示「這段期間內取消設定」。
withEnv :: [(String, Maybe String)] -> IO a -> IO a
withEnv vars act = bracket save restore (const act)
  where
    save = mapM apply vars
    apply (k, mv) = do
      old <- lookupEnv k
      maybe (unsetEnv k) (setEnv k) mv
      pure (k, old)
    restore = mapM_ (\(k, mv) -> maybe (unsetEnv k) (setEnv k) mv)

-- | 中樞檔案的位置(「數據」節「中樞路徑常數」表的字面公式,不經過 'Aapms.Workspace.Location.configPath'
-- ——那個函式本身還沒實作,fixture 不能依賴它)。
hubConfigFile :: FilePath -> FilePath
hubConfigFile dir = dir </> "config.toml"

-- | 把一段文字原封不動(顯式 UTF-8、不加 BOM、不做換行轉換)寫成該目錄的
-- @config.toml@。
writeHubConfig :: FilePath -> Text -> IO ()
writeHubConfig dir = writeUtf8NoTranslate (hubConfigFile dir)

-- | 逐字元讀回該目錄的 @config.toml@(顯式 UTF-8、不做換行轉換,L8「位元組恆等」
-- 測試的基礎——'Text' 相等蘊含檔案內容逐字元相等)。
readHubConfigText :: FilePath -> IO Text
readHubConfigText dir = readUtf8NoTranslate (hubConfigFile dir)

-- | 讀本套件 @src\/@ 底下的骨架原始碼檔(L17 用:判準只看 import 行)。兩個候選
-- 路徑因為 @cabal test@ 的工作目錄在套件目錄或專案根不一定相同
-- (對照 "Aapms.Store.MarkerSpec" 的手法)。
readWorkspaceSource :: FilePath -> IO Text
readWorkspaceSource rel = go ["src" </> rel, "workspace" </> "src" </> rel]
  where
    go [] = fail ("找不到原始碼檔:" <> rel)
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then readUtf8NoTranslate c else go rest

--------------------------------------------------------------------------------
-- F002:vault marker 檔案的讀寫、目錄樹快照

-- | vault marker 檔案的位置。字面公式獨立算(spec「相依性查證」1:
-- @markerDir root = root \<\/\> ".aapms"@,@configPath@ 再接上 @config.toml@),
-- __不依賴__ 'Aapms.Store.Marker.configPath'——那是 production 介面,fixture 的
-- 期望值不能跟著 production 一起變動,否則斷言測不出任何東西。
vaultMarkerConfigFile :: FilePath -> FilePath
vaultMarkerConfigFile root = root </> ".aapms" </> "config.toml"

-- | 把一段文字原封不動(顯式 UTF-8、不加 BOM、不做換行轉換)寫成該 vault 根目錄的
-- @.aapms\/config.toml@(先建立 @.aapms\/@ 目錄)。
writeVaultMarker :: FilePath -> Text -> IO ()
writeVaultMarker root content = do
  createDirectoryIfMissing True (root </> ".aapms")
  writeUtf8NoTranslate (vaultMarkerConfigFile root) content

-- | spec「數據」節「測試素材:vault marker 的檔案格式」的字面樣板,四個欄位可代入。
markerTomlText :: Text -> Text -> Text -> [Text] -> Text
markerTomlText idText kindText nameText refs =
  T.unlines
    [ "id   = \"" <> idText <> "\""
    , "kind = \"" <> kindText <> "\""
    , "name = \"" <> nameText <> "\""
    , "refs = [" <> T.intercalate ", " (map (\r -> "\"" <> r <> "\"") refs) <> "]"
    ]

-- | 遞迴列出一個目錄底下所有檔案的相對路徑與內容,按路徑排序——F002 L4\/L13
-- 「呼叫前後整棵目錄樹逐位元組相同」斷言的基礎。本套件底下的檔案一律是顯式 UTF-8
-- 文字(marker \/ 中樞都是),用 'readUtf8NoTranslate' 讀回,'Text' 相等蘊含逐位元組
-- 相等(對照 'readHubConfigText' 對 L8 的同一個論證);沒有二進位檔要顧慮,不需要
-- 'Data.ByteString'(本測試套件的 build-depends 沒有它)。
snapshotTree :: FilePath -> IO [(FilePath, Text)]
snapshotTree root = sortOn fst <$> go ""
  where
    go rel = do
      let full = if null rel then root else root </> rel
      isDir <- doesDirectoryExist full
      if isDir
        then do
          entries <- listDirectory full
          concat <$> mapM (\e -> go (if null rel then e else rel </> e)) entries
        else do
          content <- readUtf8NoTranslate full
          pure [(rel, content)]

--------------------------------------------------------------------------------
-- F003:spec「數據」節「測試素材:一組固定的 vault 佈局」

-- | spec 表格裡的八個 vault(A–D、M、P、Z、E),一次建好在同一個暫存目錄 'svRoot'
-- 底下,型別與欄位值逐字照抄 spec 表(id \/ kind \/ name \/ refs、中樞 @veId@ \/
-- @veKind@ \/ @veName@)。@P@(@T\/gone@)刻意__不建立__;@E@(@T\/e@)刻意
-- __不進__ 'svHub'(未註冊);@M@ 只建 @.aapms\/@ 目錄、__不寫__ @config.toml@
-- (marker 壞)。'svHub' 的 @[[vaults]]@ 順序固定是 A, B, C, D, M, P, Z(spec 原文)。
data ScopeVaults = ScopeVaults
  { svRoot :: FilePath
  , svPathA :: FilePath
  , svPathB :: FilePath
  , svPathC :: FilePath
  , svPathD :: FilePath
  , svPathM :: FilePath
  , svPathGone :: FilePath
  , svPathZ :: FilePath
  , svPathE :: FilePath
  , svEntryA :: VaultEntry
  , svEntryB :: VaultEntry
  , svEntryC :: VaultEntry
  , svEntryD :: VaultEntry
  , svEntryM :: VaultEntry
  , svEntryP :: VaultEntry
  , svEntryZ :: VaultEntry
  , svHub :: Hub
  }

-- | 建好 'ScopeVaults' 佈局,交給動作跑;動作結束後暫存目錄整個刪掉
-- (經 'withTempHubDir')。
withScopeVaults :: (ScopeVaults -> IO a) -> IO a
withScopeVaults act = withTempHubDir $ \root -> do
  let pathA = root </> "a"
      pathB = root </> "b"
      pathC = root </> "c"
      pathD = root </> "d"
      pathM = root </> "m"
      pathGone = root </> "gone"
      pathZ = root </> "z"
      pathE = root </> "e"
  writeVaultMarker pathA (markerTomlText "vlt-aaaa1111" "asset" "a" ["vlt-bbbb2222"])
  writeVaultMarker pathB (markerTomlText "vlt-bbbb2222" "story" "b" ["vlt-cccc3333"])
  writeVaultMarker pathC (markerTomlText "vlt-cccc3333" "asset" "c" ["vlt-aaaa1111"])
  writeVaultMarker pathD (markerTomlText "vlt-dddd4444" "asset" "d" [])
  createDirectoryIfMissing True (pathM </> ".aapms") -- .aapms/ 在,沒有 config.toml：marker 壞
  writeVaultMarker pathZ (markerTomlText "vlt-99998888" "asset" "z" [])
  writeVaultMarker pathE (markerTomlText "vlt-eeee5555" "story" "e" [])
  let entryA = VaultEntry (VaultId "vlt-aaaa1111") "a" AssetVault pathA
      entryB = VaultEntry (VaultId "vlt-bbbb2222") "b" StoryVault pathB
      entryC = VaultEntry (VaultId "vlt-cccc3333") "c" AssetVault pathC
      entryD = VaultEntry (VaultId "vlt-dddd4444") "d" AssetVault pathD
      entryM = VaultEntry (VaultId "vlt-mmmm1111") "m" AssetVault pathM
      entryP = VaultEntry (VaultId "vlt-pppp1111") "p" AssetVault pathGone
      entryZ = VaultEntry (VaultId "vlt-77776666") "z" AssetVault pathZ -- 與 marker 的 vlt-99998888 不符：id 漂移
      hub =
        mkHub
          [entryA, entryB, entryC, entryD, entryM, entryP, entryZ]
          []
          Nothing
          (ToolsConfig Nothing)
          ""
  act
    ScopeVaults
      { svRoot = root
      , svPathA = pathA
      , svPathB = pathB
      , svPathC = pathC
      , svPathD = pathD
      , svPathM = pathM
      , svPathGone = pathGone
      , svPathZ = pathZ
      , svPathE = pathE
      , svEntryA = entryA
      , svEntryB = entryB
      , svEntryC = entryC
      , svEntryD = entryD
      , svEntryM = entryM
      , svEntryP = entryP
      , svEntryZ = entryZ
      , svHub = hub
      }

--------------------------------------------------------------------------------
-- id / 值 helper

-- | 測試裡用到的合法 id,剖析失敗直接讓測試爆掉並印出原因
-- (對照 "Aapms.Store.Fixtures.idOf")。
idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)

-- | 'VaultId' 底下的原始文字。
vaultIdText :: VaultId -> Text
vaultIdText (VaultId t) = t

-- | 攤平一個測試前置作業裡「一定得成功」的 'Either',失敗時讓測試崩潰並印出原因
-- (對照 "Aapms.Store.Fixtures.orDie")——用來取代 do-block 裡的不完整 pattern
-- match,失敗時的訊息才看得出是哪一步、為什麼。
orDie :: Show e => Either e a -> IO a
orDie = either (\e -> fail ("測試前置作業失敗:" <> show e)) pure

--------------------------------------------------------------------------------
-- 「數據」節的範例中樞檔案

-- | spec「數據」節「測試素材:一份『有註解與空白行』的合法中樞」,逐字抄錄。
sampleHubText :: Text
sampleHubText =
  T.unlines
    [ "# 我的中樞設定 —— 手寫,請勿用工具整檔重寫"
    , ""
    , "[[vaults]]"
    , "id   = \"vlt-7f3b2a91\""
    , "name = \"alchbees-assets\""
    , "kind = \"asset\"          # 素材庫"
    , "path = \"C:/Users/User/Documents/alchbees-assets\""
    , ""
    , "# 故事側"
    , "[[vaults]]"
    , "id   = \"vlt-a0c4e1f8\""
    , "name = \"liftgame\""
    , "kind = \"story\""
    , "path = \"D:/story-vaults/liftgame\""
    , ""
    , "[[projects]]"
    , "id   = \"prj-91c0aa12\""
    , "name = \"Circle\""
    , "path = \"D:/games/Circle\""
    , ""
    , "[llm]"
    , "base_url = \"http://127.0.0.1:8080/v1\""
    , "model    = \"qwen2.5-7b-instruct\""
    , ""
    , "[tools]"
    , "seven_zip = \"C:/Program Files/7-Zip/7z.exe\""
    ]

-- | X11 期望的第一列 @[[vaults]]@。
sampleVault1 :: VaultEntry
sampleVault1 =
  VaultEntry
    { veId = VaultId "vlt-7f3b2a91"
    , veName = "alchbees-assets"
    , veKind = AssetVault
    , vePath = "C:/Users/User/Documents/alchbees-assets"
    }

-- | X11 期望的第二列 @[[vaults]]@。
sampleVault2 :: VaultEntry
sampleVault2 =
  VaultEntry
    { veId = VaultId "vlt-a0c4e1f8"
    , veName = "liftgame"
    , veKind = StoryVault
    , vePath = "D:/story-vaults/liftgame"
    }

-- | X11 期望的 @[[projects]]@ 唯一一列。
sampleProject1 :: ProjectEntry
sampleProject1 =
  ProjectEntry
    { peId = idOf "prj-91c0aa12"
    , peName = "Circle"
    , pePath = "D:/games/Circle"
    }

-- | X11 期望 @[llm]@ 段的鍵集合。
sampleLlmKeys :: [Text]
sampleLlmKeys = ["base_url", "model"]

-- | X11 期望的 @[tools]@ 段。
sampleTools :: ToolsConfig
sampleTools = ToolsConfig (Just "C:/Program Files/7-Zip/7z.exe")

--------------------------------------------------------------------------------
-- hedgehog 產生器

genHexChar :: Gen Char
genHexChar = Gen.element (['0' .. '9'] ++ ['a' .. 'f'])

-- | 8 位小寫十六進位(@vlt-@\/@prj-@ 後半段)。
genHex8 :: Gen Text
genHex8 = Gen.text (Range.singleton 8) genHexChar

-- | 64 位小寫十六進位(@Sha256@ 的內容)。
genHex64 :: Gen Text
genHex64 = Gen.text (Range.singleton 64) genHexChar

-- | 非空的一般名稱(ASCII 字母數字,1–10 字):給 'veName' \/ 'peName' 用。
genName :: Gen Text
genName = Gen.text (Range.linear 1 10) (Gen.choice [Gen.alpha, Gen.digit])

-- | 任意 C0 控制字元(U+0000–U+001F)或 DEL(U+007F)——__真的涵蓋__ @\\n@ \/ @\\t@,
-- 不是只挑「安全」的子集(F001 L18 明文要求定義域包含控制字元;同一波另一份 spec
-- 曾為了迴避序列化器缺陷把定義域縮小到「不含控制字元」,那正是要避免的錯誤)。
genC0OrDelChar :: Gen Char
genC0OrDelChar = Gen.element (['\x00' .. '\x1F'] ++ ['\x7F'])

-- | 去前後空白後非空、且__真的可能含控制字元__(含 @\\n@ \/ @\\t@ \/ 其他 U+0000–U+001F \/
-- U+007F)的名稱:給 'veName' \/ 'peName' 的 L18(完整定義域往返)用。頭尾各釘一個
-- ASCII 字母當「錨點」,保證 'Data.Text.strip' 之後一定非空(錨點本身不是空白字元),
-- 中段可以是任意控制字元或一般字元的混合,涵蓋整個定義域而不排除任何一種控制字元。
genNameWithControlChars :: Gen Text
genNameWithControlChars = do
  start <- Gen.alpha
  end <- Gen.alpha
  middle <-
    Gen.text (Range.linear 0 12) (Gen.choice [genC0OrDelChar, Gen.alpha, Gen.digit])
  pure (T.singleton start <> middle <> T.singleton end)

genPathSegment :: Gen String
genPathSegment = T.unpack <$> Gen.text (Range.linear 1 8) (Gen.choice [Gen.alpha, Gen.digit])

-- | 帶磁碟代號的絕對路徑(Windows 風格),例如 @"C:/ab3/xy"@。
genAbsPath :: Gen FilePath
genAbsPath = do
  drive <- Gen.element ['C', 'D', 'E']
  segs <- Gen.list (Range.linear 1 3) genPathSegment
  pure (drive : ":/" <> intercalate "/" segs)

genVaultId :: Gen VaultId
genVaultId = VaultId . ("vlt-" <>) <$> genHex8

-- | 合法的 @prj-@ id,經 'parseId' 剖析而來(不是直接組字串,'Id' 不透明)。
genProjectId :: Gen Id
genProjectId = do
  hex <- genHex8
  case parseId ("prj-" <> hex) of
    Right (_, i) -> pure i
    Left _ -> Gen.discard

genVaultKind :: Gen VaultKind
genVaultKind = Gen.element [AssetVault, StoryVault]

genVaultEntry :: Gen VaultEntry
genVaultEntry = VaultEntry <$> genVaultId <*> genName <*> genVaultKind <*> genAbsPath

genProjectEntry :: Gen ProjectEntry
genProjectEntry = ProjectEntry <$> genProjectId <*> genName <*> genAbsPath

-- | 任意 'TOML.Value'(只取三種簡單建構子,'LlmSection' 不解讀內容,值的形狀
-- 對 L16\/L7 的斷言不重要,重要的是「捧著什麼就是什麼」)。
genTomlValue :: Gen TOML.Value
genTomlValue =
  Gen.choice
    [ TOML.String <$> genName
    , TOML.Integer <$> Gen.integral (Range.linear 0 1000)
    , TOML.Boolean <$> Gen.bool
    ]

genLlmSection :: Gen LlmSection
genLlmSection =
  LlmSection . Map.fromList <$> Gen.list (Range.linear 0 5) ((,) <$> genName <*> genTomlValue)

genToolsConfig :: Gen ToolsConfig
genToolsConfig = ToolsConfig <$> Gen.maybe genAbsPath

-- | 任意文字,給 'hubSourceText' 這種「不解讀、只保留」的欄位用。
genHubSourceText :: Gen Text
genHubSourceText =
  Gen.text (Range.linear 0 20) (Gen.choice [Gen.alpha, Gen.digit, Gen.element (" \n#[]=.,-_/" :: String)])

-- | 去前後空白後非空、且本身不帶前後空白的字串,當 @AAPMS_HOME@ 的值(L1)。
genNonBlankEnvValue :: Gen Text
genNonBlankEnvValue = do
  drive <- Gen.element ['C', 'D', 'E']
  segs <- Gen.list (Range.linear 1 3) genPathSegment
  pure (T.pack (drive : ":/" <> intercalate "/" segs))

-- | 全空白(含空字串)的字串,當 @AAPMS_HOME@ 的值視同未設(L1)。
genBlankEnvValue :: Gen Text
genBlankEnvValue = Gen.text (Range.linear 0 4) (Gen.element (" \t" :: String))

-- | 前後帶空白、但去除空白後非空的字串——驗證 L1「@hlPath == s 的 makeAbsolute@」
-- 是對__原始__ @s@ 生效,不是先去空白再取絕對路徑。
genPaddedNonBlank :: Gen Text
genPaddedNonBlank = do
  pre <- Gen.text (Range.linear 0 2) (pure ' ')
  core <- genNonBlankEnvValue
  post <- Gen.text (Range.linear 0 2) (pure ' ')
  pure (pre <> core <> post)

-- | F002 L17:任意長度的 @vlt-@ id 字串清單,給 marker 的 @refs@ 欄位用(本 feature
-- 不展開、不驗證 refs 指向誰,所以生成器不必保證這些 id 真的存在)。
genRefIds :: Gen [Text]
genRefIds = Gen.list (Range.linear 0 4) (("vlt-" <>) <$> genHex8)
