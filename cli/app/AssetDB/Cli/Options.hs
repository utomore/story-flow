module AssetDB.Cli.Options
  ( Command (..)
  , ScanArgs (..)
  , ReorgArgs (..)
  , ReorgMode (..)
  , RuleArgs (..)
  , SearchArgs (..)
  , ProjectArgs (..)
  , NoteArgs (..)
  , LinkArgs (..)
  , AiConn (..)
  , AiClassifyArgs (..)
  , AiVisionArgs (..)
  , AiListArgs (..)
  , AiDecideArgs (..)
  , AiApplyArgs (..)
  , AiQueryArgs (..)
  , GlobalArgs (..)
  , Invocation (..)
  , parseInvocation
  , resolveDbPath
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import AssetDB.Cli.Ai
  ( AiApplyArgs (..)
  , AiClassifyArgs (..)
  , AiConn (..)
  , AiDecideArgs (..)
  , AiListArgs (..)
  , AiQueryArgs (..)
  , AiVisionArgs (..)
  )
import AssetDB.Cli.Cluster (RuleArgs (..))
import AssetDB.Cli.Search (SearchArgs (..))
import AssetDB.Cli.Project (ProjectArgs (..))
import AssetDB.Cli.Notes (LinkArgs (..), NoteArgs (..))
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))

data GlobalArgs = GlobalArgs
  { gaDbPath :: Maybe FilePath
  }

data Invocation = Invocation GlobalArgs Command

data Command
  = CmdScan ScanArgs
  | CmdTools
  | CmdDoctor
  | CmdPackList
  | CmdPackApply FilePath
  | CmdReorgPlan ReorgArgs
  | CmdClusterList (Maybe Text)
  | CmdClusterRule RuleArgs
  | CmdClusterApply (Maybe Text)
  | CmdSearch SearchArgs
  | CmdIndex
  | CmdThumbs Bool
  | CmdNewProject ProjectArgs
  | CmdNoteImport NoteArgs
  | CmdNoteList (Maybe Text)
  | CmdLink LinkArgs
  | CmdAiPing AiConn
  | CmdAiClassify AiConn AiClassifyArgs
  | CmdAiVision AiConn AiVisionArgs
  | CmdAiSuggestList AiListArgs
  | -- | confirm 與 reject 共用,以 'daDecision' 區分。
    CmdAiDecide AiDecideArgs
  | CmdAiApply AiApplyArgs
  | CmdAiQuery AiConn AiQueryArgs
  | CmdAiStatus

data ReorgArgs = ReorgArgs
  { raSource :: FilePath
  , raTarget :: FilePath
  , raMode :: ReorgMode
  }

-- | 模式互斥,而且**沒有預設值**。
--
-- 沒有預設模式是刻意的:其中一個模式會刪掉五千個檔案,
-- 「忘記給旗標」不該落進任何一個會動到檔案的模式。
data ReorgMode
  = ModeDryRun (Maybe FilePath) Bool
  | -- | 'Bool' 是 @--delete-covered@:階段 B,不可回退。
    ModeApply Bool
  | ModeUndo Text
  | ModeListBatches

data ScanArgs = ScanArgs
  { saRoot :: FilePath
  , saKind :: Text
  , saLabel :: Maybe Text
  , saRehash :: Bool
  , saQuiet :: Bool
  }

parseInvocation :: IO Invocation
parseInvocation =
  execParser $
    info
      (helper <*> (Invocation <$> globalP <*> commandP))
      ( fullDesc
          <> progDesc "Alchbees 資源與專案管理系統"
          <> header "assetdb"
      )

globalP :: Parser GlobalArgs
globalP =
  GlobalArgs
    <$> optional
      ( strOption
          ( long "db"
              <> metavar "PATH"
              <> help "資料庫檔案。預設 ./.assetdb/assetdb.sqlite"
          )
      )

