#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
"$ROOT/scripts/build-app.sh" >/dev/null

APP_SOURCE="$ROOT/dist/CodexBar.app"
APP_TARGET="$HOME/Applications/CodexBar.app"
AGENT="$HOME/Library/LaunchAgents/com.smd.codexbar.plist"
WATCHER_AGENT="$HOME/Library/LaunchAgents/com.smd.codexbar.watcher.plist"
SUPPORT="$HOME/Library/Application Support/CodexBar"
WATCHER="$SUPPORT/CodexBarWatcher"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$SUPPORT"

launchctl bootout "gui/$(id -u)/com.smd.codexbar" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.smd.codexbar.watcher" 2>/dev/null || true
pkill -x CodexBar 2>/dev/null || true
pkill -f "$WATCHER" 2>/dev/null || true
rm -rf "$APP_TARGET"
cp -R "$APP_SOURCE" "$APP_TARGET"
cp "$ROOT/.build/release/codexbar-watcher" "$WATCHER"
codesign --force --sign - "$WATCHER"

apply_plist() {
  /usr/libexec/PlistBuddy -c "Clear dict" "$AGENT" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :Label string com.smd.codexbar" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string /usr/bin/open" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string -g" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string -a" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string $APP_TARGET" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :KeepAlive bool false" "$AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$AGENT"
}
apply_plist
plutil -lint "$AGENT" >/dev/null

apply_watcher_plist() {
  /usr/libexec/PlistBuddy -c "Clear dict" "$WATCHER_AGENT" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :Label string com.smd.codexbar.watcher" "$WATCHER_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$WATCHER_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $WATCHER" "$WATCHER_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $APP_TARGET" "$WATCHER_AGENT"
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$WATCHER_AGENT"
  /usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$WATCHER_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$WATCHER_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 5" "$WATCHER_AGENT"
}
apply_watcher_plist
plutil -lint "$WATCHER_AGENT" >/dev/null

launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$WATCHER_AGENT"
echo "Installed: $APP_TARGET"
