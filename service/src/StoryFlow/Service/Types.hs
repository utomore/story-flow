-- | 業務層的回傳型別與請求型別。
--
-- __不另造一套與 'Meta' \/ 'Entity' 平行的 DTO__:核心型別已經有完整的 aeson
-- 實例("StoryFlow.Core.Json"),複製一份十四個欄位的 DTO 只會製造兩份要同步
-- 維護的編碼規則。View 型別只包一層,補上__檔案裡沒有、只有索引知道__的資訊
-- (路徑、錨點、警告)。
--
-- 請求型別則與 @store@ 的 @NewEntity@ 等分開:那些帶 @nePath@ 之類的落地細節,
-- 這裡的是業務語彙,而且要能從 JSON 解出來(func-0008 的 API 契約直接吃它們)。
module StoryFlow.Service.Types
  ( -- * View
    EntityView (..)
  , evId
  , evRevision
  , LevelView (..)
  , lvId
  , lvRevision
  , VaultView (..)
  , SearchHit (..)
  , LinkReport (..)
  , IndexReport (..)
  , DeleteReport (..)

    -- * 請求
  , NewEntityReq (..)
  , NewFragmentReq (..)
  , NewLevelReq (..)
  , NewNodeReq (..)
  , EntityPatch (..)
  , emptyPatch
  , patchOverride

    -- * 佔位
  , placeholderId
  ) where

import Control.Applicative ((<|>))
import Data.Text (Text)
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, parseId)
import StoryFlow.Core.Level (Level (..), NodeKind)
import StoryFlow.Core.Link (Link)
import StoryFlow.Core.Meta (Meta (..), Source, Status, Timeline)
import StoryFlow.Core.Tree (NodeTree)
import StoryFlow.Md (MetaOverride (..))

-- View ------------------------------------------------------------------------

-- | 一個 Entity 加上索引才知道的事。
data EntityView = EntityView
  { evEntity :: Entity
  , evPath :: FilePath
  -- ^ Vault 相對路徑
  , evAnchor :: Maybe Text
  -- ^ @Nothing@ = 檔案層主體
  , evWarnings :: [Text]
  -- ^ 型別檢查與 md 的警告,已 render 成繁中
  }
  deriving stock (Show, Eq)

-- | 兩個最常被問到的欄位:id 與 revision。
--
-- 存在的理由不是省字。介面層的每一次修改都是__先讀再寫__(樂觀鎖沒有逃生口),
-- 而「從 View 挖出 id 與 revision」如果要靠呼叫端自己往下鑽三層
-- (@metaId . entMeta . evEntity@),那 CLI、server、MCP 就會各鑽一次。
evId :: EntityView -> Id
evId = metaId . entMeta . evEntity

evRevision :: EntityView -> Int
evRevision = metaRevision . entMeta . evEntity

-- | 回__樹__而不是扁平的 @[Node]@:'StoryFlow.Core.Tree.buildTree' 已經驗證過
-- 合法性,把驗證結果丟掉再讓 CLI 與 server 各自重建一次,就是三個地方各有一份
-- 樹邏輯。
data LevelView = LevelView
  { lvLevel :: Level
  , lvTree :: NodeTree
  , lvPath :: FilePath
  }
  deriving stock (Show, Eq)

-- | Level 主體的 id 與 revision。@addNode@ \/ @removeNode@ 的樂觀鎖鎖的是
-- 整份 Level 檔,所以要的是這一份 revision,不是某個 Node 的。
lvId :: LevelView -> Id
lvId = metaId . lvlMeta . lvLevel

lvRevision :: LevelView -> Int
lvRevision = metaRevision . lvlMeta . lvLevel

-- | @vvEntityCount@ 是 'Maybe':'StoryFlow.Service.listVaults' 不會為了數幾筆
-- 就把每個 Vault 的索引都打開(那會觸發全 Vault 的過時掃描),因此那條路徑
-- 給不出數字。給 @0@ 會是說謊。
data VaultView = VaultView
  { vvName :: Text
  , vvRoot :: FilePath
  , vvEntityCount :: Maybe Int
  }
  deriving stock (Show, Eq)

data SearchHit = SearchHit
  { shMeta :: Meta
  , shSnippet :: Text
  }
  deriving stock (Show, Eq)

-- | 正向與反向一次給:「這個片段跟什麼有關」在作者心裡是一個問題,不是兩個。
data LinkReport = LinkReport
  { lrOutgoing :: [Link]
  , lrIncoming :: [(Id, Link)]
  -- ^ (來源 id, 那一筆關聯)
  }
  deriving stock (Show, Eq)