commandP :: Parser Command
commandP =
  hsubparser
    ( command "scan" (info (CmdScan <$> scanP) (progDesc "掃描素材庫,計算內容雜湊並建立索引"))
        <> command "tools" (info (pure CmdTools) (progDesc "檢查外部工具(7-Zip)是否可用"))
        <> command "doctor" (info (pure CmdDoctor) (progDesc "檢查資料庫狀態與待辦"))
        <> command "pack" (info packP (progDesc "素材包的授權與作者中繼資料"))
        <> command "reorganize" (info reorgP (progDesc "素材庫重構:dry-run / apply / undo"))
        <> command "cluster" (info clusterP (progDesc "檔名叢集:把命名決策從逐筆降到逐群"))
        <> command "search" (info (CmdSearch <$> searchP) (progDesc "全文 + facet 搜尋"))
        <> command "index" (info (pure CmdIndex) (progDesc "重建全文索引"))
        <> command
          "thumbs"
          ( info
              (CmdThumbs <$> switch (long "force" <> help "重新產生已存在的縮圖"))
              (progDesc "產生縮圖(內容定址,每份唯一內容只算一次)")
          )
        <> command "new-project" (info (CmdNewProject <$> projectP) (progDesc "建立遊戲專案並放入選定素材"))
        <> command "note" (info noteP (progDesc "知識建檔與行銷資訊"))
        <> command "link" (info (CmdLink <$> linkP) (progDesc "在實體之間建立關聯"))
        <> command "ai" (info aiP (progDesc "本機 LLM:分類、標註與自然語句查詢"))
    )

--------------------------------------------------------------------------------

-- | @--llm-url@ / @--llm-model@ 只掛在需要模型的子指令上,不做成全域選項 ——
-- 其餘十幾個指令與推論服務毫無關係,讓它們也長出這兩個旗標只會製造噪音。
aiConnP :: Parser AiConn
aiConnP =
  AiConn
    <$> optional
      ( option
          (T.pack <$> str)
          (long "llm-url" <> metavar "URL" <> help "OpenAI 相容端點。預設 http://localhost:8080")
      )
    <*> optional
      (option (T.pack <$> str) (long "llm-model" <> metavar "NAME" <> help "模型名稱"))
    <*> switch
      ( long "thinking"
          <> help
            "允許模型產生推理段落。預設關閉 —— 實測支援的模型快 24 倍且答案相同。\
            \品質有疑慮時再打開比較"
      )

aiP :: Parser Command
aiP =
  hsubparser
    ( command "ping" (info (CmdAiPing <$> aiConnP) (progDesc "檢查推論服務是否可用"))
        <> command
          "classify"
          ( info
              (CmdAiClassify <$> aiConnP <*> classifyP)
              (progDesc "叢集層分類(純文字,約 132 次呼叫)")
          )
        <> command
          "vision"
          ( info
              (CmdAiVision <$> aiConnP <*> visionP)
              (progDesc "逐份內容的視覺標註(送縮圖,產生中英文標籤)")
          )
        <> command "suggest" (info suggestP (progDesc "檢視與決定 AI 建議"))
        <> command
          "apply"
          ( info
              ( CmdAiApply
                  <$> ( AiApplyArgs
                          <$> switch (long "confirm" <> help "真的寫入。不加就只是預覽")
                      )
              )
              (progDesc "把已確認的建議寫入標籤與分類,並重建索引")
          )
        <> command
          "query"
          ( info
              ( CmdAiQuery
                  <$> aiConnP
                  <*> ( AiQueryArgs
                          <$> option (T.pack <$> str) (long "text" <> short 'q' <> metavar "Q" <> help "自然語句")
                      )
              )
              (progDesc "把一句話翻成搜尋條件")
          )
        <> command "status" (info (pure CmdAiStatus) (progDesc "建議、標註進度與批次紀錄"))
    )

