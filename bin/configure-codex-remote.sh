#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  configure-codex-remote.sh <confirmo_target_url> [--token <token>] [--timeout-ms <ms>] [--replace-targets]

Examples:
  configure-codex-remote.sh https://h1-confirmo.ngrok.app
  configure-codex-remote.sh https://h1-confirmo.ngrok.app/v1/codex/event --token abc123
  configure-codex-remote.sh https://h1-confirmo.ngrok.app --replace-targets

Behavior:
  - Writes ~/.confirmo/hooks/codex-remote.json
  - Appends target by default (deduplicated)
  - If --replace-targets is set, replaces all existing targets with this single target
  - If URL has no path, '/v1/codex/event' is appended automatically
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

TARGET_URL="${1:-}"
shift || true

TOKEN="${CONFIRMO_REMOTE_TOKEN:-}"
TIMEOUT_MS="${CONFIRMO_REMOTE_TIMEOUT_MS:-1800}"
REPLACE_TARGETS="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      TIMEOUT_MS="${2:-}"
      shift 2
      ;;
    --replace-targets)
      REPLACE_TARGETS="true"
      shift
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

if [[ -z "$TARGET_URL" ]]; then
  echo "Missing confirmo_target_url" >&2
  usage
  exit 1
fi

if ! [[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_MS" -le 0 ]]; then
  echo "--timeout-ms must be a positive integer" >&2
  exit 1
fi

if [[ "$TARGET_URL" != http://* && "$TARGET_URL" != https://* ]]; then
  TARGET_URL="https://${TARGET_URL}"
fi

if [[ "$TARGET_URL" =~ ^https?://[^/]+$ ]]; then
  TARGET_URL="${TARGET_URL}/v1/codex/event"
fi

CONF_DIR="${HOME}/.confirmo/hooks"
CONF_FILE="${CONF_DIR}/codex-remote.json"
mkdir -p "$CONF_DIR"

if ! command -v node >/dev/null 2>&1; then
  echo "node is required but was not found in PATH" >&2
  exit 1
fi

TARGET_URL="$TARGET_URL" \
TOKEN="$TOKEN" \
TIMEOUT_MS="$TIMEOUT_MS" \
REPLACE_TARGETS="$REPLACE_TARGETS" \
CONF_FILE="$CONF_FILE" \
node <<'NODE'
const fs = require('fs')

const confFile = process.env.CONF_FILE
const targetUrl = process.env.TARGET_URL
const token = process.env.TOKEN || ''
const timeoutMs = Number(process.env.TIMEOUT_MS || 1800)
const replaceTargets = process.env.REPLACE_TARGETS === 'true'

if (!/^https?:\/\//.test(targetUrl)) {
  process.stderr.write(`Invalid target URL: ${targetUrl}\n`)
  process.exit(1)
}

let parsed
try {
  parsed = new URL(targetUrl)
} catch (_) {
  process.stderr.write(`Invalid target URL: ${targetUrl}\n`)
  process.exit(1)
}

if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
  process.stderr.write(`Invalid target URL protocol: ${parsed.protocol}\n`)
  process.exit(1)
}

let config = {}
if (fs.existsSync(confFile)) {
  try {
    config = JSON.parse(fs.readFileSync(confFile, 'utf8'))
  } catch (e) {
    process.stderr.write(`Failed to parse existing config: ${confFile}\n`)
    process.exit(1)
  }
}

if (!Array.isArray(config.targets)) {
  config.targets = []
}

if (replaceTargets) {
  config.targets = [targetUrl]
} else {
  const exists = config.targets.some((t) => {
    if (typeof t === 'string') return t === targetUrl
    return Boolean(t && typeof t === 'object' && t.url === targetUrl)
  })
  if (!exists) {
    config.targets.push(targetUrl)
  }
}

if (token) {
  config.token = token
}

config.timeoutMs = timeoutMs

const out = JSON.stringify(config, null, 2) + '\n'
fs.writeFileSync(confFile, out)
NODE

echo "Configured Codex remote targets:"
echo "  config: $CONF_FILE"
echo "  target: $TARGET_URL"
if [[ -n "$TOKEN" ]]; then
  echo "  token:  [updated]"
else
  echo "  token:  [unchanged]"
fi
echo "  timeoutMs: $TIMEOUT_MS"

HOOK_FILE="${HOME}/.confirmo/hooks/confirmo-codex-hook.js"
CODEX_CONFIG="${HOME}/.codex/config.toml"

if [[ ! -f "$HOOK_FILE" ]]; then
  echo "WARN: hook file not found: $HOOK_FILE"
fi

if [[ -f "$CODEX_CONFIG" ]]; then
  if grep -q 'confirmo-codex-hook.js' "$CODEX_CONFIG"; then
    echo "notify hook: detected in $CODEX_CONFIG"
  else
    echo "WARN: notify hook not detected in $CODEX_CONFIG"
    echo "      Please ensure notify points to ~/.confirmo/hooks/confirmo-codex-hook.js"
  fi
else
  echo "WARN: codex config not found: $CODEX_CONFIG"
fi
