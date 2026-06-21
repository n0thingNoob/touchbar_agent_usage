#!/usr/bin/env bash
set -euo pipefail

CODEX_MAIN="/Applications/Codex.app/Contents/MacOS/Codex"
QUOTA_APP="/Users/apple/Desktop/touchbar-project/.build/CodexQuotaBar.app"
QUOTA_BIN="$QUOTA_APP/Contents/MacOS/CodexQuotaBar"

codex_running=false
if pgrep -x "Codex" >/dev/null 2>&1 && pgrep -f "^$CODEX_MAIN($| )" >/dev/null 2>&1; then
  codex_running=true
fi

quota_pids="$(pgrep -f "^$QUOTA_BIN($| )" || true)"

if [[ "$codex_running" == true ]]; then
  if [[ -z "$quota_pids" ]]; then
    open "$QUOTA_APP"
  fi
else
  if [[ -n "$quota_pids" ]]; then
    kill $quota_pids >/dev/null 2>&1 || true
  fi
fi