classifyP :: Parser AiClassifyArgs
classifyP =
  AiClassifyArgs
    <$> optional (option (T.pack <$> str) (long "pack" <> metavar "SLUG" <> help "限定某一包"))
    <*> option
      auto
      ( long "min-members"
          <> metavar "N"
          <> value 1
          <> showDefault
          <> help "只處理成員數達此數的叢集"
      )
    <*> optional (option auto (long "limit" <> metavar "N" <> help "最多處理幾個叢集"))
    <*> switch (long "force" <> help "重跑已經有建議的叢集")

visionP :: Parser AiVisionArgs
visionP =
  AiVisionArgs
    <$> optional (option (T.pack <$> str) (long "pack" <> metavar "SLUG" <> help "限定某一包"))
    <*> optional (option auto (long "limit" <> metavar "N" <> help "最多處理幾份內容"))
    <*> switch (long "force" <> help "連已標註過的也重跑")
    <*> switch (long "retry-failed" <> help "把先前失敗的重新排進佇列")
    <*> switch (long "small" <> help "送 128px 而不是 512px 縮圖。快但看不清楚")

suggestP :: Parser Command
suggestP =
  hsubparser
    ( command
        "list"
        ( info
            ( CmdAiSuggestList
                <$> ( AiListArgs
                        <$> optional
                          ( option
                              (T.pack <$> str)
                              (long "status" <> metavar "S" <> help "pending / confirmed / rejected / applied")
                          )
                        <*> optional
                          (option (T.pack <$> str) (long "target" <> metavar "T" <> help "blob / cluster / asset / pack"))
                        <*> optional
                          (option (T.pack <$> str) (long "field" <> metavar "F" <> help "category / tag / subject"))
                        <*> optional (option auto (long "min-confidence" <> metavar "R" <> help "只看信心值達標的"))
                        <*> option auto (long "limit" <> metavar "N" <> value 50 <> showDefault <> help "顯示筆數")
                    )
            )
            (progDesc "列出建議")
        )
        <> command "confirm" (info (CmdAiDecide <$> decideP "confirmed") (progDesc "確認建議"))
        <> command "reject" (info (CmdAiDecide <$> decideP "rejected") (progDesc "退回建議"))
    )

decideP :: Text -> Parser AiDecideArgs
decideP decision =
  AiDecideArgs
    <$> many (option auto (long "id" <> metavar "N" <> help "建議編號,可重複"))
    <*> switch (long "all-pending" <> help "所有待確認的建議")
    <*> optional (option auto (long "min-confidence" <> metavar "R" <> help "搭配 --all-pending 使用"))
    <*> pure decision
    <*> switch (long "confirm" <> help "真的寫入。不加就只是預覽")

noteP :: Parser Command
noteP =
  hsubparser
    ( command
        "import"
        ( info
            ( CmdNoteImport
                <$> ( NoteArgs
                        <$> option
                          (T.pack <$> str)
                          ( long "kind"
                              <> metavar "K"
                              <> value "knowledge"
                              <> showDefault
                              <> help "knowledge / marketing / decision / reference"
                          )
                        <*> strOption (long "path" <> metavar "DIR" <> help "含 Markdown 的目錄")
                    )
            )
            (progDesc "匯入 Markdown。以 source_path 為鍵,重複匯入是更新")
        )
        <> command
          "list"
          ( info
              (CmdNoteList <$> optional (option (T.pack <$> str) (long "kind" <> metavar "K")))
              (progDesc "列出筆記")
          )
    )

linkP :: Parser LinkArgs
linkP =
  LinkArgs
    <$> option (T.pack <$> str) (long "from" <> metavar "REF" <> help "<型別>:<ULID>,如 asset:01ABC")
    <*> option (T.pack <$> str) (long "to" <> metavar "REF" <> help "同上")
    <*> option
      (T.pack <$> str)
      ( long "rel"
          <> metavar "R"
          <> help "uses / derives-from / variant-of / similar-to / documents / promotes"
      )
    <*> optional (option (T.pack <$> str) (long "note" <> metavar "TEXT" <> help "這條關聯的說明"))

