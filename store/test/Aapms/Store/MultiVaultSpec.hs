-- | graph-core\/F009:"Aapms.Store.MultiVault" 的 'VaultSet' 三型別 + 九函式,
-- 以及 "Aapms.Store.Error" 新增的 'TooManyVaults' \/ 'VaultIdCollision' 兩個
-- 建構子的訊息。
--
-- __spec 對照__(@.design\/subsystems\/graph-core\/features\/F009-store-multi-vault-read.md@):
--
-- @
-- L1   openVaultSet 去重與上限(撞號優先於上限的分工見 L1b)      -> prop_L1_dedupe_and_limit / test_L1_dedupe_at_limit_boundary
-- L1b  openVaultSet 撞號 -> VaultIdCollision,優先於上限          -> prop_L1b_collision / test_L1b_collision_over_limit
-- L2   closeVaultSet 之後單一 vault 讀取不受影響                -> test_L2
-- L3   openVaultSet 之後單一 vault 讀取不受任何 *Across 呼叫影響 -> test_L3
-- L4   listAcross 的多重集合等於逐 vault listNodes 的多重集合   -> prop_L4
-- L5   listAcross 全域排序(metaId,平手比 vault)               -> prop_L5
-- L6   listAcross 分頁是對整體切窗                              -> prop_L6
-- L7   listAcross 每筆的 vault 欄與 metaVault 一致              -> prop_L7
-- L8   searchAcross 逐 vault 等價(四欄全比)                    -> prop_L8
-- L9   searchAcross 全域排序                                    -> prop_L9
-- L10  searchAcross 分頁與 srTotal                              -> prop_L10
-- L11  searchAcross 每筆 vault 欄一致                           -> prop_L11
-- L12  facet(Just/Nothing、fcVaults 求和、四維度求和、零命中濾除)-> prop_L12_toggle / prop_L12_sum / test_L12_zero_hit_filtered
-- L13  lookupRef 帶 vault 的 Ref 只認自己那個 vault              -> prop_L13
-- L14  lookupRef 預設 vault                                     -> prop_L14
-- L15  lookupRef vault 不在集合裡 -> Nothing                    -> prop_L15
-- L16  checkReferences 完整且不多報                             -> test_L16
-- L17  renderDanglingRef                                        -> test_L17
-- L18  空集合退化                                                -> test_L18
-- L19  單一 vault 退化成 F006\/F007                              -> test_L19
-- L20  TooManyVaults\/VaultIdCollision 的 renderStoreError       -> prop_L20 / test_L20_examples
-- E1   searchAcross 一次回兩種 vault                             -> test_E1
-- E2   listAcross 排序與分頁跨 vault                             -> test_E2
-- E3   lookupRef 預設 vault 解析                                 -> test_E3
-- E4   lookupRef 帶 vault 覆蓋預設 vault                         -> test_E4
-- E5   lookupRef 目標 vault 不在集合裡                           -> test_E5
-- E6   openVaultSet 第 11 個 vault -> TooManyVaults              -> test_E6
-- E7   同路徑重複 -> 保序去重                                    -> test_E7
-- E8   checkReferences 兩種懸空各一筆,不誤報                    -> test_E8
-- E9   renderDanglingRef 兩則訊息                                -> test_E9
-- E10  空集合下 *Across 全空、checkReferences 全 TargetVaultAbsent -> test_E10
-- E11  單一 vault 退化                                           -> test_E11
-- E12  facet 的 vault 維度、VaultSet 不接管把手生命週期          -> test_E12
-- E13  異路徑撞號 -> VaultIdCollision                            -> test_E13
-- E14  撞號優先於上限                                            -> test_E14
-- E15  renderStoreError 的兩則訊息                               -> test_E15
-- E16  nfIncludeReference 的兩處裸表名之一                       -> test_E16
-- E17  nfTags 的兩處裸表名之二                                   -> test_E17
-- @
--
-- __非退化前提如何落地__(qa 角色的關鍵風險,見任務指示):
--
-- * __L5\/P2__(排序鍵交錯):F-A\/F-B 的 @ent-@ id 刻意交錯
--   (@A:01 \< B:01 \< B:03 \< A:05 \< A:07@),見 'linkedTopicMd'\/'lindaOldNoteMd'\/
--   'lindaAppendixMd'\/'sameShortIdTopicMd'。'ent-00000005'\/'ent-00000007' 是各自
--   __獨立__的檔案,__不是__ 'linkedTopicMd' 的片段(G19:節層繼承對 @tags@ 是聯集
--   去重,同檔片段會連檔案層的 @"琳達"@ 標籤都繼承走)。
-- * __L12\/P3-like 共同 facet 值__:F-A 的 @ent-00000001@ 與 F-B 的 @ast-00000002@
--   都帶標籤 @"canon"@(見 'linkedTopicMd'\/'potionsPackMd'),求和與取其中一個才會
--   給出不同答案。
-- * __L4\/E16\/E17 的裸表名__:兩個 vault __各自都有__ reference pack('loreRefPackMd'\/
--   'relicsRefPackMd')與__各自可分辨__的標籤(F-A 專屬 @"琳達"@,只在
--   'linkedTopicMd' 的 @ent-00000001@ 身上、F-B 專屬 @"藥水"@,只在 'potionsPackMd'
--   的 @ast-00000002@ 身上——pack 自己的標題\/正文刻意不含「藥水」二字),漏 schema
--   前綴時會拿別的 vault 的那張表篩這個 vault。
-- * __L12 零命中__:'test_L12_zero_hit_filtered' 用只有一個 vault 命中的查詢字，
--   斷言 @fcVaults@ 不含命中數 0 的那個 vault。
-- * __短 id 跨 vault 撞號(P3)__:F-A 與 F-B __都有__ @ent-00000001@(標題不同),
--   L13\/L5\/L9 等一律用 @(VaultId, Id)@ 這一對驗證，抓得到「用 Id 當鍵」的合併。
--
-- __已知的最佳努力(best-effort)之處__:'searchTermForOrdering'\/L9 的分數交錯
-- (P2 的分數版)依賴 SQLite FTS5 的 bm25 對詞頻\/文件長度的實際計算，qa 端只能
-- 透過刻意安排不同詞頻與文件長度來__提高__交錯機率，無法在骨架全 @undefined@
-- 的階段執行驗證；若之後仍證明是恆真（未交錯），留給 impl 完成後的仲裁處理，
-- 不影響本檔的紅\/綠判準（L9 的斷言本身是「相鄰兩筆滿足排序關係」，不依賴任何
-- 事先假設的分數值)。
-- graph-core/B001:'vaultAFiles' / 'vaultBFiles' 一併匯出,供
-- "Aapms.Store.VaultLayoutSpec" 對 vault 目錄配置斷言。
module Aapms.Store.MultiVaultSpec (spec, vaultAFiles, vaultBFiles) where

import Control.Monad (forM, forM_)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Aapms.Core.AnyNode (AnyNode, anyMeta)
import Aapms.Core.Id (Id, IdPrefix (..), Ref (..), VaultId (..), idPrefix, renderId, renderIdPrefix)
import Aapms.Core.Link (Link (..), LinkKind (..))
import Aapms.Core.Meta (Meta (..), Status (..), TypeKey (..))
import Aapms.Store.Error
import Aapms.Store.Fixtures (idOf, orDie, refOf, testRegistry, typeOf, writeFiles)
import Aapms.Store.Index (rebuildIndex)
import Aapms.Store.Marker
import Aapms.Store.MultiVault
import Aapms.Store.Query
import Aapms.Store.Schema (VaultKind (..))
import Numeric (showHex)
import System.IO.Temp (withSystemTempDirectory)

--------------------------------------------------------------------------------
-- Fixture:F-A(story vault)/ F-B(asset vault),見 spec「Examples」的 Fixture 前提

vidA, vidB, vidAbsent :: VaultId
vidA = VaultId "vlt-aaaa0001"
vidB = VaultId "vlt-bbbb0002"
vidAbsent = VaultId "vlt-cccc0003"

-- | @.aapms\/config.toml@ 的內容,逐字比照 'Aapms.Store.Marker.renderMarker'
-- 的格式(本檔__不能__用 'Aapms.Store.Marker.initVaultAt',它會自己雜湊一個
-- id,而 spec 的 Examples 要求逐字固定的 @vlt-aaaa0001@\/@vlt-bbbb0002@)。
markerToml :: VaultId -> VaultKind -> Text -> Text
markerToml (VaultId vid) kind name =
  T.unlines
    [ "id   = \"" <> vid <> "\""
    , "kind = \"" <> renderVaultKindText kind <> "\""
    , "name = \"" <> name <> "\""
    , "refs = []"
    ]
  where
    renderVaultKindText StoryVault = "story"
    renderVaultKindText AssetVault = "asset"

