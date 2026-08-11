-- | 專案樣板:目錄結構與初始檔案。
--
-- 樣板是**資料**(路徑 → 內容),不是一段建立目錄的程序。
-- 這讓「這個樣板會產生什麼」可以在不碰檔案系統的情況下完整測試。
module AssetDB.Project.Template
  ( TemplateFile (..)
  , templateDirs
  , templateFiles
  , creditsSection
  ) where

import Data.Text (Text)
import Data.Text qualified as T

data TemplateFile = TemplateFile
  { tfPath :: FilePath
  , tfContent :: Text
  }
  deriving stock (Eq, Show)

-- | 空目錄也要建立。@audio\/{sfx,bgm}@ 現在是空的,但先建好,
-- 音效功能上線時不需要有人記得補 —— 而「記得補」是不會發生的。
templateDirs :: [FilePath]
templateDirs =
  [ "src"
  , "app"
  , "test"
  , "docs/decisions"
  , "tools"
  , "assets/sprites/gui"
  , "assets/sprites/characters"
  , "assets/sprites/items"
  , "assets/sprites/fx"
  , "assets/tilesets/ground"
  , "assets/fonts"
  , "assets/levels"
  , "assets/shaders"
  , "assets/audio/sfx"
  , "assets/audio/bgm"
  , "assets/theme"
  , ".assetdb"
  ]

templateFiles :: Text -> Text -> [TemplateFile]
templateFiles name credits =
  [ TemplateFile "SKILL.md" (skillMd name credits)
  , TemplateFile "README.md" (readmeMd name)
  , TemplateFile "docs/提案書.md" (proposalMd name)
  , TemplateFile "docs/技術文檔.md" (techMd name)
  , TemplateFile "docs/decisions/ADR-0001-記錄架構決策.md" adr0001
  , TemplateFile ".gitattributes" gitattributes
  , TemplateFile ".gitignore" gitignore
  , TemplateFile "assets/theme/theme.json" themeJson
  ]

--------------------------------------------------------------------------------

-- | 給 AI agent 與新成員的操作說明。
--
-- 這個檔案的存在理由是:接手的人(或 Claude Code)第一件事就是讀它,
-- 而它必須回答「怎麼跑、素材在哪、命名規則是什麼、加新素材的流程」。
-- 把這些寫在 README 裡會被淹沒在專案介紹中。
skillMd :: Text -> Text -> Text
skillMd name credits =
  T.unlines
    [ "# " <> name <> " — 操作說明"
    , ""
    , "> 由 assetdb 產生。給接手的人與 AI agent 讀的第一份文件。"
    , ""
    , "## 建置與執行"
    , ""
    , "```bash"
    , "cabal build"
    , "```"
    , ""
    , "```bash"
    , "cabal run " <> name
    , "```"
    , ""
    , "⚠️ **建置路徑不可含空格。** GHC 在 Windows 上的 `llvm-ar` 會在空格處截斷路徑。"
    , ""
    , "## 素材"
    , ""
    , "`assets/manifest.json` 是素材清單,型別定義在 `AssetDB.Manifest`(assetdb-core)。"
    , "遊戲直接 `import` 那個型別 —— schema 改動在編譯期爆炸,不是執行期黑畫面。"
    , ""
    , "`assets/Assets.hs` 是產生的素材 key 常數。**用它,不要用字串字面值。**"
    , ""
    , "```haskell"
    , "import Assets (uiGuiTravelBookFrame01a)"
    , "```"
    , ""
    , "### 素材命名規則"
    , ""
    , "```"
    , "<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]"
    , "```"
    , ""
    , "全小寫純 ASCII。檔名去掉副檔名後就是載入器的查表 key。"
    , ""
    , "### 加入新素材"
    , ""
    , "**不要手動複製檔案進 `assets/`。** `manifest.json` 與 `Assets.hs` 是由 assetdb"
    , "從資料庫產生的;手動放進來的檔案不會出現在裡面,載入器查不到 key,"
    , "而且授權閘門也不會看過它。"
    , ""
    , "增量加入素材的指令(`project sync`)**尚未實作**。目前的作法是用同樣的"
    , "`--pack` / `--match` 條件加上新的條件,重新產生到一個新目錄,再把"
    , "`assets/`、`manifest.json` 與 `Assets.hs` 換過去 —— 其餘手寫的程式碼不受影響。"
    , ""
    , "```bash"
    , "assetdb new-project --name <名稱> --path <新目錄> --pack <包1> --pack <包2>"
    , "```"
    , ""
    , "## 授權"
    , ""
    , credits
    , ""
    , "## 目錄"
    , ""
    , "```"
    , "src/          遊戲模組"
    , "app/          進入點"
    , "assets/       素材(由 assetdb 管理)"
    , "docs/         提案書、技術文檔、ADR"
    , "tools/        專案專屬工具"
    , "```"
    ]

