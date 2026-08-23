# 產出可獨立發佈的資料夾並壓成 zip(G-E002)。Windows 版,與 release.sh 做同一件事。
#
#   scripts\release.ps1                              建置三個執行檔,組裝,壓縮
#   scripts\release.ps1 -Stage <已建好的目錄> -Version <版本>   跳過建置,只組裝(測試用)
#
# 產出:dist-release\story-flow-<版本>-windows-x64\ 與同名 .zip,內含恰好:
#   story-flow.exe  story-flow-serve.exe  story-flow-mcp.exe  registry\*.toml  README.md
#
# 刻意不設 $ErrorActionPreference = 'Stop':PowerShell 5.1 會把 native 指令寫到 stderr
# 的每一行包成 ErrorRecord 並中止——cabal 的正常輸出就會讓腳本假失敗(check.ps1 踩過)。
# 改看 $LASTEXITCODE。
param(
  [string]$Stage = "",
  [string]$Version = ""
)

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$OutRoot = Join-Path $Root "dist-release"
$Platform = "windows-x64"
$Cleanup = $false

if ($Stage -eq "") {
  $Stage = Join-Path ([System.IO.Path]::GetTempPath()) ("storyflow-release-" + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Force $Stage | Out-Null
  $Cleanup = $true
  Write-Host "建置三個執行檔到 $Stage"
  Push-Location $Root
  try {
    cabal install exe:story-flow exe:story-flow-serve exe:story-flow-mcp `
      --installdir="$Stage" --install-method=copy --overwrite-policy=always
    if ($LASTEXITCODE -ne 0) { Write-Host "cabal install 失敗"; exit 1 }
  } finally { Pop-Location }
}

$Exe = Join-Path $Stage "story-flow.exe"
if (-not (Test-Path $Exe)) { Write-Host "$Stage 裡沒有 story-flow.exe"; exit 1 }

if ($Version -eq "") {
  # 輸出是「story-flow <版本>」一行
  $line = (& $Exe --version) | Select-Object -First 1
  if ($LASTEXITCODE -ne 0 -or -not $line) { Write-Host "story-flow --version 沒有回版本"; exit 1 }
  $Version = ($line -split ' ')[1]
}

$Name = "story-flow-$Version-$Platform"
$Out = Join-Path $OutRoot $Name
$Zip = "$Out.zip"
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
if (Test-Path $Zip) { Remove-Item -Force $Zip }
New-Item -ItemType Directory -Force (Join-Path $Out "registry") | Out-Null

foreach ($bin in @("story-flow.exe", "story-flow-serve.exe", "story-flow-mcp.exe")) {
  $src = Join-Path $Stage $bin
  if (-not (Test-Path $src)) { Write-Host "缺執行檔:$bin"; exit 1 }
  Copy-Item $src $Out
}

Copy-Item (Join-Path $Root "types\registry\*.toml") (Join-Path $Out "registry")
Copy-Item (Join-Path $Root "scripts\release-readme.md") (Join-Path $Out "README.md")

Compress-Archive -Path $Out -DestinationPath $Zip -Force
if ($Cleanup) { Remove-Item -Recurse -Force $Stage }

Write-Host "完成:$Out"
Write-Host "      $Zip"
