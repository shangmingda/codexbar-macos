#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
"$ROOT/scripts/build-app.sh" >/dev/null
"$ROOT/scripts/install-credential-helper.sh"

APP_SOURCE="$ROOT/dist/CodexBar.app"
APP_TARGET="$HOME/Applications/CodexBar.app"
AGENT="$HOME/Library/LaunchAgents/com.smd.codexbar.plist"
WATCHER_AGENT="$HOME/Library/LaunchAgents/com.smd.codexbar.watcher.plist"
CONTROL_AGENT="$HOME/Library/LaunchAgents/com.smd.codexbar.appserver.plist"
SUPPORT="$HOME/Library/Application Support/CodexBar"
WATCHER="$SUPPORT/CodexBarWatcher"
CODEX_APP="$(mdfind 'kMDItemCFBundleIdentifier == "com.openai.codex"' | head -n 1)"
if [[ -z "$CODEX_APP" ]]; then
  for candidate in "/Applications/ChatGPT.app" "/Applications/Codex.app" "$HOME/Applications/ChatGPT.app" "$HOME/Applications/Codex.app"; do
    if [[ -d "$candidate" ]]; then CODEX_APP="$candidate"; break; fi
  done
fi
CODEX_BIN="$CODEX_APP/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
if [[ ! -x "$CODEX_BIN" ]]; then
  CODEX_BIN="$CODEX_APP/Contents/Resources/codex"
fi
if [[ -z "$CODEX_APP" || ! -x "$CODEX_BIN" ]]; then
  echo "未找到 Codex Desktop，请先安装后再运行安装脚本" >&2
  exit 1
fi
CODEX_GUI_EXECUTABLE="$(defaults read "$CODEX_APP/Contents/Info" CFBundleExecutable 2>/dev/null || echo ChatGPT)"
CODEX_GUI_BIN="$CODEX_APP/Contents/MacOS/$CODEX_GUI_EXECUTABLE"
codex_desktop_running() {
  /bin/ps -ww -axo command= | /usr/bin/awk -v target="$CODEX_GUI_BIN" '$1 == target { found=1 } END { exit(found ? 0 : 1) }'
}
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$SUPPORT"

PROVIDER_ROLLBACK=0
if ! codex_desktop_running && [[ -x "$WATCHER" ]] && /usr/bin/grep -a -q -- '--restore-only' "$WATCHER"; then
  set +e
  "$WATCHER" --restore-only
  ROLLBACK_STATUS=$?
  set -e
  if [[ "$ROLLBACK_STATUS" == "10" ]]; then
    PROVIDER_ROLLBACK=1
  elif [[ "$ROLLBACK_STATUS" != "0" && "$ROLLBACK_STATUS" != "2" ]]; then
    echo "升级前恢复 OpenAI 配置失败，已停止安装以保护 Codex 原配置" >&2
    exit 1
  fi
fi

CONTROL_RESTART=1
if launchctl print "gui/$(id -u)/com.smd.codexbar.appserver" >/dev/null 2>&1 && \
   [[ -S "$HOME/.codex/app-server-control/app-server-control.sock" ]] && \
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$CONTROL_AGENT" 2>/dev/null)" == "$CODEX_BIN" ]] && \
   codex_desktop_running; then
  CONTROL_RESTART=0
fi
launchctl bootout "gui/$(id -u)/com.smd.codexbar" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.smd.codexbar.watcher" 2>/dev/null || true
if [[ "$CONTROL_RESTART" == "1" ]]; then
  launchctl bootout "gui/$(id -u)/com.smd.codexbar.appserver" 2>/dev/null || true
fi
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

apply_control_plist() {
  /usr/libexec/PlistBuddy -c "Clear dict" "$CONTROL_AGENT" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :Label string com.smd.codexbar.appserver" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $CODEX_BIN" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string app-server" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --listen" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string unix://" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ProcessType string Background" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 5" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :StandardOutPath string /dev/null" "$CONTROL_AGENT"
  /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string /dev/null" "$CONTROL_AGENT"
}
apply_control_plist
plutil -lint "$CONTROL_AGENT" >/dev/null

launchctl setenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 1
if [[ "$CONTROL_RESTART" == "1" ]]; then
  launchctl bootstrap "gui/$(id -u)" "$CONTROL_AGENT"
else
  echo "检测到 Codex 正在运行，保留现有共享控制服务以避免中断任务。"
fi
launchctl bootstrap "gui/$(id -u)" "$WATCHER_AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
if [[ "$PROVIDER_ROLLBACK" == "1" ]] && codex_desktop_running; then
  echo "OpenAI 配置已恢复；CodexBar 未自动退出 Codex，请在方便时手动按 ⌘Q 退出并重新打开" >&2
fi
for _ in {1..24}; do
  [[ -S "$HOME/.codex/app-server-control/app-server-control.sock" ]] && break
  sleep 0.5
done
if [[ ! -S "$HOME/.codex/app-server-control/app-server-control.sock" ]]; then
  echo "Codex 共享控制通道启动失败，请重新运行安装脚本" >&2
  exit 1
fi
echo "Installed: $APP_TARGET"
if codex_desktop_running; then
  echo "CodexBar 将自动检测当前任务控制状态；若旧连接任务需要启用自动停止，只会在你当次明确确认后重启 Codex。"
fi
