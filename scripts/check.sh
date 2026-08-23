#!/usr/bin/env bash
# aapms 一鍵建置與測試。CI 的替代品(見 .design/subsystems/entity-graph-core/features/F001-project-skeleton.md)。
# 指令內容必須與 check.ps1 一致,否則會出現「本機過、另一台不過」。
set -euo pipefail

echo '== cabal build all =='
cabal build all

echo '== cabal test all =='
cabal test all --test-show-details=direct

echo '== OK =='
