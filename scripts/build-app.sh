#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release

APP="$ROOT/dist/CodexBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/CodexBar" "$APP/Contents/MacOS/CodexBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/SupportAuthor.png" "$APP/Contents/Resources/SupportAuthor.png"
codesign --force --deep --sign - "$APP"
echo "$APP"
