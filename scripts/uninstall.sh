#!/bin/zsh
set -euo pipefail

codex_desktop_running() {
  /bin/ps -ww -axo command= | /usr/bin/awk '$1 ~ /\/(ChatGPT|Codex)\.app\/Contents\/MacOS\/(ChatGPT|Codex)$/ { found=1 } END { exit(found ? 0 : 1) }'
}

if codex_desktop_running; then
  echo "为避免中断正在运行的 Codex 任务，请先退出 Codex Desktop，再执行卸载。" >&2
  exit 1
fi

WATCHER="$HOME/Library/Application Support/CodexBar/CodexBarWatcher"
APP_EXECUTABLE="$HOME/Applications/CodexBar.app/Contents/MacOS/CodexBar"
if [[ -x "$WATCHER" ]] && /usr/bin/grep -a -q -- '--restore-only' "$WATCHER"; then
  set +e
  "$WATCHER" --restore-only
  ROLLBACK_STATUS=$?
  set -e
  if [[ "$ROLLBACK_STATUS" != "0" && "$ROLLBACK_STATUS" != "10" && "$ROLLBACK_STATUS" != "2" ]]; then
    echo "恢复 OpenAI 配置失败，已停止卸载" >&2
    exit 1
  fi
fi
if [[ -x "$APP_EXECUTABLE" ]]; then
  "$APP_EXECUTABLE" --delete-deepseek-credential 2>/dev/null || true
fi

launchctl bootout "gui/$(id -u)/com.smd.codexbar" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.smd.codexbar.watcher" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.smd.codexbar.appserver" 2>/dev/null || true
launchctl unsetenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 2>/dev/null || true
pkill -x CodexBar 2>/dev/null || true
pkill -f "$WATCHER" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.smd.codexbar.plist"
rm -f "$HOME/Library/LaunchAgents/com.smd.codexbar.watcher.plist"
rm -f "$HOME/Library/LaunchAgents/com.smd.codexbar.appserver.plist"
rm -rf "$HOME/Library/Application Support/CodexBar"
rm -rf "$HOME/Applications/CodexBar.app"
echo "CodexBar 已卸载"