-- | F-A 的主題檔:__只有__主體 'ent-00000001'(標題含「藥水」,帶 P4 的三種關聯、
-- 專屬標籤 @"琳達"@)。__不__在這個檔案裡放片段——'design.md' 的節層繼承規則對
-- @tags@ 是聯集去重,同檔的片段會把檔案層(= 主體自己)的 @tags@ 也繼承走
-- (G19:曾經讓 @nfTags=[琳達]@ 連片段一起回三筆)。'ent-00000005'\/'ent-00000007'
-- 改放到各自獨立的檔案('lindaOldNoteMd'\/'lindaAppendixMd'),避免這個繼承管道。
linkedTopicMd :: Text
linkedTopicMd =
  T.unlines
    [ "---"
    , "id: ent-00000001"
    , "vault: F-A"
    , "type: character"
    , "title: 琳達的藥水日記"
    , "summary: F009 fixture 的主體節點"
    , "tags: [琳達, canon]"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "links:"
    , "  - {kind: uses, target: vlt-bbbb0002:ast-00000002}"
    , "  - {kind: references, target: ent-0000dead}"
    , "  - {kind: derivedFrom, target: vlt-cccc0003:ent-00000001}"
    , "---"
    , ""
    , "琳達的手記提到魔法藥水瓶。這是她的手記。"
    ]

-- | F-A 的獨立節點(__不是__ 'linkedTopicMd' 的片段,見它上面的說明):
-- 'ent-00000005',標題__不__含「藥水」,只用來讓 L5 的排序鍵交錯前提成立
-- (@ent-00000001 \< ent-00000005@)。
lindaOldNoteMd :: Text
lindaOldNoteMd =
  T.unlines
    [ "---"
    , "id: ent-00000005"
    , "vault: F-A"
    , "type: character-fragment"
    , "title: 舊筆記"
    , "summary: 一段與本次主題無關的舊筆記"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "手記手記手記,以前寫的東西。"
    ]

-- | F-A 的獨立節點:'ent-00000007',同 'lindaOldNoteMd' 的理由,獨立成檔以免
-- 繼承 'linkedTopicMd' 的 @"琳達"@ 標籤。
lindaAppendixMd :: Text
lindaAppendixMd =
  T.unlines
    [ "---"
    , "id: ent-00000007"
    , "vault: F-A"
    , "type: character-fragment"
    , "title: 附錄"
    , "summary: 補充說明"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "補充說明的內文,沒有特別的內容。"
    ]

-- | F-A 的 reference pack(@library\/reference\/@ 底下),供 L4\/E16 用。
loreRefPackMd :: Text
loreRefPackMd =
  T.unlines
    [ "---"
    , "id: pck-50000001"
    , "vault: F-A"
    , "type: asset-pack"
    , "title: 未公開的傳說筆記"
    , "status: canon"
    , "source: scan"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "參考資料,索引時不該預設出現在查詢結果裡。"
    , ""
    , "## legend.png {#ast-50000002}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: PNG/legend.png"
    , "sha256: \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
    , "```"
    ]

-- | F-B 的主要 pack:'pck-00000001'(帶 license,標題與正文__刻意不__含「藥水」
-- 二字——G19:pack 本身的標題\/正文會被 FTS 命中,曾讓 E1「恰兩筆」與 E12 的
-- facet 計數落空)+ 'ast-00000002'(標題逐字「魔法藥水瓶」,帶 P4\/L4\/E17 用的
-- 標籤)+ 'ast-00000004'(named,供 @nfNamedOnly@)+ 'ast-00000005'
-- (@status: missing@,供 @nfStatus@)。
potionsPackMd :: Text
potionsPackMd =
  T.unlines
    [ "---"
    , "id: pck-00000001"
    , "vault: F-B"
    , "type: asset-pack"
    , "title: B 庫素材包"
    , "license: lic-b0000001"
    , "status: canon"
    , "source: scan"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "本包收錄魔法容器系列素材。"
    , ""
    , "## 魔法藥水瓶 {#ast-00000002}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: PNG/potion.png"
    , "sha256: \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\""
    , "tags: [藥水, canon]"
    , "```"
    , ""
    , "魔法藥水瓶的素材說明。"
    , ""
    , "## 已命名的容器 {#ast-00000004}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "name: liquid_potion_001"
    , "entry: PNG/potion-vial.png"
    , "sha256: \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\""
    , "```"
    , ""
    , "有命名的容器素材。"
    , ""
    , "## 破損的容器 {#ast-00000005}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: PNG/potion-broken.png"
    , "sha256: \"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\""
    , "status: missing"
    , "```"
    ]

-- | F-B 的授權登記檔,供 'potionsPackMd' 的 @license@ 欄位參照。
bLicensesMd :: Text
bLicensesMd =
  T.unlines
    [ "---"
    , "id: lic-b0000001"
    , "vault: F-B"
    , "type: asset-license"
    , "title: F-B 授權登記"
    , "status: canon"
    , "source: human"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "本檔登記授權條款。"
    ]

-- | F-B 的另一份主題檔:主體節點 id __逐字等於__ 'ent-00000001'(P3;短 id 跨
-- vault 撞號),標題「B 庫的同號節點」;片段 'ent-00000003'。
sameShortIdTopicMd :: Text
sameShortIdTopicMd =
  T.unlines
    [ "---"
    , "id: ent-00000001"
    , "vault: F-B"
    , "type: character"
    , "title: B 庫的同號節點"
    , "summary: 與 F-A 的主體節點共用短 id,標題不同"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "這是 B 庫自己的手記,和 A 庫的同號節點無關。"
    , ""
    , "## B 庫片段 {#ent-00000003}"
    , ""
    , "```meta"
    , "type: character-fragment"
    , "summary: B 庫的片段"
    , "```"
    , ""
    , "片段片段的手記內文。"
    ]

-- | F-B 的 reference pack,供 L4\/E16 用。
relicsRefPackMd :: Text
relicsRefPackMd =
  T.unlines
    [ "---"
    , "id: pck-60000001"
    , "vault: F-B"
    , "type: asset-pack"
    , "title: 未公開的遺物掃描"
    , "status: canon"
    , "source: scan"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "參考資料,索引時不該預設出現在查詢結果裡。"
    , ""
    , "## relic.jpg {#ast-60000002}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "entry: JPG/relic.jpg"
    , "sha256: \"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\""
    , "```"
    ]

vaultAFiles :: [(FilePath, Text)]
vaultAFiles =
  [ ("characters/linda.md", linkedTopicMd)
  , ("characters/linda-old-note.md", lindaOldNoteMd)
  , ("characters/linda-appendix.md", lindaAppendixMd)
  , ("library/reference/lore/pack.md", loreRefPackMd)
  ]

vaultBFiles :: [(FilePath, Text)]
vaultBFiles =
  [ ("library/packs/test-vendor/potions/pack.md", potionsPackMd)
  , ("library/licenses.md", bLicensesMd)
  , ("topics/samename.md", sameShortIdTopicMd)
  , ("library/reference/relics/pack.md", relicsRefPackMd)
  ]

-- | 開一個全新 vault:寫 marker(固定 vmId)→ 寫檔案 → 'openVault' →
-- 'rebuildIndex'。__不__用 'Aapms.Store.Marker.initVaultAt'(見 'markerToml'
-- 的說明)。呼叫端自行負責 'closeVault'。
openFreshIndexedVault :: FilePath -> VaultId -> VaultKind -> Text -> [(FilePath, Text)] -> IO VaultHandle
openFreshIndexedVault dir vid kind name files = do
  writeFiles dir [(".aapms/config.toml", markerToml vid kind name)]
  writeFiles dir files
  (h, _issues) <- orDie =<< openVault testRegistry dir
  _ <- orDie =<< rebuildIndex h
  pure h

-- | 對同一個路徑再 'openVault' 一次(E7:同路徑重複 → 保序去重),沿用已經
-- 存在的 marker\/索引,__不__重寫檔案。
reopenVault :: FilePath -> IO VaultHandle
reopenVault dir = fst <$> (orDie =<< openVault testRegistry dir)

