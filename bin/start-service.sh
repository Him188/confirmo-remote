#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE_BIN:-}"
TOKEN_FILE="${CONFIRMO_REMOTE_TOKEN_FILE:-$HOME/.confirmo/remote/confirmo-remote.token}"
LISTEN_ADDR="${CONFIRMO_REMOTE_LISTEN:-127.0.0.1:17890}"
EVENT_PATH="${CONFIRMO_REMOTE_PATH:-/v1/codex/event}"
STREAM_PATH="${CONFIRMO_REMOTE_STREAM_PATH:-/v1/codex/stream}"
STATUS_DIR="${CONFIRMO_REMOTE_STATUS_DIR:-$HOME/.confirmo/codex-status}"
CODEX_SESSIONS_ROOT="${CONFIRMO_CODEX_SESSIONS_ROOT:-$HOME/.codex/sessions}"

if [[ -z "$NODE_BIN" ]]; then
  NODE_BIN="$(command -v node || true)"
fi

if [[ ! -x "$NODE_BIN" ]]; then
  echo "node not found at $NODE_BIN" >&2
  exit 1
fi

if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "token file missing or empty: $TOKEN_FILE" >&2
  exit 1
fi

TOKEN="$(cat "$TOKEN_FILE")"

# Set argv0 to "codex" so Confirmo AgentMonitor polls Codex JSONL continuously.
exec -a codex "$NODE_BIN" "$ROOT_DIR/bin/confirmo-remote.js" serve \
  --listen "$LISTEN_ADDR" \
  --path "$EVENT_PATH" \
  --stream-path "$STREAM_PATH" \
  --status-dir "$STATUS_DIR" \
  --codex-sessions-root "$CODEX_SESSIONS_ROOT" \
  --token "$TOKEN"
