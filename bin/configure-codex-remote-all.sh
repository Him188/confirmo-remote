#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  configure-codex-remote-all.sh <confirmo_target_url> [options]

Examples:
  configure-codex-remote-all.sh https://h1-confirmo.ngrok.app --token abc123 --replace-targets

Behavior:
  - Runs configure-codex-remote.sh (hook + notify + remote event target)
  - Runs configure-codex-active-bridge.sh (launchd active bridge to stream endpoint)
  - Designed for one-command setup on Codex machine

Options:
  --token <token>              Shared token (optional, can come from existing config)
  --timeout-ms <ms>            Forward timeout for hook remote event
  --replace-targets            Replace targets instead of append
  --force-install-hook         Reinstall hook file
  --hook-url <url>             Hook source URL for configure-codex-remote.sh
  --bridge-url <url>           Bridge source URL for configure-codex-active-bridge.sh
  --source <name>              Source label for bridge (default: hostname)
  --script-base-url <url>      Base URL that hosts configure scripts (default: GitHub Pages /bin)
  -h, --help                   Show help
EOF
}

TARGET_URL=""
TOKEN="${CONFIRMO_REMOTE_TOKEN:-}"
TIMEOUT_MS="${CONFIRMO_REMOTE_TIMEOUT_MS:-}"
REPLACE_TARGETS="false"
FORCE_INSTALL_HOOK="false"
HOOK_URL="${CONFIRMO_CODEX_HOOK_URL:-}"
BRIDGE_URL="${CONFIRMO_ACTIVITY_BRIDGE_URL:-}"
SOURCE_NAME="${CONFIRMO_SOURCE:-}"
SCRIPT_BASE_URL="${CONFIRMO_REMOTE_INSTALL_BASE_URL:-https://him188.github.io/confirmo-remote/bin}"

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
    --force-install-hook)
      FORCE_INSTALL_HOOK="true"
      shift
      ;;
    --hook-url)
      HOOK_URL="${2:-}"
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
    --script-base-url)
      SCRIPT_BASE_URL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$TARGET_URL" ]]; then
        echo "Only one confirmo_target_url is allowed" >&2
        usage
        exit 1
      fi
      TARGET_URL="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET_URL" ]]; then
  echo "Missing confirmo_target_url" >&2
  usage
  exit 1
fi

if [[ -n "$TIMEOUT_MS" ]] && { ! [[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_MS" -le 0 ]]; }; then
  echo "--timeout-ms must be a positive integer" >&2
  exit 1
fi

if [[ "$SCRIPT_BASE_URL" != http://* && "$SCRIPT_BASE_URL" != https://* ]]; then
  echo "Invalid --script-base-url: $SCRIPT_BASE_URL" >&2
  exit 1
fi

SCRIPT_BASE_URL="${SCRIPT_BASE_URL%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SCRIPT_LOCAL="$SCRIPT_DIR/configure-codex-remote.sh"
BRIDGE_SCRIPT_LOCAL="$SCRIPT_DIR/configure-codex-active-bridge.sh"
REMOTE_SCRIPT_URL="$SCRIPT_BASE_URL/configure-codex-remote.sh"
BRIDGE_SCRIPT_URL="$SCRIPT_BASE_URL/configure-codex-active-bridge.sh"

run_local_or_remote_script() {
  local local_script="$1"
  local remote_script="$2"
  shift 2

  if [[ -f "$local_script" ]]; then
    bash "$local_script" "$@"
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required when script is downloaded via process substitution" >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$remote_script" -o "$tmp"; then
    rm -f "$tmp"
    echo "Failed to download script: $remote_script" >&2
    exit 1
  fi
  chmod +x "$tmp"
  bash "$tmp" "$@"
  rm -f "$tmp"
}

REMOTE_ARGS=("$TARGET_URL")
if [[ -n "$TOKEN" ]]; then
  REMOTE_ARGS+=(--token "$TOKEN")
fi
if [[ -n "$TIMEOUT_MS" ]]; then
  REMOTE_ARGS+=(--timeout-ms "$TIMEOUT_MS")
fi
if [[ "$REPLACE_TARGETS" == "true" ]]; then
  REMOTE_ARGS+=(--replace-targets)
fi
if [[ "$FORCE_INSTALL_HOOK" == "true" ]]; then
  REMOTE_ARGS+=(--force-install-hook)
fi
if [[ -n "$HOOK_URL" ]]; then
  REMOTE_ARGS+=(--hook-url "$HOOK_URL")
fi

BRIDGE_ARGS=(--target "$TARGET_URL")
if [[ -n "$TOKEN" ]]; then
  BRIDGE_ARGS+=(--token "$TOKEN")
fi
if [[ -n "$SOURCE_NAME" ]]; then
  BRIDGE_ARGS+=(--source "$SOURCE_NAME")
fi
if [[ -n "$BRIDGE_URL" ]]; then
  BRIDGE_ARGS+=(--bridge-url "$BRIDGE_URL")
fi

run_local_or_remote_script "$REMOTE_SCRIPT_LOCAL" "$REMOTE_SCRIPT_URL" "${REMOTE_ARGS[@]}"
run_local_or_remote_script "$BRIDGE_SCRIPT_LOCAL" "$BRIDGE_SCRIPT_URL" "${BRIDGE_ARGS[@]}"

echo "All done: remote event hook + active bridge are configured."