withVaultA :: (VaultHandle -> IO a) -> IO a
withVaultA act = withSystemTempDirectory "aapms-f009-a" $ \dir -> do
  h <- openFreshIndexedVault dir vidA StoryVault "F-A" vaultAFiles
  r <- act h
  closeVault h
  pure r

withVaultB :: (VaultHandle -> IO a) -> IO a
withVaultB act = withSystemTempDirectory "aapms-f009-b" $ \dir -> do
  h <- openFreshIndexedVault dir vidB AssetVault "F-B" vaultBFiles
  r <- act h
  closeVault h
  pure r

-- | F-A + F-B 兩個把手,不建 'VaultSet'(供需要自己控制 'VaultSet' 生命週期
-- 的測試:L2)。收尾時自動 'closeVault' 兩個把手。
withDualVaultRaw :: ((VaultHandle, VaultHandle) -> IO a) -> IO a
withDualVaultRaw act =
  withVaultA $ \hA -> withVaultB $ \hB -> act (hA, hB)

-- | 跟 'withDualVaultRaw' 一樣開好 F-A\/F-B,但__不__自動收尾——action 自己要
-- 負責 'closeVault' 兩個把手(E12:測試本身就要驗證「呼叫端自己
-- 'closeVault' 正常完成」,不能讓外層 bracket 再關一次)。
withDualVaultOpenOnly :: ((VaultHandle, VaultHandle) -> IO a) -> IO a
withDualVaultOpenOnly act =
  withSystemTempDirectory "aapms-f009-a" $ \dirA ->
    withSystemTempDirectory "aapms-f009-b" $ \dirB -> do
      hA <- openFreshIndexedVault dirA vidA StoryVault "F-A" vaultAFiles
      hB <- openFreshIndexedVault dirB vidB AssetVault "F-B" vaultBFiles
      act (hA, hB)

-- | F-A + F-B + 已經 'openVaultSet' 好的 'VaultSet',收尾時
-- 'closeVaultSet' → 'closeVault' 兩個把手。絕大多數 law\/example 用這個。
withDualVaultSet :: ((VaultSet, VaultHandle, VaultHandle) -> IO a) -> IO a
withDualVaultSet act = withDualVaultRaw $ \(hA, hB) -> do
  vs <- orDie =<< openVaultSet [hA, hB]
  r <- act (vs, hA, hB)
  closeVaultSet vs
  pure r

-- | 給定的 vault 一定要涵蓋 hA \/ hB 之外的把手時用:再開 N 個「乾淨、只有
-- 一個節點」的迷你 vault,供 E6\/E7\/E13\/E14\/L1\/L1b 這種只在意「id 撞不撞、
-- 數量夠不夠」而不需要豐富內容的測試使用。
minimalTopicMd :: Text -> Text
minimalTopicMd idTxt =
  T.unlines
    [ "---"
    , "id: " <> idTxt
    , "vault: minimal"
    , "type: character"
    , "title: 極簡節點"
    , "summary: 只用來讓索引非空"
    , "status: canon"
    , "source: human"
    , "revision: 1"
    , "created: 2026-08-20"
    , "updated: 2026-08-20"
    , "---"
    , ""
    , "極簡內文。"
    ]

-- | 開一個帶指定 'VaultId' 的極簡 vault(唯一節點 @ent-00000001@,索引非空)。
openMinimalVaultAt :: FilePath -> VaultId -> IO VaultHandle
openMinimalVaultAt dir vid =
  openFreshIndexedVault dir vid StoryVault "minimal" [("topic.md", minimalTopicMd "ent-00000001")]

-- | 第 n 個(從 1 起)迷你 vault 的固定 'VaultId'(8 位十六進位,保證兩兩相異)。
minimalVaultId :: Int -> VaultId
minimalVaultId n = VaultId ("vlt-" <> T.justifyRight 8 '0' (T.pack (showHex n "")))

-- | 開 n 個兩兩相異 'VaultId' 的迷你 vault(依 1..n 的順序),交給 action,
-- 結束後逐一 'closeVault'(臨時目錄由巢狀的 'withSystemTempDirectory' 自動清掉)。
withNMinimalVaults :: Int -> ([VaultHandle] -> IO a) -> IO a
withNMinimalVaults n act = go 1 []
  where
    go i acc
      | i > n = act (reverse acc)
      | otherwise = withSystemTempDirectory ("aapms-f009-min-" <> show i) $ \dir -> do
          h <- openMinimalVaultAt dir (minimalVaultId i)
          r <- go (i + 1) (h : acc)
          closeVault h
          pure r

vid :: VaultHandle -> VaultId
vid h = vmId (vhMarker h)

wideLimit :: Int
wideLimit = 10000

wideFilter :: NodeFilter -> NodeFilter
wideFilter f = f {nfLimit = wideLimit, nfOffset = 0}

wideQuery :: SearchQuery -> SearchQuery
wideQuery q = q {sqFilter = wideFilter (sqFilter q)}

-- | @'srFacets' r@ 應為 'Just' 時的取值輔助:是 'Nothing' 就讓測試失敗(而不是
-- 靜默地跳過),訊息說明是哪裡預期錯了。
expectJustFacets :: SearchResult -> IO FacetCounts
expectJustFacets r = case srFacets r of
  Just fc -> pure fc
  Nothing -> expectationFailure "預期 srFacets 為 Just" >> fail "unreachable"

-- | 依 (metaId 的文字, vault 的文字) 排序,供「視為集合\/多重集合」的比較用。
byIdThenVault :: (VaultId, Meta) -> (Text, Text)
byIdThenVault (VaultId v, m) = (renderId (metaId m), v)

-- | 與 'byIdThenVault' 相同的排序鍵,但作用在 @(VaultId, Id)@ 上(E17 用)。
byIdThenVaultId :: (VaultId, Id) -> (Text, Text)
byIdThenVaultId (VaultId v, i) = (renderId i, v)

byHitIdThenVault :: SearchHit -> (Text, Text)
byHitIdThenVault h = (renderId (metaId (shMeta h)), let VaultId v = shVault h in v)

spec :: Spec
spec = describe "graph-core/F009 MultiVault" $ do
  describe "建立、上限與生命週期" $ do
    l1Spec
    l1bSpec
    l2Spec
    l3Spec
    e6Spec
    e7Spec
    e13Spec
    e14Spec

  describe "listAcross" $ do
    l4Spec
    l5Spec
    l6Spec
    l7Spec
    e2Spec
    e16Spec
    e17Spec

  describe "searchAcross" $ do
    l8Spec
    l9Spec
    l10Spec
    l11Spec
    l12Spec
    e1Spec
    e12Spec

  describe "lookupRef" $ do
    l13Spec
    l14Spec
    l15Spec
    e3Spec
    e4Spec
    e5Spec

  describe "checkReferences" $ do
    l16Spec
    l17Spec
    e8Spec
    e9Spec

  describe "退化情形" $ do
    l18Spec
    l19Spec
    e10Spec
    e11Spec

  describe "StoreError 新增建構子" $ do
    l20Spec
    e15Spec

--------------------------------------------------------------------------------
-- 建立、上限與生命週期(L1 / L1b / L2 / L3 / E6 / E7 / E13 / E14)

l1Spec :: Spec
l1Spec = describe "L1: 去重與上限(maxAttachedVaults == 10)" $ do
  it "maxAttachedVaults == 10" $
    maxAttachedVaults `shouldBe` 10

  it "10 個兩兩相異的 vault 成功,vaultSetIds 依原順序" $
    withNMinimalVaults 10 $ \hs -> do
      r <- openVaultSet hs
      case r of
        Left e -> expectationFailure ("預期 Right,得到 " <> T.unpack (renderStoreError e))
        Right vs -> do
          vaultSetIds vs `shouldBe` map vid hs
          closeVaultSet vs

  it "11 個兩兩相異的 vault -> TooManyVaults 11 10" $
    withNMinimalVaults 11 $ \hs -> do
      r <- openVaultSet hs
      case r of
        Left e -> e `shouldBe` TooManyVaults 11 10
        Right vs -> do
          closeVaultSet vs
          expectationFailure "預期 Left (TooManyVaults 11 10),得到 Right"

  it "*非退化*:同一個 vault(同路徑)重複到清單長度 > 上限,但去重後 <= 上限時仍成功" $
    withVaultA $ \hA -> do
      let hs = replicate 11 hA -- 同一個把手(同 vmId、同 vhRoot),去重後只剩 1
      r <- openVaultSet hs
      case r of
        Left e -> expectationFailure ("預期去重後成功,得到 " <> T.unpack (renderStoreError e))
        Right vs -> do
          vaultSetIds vs `shouldBe` [vidA]
          closeVaultSet vs

