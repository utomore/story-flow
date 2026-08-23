-- | 叢集規則的持久化與套用。
--
-- 資料庫存的是**規則**而不是結果。廠商出更新版時,新檔案只要形狀相同
-- 就自動套用既有規則 —— 不需要重新確認一次。
module AssetDB.Ingest.ClusterDb
  ( PackRef (..)
  , listPacks
  , packPaths
  , packClusters
  , saveRule
  , loadRules
  , NamePreview (..)
  , previewCluster
  , ApplyNames (..)
  , applyNames
  ) where

import AssetDB.Ingest.Cluster
import AssetDB.Naming
import AssetDB.Guard (guardedTry)
import AssetDB.Store
import AssetDB.Store.Errors (renderUnexpected)
import Data.Aeson (ToJSON, decodeStrict, encode)
import Data.ByteString.Lazy qualified as BL
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple

data PackRef = PackRef
  { pkId :: Int
  , pkSlug :: Text
  , pkName :: Text
  }
  deriving stock (Eq, Show)

instance FromRow PackRef where
  fromRow = PackRef <$> field <*> field <*> field

listPacks :: Store -> Maybe Text -> IO [PackRef]
listPacks st mSlug =
  query
    (storeConn st)
    "SELECT id, slug, name FROM packs WHERE (? IS NULL OR slug = ?) ORDER BY slug"
    (mSlug, mSlug)

packPaths :: Store -> Int -> IO [Text]
packPaths st pid =
  map fromOnly
    <$> query
      (storeConn st)
      "SELECT entry_path FROM assets \
      \WHERE pack_id = ? AND entry_path IS NOT NULL ORDER BY entry_path"
      (Only pid)

packClusters :: Store -> Int -> IO [Cluster]
packClusters st pid = clusterBy <$> packPaths st pid

--------------------------------------------------------------------------------
-- 規則

saveRule :: Store -> Int -> Cluster -> NameRule -> IO ()
saveRule st pid cl rule = do
  now <- T.pack . iso8601Show <$> getCurrentTime
  execute
    (storeConn st)
    "INSERT INTO name_clusters (pack_id, shape, member_count, sample_json, rule_json, confirmed_by, confirmed_at) \
    \VALUES (?,?,?,?,?,'local',?) \
    \ON CONFLICT (pack_id, shape) DO UPDATE SET \
    \  member_count = excluded.member_count, \
    \  sample_json  = excluded.sample_json, \
    \  rule_json    = excluded.rule_json, \
    \  confirmed_by = excluded.confirmed_by, \
    \  confirmed_at = excluded.confirmed_at"
    ( pid
    , clusterKeyText (clKey cl)
    , clCount cl
    , jsonText (clSamples cl)
    , jsonText rule
    , now
    )

loadRules :: Store -> Int -> IO (Map.Map Text NameRule)
loadRules st pid = do
  rows <-
    query
      (storeConn st)
      "SELECT shape, rule_json FROM name_clusters WHERE pack_id = ? AND rule_json IS NOT NULL"
      (Only pid) ::
      IO [(Text, Text)]
  pure (Map.fromList [(s, r) | (s, j) <- rows, Just r <- [decodeStrict (encodeUtf8 j)]])

--------------------------------------------------------------------------------
-- 預覽

data NamePreview = NamePreview
  { npPath :: Text
  , npResult :: Either Text Text
  }
  deriving stock (Eq, Show)

-- | 對叢集的樣本套用規則,不寫入任何東西。
--
-- 確認之前一定要看得到結果。規則的參數(丟哪個權杖、數字當變體還是格號)
-- 抽象到人腦裡難以驗證,但「這 5 個檔案會變成這 5 個名字」一眼就能判斷對錯。
previewCluster :: NamingVocab -> NameRule -> [Text] -> [NamePreview]
previewCluster vocab rule =
  map (\p -> NamePreview p (either (Left . renderNameError) (Right . logicalNameText) (applyRule vocab rule p)))