projectP :: Parser ProjectArgs
projectP =
  ProjectArgs
    <$> option (T.pack <$> str) (long "name" <> metavar "NAME" <> help "專案名稱,也是 cabal 套件名")
    <*> strOption (long "path" <> metavar "PATH" <> help "專案目錄。必須不存在或為空")
    <*> many (option (T.pack <$> str) (long "pack" <> metavar "SLUG" <> help "納入整個素材包,可重複"))
    <*> optional (option (T.pack <$> str) (long "match" <> metavar "Q" <> help "只納入邏輯名稱含此字串的素材"))
    <*> switch
      ( long "allow-non-commercial"
          <> help "略過授權閘門。**只在確定專案不商業發行時使用**"
      )

searchP :: Parser SearchArgs
searchP =
  SearchArgs
    <$> optional (option (T.pack <$> str) (long "text" <> short 'q' <> metavar "Q" <> help "全文查詢。中英文皆可"))
    <*> many (option (T.pack <$> str) (long "kind" <> metavar "K" <> help "image / audio / font / …,可重複"))
    <*> many (option (T.pack <$> str) (long "pack" <> metavar "SLUG" <> help "素材包,可重複"))
    <*> many (option (T.pack <$> str) (long "author" <> metavar "A" <> help "作者,可重複"))
    <*> many (option (T.pack <$> str) (long "vendor" <> metavar "V" <> help "廠商,可重複"))
    <*> many
      ( option
          (T.pack <$> str)
          ( long "category"
              <> metavar "PATH"
              <> help "分類路徑,如 icon 或 icon/potion,可重複。由 assetdb ai classify 產生"
          )
      )
    <*> switch (long "commercial" <> help "只要可商用的")
    <*> switch (long "named" <> help "只要已指定邏輯名稱的")
    <*> switch (long "include-excluded" <> help "納入被判定為非素材的項目(宣傳圖等)")
    <*> switch (long "include-reference" <> help "納入參考資料。預設排除 —— 找 GUI 框時不該跳出廟宇照片")
    <*> option auto (long "limit" <> metavar "N" <> value 20 <> showDefault <> help "顯示筆數")
    <*> switch (long "facets" <> help "同時顯示各 facet 的計數")

clusterP :: Parser Command
clusterP =
  hsubparser
    ( command
        "list"
        ( info
            (CmdClusterList <$> optional packOpt)
            (progDesc "列出每個素材包的命名叢集")
        )
        <> command
          "rule"
          ( info
              (CmdClusterRule <$> ruleArgsP)
              (progDesc "預覽或確認一個叢集的命名規則(預設只預覽)")
          )
        <> command
          "apply"
          ( info
              (CmdClusterApply <$> optional packOpt)
              (progDesc "把已確認的規則套用成邏輯名稱")
          )
    )
  where
    packOpt = option (T.pack <$> str) (long "pack" <> metavar "SLUG" <> help "限定某一包")

ruleArgsP :: Parser RuleArgs
ruleArgsP =
  RuleArgs
    <$> option (T.pack <$> str) (long "pack" <> metavar "SLUG" <> help "素材包 slug")
    <*> option (T.pack <$> str) (long "shape" <> metavar "KEY" <> help "叢集鍵,取自 cluster list")
    <*> option (T.pack <$> str) (long "kind" <> metavar "K" <> help "spr / tex / ui / fnt / sfx …")
    <*> option (T.pack <$> str) (long "domain" <> metavar "D" <> help "gui / ground / char / fx …")
    <*> optional
      ( option
          (T.pack <$> str)
          ( long "subject"
              <> metavar "S"
              <> help "固定主體前綴。檔名裡沒有主體時必填(如 idle_down.png)"
          )
      )
    <*> many (option auto (long "drop" <> metavar "N" <> help "丟掉第 N 個權杖(0 起算),可重複"))
    <*> option
      auto
      ( long "dirs"
          <> metavar "N"
          <> value 0
          <> showDefault
          <> help "把最後 N 層目錄名納入主體。純數字檔名時用來避免撞名"
      )
    <*> option
      (T.pack <$> str)
      ( long "numeric"
          <> metavar "MODE"
          <> value "auto"
          <> showDefault
          <> help "尾端數字的角色:auto / variant / index"
      )
    <*> many (option (T.pack <$> str) (long "tag" <> metavar "T" <> help "附加標籤,可重複"))
    <*> switch (long "confirm" <> help "真的寫入規則。不加就只是預覽")