l1bSpec :: Spec
l1bSpec = describe "L1b: 撞號(VaultIdCollision),優先於上限" $ do
  it "兩個不同路徑帶著相同 vmId,且清單長度 <= 上限時 -> Left (VaultIdCollision v p q)" $
    withDualCollisionA $ \(hA, hA') ->
      withVaultB $ \hB -> do
        r <- openVaultSet [hA, hB, hA']
        case r of
          Left (VaultIdCollision v p q) -> do
            v `shouldBe` vidA
            p `shouldBe` vhRoot hA
            q `shouldBe` vhRoot hA'
          Left e -> expectationFailure ("預期 VaultIdCollision,得到 Left " <> T.unpack (renderStoreError e))
          Right vs -> do
            closeVaultSet vs
            expectationFailure "預期 VaultIdCollision,得到 Right"

  it "*非退化*:撞號且清單長度 > 上限時仍是 VaultIdCollision,不是 TooManyVaults" $
    withDualCollisionA $ \(hA, hA') ->
      withNMinimalVaults 10 $ \others -> do
        r <- openVaultSet ([hA, hA'] ++ others)
        case r of
          Left (VaultIdCollision v p q) -> do
            v `shouldBe` vidA
            p `shouldBe` vhRoot hA
            q `shouldBe` vhRoot hA'
          Left e -> expectationFailure ("預期撞號優先於上限,得到 Left " <> T.unpack (renderStoreError e))
          Right vs -> do
            closeVaultSet vs
            expectationFailure "預期撞號優先於上限,得到 Right"

-- | 兩個__不同路徑__、__都非空索引__、vmId 都是 'vidA' 的把手(L1b 的非退化前提:
-- 撞號的兩個 vault 各自的索引都要非空)。
withDualCollisionA :: ((VaultHandle, VaultHandle) -> IO a) -> IO a
withDualCollisionA act =
  withSystemTempDirectory "aapms-f009-a1" $ \dir1 ->
    withSystemTempDirectory "aapms-f009-a2" $ \dir2 -> do
      h1 <- openFreshIndexedVault dir1 vidA StoryVault "F-A" vaultAFiles
      h2 <- openFreshIndexedVault dir2 vidA StoryVault "F-A" vaultAFiles
      r <- act (h1, h2)
      closeVault h1
      closeVault h2
      pure r

l2Spec :: Spec
l2Spec = describe "L2: closeVaultSet 之後,單一 vault 的讀取不受影響" $
  it "closeVaultSet vs 之後 listNodes hA f 與之前逐筆相同,closeVault hA 仍正常完成" $
    withDualVaultRaw $ \(hA, hB) -> do
      before <- listNodes hA (wideFilter emptyNodeFilter)
      vs <- orDie =<< openVaultSet [hA, hB]
      closeVaultSet vs
      after <- listNodes hA (wideFilter emptyNodeFilter)
      after `shouldBe` before

l3Spec :: Spec
l3Spec = describe "L3: VaultSet 不改變單一 vault 的讀取行為(任意次數的 *Across 之後)" $
  it "listNodes hA f 與 search hA q 在多次 *Across 呼叫前後逐筆相同" $
    withDualVaultSet $ \(vs, hA, _hB) -> do
      let f = wideFilter emptyNodeFilter
          q = wideQuery emptySearchQuery {sqText = Just "藥水"}
      nodesBefore <- listNodes hA f
      searchBefore <- search hA q
      _ <- listAcross vs f
      _ <- searchAcross vs q
      _ <- lookupRef vs vidA (refOf "ent-00000001")
      _ <- checkReferences vs hA
      _ <- listAcross vs f
      nodesAfter <- listNodes hA f
      searchAfter <- search hA q
      nodesAfter `shouldBe` nodesBefore
      searchAfter `shouldBe` searchBefore

e6Spec :: Spec
e6Spec = describe "E6: 第 11 個 vault -> TooManyVaults,10 個成功" $ do
  it "11 個 vmId 兩兩相異的把手 -> Left (TooManyVaults 11 10)" $
    withNMinimalVaults 11 $ \hs -> do
      r <- openVaultSet hs
      case r of
        Left e -> e `shouldBe` TooManyVaults 11 10
        Right vs -> do
          closeVaultSet vs
          expectationFailure "預期 Left (TooManyVaults 11 10),得到 Right"

  it "其中任意 10 個 -> Right,長度 10" $
    withNMinimalVaults 11 $ \hs -> do
      r <- openVaultSet (take 10 hs)
      case r of
        Right vs -> do
          length (vaultSetIds vs) `shouldBe` 10
          closeVaultSet vs
        Left e -> expectationFailure ("預期成功,得到 " <> T.unpack (renderStoreError e))

e7Spec :: Spec
e7Spec = describe "E7: 同一個路徑重複傳 -> 保序去重" $
  it "openVaultSet [hA, hB, hA2](hA2 是對同路徑再開一次)-> vaultSetIds == [vidA, vidB]" $
    withDualVaultRaw $ \(hA, hB) -> do
      hA2 <- reopenVault (vhRoot hA)
      r <- openVaultSet [hA, hB, hA2]
      case r of
        Right vs -> do
          vaultSetIds vs `shouldBe` [vidA, vidB]
          closeVaultSet vs
        Left e -> expectationFailure ("預期成功,得到 " <> T.unpack (renderStoreError e))
      closeVault hA2

e13Spec :: Spec
e13Spec = describe "E13: 異路徑撞號 -> VaultIdCollision(不是 Right、也不是去重後的成功)" $
  it "openVaultSet [hA, hB, hA'] -> Left (VaultIdCollision vidA <hA 的 vhRoot> <hA' 的 vhRoot>)" $
    withDualCollisionA $ \(hA, hA') ->
      withVaultB $ \hB -> do
        r <- openVaultSet [hA, hB, hA']
        case r of
          Left e -> e `shouldBe` VaultIdCollision vidA (vhRoot hA) (vhRoot hA')
          Right vs -> do
            closeVaultSet vs
            expectationFailure "預期 Left (VaultIdCollision …),得到 Right"

e14Spec :: Spec
e14Spec = describe "E14: 撞號優先於上限" $
  it "11 個 vmId 相異的把手,其中一個換成 F-A 的複製 -> Left (VaultIdCollision …),不是 TooManyVaults" $
    withDualCollisionA $ \(hA, hA') ->
      withNMinimalVaults 9 $ \others -> do
        let hs = [hA, hA'] ++ others -- 2 + 9 = 11 > 10,且撞號
        r <- openVaultSet hs
        case r of
          Left (VaultIdCollision {}) -> pure ()
          Left e -> expectationFailure ("預期撞號優先於上限,得到 Left " <> T.unpack (renderStoreError e))
          Right vs -> do
            closeVaultSet vs
            expectationFailure "預期撞號優先於上限,得到 Right"

--------------------------------------------------------------------------------
-- listAcross(L4 / L5 / L6 / L7 / E2 / E16 / E17)

-- | L4 的 8 個維度各自的候選值(每個都在 F-A/F-B 的 fixture 裡__對預設值造成真實差異__)。
-- 七個維度是「限縮」語意(非預設值下結果__變少__);'nfIncludeReference' 是唯一的例外
-- ——它預設(False)排除兩個 vault 的 reference pack 與其 asset,設成 'True' 是
-- __加回__那 4 筆(見 'e16Spec' 的 @length withRef == length withoutRef + 4@),
-- 所以它的非退化方向是「結果__變多__」,不是「變少」。'fdNonDegenerate' 記錄每個維度
-- 該用哪個方向比對,而不是用同一個 @(<)@ 硬套八個語意不同的維度。
data FilterDim = FilterDim
  { fdName :: String
  , fdApply :: NodeFilter -> NodeFilter
  , fdNonDegenerate :: Int -> Int -> Bool -- \dimCount defaultCount -> 是否為真實差異
  }

filterDims :: [FilterDim]
filterDims =
  [ FilterDim "nfPrefixes" (\f -> f {nfPrefixes = [PEnt]}) (<)
  , FilterDim "nfTypes" (\f -> f {nfTypes = [typeOf "character"]}) (<)
  , FilterDim "nfStatus" (\f -> f {nfStatus = [Missing]}) (<)
  , FilterDim "nfTags" (\f -> f {nfTags = ["canon"]}) (<)
  , FilterDim "nfOwner" (\f -> f {nfOwner = Just (idOf "pck-00000001")}) (<)
  , FilterDim "nfLicense" (\f -> f {nfLicense = Just (refOf "lic-b0000001")}) (<)
  , FilterDim "nfNamedOnly" (\f -> f {nfNamedOnly = True}) (<)
  , FilterDim "nfIncludeReference" (\f -> f {nfIncludeReference = True}) (>)
  ]

l4Spec :: Spec
l4Spec = describe "L4: listAcross 的多重集合等於逐 vault listNodes 的多重集合" $ do
  it "emptyNodeFilter(wide)下,listAcross 與逐 vault listNodes 串接後相同(視為多重集合)" $
    withDualVaultSet $ \(vs, hA, hB) -> do
      got <- listAcross vs (wideFilter emptyNodeFilter)
      wantA <- listNodes hA (wideFilter emptyNodeFilter)
      wantB <- listNodes hB (wideFilter emptyNodeFilter)
      let want = map ((,) vidA) wantA ++ map ((,) vidB) wantB
      sortOn byIdThenVault got `shouldBe` sortOn byIdThenVault want

  it "*非退化*:8 個維度各自的非預設值也都跟逐 vault listNodes 一致,且對預設值造成真實差異" $
    withDualVaultSet $ \(vs, hA, hB) -> do
      allR <- listAcross vs (wideFilter emptyNodeFilter)
      forM_ filterDims $ \dim -> do
        let f = fdApply dim (wideFilter emptyNodeFilter)
        got <- listAcross vs f
        wantA <- listNodes hA f
        wantB <- listNodes hB f
        let want = map ((,) vidA) wantA ++ map ((,) vidB) wantB
        sortOn byIdThenVault got `shouldBe` sortOn byIdThenVault want
        -- 非退化:這個維度的非預設值真的讓結果跟全預設值不同(方向依 fdNonDegenerate,
        -- 見 'FilterDim' 上的說明——七個維度是變少,'nfIncludeReference' 是變多)
        (fdName dim, length got, length allR)
          `shouldSatisfy` (\(_, g, a) -> fdNonDegenerate dim g a)

l5Spec :: Spec
l5Spec = describe "L5: 全域排序(metaId 遞增,平手比 vault)" $
  it "listAcross vs (wide f) 相鄰兩筆滿足 metaId 遞增,或平手時 vault 遞增" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (wideFilter emptyNodeFilter)
      length got `shouldSatisfy` (> 1)
      let adjacentOk ((v1, m1), (v2, m2)) =
            metaId m1 < metaId m2 || (metaId m1 == metaId m2 && v1 < v2)
      all adjacentOk (zip got (drop 1 got)) `shouldBe` True

l6Spec :: Spec
l6Spec = describe "L6: 分頁是對整體切窗" $
  it "listAcross vs f{offset=j,limit=k} == take k (drop j (listAcross vs (wide f)))(涵蓋跨界與落在後段兩種窗)" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      full <- listAcross vs (wideFilter emptyNodeFilter)
      let n = length full
      n `shouldSatisfy` (>= 4)
      -- 視窗跨越 vault 邊界(offset=0,limit 取一半左右)、以及完全落在後段
      let windows = [(0, n `div` 2), (n - 2, 2), (1, 2)]
      forM_ windows $ \(j, k) -> do
        paged <- listAcross vs (emptyNodeFilter {nfOffset = j, nfLimit = k})
        paged `shouldBe` take k (drop j full)

l7Spec :: Spec
l7Spec = describe "L7: listAcross 每筆的 vault 欄與 metaVault 一致" $
  it "每筆 (v, m) 滿足 metaVault m == v,且 v 屬於 vaultSetIds vs" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (wideFilter emptyNodeFilter)
      let ids = vaultSetIds vs
      forM_ got $ \(v, m) -> do
        metaVault m `shouldBe` v
        v `shouldSatisfy` (`elem` ids)

e2Spec :: Spec
e2Spec = describe "E2: 排序與分頁跨 vault" $ do
  it "listAcross vsAB (nfPrefixes=[PEnt], nfLimit=10) 依序是 [A01,B01,B03,A05,A07]" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (emptyNodeFilter {nfPrefixes = [PEnt], nfLimit = 10})
      assertE2Order got

  it "第二次 listAcross vsAB (nfPrefixes=[PEnt], offset=1, limit=2) 是 [B01,B03]" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (emptyNodeFilter {nfPrefixes = [PEnt], nfOffset = 1, nfLimit = 2})
      map (fmap metaId) got `shouldBe` [(vidB, idOf "ent-00000001"), (vidB, idOf "ent-00000003")]

-- | E2 第一次呼叫的期望順序。
assertE2Order :: [(VaultId, Meta)] -> Expectation
assertE2Order got =
  map (fmap metaId) got
    `shouldBe` [ (vidA, idOf "ent-00000001")
               , (vidB, idOf "ent-00000001")
               , (vidB, idOf "ent-00000003")
               , (vidA, idOf "ent-00000005")
               , (vidA, idOf "ent-00000007")
               ]

e16Spec :: Spec
e16Spec = describe "E16: nfIncludeReference 的裸表名之一(packs 的 reference 子查詢)" $
  it "預設排除兩個 vault 的 reference pack 與其 asset;True 時兩邊都回,差集恰是兩個 vault 的 reference 節點聯集" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      withoutRef <- listAcross vs (wideFilter emptyNodeFilter)
      withRef <- listAcross vs (wideFilter emptyNodeFilter {nfIncludeReference = True})
      let idsOf = map (metaId . snd)
          refIds = [idOf "pck-50000001", idOf "ast-50000002", idOf "pck-60000001", idOf "ast-60000002"]
      forM_ refIds $ \i -> do
        idsOf withoutRef `shouldNotContain` [i]
        idsOf withRef `shouldContain` [i]
      length withRef `shouldBe` length withoutRef + 4

e17Spec :: Spec
e17Spec = describe "E17: nfTags 的裸表名之二(node_tags 存在性子查詢)" $ do
  it "nfTags=[琳達] 只回 A 的 ent-00000001" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (wideFilter emptyNodeFilter {nfTags = ["琳達"]})
      map (fmap metaId) got `shouldBe` [(vidA, idOf "ent-00000001")]

  it "nfTags=[藥水] 只回 B 的 ast-00000002" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (wideFilter emptyNodeFilter {nfTags = ["藥水"]})
      map (fmap metaId) got `shouldBe` [(vidB, idOf "ast-00000002")]

  it "nfTags=[canon] 兩筆都回(各一)" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (wideFilter emptyNodeFilter {nfTags = ["canon"]})
      sortOn byIdThenVaultId (map (fmap metaId) got)
        `shouldBe` sortOn
          byIdThenVaultId
          [(vidA, idOf "ent-00000001"), (vidB, idOf "ast-00000002")]

  it "nfTags=[琳達,藥水](AND)回 []" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- listAcross vs (wideFilter emptyNodeFilter {nfTags = ["琳達", "藥水"]})
      got `shouldBe` []

--------------------------------------------------------------------------------
-- searchAcross(L8 / L9 / L10 / L11 / L12 / E1 / E12)

searchTextCandidates :: Gen (Maybe Text)
searchTextCandidates =
  Gen.choice
    [ pure Nothing
    , Just <$> Gen.element ["藥水", "手記", "琳達", "不存在的字串xyz"]
    ]

l8Spec :: Spec
l8Spec = describe "L8: searchAcross 逐 vault 等價(四欄逐欄相同)" $
  it "srHits (searchAcross vs q') 的多重集合等於 concat [srHits (search h q') | h <- hs] 的多重集合" $
    hedgehog $ do
      textM <- forAll searchTextCandidates
      let q' = (wideQuery emptySearchQuery {sqText = textM}) {sqFacets = False}
      (got, want) <- evalIO $ withDualVaultSet $ \(vs, hA, hB) -> do
        gotR <- searchAcross vs q'
        wantA <- search hA q'
        wantB <- search hB q'
        pure (gotR, srHits wantA ++ srHits wantB)
      sortOn byHitIdThenVault (srHits got) === sortOn byHitIdThenVault want

l9Spec :: Spec
l9Spec = describe "L9: searchAcross 全域排序(score 遞減,平手比 metaId,再平手比 vault)" $
  it "srHits 相鄰兩筆滿足排序關係(以「手記」為查詢字,詞頻/文件長度刻意不同以提高交錯機率)" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      r <- searchAcross vs (wideQuery emptySearchQuery {sqText = Just "手記"})
      let hits = srHits r
      length hits `shouldSatisfy` (>= 2)
      let ok a b =
            shScore a > shScore b
              || (shScore a == shScore b && metaId (shMeta a) < metaId (shMeta b))
              || ( shScore a == shScore b
                     && metaId (shMeta a) == metaId (shMeta b)
                     && shVault a < shVault b
                 )
      all (uncurry ok) (zip hits (drop 1 hits)) `shouldBe` True

l10Spec :: Spec
l10Spec = describe "L10: searchAcross 分頁與 srTotal" $
  it "分頁是對整體切窗;srTotal 對分頁不敏感;srTotal 等於逐 vault srTotal 之和" $
    withDualVaultSet $ \(vs, hA, hB) -> do
      let q = wideQuery emptySearchQuery {sqText = Just "手記"}
      full <- searchAcross vs q
      let n = length (srHits full)
      n `shouldSatisfy` (>= 2)
      let windows = [(0, n), (0, 1), (n - 1, 1)]
      forM_ windows $ \(j, k) -> do
        let qjk = q {sqFilter = (sqFilter q) {nfOffset = j, nfLimit = k}}
        paged <- searchAcross vs qjk
        srHits paged `shouldBe` take k (drop j (srHits full))
        srTotal paged `shouldBe` srTotal full
      totalA <- srTotal <$> search hA q
      totalB <- srTotal <$> search hB q
      srTotal full `shouldBe` totalA + totalB

l11Spec :: Spec
l11Spec = describe "L11: searchAcross 每筆 vault 欄一致(檢索側)" $
  it "每筆 x 滿足 metaVault (shMeta x) == shVault x,且 shVault x 屬於 vaultSetIds vs" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      r <- searchAcross vs (wideQuery emptySearchQuery {sqText = Just "藥水"})
      let ids = vaultSetIds vs
      forM_ (srHits r) $ \h -> do
        metaVault (shMeta h) `shouldBe` shVault h
        shVault h `shouldSatisfy` (`elem` ids)

l12Spec :: Spec
l12Spec = describe "L12: facet" $ do
  it "sqFacets 控制 srFacets 的 Just/Nothing" $
    hedgehog $ do
      on <- forAll Gen.bool
      textM <- forAll searchTextCandidates
      r <- evalIO $ withDualVaultSet $ \(vs, _hA, _hB) ->
        searchAcross vs (wideQuery emptySearchQuery {sqText = textM, sqFacets = on})
      case (on, srFacets r) of
        (True, Just _) -> pure ()
        (False, Nothing) -> pure ()
        _ -> annotate "sqFacets 與 srFacets 的 Just/Nothing 不一致" >> failure

  it "fcVaults 恰是命中數 > 0 的 vault 各一筆,計數等於該 vault 單獨 srTotal,總和等於 srTotal" $
    withDualVaultSet $ \(vs, hA, hB) -> do
      let q = wideQuery emptySearchQuery {sqText = Just "藥水", sqFacets = True}
      r <- searchAcross vs q
      fc <- expectJustFacets r
      totalA <- srTotal <$> search hA q
      totalB <- srTotal <$> search hB q
      let VaultId va = vidA
          VaultId vb = vidB
          expected = [(va, totalA) | totalA > 0] ++ [(vb, totalB) | totalB > 0]
      sortOn fst (fcVaults fc) `shouldBe` sortOn fst expected
      sum (map snd (fcVaults fc)) `shouldBe` srTotal r

  it "*非退化*:fcTypes/fcTags 的求和(canon 標籤兩邊都有,求和才與取其中一個不同)" $
    withDualVaultSet $ \(vs, hA, hB) -> do
      let q = wideQuery emptySearchQuery {sqText = Nothing, sqFacets = True}
      r <- searchAcross vs q
      fc <- expectJustFacets r
      fcA <- expectJustFacets =<< search hA q
      fcB <- expectJustFacets =<< search hB q
      let sumOf sel = M.toList (M.unionWith (+) (M.fromList (sel fcA)) (M.fromList (sel fcB)))
      sortOn fst (fcTypes fc) `shouldBe` sortOn fst (sumOf fcTypes)
      sortOn fst (fcTags fc) `shouldBe` sortOn fst (sumOf fcTags)
      sortOn fst (fcOwners fc) `shouldBe` sortOn fst (sumOf fcOwners)
      sortOn fst (fcLicenses fc) `shouldBe` sortOn fst (sumOf fcLicenses)
      -- 兩邊都有的共同標籤 "canon":求和一定 >= 2(不是只取其中一邊的 1)
      lookup "canon" (fcTags fc) `shouldSatisfy` maybe False (>= 2)

  it "facet 不因該維度自己的過濾條件改變(比照 F007 L17)" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      let base = wideQuery emptySearchQuery {sqFacets = True}
      baseR <- searchAcross vs base
      fcBase <- expectJustFacets baseR
      rTypes <- searchAcross vs base {sqFilter = (sqFilter base) {nfTypes = [typeOf "character"]}}
      fmap fcTypes (srFacets rTypes) `shouldBe` Just (fcTypes fcBase)
      rTags <- searchAcross vs base {sqFilter = (sqFilter base) {nfTags = ["canon"]}}
      fmap fcTags (srFacets rTags) `shouldBe` Just (fcTags fcBase)

  it "*非退化*(零命中的 vault 不出現在 fcVaults):只有一個 vault 命中的查詢字" $
    withDualVaultSet $ \(vs, hA, hB) -> do
      -- "琳達" 只出現在 F-A;F-B 對這個字完全沒有命中
      let q = wideQuery emptySearchQuery {sqText = Just "琳達", sqFacets = True}
      totalB <- srTotal <$> search hB q
      totalB `shouldBe` 0 -- 確認 fixture 真的讓 B 零命中(非退化前提)
      r <- searchAcross vs q
      fc <- expectJustFacets r
      let VaultId vb = vidB
      lookup vb (fcVaults fc) `shouldBe` Nothing
      totalA <- srTotal <$> search hA q
      totalA `shouldSatisfy` (> 0)

e1Spec :: Spec
e1Spec = describe "E1: searchAcross 一次回兩種 vault" $
  it "searchAcross vsAB {sqText = Just 藥水} 恰兩筆,各自 shVault/metaId 正確" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      r <- searchAcross vs (wideQuery emptySearchQuery {sqText = Just "藥水"})
      let hits = srHits r
      length hits `shouldBe` 2
      srTotal r `shouldBe` 2
      forM_ hits $ \h -> do
        shScore h `shouldSatisfy` (> 0)
        shSnippet h `shouldSatisfy` T.isInfixOf "藥水"
        metaVault (shMeta h) `shouldBe` shVault h
      let byVault v = [h | h <- hits, shVault h == v]
      case byVault vidA of
        [h] -> metaId (shMeta h) `shouldBe` idOf "ent-00000001"
        other -> expectationFailure ("預期 A 恰一筆,得到 " <> show (length other))
      case byVault vidB of
        [h] -> metaId (shMeta h) `shouldBe` idOf "ast-00000002"
        other -> expectationFailure ("預期 B 恰一筆,得到 " <> show (length other))

e12Spec :: Spec
e12Spec = describe "E12: facet 的 vault 維度跨 vault;VaultSet 不接管把手的生命週期" $
  it "fcVaults 依值遞增(計數相同時);closeVaultSet 之後 hA 仍可正常讀取與關閉" $
    withDualVaultOpenOnly $ \(hA, hB) -> do
      vs <- orDie =<< openVaultSet [hA, hB]
      r <- searchAcross vs (wideQuery emptySearchQuery {sqText = Just "藥水", sqFacets = True})
      fc <- expectJustFacets r
      let VaultId va = vidA
          VaultId vb = vidB
      fcVaults fc `shouldBe` [(va, 1), (vb, 1)]
      sum (map snd (fcVaults fc)) `shouldBe` srTotal r
      before <- listNodes hA (wideFilter emptyNodeFilter)
      closeVaultSet vs
      after <- listNodes hA (wideFilter emptyNodeFilter)
      after `shouldBe` before
      closeVault hA
      closeVault hB

--------------------------------------------------------------------------------
-- lookupRef(L13 / L14 / L15 / E3 / E4 / E5)

l13Spec :: Spec
l13Spec = describe "L13: 帶 vault 的 Ref 只認自己那個 vault" $
  it "lookupRef vs v (Ref (Just (vid h)) i) 等於 fmap ((,) (vid h)) <$> lookupNode h i(v == vid h 與 v /= vid h 都要驗)" $
    withDualVaultSet $ \(vs, hA, hB) -> do
      forM_ [(hA, vidA), (hA, vidB), (hB, vidA), (hB, vidB)] $ \(h, v) -> do
        forM_ [idOf "ent-00000001", idOf "ent-00000099"] $ \i -> do
          got <- lookupRef vs v (Ref (Just (vid h)) i)
          wantNode <- lookupNode h i
          got `shouldBe` fmap ((,) (vid h)) wantNode

l14Spec :: Spec
l14Spec = describe "L14: 預設 vault" $
  it "lookupRef vs v (Ref Nothing i) == lookupRef vs v (Ref (Just v) i)" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      forM_ (vaultSetIds vs) $ \v ->
        forM_ [idOf "ent-00000001", idOf "ent-00000099"] $ \i -> do
          withDefault <- lookupRef vs v (Ref Nothing i)
          withExplicit <- lookupRef vs v (Ref (Just v) i)
          withDefault `shouldBe` withExplicit

l15Spec :: Spec
l15Spec = describe "L15: vault 不在集合裡 -> Nothing" $
  it "目標 vault 不屬於 vaultSetIds vs 時,即使 id 在集合裡的某個 vault 真的存在也回 Nothing" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      let w = vidAbsent
          i = idOf "ent-00000001" -- 在 A、B 都真的存在(P3)
      forM_ (vaultSetIds vs) $ \v -> do
        got <- lookupRef vs v (Ref (Just w) i)
        got `shouldBe` Nothing

e3Spec :: Spec
e3Spec = describe "E3: 不帶 vault 的 Ref 以呼叫端指定的預設 vault 解析" $
  it "lookupRef vsAB vidA (Ref Nothing ent-00000001) 與 lookupRef vsAB vidB (Ref Nothing ent-00000001) 分別是 A/B 的節點" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      gotA <- lookupRef vs vidA (Ref Nothing (idOf "ent-00000001"))
      case gotA of
        Just (v, n) -> do
          v `shouldBe` vidA
          metaTitle (anyMeta n) `shouldBe` "琳達的藥水日記"
        Nothing -> expectationFailure "預期 Just"
      gotB <- lookupRef vs vidB (Ref Nothing (idOf "ent-00000001"))
      case gotB of
        Just (v, n) -> do
          v `shouldBe` vidB
          metaTitle (anyMeta n) `shouldBe` "B 庫的同號節點"
        Nothing -> expectationFailure "預期 Just"

e4Spec :: Spec
e4Spec = describe "E4: 帶 vault 的 Ref 覆蓋預設 vault" $
  it "lookupRef vsAB vidA (Ref (Just vidB) ent-00000001) -> Just (vidB, B 的節點)" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- lookupRef vs vidA (Ref (Just vidB) (idOf "ent-00000001"))
      case got of
        Just (v, n) -> do
          v `shouldBe` vidB
          metaTitle (anyMeta n) `shouldBe` "B 庫的同號節點"
        Nothing -> expectationFailure "預期 Just"

e5Spec :: Spec
e5Spec = describe "E5: 目標 vault 不在集合裡" $
  it "lookupRef vsAB vidA (Ref (Just vidAbsent) ent-00000001) -> Nothing" $
    withDualVaultSet $ \(vs, _hA, _hB) -> do
      got <- lookupRef vs vidA (Ref (Just vidAbsent) (idOf "ent-00000001"))
      got `shouldBe` Nothing

--------------------------------------------------------------------------------
-- checkReferences(L16 / L17 / E8 / E9)

-- | L16 公式的直接翻譯:用 'loadLinkGraph' + 'lookupRef' + 'vaultSetIds' 重新
-- 算出「這個 vault 指出去的懸空引用」,作為 'checkReferences' 的 oracle。
expectedDangling :: VaultSet -> VaultHandle -> IO [DanglingRef]
expectedDangling vs h = do
  graph <- loadLinkGraph h
  let selfVid = vid h
      pairs = [(s, l) | (s, ls) <- M.toList graph, l <- ls]
  results <- forM pairs $ \(s, l) -> do
    let target = case linkTarget l of
          Ref mv i -> Ref (Just (fromMaybe selfVid mv)) i
    reasonM <- reasonOf vs target
    pure (fmap (\r -> DanglingRef s l target r) reasonM)
  pure [d | Just d <- results]

reasonOf :: VaultSet -> Ref -> IO (Maybe DanglingReason)
reasonOf vs (Ref (Just w) i)
  | w `notElem` vaultSetIds vs = pure (Just TargetVaultAbsent)
  | otherwise = do
      r <- lookupRef vs w (Ref (Just w) i)
      pure (if r == Nothing then Just TargetNodeMissing else Nothing)
reasonOf _ (Ref Nothing _) = pure Nothing -- 不會發生:呼叫端一定先套用過預設 vault

danglingSortKey :: DanglingRef -> (Text, Text, Text, String)
danglingSortKey d =
  ( renderId (drSource d)
  , T.pack (show (linkKind (drLink d)))
  , renderRefTxt (drTarget d)
  , show (drReason d)
  )
  where
    renderRefTxt (Ref mv i) = maybe "" (\(VaultId v) -> v <> ":") mv <> renderId i

l16Spec :: Spec
l16Spec = describe "L16: checkReferences 完整且不多報" $
  it "checkReferences vsAB hA(視為集合)等於用 loadLinkGraph/lookupRef/vaultSetIds 重新推導出的懸空清單" $
    withDualVaultSet $ \(vs, hA, _hB) -> do
      got <- checkReferences vs hA
      want <- expectedDangling vs hA
      sortOn danglingSortKey got `shouldBe` sortOn danglingSortKey want
      -- P4 非退化:三種成因都要在場
      let reasons = map drReason got
      reasons `shouldSatisfy` elem TargetNodeMissing
      reasons `shouldSatisfy` elem TargetVaultAbsent
      length got `shouldSatisfy` (< 3) -- 第三種(解析得到)不出現在結果裡

l17Spec :: Spec
l17Spec = describe "L17: renderDanglingRef" $
  it "非空、含 renderId drSource 與 renderRef drTarget 子字串、至少一段以「請」起頭;兩種成因訊息不相等" $
    withDualVaultSet $ \(vs, hA, _hB) -> do
      ds <- checkReferences vs hA
      length ds `shouldSatisfy` (>= 2) -- P4 非退化:兩種成因各至少一筆
      forM_ ds $ \d -> do
        let msg = renderDanglingRef d
        msg `shouldNotBe` ""
        msg `shouldSatisfy` T.isInfixOf (renderId (drSource d))
        msg `shouldSatisfy` T.isInfixOf (renderRefText (drTarget d))
        msg `shouldSatisfy` hasQingClause
      let byReason r = [renderDanglingRef d | d <- ds, drReason d == r]
      case (byReason TargetVaultAbsent, byReason TargetNodeMissing) of
        (m1 : _, m2 : _) -> m1 `shouldNotBe` m2
        _ -> expectationFailure "預期兩種成因各至少一筆"

renderRefText :: Ref -> Text
renderRefText (Ref mv i) = maybe "" (\(VaultId v) -> v <> ":") mv <> renderId i

-- | 判準與 F008 L15 相同:以 @;@\/@；@\/@,@\/@，@\/@。@ 切子句,去頭尾空白後
-- 比對開頭是不是「請」。
hasQingClause :: Text -> Bool
hasQingClause msg = any (T.isPrefixOf "請" . T.strip) splitClauses
  where
    delimiters = [";", "；", ",", "，", "。"]
    splitClauses = foldl (\acc d -> concatMap (T.splitOn d) acc) [msg] delimiters

e8Spec :: Spec
e8Spec = describe "E8: 兩種懸空都找得到,解析得到的那一筆不會被誤報" $
  it "checkReferences vsAB hA 恰兩筆(TargetNodeMissing 一筆、TargetVaultAbsent 一筆),uses 那筆不出現" $
    withDualVaultSet $ \(vs, hA, _hB) -> do
      ds <- checkReferences vs hA
      length ds `shouldBe` 2
      let bySource = [d | d <- ds, drSource d == idOf "ent-00000001"]
      length bySource `shouldBe` 2
      forM_ ds $ \d -> linkKind (drLink d) `shouldNotBe` Uses
      let missing = [d | d <- ds, drReason d == TargetNodeMissing]
          absent = [d | d <- ds, drReason d == TargetVaultAbsent]
      case missing of
        [d] -> do
          linkKind (drLink d) `shouldBe` References
          drTarget d `shouldBe` Ref (Just vidA) (idOf "ent-0000dead")
        other -> expectationFailure ("預期 TargetNodeMissing 恰一筆,得到 " <> show (length other))
      case absent of
        [d] -> do
          linkKind (drLink d) `shouldBe` DerivedFrom
          drTarget d `shouldBe` Ref (Just vidAbsent) (idOf "ent-00000001")
        other -> expectationFailure ("預期 TargetVaultAbsent 恰一筆,得到 " <> show (length other))

e9Spec :: Spec
e9Spec = describe "E9: renderDanglingRef 兩則訊息" $
  it "兩則都非空、互不相等,各含 ent-00000001,分別含 vlt-aaaa0001:ent-0000dead 與 vlt-cccc0003:ent-00000001,都有以「請」起頭的子句" $
    withDualVaultSet $ \(vs, hA, _hB) -> do
      ds <- checkReferences vs hA
      let msgs = map renderDanglingRef ds
      length msgs `shouldBe` 2
      msgs `shouldSatisfy` \[m1, m2] -> m1 /= m2
      forM_ msgs $ \m -> do
        m `shouldSatisfy` T.isInfixOf "ent-00000001"
        m `shouldSatisfy` hasQingClause
      let missingMsgs = [renderDanglingRef d | d <- ds, drReason d == TargetNodeMissing]
          absentMsgs = [renderDanglingRef d | d <- ds, drReason d == TargetVaultAbsent]
      missingMsgs `shouldSatisfy` any (T.isInfixOf "vlt-aaaa0001:ent-0000dead")
      absentMsgs `shouldSatisfy` any (T.isInfixOf "vlt-cccc0003:ent-00000001")

--------------------------------------------------------------------------------
-- 退化情形(L18 / L19 / E10 / E11)

l18Spec :: Spec
l18Spec = describe "L18: 空集合" $
  it "openVaultSet [] -> Right vs,vaultSetIds == [],*Across 全空,lookupRef 全 Nothing,checkReferences 全 TargetVaultAbsent" $
    withVaultA $ \hA -> do
      vs <- orDie =<< openVaultSet []
      vaultSetIds vs `shouldBe` []
      la <- listAcross vs (wideFilter emptyNodeFilter)
      la `shouldBe` []
      sa <- searchAcross vs (wideQuery emptySearchQuery)
      sa `shouldBe` SearchResult {srHits = [], srTotal = 0, srFacets = Nothing}
      lr <- lookupRef vs vidA (Ref Nothing (idOf "ent-00000001"))
      lr `shouldBe` Nothing
      ds <- checkReferences vs hA
      ds `shouldSatisfy` (not . null) -- 非退化:hA 的索引裡至少有一筆關聯
      forM_ ds $ \d -> drReason d `shouldBe` TargetVaultAbsent
      closeVaultSet vs

l19Spec :: Spec
l19Spec = describe "L19: 單一 vault 退化成 F006/F007" $
  it "openVaultSet [hA] 之後,listAcross/searchAcross 逐筆等於 listNodes/search" $
    withVaultA $ \hA -> do
      vs <- orDie =<< openVaultSet [hA]
      let f = wideFilter emptyNodeFilter {nfIncludeReference = False}
          q = wideQuery emptySearchQuery {sqText = Just "藥水", sqFacets = True}
      la <- listAcross vs f
      wantNodes <- listNodes hA f
      map snd la `shouldBe` wantNodes
      forM_ la $ \(v, _) -> v `shouldBe` vidA
      sa <- searchAcross vs q
      wantSearch <- search hA q
      sa `shouldBe` wantSearch
      closeVaultSet vs

e10Spec :: Spec
e10Spec = describe "E10: 空集合不是錯誤,空集合下 checkReferences 對每一筆關聯都回 TargetVaultAbsent" $
  it "listAcross/searchAcross/lookupRef 全空;checkReferences hA 的每一筆(三筆)都是 TargetVaultAbsent" $
    withVaultA $ \hA -> do
      vs <- orDie =<< openVaultSet []
      la <- listAcross vs emptyNodeFilter
      la `shouldBe` []
      sa <- searchAcross vs emptySearchQuery
      sa `shouldBe` SearchResult {srHits = [], srTotal = 0, srFacets = Nothing}
      lr <- lookupRef vs vidA (Ref Nothing (idOf "ent-00000001"))
      lr `shouldBe` Nothing
      ds <- checkReferences vs hA
      length ds `shouldBe` 3
      forM_ ds $ \d -> drReason d `shouldBe` TargetVaultAbsent
      closeVaultSet vs

e11Spec :: Spec
e11Spec = describe "E11: 單一 vault 退化" $
  it "listAcross 逐筆等於 listNodes hA;每筆 fst == vidA;searchAcross 逐欄等於 search hA" $
    withVaultA $ \hA -> do
      vs <- orDie =<< openVaultSet [hA]
      la <- listAcross vs emptyNodeFilter
      wantNodes <- listNodes hA emptyNodeFilter
      map snd la `shouldBe` wantNodes
      forM_ la $ \(v, _) -> v `shouldBe` vidA
      let q = emptySearchQuery {sqText = Just "藥水", sqFacets = True}
      sa <- searchAcross vs q
      wantSearch <- search hA q
      sa `shouldBe` wantSearch
      closeVaultSet vs

--------------------------------------------------------------------------------
-- StoreError 新增建構子(L20 / E15)

l20Spec :: Spec
l20Spec = describe "L20: TooManyVaults / VaultIdCollision 的 renderStoreError" $
  it "非空、含指定的數字/路徑文字、至少一段以「請」起頭;n /= limit 且 p /= q 時兩則訊息互不相等" $
    hedgehog $ do
      -- *非退化*:n 的值域(11..999)與 limit 的值域(1..10)不相交,保證
      -- n /= limit;p/q 各自的候選集不相交,保證 p /= q。
      n <- forAll (Gen.int (Range.linear 11 999))
      limit <- forAll (Gen.int (Range.linear 1 10))
      p <- forAll (Gen.element ["C:/vaults/a", "/tmp/a"])
      q <- forAll (Gen.element ["C:/vaults/b", "/tmp/b"])
      let vTxt = "vlt-aaaa0001"
          msg1 = renderStoreError (TooManyVaults n limit)
          msg2 = renderStoreError (VaultIdCollision (VaultId vTxt) p q)
      annotate (T.unpack msg1)
      msg1 `shouldSatisfyH` (T.isInfixOf (T.pack (show n)))
      msg1 `shouldSatisfyH` (T.isInfixOf (T.pack (show limit)))
      msg1 `shouldSatisfyH` hasQingClause
      msg2 `shouldSatisfyH` (T.isInfixOf vTxt)
      msg2 `shouldSatisfyH` (T.isInfixOf (T.pack p))
      msg2 `shouldSatisfyH` (T.isInfixOf (T.pack q))
      msg2 `shouldSatisfyH` hasQingClause
      msg1 /== msg2
  where
    shouldSatisfyH x p = assert (p x)

e15Spec :: Spec
e15Spec = describe "E15: renderStoreError 的兩則訊息" $
  it "TooManyVaults 11 10 與 VaultIdCollision vlt-aaaa0001 C:/a C:/b" $ do
    let msg1 = renderStoreError (TooManyVaults 11 10)
        msg2 = renderStoreError (VaultIdCollision (VaultId "vlt-aaaa0001") "C:/a" "C:/b")
    msg1 `shouldNotBe` ""
    msg2 `shouldNotBe` ""
    msg1 `shouldNotBe` msg2
    msg1 `shouldSatisfy` T.isInfixOf "11"
    msg1 `shouldSatisfy` T.isInfixOf "10"
    msg2 `shouldSatisfy` T.isInfixOf "vlt-aaaa0001"
    msg2 `shouldSatisfy` T.isInfixOf "C:/a"
    msg2 `shouldSatisfy` T.isInfixOf "C:/b"
    msg1 `shouldSatisfy` hasQingClause
    msg2 `shouldSatisfy` hasQingClause