--------------------------------------------------------------------------------
-- 套用

data ApplyNames = ApplyNames
  { anNamed :: Int
  , anSkipped :: Int
  -- ^ 所屬叢集尚未確認規則。
  , anFailed :: [(Text, Text)]
  -- ^ (路徑, 錯誤)
  , anCollisions :: [(Text, [Text])]
  -- ^ (邏輯名稱, 撞名的路徑)
  , anNames :: [(Text, Text)]
  -- ^ (項目路徑, 邏輯名稱) —— 通過驗證且不撞名的那些,也就是**會被寫入或
  -- 已被寫入**的完整對應。預覽模式靠它讓人看見「這個檔案會變成這個名字」;
  -- 有撞名或失敗時是空的(那種情況一筆都不寫)。
  }
  deriving stock (Eq, Show)

-- | 對一個素材包套用所有已確認的規則。
--
-- **撞名在寫入之前就攔下來。** @logical_name@ 有 UNIQUE 約束,
-- 邊算邊寫的話第一個撞到的會讓整批交易失敗,而且不知道還有多少個。
-- 先全部算完、找出所有撞名、一次回報,人才能一次修完規則。
applyNames :: Store -> NamingVocab -> Int -> Bool -> IO ApplyNames
applyNames st vocab pid confirm = do
  rules <- loadRules st pid
  paths <- packPaths st pid

  let resolved =
        [ (p, Map.lookup (shapeKeyOf p) rules)
        | p <- paths
        ]

      skipped = length [() | (_, Nothing) <- resolved]

      computed =
        [ (p, applyRule vocab r p)
        | (p, Just r) <- resolved
        ]

      failures = [(p, renderNameError e) | (p, Left e) <- computed]
      oks = [(p, logicalNameText n) | (p, Right n) <- computed]

      byName = Map.fromListWith (<>) [(n, [p]) | (p, n) <- oks]
      collisions = [(n, ps) | (n, ps) <- Map.toList byName, length ps > 1]
      safe = [(p, n) | (p, n) <- oks, maybe False ((== 1) . length) (Map.lookup n byName)]

  if null collisions && null failures
    then do
      -- 未確認時到此為止:計算全部做完(所以預覽的數字與名字就是實際會發生的),
      -- 但不進交易。預覽與套用共用這一整段,兩者不可能漂移(G-B001)。
      -- 撞名檢查只在**這一包內**建表,而 logical_name 是**全域唯一**的
      -- (ADR-004)—— 跨包撞名會撞 UNIQUE。少了這個出口的話,一個跨包的
      -- 重名會讓整個 cluster apply 以 SQLite 的 constraint 錯誤崩掉,而
      -- 使用者看不出是哪一筆(G-E003)。
      w <-
        if confirm
          then do
            now <- T.pack . iso8601Show <$> getCurrentTime
            guardedTry $
              withTransaction (storeConn st) $
                mapM_
                  ( \(p, n) ->
                      execute
                        (storeConn st)
                        "UPDATE assets SET logical_name = ?, updated_at = ? WHERE pack_id = ? AND entry_path = ?"
                        (n, now, pid, p)
                  )
                  safe
          else pure (Right ())
      case w of
        -- 全有全無:寫入是一個交易,失敗就整批回滾,所以這裡一筆都沒寫進去。
        Left e -> pure (ApplyNames 0 skipped [("(整批寫入)", renderUnexpected e)] [] [])
        Right () -> pure (ApplyNames (length safe) skipped [] [] safe)
    else
      -- 有問題就**什麼都不寫**。半套用的命名比沒有命名更難收拾:
      -- 你不知道哪些是舊的、哪些是新的。
      pure (ApplyNames 0 skipped failures (sortOn fst collisions) [])

shapeKeyOf :: Text -> Text
shapeKeyOf = clusterKeyText . clusterKeyOf

jsonText :: ToJSON a => a -> Text
jsonText = decodeUtf8Lenient . BL.toStrict . encode