reorgP :: Parser Command
reorgP =
  CmdReorgPlan
    <$> ( ReorgArgs
            <$> strOption (long "source" <> metavar "PATH" <> help "現有素材庫根目錄")
            <*> strOption (long "target" <> metavar "PATH" <> help "重構後的根目錄")
            <*> modeP
        )

modeP :: Parser ReorgMode
modeP =
  dryRunP <|> applyP <|> undoP <|> listP
  where
    dryRunP =
      flag' ()
        ( long "dry-run"
            <> help "產生計畫但不改動任何檔案"
        )
        *> ( ModeDryRun
              <$> optional (strOption (long "out" <> metavar "FILE" <> help "把完整計畫寫進檔案,終端機只顯示摘要"))
              <*> switch (long "verbose" <> help "列出每一個要刪除的檔案,而不是只顯示分組數量")
           )

    -- 階段 A 與階段 B 需要兩個旗標。階段 A 完全可回退,階段 B 不可 ——
    -- 綁在一起等於讓可回退的部分被不可回退的部分綁架。
    applyP =
      flag' ()
        ( long "apply"
            <> help "執行階段 A:建目錄、搬壓縮檔、寫 pack.toml。完全可回退"
        )
        *> ( ModeApply
              <$> switch
                ( long "delete-covered"
                    <> help "同時執行階段 B:刪除已由 SHA-256 證明存在於壓縮檔內的散檔。**不可回退**"
                )
           )

    undoP =
      ModeUndo
        <$> option
          (T.pack <$> str)
          (long "undo" <> metavar "BATCH" <> help "回退某個批次的搬移(刪除無法回退)")

    listP = flag' ModeListBatches (long "list-batches" <> help "列出已執行的批次")

packP :: Parser Command
packP =
  hsubparser
    ( command "list" (info (pure CmdPackList) (progDesc "列出素材包與其授權狀態"))
        <> command
          "apply"
          ( info
              (CmdPackApply <$> strOption (long "catalogue" <> metavar "FILE" <> help "packs.toml 的路徑"))
              (progDesc "從 packs.toml 套用作者與授權")
          )
    )

scanP :: Parser ScanArgs
scanP =
  ScanArgs
    <$> strOption (long "root" <> metavar "PATH" <> help "要掃描的素材庫根目錄")
    <*> option
      (T.pack <$> str)
      ( long "kind"
          <> metavar "KIND"
          <> value "packs"
          <> showDefault
          <> help "根目錄類型:packs / reference / studio"
      )
    <*> optional (option (T.pack <$> str) (long "label" <> metavar "NAME" <> help "根目錄顯示名稱,預設取目錄名"))
    <*> switch
      ( long "rehash"
          <> help "忽略「壓縮檔雜湊未變就跳過」的最佳化,強制重新計算全部內容"
      )
    <*> switch (long "quiet" <> help "只輸出最後的摘要")

-- | 資料庫預設放在工作目錄下的 @.assetdb\/@。
--
-- 刻意**不**放進素材庫根目錄:資料庫是衍生物,而素材庫是備份目標 ——
-- 混在一起會讓每次掃描都弄髒備份。
resolveDbPath :: GlobalArgs -> IO FilePath
resolveDbPath GlobalArgs {..} =
  case gaDbPath of
    Just p -> pure p
    Nothing -> do
      cwd <- getCurrentDirectory
      pure (cwd </> ".assetdb" </> "assetdb.sqlite")