readmeMd :: Text -> Text
readmeMd name =
  T.unlines
    [ "# " <> name
    , ""
    , "由 assetdb 建立。操作說明見 [SKILL.md](SKILL.md)。"
    , ""
    , "- [提案書](docs/提案書.md)"
    , "- [技術文檔](docs/技術文檔.md)"
    , "- [架構決策](docs/decisions/)"
    ]

proposalMd :: Text -> Text
proposalMd name =
  T.unlines
    [ "# " <> name <> " 提案書"
    , ""
    , "## 一句話"
    , ""
    , "_(這個遊戲是什麼?一句話說完。說不完代表還沒想清楚。)_"
    , ""
    , "## 玩家在做什麼"
    , ""
    , "## 為什麼有人會想玩"
    , ""
    , "## 範圍"
    , ""
    , "### 做"
    , ""
    , "### 不做"
    , ""
    , "_(這一節比上一節重要。)_"
    , ""
    , "## 里程碑"
    ]

techMd :: Text -> Text
techMd name =
  T.unlines
    [ "# " <> name <> " 技術文檔"
    , ""
    , "## 技術棧"
    , ""
    , "| 套件 | 用途 |"
    , "|---|---|"
    , "| `h-raylib` | 渲染 / 輸入 / 音效 |"
    , "| `apecs` | ECS |"
    , "| `aeson` | manifest 與設定解析 |"
    , "| `assetdb-core` | **素材 manifest 的型別,與資源管理系統共用** |"
    , ""
    , "## 已知風險"
    , ""
    , "- `apecs` 的 `SystemT` 與 `effectful` 的 `Eff` 不自然相容。先寫 spike 驗證。"
    , "- `dear-imgui` 沒有 raylib backend。除錯面板先用 raylib 自己畫。"
    , ""
    , "## 渲染分層"
    , ""
    , "每個可繪製實體需要 `Layer`(列舉)與 `SortKey`(通常是 Y 座標)。"
    , "繪製系統先依 Layer 分組,層內再依 SortKey 排序。**這要在 spike 階段就定下來**,"
    , "之後改動成本很高。"
    ]

adr0001 :: Text
adr0001 =
  T.unlines
    [ "# ADR-0001:記錄架構決策"
    , ""
    , "## 狀態"
    , ""
    , "已接受"
    , ""
    , "## 脈絡"
    , ""
    , "架構決策的**理由**比決策本身更容易流失。六個月後看到一段奇怪的程式碼,"
    , "問題永遠是「為什麼當初這樣做」,而答案通常已經沒人記得。"
    , ""
    , "## 決定"
    , ""
    , "每個影響結構的決策寫一份 ADR,放在 `docs/decisions/`。"
    , "記錄脈絡與後果,不只記結論 —— 結論從程式碼看得出來,脈絡看不出來。"
    , ""
    , "## 後果"
    , ""
    , "推翻舊決策時要寫新的 ADR 並標記舊的為「已取代」,而不是編輯舊的。"
    , "決策的歷史本身就是資訊。"
    ]

gitattributes :: Text
gitattributes =
  T.unlines
    [ "* text=auto eol=lf"
    , "*.hs text eol=lf"
    , ""
    , "# 二進位素材走 LFS。PNG 進 repo 前先確認 LFS 已設定,"
    , "# 否則 git 歷史會被塞滿無法差異比對的二進位資料。"
    , "*.png filter=lfs diff=lfs merge=lfs -text"
    , "*.psd filter=lfs diff=lfs merge=lfs -text"
    , "*.wav filter=lfs diff=lfs merge=lfs -text"
    , "*.ogg filter=lfs diff=lfs merge=lfs -text"
    ]

gitignore :: Text
gitignore = T.unlines ["dist-newstyle/", "*.hi", "*.o", ".assetdb/cache/"]

themeJson :: Text
themeJson =
  T.unlines
    [ "{"
    , "  \"_comment\": \"9-slice 邊界。素材包不會附這個 —— 那是引擎端概念。\","
    , "  \"_howto\": \"用圖片編輯器量邊框裝飾佔幾 pixel 填進去,錯了改數字即可。\","
    , "  \"nineSlice\": {"
    , "  }"
    , "}"
    ]

--------------------------------------------------------------------------------

-- | 致謝段落。
--
-- 需要署名的授權**必須**出現在這裡 —— 這是 pack.toml 的
-- @attribution_required@ 唯一有實際效果的地方。
creditsSection :: [(Text, Maybe Text, Bool)] -> Text
creditsSection packs
  | null packs = "_(這個專案還沒有使用任何素材。)_"
  | otherwise =
      T.unlines $
        ["| 素材包 | 授權 | 需署名 |", "|---|---|:-:|"]
          <> [ "| " <> n <> " | " <> maybe "?" id l <> " | " <> (if req then "**是**" else "否") <> " |"
             | (n, l, req) <- packs
             ]
          <> case [n | (n, _, True) <- packs] of
            [] -> []
            required ->
              [ ""
              , "⚠️ **以下素材包的授權要求署名,發行時必須出現在致謝畫面:**"
              , ""
              ]
                <> map ("- " <>) required
