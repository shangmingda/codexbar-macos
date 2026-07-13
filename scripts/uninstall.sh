#!/bin/zsh
set -euo pipefail

launchctl bootout "gui/$(id -u)/com.smd.codexbar" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.smd.codexbar.watcher" 2>/dev/null || true
pkill -x CodexBar 2>/dev/null || true
pkill -f "$HOME/Library/Application Support/CodexBar/CodexBarWatcher" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.smd.codexbar.plist"
rm -f "$HOME/Library/LaunchAgents/com.smd.codexbar.watcher.plist"
rm -rf "$HOME/Library/Application Support/CodexBar"
rm -rf "$HOME/Applications/CodexBar.app"
echo "CodexBar 已卸载"
