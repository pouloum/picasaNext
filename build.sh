#!/usr/bin/env bash
# Builds PicasaNext with swiftc directly (no SwiftPM). Same targets as Package.swift.
# Useful where SwiftPM cannot write its caches; otherwise `swift build -c release` works too.
#   ./build.sh [debug|release]   → build/<config>/{picasa-cli,PicasaNext.app}
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
OUT="build/$CONFIG"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/picasanext-mc}"
SDK="$(xcrun --show-sdk-path 2>/dev/null)"
SWIFTC_BIN="$(xcrun -f swiftc 2>/dev/null)"
TARGET="$(uname -m)-apple-macosx14.0"
OPT=(-Onone -g); [ "$CONFIG" = release ] && OPT=(-O -wmo)
SWIFTC=("$SWIFTC_BIN" -sdk "$SDK" -target "$TARGET" -swift-version 6 "${OPT[@]}" -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I "$OUT" -L "$OUT")

lib() { # name sources...
  local name=$1; shift
  "${SWIFTC[@]}" -parse-as-library -module-name "$name" -emit-module -emit-module-path "$OUT/$name.swiftmodule" \
    -emit-library -static -o "$OUT/lib$name.a" "$@"
}

echo "[build] PicasaFormats"; lib PicasaFormats Sources/PicasaFormats/*.swift
echo "[build] PicasaCore";    lib PicasaCore Sources/PicasaCore/*.swift -lPicasaFormats
echo "[build] picasa-cli"
"${SWIFTC[@]}" -module-name picasa_cli -o "$OUT/picasa-cli" Sources/picasa-cli/*.swift -lPicasaCore -lPicasaFormats -lsqlite3

echo "[build] PicasaNext.app"
APP="$OUT/PicasaNext.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"${SWIFTC[@]}" -parse-as-library -module-name PicasaViewer -o "$APP/Contents/MacOS/PicasaNext" Sources/PicasaViewer/*.swift -lPicasaCore -lPicasaFormats -lsqlite3
cp Resources/Info.plist "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [ "${TESTS:-0}" = 1 ]; then
  echo "[build] tests"
  "${SWIFTC[@]}" -module-name PicasaTests -o "$OUT/picasa-tests" Tests/Runner/*.swift -lPicasaCore -lPicasaFormats -lsqlite3
  "$OUT/picasa-tests"
fi
echo "[build] done → $OUT"
