#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="local.codex-quota-bar.watch-codex"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT_DIR="$HOME/Library/Application Support/CodexQuotaBar"
WATCHER="$SUPPORT_DIR/codex-quota-watch.sh"
SOURCE_APP="$ROOT_DIR/.build/CodexQuotaBar.app"
INSTALLED_APP="$HOME/Applications/CodexQuotaBar.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  "$ROOT_DIR/Scripts/build-app.sh"
fi

mkdir -p "$HOME/Applications" "$SUPPORT_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$SOURCE_APP" "$INSTALLED_APP"

cat > "$WATCHER" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

CODEX_MAIN="/Applications/Codex.app/Contents/MacOS/Codex"
QUOTA_APP="$INSTALLED_APP"
QUOTA_BIN="\$QUOTA_APP/Contents/MacOS/CodexQuotaBar"

codex_running=false
if pgrep -x "Codex" >/dev/null 2>&1 && pgrep -f "^\$CODEX_MAIN($| )" >/dev/null 2>&1; then
  codex_running=true
fi

quota_pids="\$(pgrep -f "^\$QUOTA_BIN($| )" || true)"

if [[ "\$codex_running" == true ]]; then
  if ! pgrep -f "^\$QUOTA_BIN($| )" >/dev/null 2>&1; then
    open "\$QUOTA_APP"
  fi
else
  if [[ -n "\$quota_pids" ]]; then
    kill \$quota_pids >/dev/null 2>&1 || true
  fi
fi
SCRIPT
chmod +x "$WATCHER"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WATCHER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/codex-quota-watch.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/codex-quota-watch.err</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $PLIST"
