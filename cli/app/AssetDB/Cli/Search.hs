module AssetDB.Cli.Search
  ( SearchArgs (..)
  , runSearch
  , runIndex
  ) where

import AssetDB.Store
import AssetDB.Store.Index
import AssetDB.Store.Search
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO

data SearchArgs = SearchArgs
  { seText :: Maybe Text
  , seKinds :: [Text]
  , sePacks :: [Text]
  , seAuthors :: [Text]
  , seVendors :: [Text]
  , seCommercial :: Bool
  , seNamed :: Bool
  , seIncludeExcluded :: Bool
  , seIncludeReference :: Bool
  , seLimit :: Int
  , seFacets :: Bool
  }

runSearch :: FilePath -> SearchArgs -> IO ()
runSearch dbPath SearchArgs {..} =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    let conn = storeConn st

    stale <- ftsStale conn
    if stale
      then TIO.putStrLn "⚠ 全文索引與資源表筆數不符,結果可能不完整。執行 assetdb index 重建。\n"
      else pure ()

    let q =
          emptyQuery
            { sqText = seText
            , sqKinds = seKinds
            , sqPacks = sePacks
            , sqAuthors = seAuthors
            , sqVendors = seVendors
            , sqCommercialOnly = seCommercial
            , sqNamedOnly = seNamed
            , sqIncludeExcluded = seIncludeExcluded
            , sqIncludeReference = seIncludeReference
            , sqLimit = seLimit
            }

    total <- searchCount conn q
    hits <- search conn q

    mapM_ renderHit hits
    TIO.putStrLn ""
    TIO.putStrLn
      ( "共 " <> tshow total <> " 筆"
          <> (if total > length hits then ",顯示前 " <> tshow (length hits) else "")
      )

    if seFacets
      then do
        fc <- facetCounts conn q
        TIO.putStrLn ""
        renderFacet "類型" (fcKinds fc)
        renderFacet "廠商" (fcVendors fc)
        renderFacet "作者" (fcAuthors fc)
        renderFacet "素材包" (take 12 (fcPacks fc))
      else pure ()

renderHit :: SearchHit -> IO ()
renderHit SearchHit {..} = do
  TIO.putStrLn (maybe ("(未命名) " <> hitOriginal) id hitLogical)
  TIO.putStrLn
    ( "    " <> pad 8 hitKind
        <> pad 30 (ellipsis 28 (maybe "—" id hitPack))
        <> maybe "" (<> "  ") hitAuthor
    )
  TIO.putStrLn ("    " <> dim hitPath)
  where
    dim = id

renderFacet :: Text -> [(Text, Int)] -> IO ()
renderFacet _ [] = pure ()
renderFacet title xs = do
  TIO.putStrLn ("── " <> title)
  mapM_ (\(k, n) -> TIO.putStrLn ("  " <> pad 34 (ellipsis 32 k) <> tshow n)) xs
  TIO.putStrLn ""

--------------------------------------------------------------------------------

runIndex :: FilePath -> IO ()
runIndex dbPath =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    n <- reindexFts (storeConn st)
    (fts, cjk) <- ftsRowCount (storeConn st)
    TIO.putStrLn ("重建完成:" <> tshow n <> " 筆資源")
    TIO.putStrLn ("  assets_fts " <> tshow fts <> "(trigram,ASCII 與三字以上中文)")
    TIO.putStrLn ("  assets_cjk " <> tshow cjk <> "(unicode61 + n-gram,兩字以下中文)")

--------------------------------------------------------------------------------

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - displayWidth t)) " "

-- | 中文字在等寬終端機佔兩格。
displayWidth :: Text -> Int
displayWidth = sum . map (\c -> if fromEnum c > 0x1100 then 2 else 1) . T.unpack

ellipsis :: Int -> Text -> Text
ellipsis n t = if T.length t <= n then t else T.take (n - 1) t <> "…"

tshow :: Show a => a -> Text
tshow = T.pack . show
