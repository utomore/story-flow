# story-flow 一鍵建置與測試。CI 的替代品(見 docs/spec/func-0001-project-skeleton.md)。
$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Write-Host '== cabal build all =='
cabal build all
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host '== cabal test all =='
cabal test all --test-show-details=direct
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host '== OK =='
