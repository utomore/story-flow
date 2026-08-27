#!/usr/bin/env bash
# 產出可獨立發佈的資料夾並壓成 zip(G-E002)。
#
#   scripts/release.sh                      建置三個執行檔,組裝,壓縮
#   scripts/release.sh <已建好的目錄> <版本>  跳過建置,只組裝(測試用)
#
# 產出:dist-release/aapms-<版本>-<平台>/ 與同名 .zip,內含恰好:
#   aapms  aapms-serve  aapms-mcp  registry/*.toml  README.md
#
# 版本從 `aapms --version` 的輸出取,不另外 parse .cabal——那會是第二份規則。
# 任一步失敗就停,不產出半個 zip。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_ROOT="$ROOT/dist-release"
STAGE="${1:-}"
VERSION="${2:-}"

case "$(uname -s)" in
  Linux*)  PLATFORM="linux-$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')" ;;
  Darwin*) PLATFORM="macos-$(uname -m | sed 's/x86_64/x64/')" ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows-x64" ;;
  *) echo "不認得的平台:$(uname -s)" >&2; exit 1 ;;
esac

if [ -z "$STAGE" ]; then
  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  echo "建置三個執行檔到 $STAGE"
  ( cd "$ROOT" && cabal install exe:aapms exe:aapms-serve exe:aapms-mcp \
      --installdir="$STAGE" --install-method=copy --overwrite-policy=always )
fi

EXE=""
for cand in "$STAGE/aapms" "$STAGE/aapms.exe"; do
  [ -f "$cand" ] && EXE="$cand" && break
done
[ -n "$EXE" ] || { echo "$STAGE 裡沒有 aapms 執行檔" >&2; exit 1; }

if [ -z "$VERSION" ]; then
  # 輸出是「aapms <版本>」一行
  VERSION=$("$EXE" --version | awk '{print $2}')
  [ -n "$VERSION" ] || { echo "aapms --version 沒有回版本" >&2; exit 1; }
fi

NAME="aapms-$VERSION-$PLATFORM"
OUT="$OUT_ROOT/$NAME"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/registry"

for bin in aapms aapms-serve aapms-mcp; do
  src=""
  for cand in "$STAGE/$bin" "$STAGE/$bin.exe"; do
    [ -f "$cand" ] && src="$cand" && break
  done
  [ -n "$src" ] || { echo "缺執行檔:$bin" >&2; exit 1; }
  cp "$src" "$OUT/"
done

cp "$ROOT"/types/registry/*.toml "$OUT/registry/"
cp "$ROOT/scripts/release-readme.md" "$OUT/README.md"

# zip 不是每個環境都有(Git Bash 就沒有)。bsdtar 的 -a 會依副檔名選 zip;
# Windows 內建的 tar.exe 就是 bsdtar,但 Git Bash 的 PATH 會先命中 GNU tar,所以明指。
BSDTAR=""
for t in tar /c/Windows/System32/tar.exe; do
  if "$t" --version 2>/dev/null | grep -qi bsdtar; then BSDTAR="$t"; break; fi
done
if command -v zip >/dev/null 2>&1; then
  ( cd "$OUT_ROOT" && zip -qr "$NAME.zip" "$NAME" )
elif [ -n "$BSDTAR" ]; then
  ( cd "$OUT_ROOT" && "$BSDTAR" -a -cf "$NAME.zip" "$NAME" )
else
  echo "沒有 zip 也沒有 bsdtar,壓不了;資料夾已組好:$OUT" >&2; exit 1
fi
echo "完成:$OUT"
echo "      $OUT.zip"