data IndexReport = IndexReport
  { irFiles :: Int
  , irIssues :: [Text]
  }
  deriving stock (Show, Eq)

-- | 欄位不沿用 @store@ 的 @DeleteResult@ 命名(@drPath@ 等):兩個型別在
-- "StoryFlow.Service" 同時在作用域裡,同名欄位會直接撞在一起。
data DeleteReport = DeleteReport
  { delPath :: FilePath
  , delRemoved :: [Id]
  -- ^ 刪整份檔案時不只一個
  , delBrokenLinks :: [(Id, Link)]
  -- ^ 強制刪除打斷的關聯
  }
  deriving stock (Show, Eq)

-- 請求 -------------------------------------------------------------------------

data NewEntityReq = NewEntityReq
  { nerType :: Text
  , nerTitle :: Text
  , nerSummary :: Text
  , nerBody :: Text
  , nerTags :: [Text]
  , nerAliases :: [Text]
  , nerStatus :: Status
  , nerTimeline :: Timeline
  , nerLinks :: [Link]
  , nerSource :: Source
  }
  deriving stock (Show, Eq)

-- | 只填__與檔案層不同__的欄位,其餘留 @Nothing@ 讓繼承生效。
-- @summary@ 不繼承,所以它不是 'Maybe'。
data NewFragmentReq = NewFragmentReq
  { nfrTitle :: Text
  , nfrSummary :: Text
  , nfrBody :: Text
  , nfrType :: Maybe Text
  , nfrTags :: [Text]
  , nfrAliases :: [Text]
  , nfrStatus :: Maybe Status
  , nfrTimeline :: Maybe Timeline
  , nfrLinks :: [Link]
  , nfrSource :: Maybe Source
  }
  deriving stock (Show, Eq)

data NewLevelReq = NewLevelReq
  { nlrTitle :: Text
  , nlrSummary :: Text
  , nlrBody :: Text
  , nlrRootTitle :: Text
  , nlrRootKind :: NodeKind
  , nlrStatus :: Status
  }
  deriving stock (Show, Eq)

data NewNodeReq = NewNodeReq
  { nnrTitle :: Text
  , nnrKind :: NodeKind
  , nnrSummary :: Text
  , nnrBody :: Text
  , nnrLinks :: [Link]
  }
  deriving stock (Show, Eq)

-- | 只改有給值的欄位。
--
-- @epTitle@ 不走 'MetaOverride' ——標題在檔案層是 frontmatter 的一欄、在節層是
-- 標題行本身,兩者 'MetaOverride' 都表達不了,所以它由
-- 'StoryFlow.Store.Write.writeEntityPatch' 另外吃。
data EntityPatch = EntityPatch
  { epTitle :: Maybe Text
  , epSummary :: Maybe Text
  , epTags :: Maybe [Text]
  , epStatus :: Maybe Status
  , epTimeline :: Maybe Timeline
  , epAliases :: Maybe [Text]
  , epSource :: Maybe Source
  }
  deriving stock (Show, Eq)

emptyPatch :: EntityPatch
emptyPatch =
  EntityPatch
    { epTitle = Nothing
    , epSummary = Nothing
    , epTags = Nothing
    , epStatus = Nothing
    , epTimeline = Nothing
    , epAliases = Nothing
    , epSource = Nothing
    }

-- | 把 patch 疊在目前的覆寫上。
--
-- @patch 有值就蓋過去,沒值就保留原樣__包括原本的 @Nothing@__ ——節層的
-- @Nothing@ 代表「繼承檔案層」,把它填成具體值等於偷偷把繼承來的欄位釘死在
-- 節上(func-0003 的繼承規則就白寫了)。
patchOverride :: EntityPatch -> MetaOverride -> MetaOverride
patchOverride EntityPatch {..} ov =
  ov
    { moSummary = epSummary <|> moSummary ov
    , moTags = epTags <|> moTags ov
    , moStatus = epStatus <|> moStatus ov
    , moTimeline = epTimeline <|> moTimeline ov
    , moAliases = epAliases <|> moAliases ov
    , moSource = epSource <|> moSource ov
    }

-- | 還沒配置 id 的新實體在__寫入前的驗證__階段用的佔位 id。
--
-- 'StoryFlow.Core.Registry.checkEntity' 不看 id,它只是為了讓 'Meta' 完整。
-- 驗證發生在寫檔之前,而 id 是 @store@ 查過索引才配得出來的,所以這個順序下
-- 一定會有一段「還沒有 id 的 Entity」。
placeholderId :: Id
placeholderId = case parseId "ent-00000000" of
  Right (_, i) -> i
  Left e -> error ("不可能:ent-00000000 應為合法 id —— " <> show e)
