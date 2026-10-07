#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
SUPPORT="$HOME/Library/Application Support/CodexBar"
HELPER="$SUPPORT/CodexBarCredentialHelper"
mkdir -p "$SUPPORT"
if [[ -e "$HELPER" ]]; then
  codesign --verify --strict "$HELPER"
  [[ "$("$HELPER" protocol-version)" == "1" ]]
else
  cp "$ROOT/.build/release/codexbar-credential-helper" "$HELPER"
  chmod 700 "$HELPER"
  codesign --force --sign - "$HELPER"
fi
"$ROOT/.build/release/codexbar-diagnostics" --migrate-stable-credentials
