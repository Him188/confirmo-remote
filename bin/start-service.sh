#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/Users/him188/IdeaProjects/confirmo-remote"
NODE_BIN="${NODE_BIN:-/opt/homebrew/bin/node}"
TOKEN_FILE="${CONFIRMO_REMOTE_TOKEN_FILE:-$HOME/.confirmo/remote/confirmo-remote.token}"
LISTEN_ADDR="${CONFIRMO_REMOTE_LISTEN:-127.0.0.1:17890}"
EVENT_PATH="${CONFIRMO_REMOTE_PATH:-/v1/codex/event}"
STATUS_DIR="${CONFIRMO_REMOTE_STATUS_DIR:-$HOME/.confirmo/codex-status}"

if [[ ! -x "$NODE_BIN" ]]; then
  echo "node not found at $NODE_BIN" >&2
  exit 1
fi

if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "token file missing or empty: $TOKEN_FILE" >&2
  exit 1
fi

TOKEN="$(cat "$TOKEN_FILE")"

exec "$NODE_BIN" "$ROOT_DIR/bin/confirmo-remote.js" serve \
  --listen "$LISTEN_ADDR" \
  --path "$EVENT_PATH" \
  --status-dir "$STATUS_DIR" \
  --token "$TOKEN"
