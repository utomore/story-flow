-- | 契約 4:相依方向(system.md「通訊拓撲與原則」的四條硬規則)。
--
-- 逐字清單,不是黑名單推理:每條規則寫死「誰不准出現在誰的 build-depends」。
-- 套件還沒建的(P3 之後才有的 workspace / archive / …)自動略過;建了就自動受檢。
--
-- 只讀 @.cabal@ 檔的文字,不依賴 Cabal library——這個測試本身也要守「不依賴內部型別」。
module Aapms.Contract.CabalRulesSpec (spec) where

import Control.Monad (filterM, forM, forM_, unless)
import Data.Char (isSpace)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.List (isPrefixOf, isSuffixOf, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import Test.Hspec

-- 讀 .cabal ------------------------------------------------------------------

data Stanza = Stanza {stKind :: String, stDeps :: Set String}

-- | 一份 .cabal → (套件名, 各 stanza 的 build-depends)。
-- 只認最上層 stanza(library / executable / test-suite / benchmark / common);
-- @common@ 的相依保守地併進 library 與 executable。
parseCabal :: String -> (String, [Stanza])
parseCabal src = (pkgName, withCommon)
  where
    ls = lines src
    pkgName = case [trim (drop 5 l) | l <- ls, "name:" `isPrefixOf` l] of { (n : _) -> n; [] -> "?" }
    -- 切 stanza:頂格且以 stanza 關鍵字開頭的行
    isHeader l = startsNonSpace l && any (`isPrefixOf` map toLowerAscii l) stanzaKinds
    stanzaKinds = ["library", "executable", "test-suite", "benchmark", "common", "flag", "source-repository"]
    chunks = splitOn isHeader ls
    stanzas = [Stanza (headWord h) (depsOf body) | (h : body) <- chunks, isHeader h]
    commonDeps = S.unions [stDeps s | s <- stanzas, stKind s == "common"]
    withCommon =
      [ if stKind s `elem` ["library", "executable"] then s {stDeps = stDeps s `S.union` commonDeps} else s
      | s <- stanzas
      ]
    headWord = map toLowerAscii . takeWhile (not . isSpace)
    toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | 從一個 stanza 的內文抓 build-depends 的套件名。
depsOf :: [String] -> Set String
depsOf body = S.fromList (concatMap names (fieldValues "build-depends" body))
  where
    names line = mapMaybe pkg (splitOn' ',' line)
    pkg s = case words (dropWhile (== ',') (trim s)) of
      (n : _) | not (null n), not ("--" `isPrefixOf` n) -> Just (takeWhile (\c -> c /= ':' && c /= '{') n)
      _ -> Nothing

-- | 某個欄位(含延續行)的值;欄位可能出現多次(例如 if 分支裡),全部收。
fieldValues :: String -> [String] -> [String]
fieldValues field = go
  where
    go [] = []
    go (l : rest)
      | isField l =
          let inline = dropFieldName l
              (cont, rest') = span isContinuation rest
           in (inline : map stripComment cont) <> go rest'
      | otherwise = go rest
    isField l = (field <> ":") `isPrefixOf` trim (map toLowerAscii' l)
    dropFieldName l = stripComment (drop (length field + 1) (trim l))
    -- 延續行:縮排且不是另一個欄位(「字:」開頭)
    isContinuation l = not (null (trim l)) && not (startsNonSpace l) && not (looksLikeField l)
    looksLikeField l = case break (== ':') (trim l) of
      (k, ':' : _) -> not (null k) && all (\c -> c `elem` ("-abcdefghijklmnopqrstuvwxyz" :: String)) (map toLowerAscii' k)
      _ -> False
    stripComment = takeWhile' . trim
    takeWhile' s = case breakOn "--" s of (a, _) -> a
    toLowerAscii' c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

breakOn :: String -> String -> (String, String)
breakOn pat = go []
  where
    go acc s@(c : cs)
      | pat `isPrefixOf` s = (reverse acc, s)
      | otherwise = go (c : acc) cs
    go acc [] = (reverse acc, [])

splitOn :: (a -> Bool) -> [a] -> [[a]]
splitOn p xs = case break p xs of
  (pre, []) -> [pre | not (null pre)]
  (pre, h : rest) -> [pre | not (null pre)] <> go h rest
  where
    go h rest = case break p rest of
      (body, []) -> [h : body]
      (body, h' : rest') -> (h : body) : go h' rest'

splitOn' :: Char -> String -> [String]
splitOn' c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn' c rest

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- 找套件 ---------------------------------------------------------------------

-- | 專案根目錄下每個套件目錄的 .cabal(略過 legacy/ 與隱藏目錄)。
findCabals :: IO (M.Map String [Stanza])
findCabals = do
  let root = ".."
  dirs <- listDirectory root >>= filterM (\d -> doesDirectoryExist (root </> d))
  let candidates = [d | d <- sort dirs, not ("." `isPrefixOf` d), d `notElem` ["legacy", "dist-newstyle", "docs", "scripts"]]
  files <- fmap concat . forM candidates $ \d -> do
    fs <- listDirectory (root </> d)
    pure [root </> d </> f | f <- fs, ".cabal" `isSuffixOf` f]
  parsed <- forM files (fmap parseCabal . readUtf8)
  pure (M.fromList parsed)

libDeps, libAndExeDeps :: [Stanza] -> Set String
libDeps ss = S.unions [stDeps s | s <- ss, stKind s == "library"]
libAndExeDeps ss = S.unions [stDeps s | s <- ss, stKind s `elem` ["library", "executable"]]

-- 規則 -----------------------------------------------------------------------

domainAndShell :: [String]
domainAndShell =
  [ "aapms-archive", "aapms-ingest", "aapms-reorg"
  , "aapms-conflict", "aapms-llm", "aapms-ai", "aapms-workshop", "aapms-project"
  , "aapms-api", "aapms-cli", "aapms-server", "aapms-mcp"
  ]

foundation :: [String]
foundation = ["aapms-core", "aapms-types", "aapms-md", "aapms-store", "aapms-workspace"]

heavy :: [String]
heavy = ["aapms-archive", "aapms-ingest", "aapms-reorg", "zip", "zip-archive", "JuicyPixels", "typed-process", "conduit"]

-- | aapms-core 的 build-depends 逐字清單(system.md 規則 4:遊戲本體的相依面)。
-- 要加新相依就改這裡——這個動作本身就是一次架構決定,不該悄悄發生。
coreAllowed :: [String]
coreAllowed =
  [ "base", "aeson", "bytestring", "containers", "text", "time"
  , "unordered-containers", "vector", "scientific", "hashable", "deepseq", "mtl", "transformers"
  ]

-- | 「A 的 build-depends 不得含 B 清單」。套件不存在就略過。
forbid :: M.Map String [Stanza] -> ([Stanza] -> Set String) -> String -> [String] -> Expectation
forbid pkgs sel who banned = case M.lookup who pkgs of
  Nothing -> pure ()
  Just ss -> do
    let hit = S.toList (sel ss `S.intersection` S.fromList banned)
    unless (null hit) $
      expectationFailure (who <> " 的 build-depends 含禁止的相依:" <> show hit)

spec :: Spec
spec = describe "相依方向(CabalSpec,逐字清單)" $ do
  it "找得到套件(至少 aapms-core / aapms-service / aapms-contract)" $ do
    pkgs <- findCabals
    forM_ ["aapms-core", "aapms-service", "aapms-contract"] $ \p ->
      M.member p pkgs `shouldBe` True

  it "規則 1:契約層單向——aapms-service 不 import 任何領域或外殼套件" $ do
    pkgs <- findCabals
    forbid pkgs libDeps "aapms-service" domainAndShell

  it "規則 2:地基不認識上面——graph-core / workspace 不 import service 以上" $ do
    pkgs <- findCabals
    forM_ foundation $ \p -> forbid pkgs libDeps p ("aapms-service" : domainAndShell)

  it "規則 3:重量級相依隔離——api / server / mcp 不依賴 archive / ingest / reorg 與影像、壓縮、子程序套件" $ do
    pkgs <- findCabals
    forM_ ["aapms-api", "aapms-server", "aapms-mcp"] $ \p -> forbid pkgs libAndExeDeps p heavy

  it "規則 4:aapms-core 的 build-depends 只能是逐字清單上的純套件" $ do
    pkgs <- findCabals
    case M.lookup "aapms-core" pkgs of
      Nothing -> expectationFailure "找不到 aapms-core"
      Just ss -> do
        -- 先確認解析器真的讀到東西,否則空集合會讓這條規則空洞地通過
        S.member "base" (libDeps ss) `shouldBe` True
        S.member "aeson" (libDeps ss) `shouldBe` True
        let extra = S.toList (libDeps ss `S.difference` S.fromList coreAllowed)
        unless (null extra) $
          expectationFailure ("aapms-core 多了清單外的相依:" <> show extra <> ";要加就同時更新 CabalRulesSpec.coreAllowed")

  it "自檢:契約測試本身不依賴任何 aapms-* library" $ do
    pkgs <- findCabals
    case M.lookup "aapms-contract" pkgs of
      Nothing -> expectationFailure "找不到 aapms-contract"
      Just ss -> do
        S.member "hspec" (S.unions (map stDeps ss)) `shouldBe` True
        let libs = [d | d <- S.toList (S.unions (map stDeps ss)), "aapms-" `isPrefixOf` d]
        libs `shouldBe` []

startsNonSpace :: String -> Bool
startsNonSpace (c : _) = not (isSpace c)
startsNonSpace [] = False

-- | 以位元組讀、自己解 UTF-8:@readFile@ 依 locale 解碼,Windows 的 cp950 會對繁中註解炸掉。
readUtf8 :: FilePath -> IO String
readUtf8 p = T.unpack . TE.decodeUtf8 <$> BS.readFile p
