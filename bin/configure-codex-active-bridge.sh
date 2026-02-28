#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  configure-codex-active-bridge.sh [--target <url>] [--token <token>] [--bridge-url <url>] [--source <name>]

Examples:
  configure-codex-active-bridge.sh --target https://h1-confirmo.ngrok.app/v1/codex/event --token abc123
  configure-codex-active-bridge.sh

Behavior:
  - Installs codex-activity-bridge script to ~/.confirmo/bridge/
  - Creates/updates launchd agent: com.him188.confirmo-codex-activity-bridge
  - Starts the bridge immediately (macOS)
  - If --target is omitted, reads first target from ~/.confirmo/hooks/codex-remote.json
  - If --token is omitted, reads token from ~/.confirmo/hooks/codex-remote.json
EOF
}

TARGET_URL="${CONFIRMO_REMOTE_STREAM_URL:-}"
TOKEN="${CONFIRMO_REMOTE_TOKEN:-}"
SOURCE_NAME="${CONFIRMO_SOURCE:-$(hostname)}"
BRIDGE_URL="${CONFIRMO_ACTIVITY_BRIDGE_URL:-https://him188.github.io/confirmo-remote/bin/codex-activity-bridge.js}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_URL="${2:-}"
      shift 2
      ;;
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --bridge-url)
      BRIDGE_URL="${2:-}"
      shift 2
      ;;
    --source)
      SOURCE_NAME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v node >/dev/null 2>&1; then
  echo "node is required but was not found in PATH" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but was not found in PATH" >&2
  exit 1
fi

CONF_FILE="$HOME/.confirmo/hooks/codex-remote.json"
if [[ -f "$CONF_FILE" ]]; then
  TMP_ENV_FILE="$(mktemp)"
  CONF_FILE="$CONF_FILE" node <<'NODE' > "$TMP_ENV_FILE"
const fs = require('fs')
const file = process.env.CONF_FILE
let config = {}
try {
  config = JSON.parse(fs.readFileSync(file, 'utf8'))
} catch (_) {}

const firstTarget = Array.isArray(config.targets) && config.targets.length > 0
  ? config.targets[0]
  : ''
const targetUrl = typeof firstTarget === 'string'
  ? firstTarget
  : (firstTarget && typeof firstTarget.url === 'string' ? firstTarget.url : '')
const token = typeof config.token === 'string' ? config.token : ''

function escapeShell(value) {
  return String(value).replace(/'/g, "'\\''")
}

if (targetUrl) {
  process.stdout.write("CONFIRMO_CONFIG_TARGET='" + escapeShell(targetUrl) + "'\n")
}
if (token) {
  process.stdout.write("CONFIRMO_CONFIG_TOKEN='" + escapeShell(token) + "'\n")
}
NODE
  # shellcheck disable=SC1090
  . "$TMP_ENV_FILE"
  rm -f "$TMP_ENV_FILE"
fi

if [[ -z "$TARGET_URL" && -n "${CONFIRMO_CONFIG_TARGET:-}" ]]; then
  TARGET_URL="$CONFIRMO_CONFIG_TARGET"
fi
if [[ -z "$TOKEN" && -n "${CONFIRMO_CONFIG_TOKEN:-}" ]]; then
  TOKEN="$CONFIRMO_CONFIG_TOKEN"
fi

if [[ -z "$TARGET_URL" ]]; then
  echo "Missing target URL. Pass --target or configure ~/.confirmo/hooks/codex-remote.json first." >&2
  exit 1
fi
if [[ -z "$TOKEN" ]]; then
  echo "Missing token. Pass --token or configure ~/.confirmo/hooks/codex-remote.json first." >&2
  exit 1
fi

if [[ "$TARGET_URL" != http://* && "$TARGET_URL" != https://* ]]; then
  TARGET_URL="https://${TARGET_URL}"
fi
if [[ "$TARGET_URL" =~ /v1/codex/event$ ]]; then
  TARGET_URL="${TARGET_URL%/v1/codex/event}/v1/codex/stream"
elif [[ "$TARGET_URL" =~ ^https?://[^/]+/?$ ]]; then
  TARGET_URL="${TARGET_URL%/}/v1/codex/stream"
fi

if [[ "$BRIDGE_URL" != http://* && "$BRIDGE_URL" != https://* ]]; then
  echo "Invalid --bridge-url: $BRIDGE_URL" >&2
  exit 1
fi

BRIDGE_DIR="$HOME/.confirmo/bridge"
BRIDGE_FILE="$BRIDGE_DIR/codex-activity-bridge.js"
LOG_DIR="$HOME/.confirmo/logs"
PLIST="$HOME/Library/LaunchAgents/com.him188.confirmo-codex-activity-bridge.plist"
NODE_BIN="$(command -v node)"

mkdir -p "$BRIDGE_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

TMP_FILE="$(mktemp)"
if ! curl -fsSL "$BRIDGE_URL" -o "$TMP_FILE"; then
  rm -f "$TMP_FILE"
  echo "Failed to download bridge script from $BRIDGE_URL" >&2
  exit 1
fi
if ! grep -q "Confirmo Codex Activity Bridge" "$TMP_FILE"; then
  rm -f "$TMP_FILE"
  echo "Downloaded file does not look like codex-activity-bridge.js" >&2
  exit 1
fi
mv "$TMP_FILE" "$BRIDGE_FILE"
chmod +x "$BRIDGE_FILE"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.him188.confirmo-codex-activity-bridge</string>

  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$BRIDGE_FILE</string>
    <string>run</string>
    <string>--target</string>
    <string>$TARGET_URL</string>
    <string>--token</string>
    <string>$TOKEN</string>
    <string>--source</string>
    <string>$SOURCE_NAME</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>$LOG_DIR/codex-activity-bridge.out.log</string>

  <key>StandardErrorPath</key>
  <string>$LOG_DIR/codex-activity-bridge.err.log</string>
</dict>
</plist>
PLIST

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST" >/dev/null
fi

if command -v launchctl >/dev/null 2>&1; then
  uid="$(id -u)"
  launchctl bootout "gui/$uid" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$uid" "$PLIST"
  launchctl enable "gui/$uid/com.him188.confirmo-codex-activity-bridge" || true
  launchctl kickstart -k "gui/$uid/com.him188.confirmo-codex-activity-bridge"
  echo "Bridge installed and started via launchd: com.him188.confirmo-codex-activity-bridge"
else
  echo "launchctl not found. Run manually:"
  echo "  $NODE_BIN $BRIDGE_FILE run --target '$TARGET_URL' --token '$TOKEN' --source '$SOURCE_NAME'"
fi

echo "target: $TARGET_URL"
echo "source: $SOURCE_NAME"
echo "bridge script: $BRIDGE_FILE"
echo "launch agent: $PLIST"
