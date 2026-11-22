#!/bin/sh
# Builds "PS2 HDD Manager.app": the hdl_dump + pfsshell engines and the SwiftUI front-end.
# Requirements: Xcode command line tools, meson + ninja (brew install meson ninja).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${OUT:-$HERE/build}"
APP="$OUT/PS2 HDD Manager.app"
CONFIG="${CONFIG:-release}"

echo "==> hdl_dump"
make -C "$ROOT" RELEASE=yes hdl_dump >/dev/null

echo "==> pfsshell"
PFS="$HERE/vendor/pfsshell"
if [ ! -f "$PFS/meson.build" ]; then
    git -C "$ROOT" submodule update --init --recursive
fi
if [ ! -d "$OUT/pfsshell" ]; then
    meson setup "$OUT/pfsshell" "$PFS" -Denable_pfsfuse=false --buildtype=release >/dev/null
fi
ninja -C "$OUT/pfsshell" pfsshell >/dev/null

echo "==> SwiftUI app ($CONFIG)"
swift build --package-path "$HERE" -c "$CONFIG" >/dev/null
BIN="$(swift build --package-path "$HERE" -c "$CONFIG" --show-bin-path)"

echo "==> Bundling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PS2HDDManager" "$APP/Contents/MacOS/PS2HDDManager"
cp "$ROOT/hdl_dump" "$APP/Contents/MacOS/hdl_dump"
cp "$OUT/pfsshell/pfsshell" "$APP/Contents/MacOS/pfsshell"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Gatekeeper on this Mac runs it; use a Developer ID to distribute.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "Built: $APP"
