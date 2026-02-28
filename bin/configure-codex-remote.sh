#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  configure-codex-remote.sh <confirmo_target_url> [options]

Examples:
  configure-codex-remote.sh https://h1-confirmo.ngrok.app --token abc123
  configure-codex-remote.sh https://h1-confirmo.ngrok.app --replace-targets --force-install-hook

Options:
  --token <token>              Update default remote token
  --timeout-ms <ms>            Update request timeout
  --replace-targets            Replace targets instead of append
  --hook-url <url>             Hook source URL (default: GitHub Pages)
  --force-install-hook         Always reinstall hook file
  -h, --help                   Show help

Behavior:
  - Writes ~/.confirmo/hooks/codex-remote.json
  - Installs ~/.confirmo/hooks/confirmo-codex-hook.js when missing
  - Patches ~/.codex/config.toml notify to use this hook automatically
  - Appends target by default (deduplicated)
  - If --replace-targets is set, replaces all existing targets with this single target
  - If URL has no path, '/v1/codex/event' is appended automatically
EOF
}

TARGET_URL=""

TOKEN="${CONFIRMO_REMOTE_TOKEN:-}"
TIMEOUT_MS="${CONFIRMO_REMOTE_TIMEOUT_MS:-}"
HAS_TIMEOUT_OVERRIDE="false"
REPLACE_TARGETS="false"
FORCE_INSTALL_HOOK="false"
HOOK_URL="${CONFIRMO_CODEX_HOOK_URL:-https://him188.github.io/confirmo-remote/hooks/confirmo-codex-hook.js}"

if [[ -n "$TIMEOUT_MS" ]]; then
  HAS_TIMEOUT_OVERRIDE="true"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      TIMEOUT_MS="${2:-}"
      HAS_TIMEOUT_OVERRIDE="true"
      shift 2
      ;;
    --replace-targets)
      REPLACE_TARGETS="true"
      shift
      ;;
    --hook-url)
      HOOK_URL="${2:-}"
      shift 2
      ;;
    --force-install-hook)
      FORCE_INSTALL_HOOK="true"
      shift
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

if [[ "$HAS_TIMEOUT_OVERRIDE" == "true" ]] && { ! [[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_MS" -le 0 ]]; }; then
  echo "--timeout-ms must be a positive integer" >&2
  exit 1
fi

if [[ "$TARGET_URL" == -* ]]; then
  echo "Invalid confirmo_target_url: $TARGET_URL" >&2
  exit 1
fi

if [[ "$TARGET_URL" != http://* && "$TARGET_URL" != https://* ]]; then
  TARGET_URL="https://${TARGET_URL}"
fi

if [[ "$TARGET_URL" =~ ^https?://[^/]+/?$ ]]; then
  TARGET_URL="${TARGET_URL}/v1/codex/event"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required but was not found in PATH" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but was not found in PATH" >&2
  exit 1
fi

NODE_BIN="$(command -v node)"
CONF_HOOK_DIR="${HOME}/.confirmo/hooks"
HOOK_FILE="${CONF_HOOK_DIR}/confirmo-codex-hook.js"
CONF_FILE="${CONF_HOOK_DIR}/codex-remote.json"
CODEX_DIR="${HOME}/.codex"
CODEX_CONFIG="${CODEX_DIR}/config.toml"

mkdir -p "$CONF_HOOK_DIR" "$CODEX_DIR"

write_embedded_hook() {
  cat > "$HOOK_FILE" <<'EMBEDDED_HOOK'
#!/usr/bin/env node
// Confirmo Codex Status Hook
// This script is called by Codex notify hook when agent-turn-complete event occurs

const fs = require('fs')
const path = require('path')
const os = require('os')
const http = require('http')
const https = require('https')

const { spawnSync } = require('child_process')

const STATUS_DIR = path.join(os.homedir(), '.confirmo', 'codex-status')
const STATUS_FILE = path.join(STATUS_DIR, 'status.json')
const SESSIONS_DIR = path.join(STATUS_DIR, 'sessions')
const ORIGINAL_NOTIFY_FILE = path.join(os.homedir(), '.confirmo', 'hooks', 'codex-original-notify.json')
const REMOTE_CONFIG_FILE = path.join(os.homedir(), '.confirmo', 'hooks', 'codex-remote.json')
const DEFAULT_REMOTE_TIMEOUT_MS = 1500

// Ensure directories exist
function ensureDirs() {
  if (!fs.existsSync(STATUS_DIR)) {
    fs.mkdirSync(STATUS_DIR, { recursive: true })
  }
  if (!fs.existsSync(SESSIONS_DIR)) {
    fs.mkdirSync(SESSIONS_DIR, { recursive: true })
  }
}

// Atomic write using temp file + rename
function writeStatusAtomic(filePath, data) {
  const tempPath = filePath + '.tmp.' + process.pid
  try {
    fs.writeFileSync(tempPath, JSON.stringify(data, null, 2))
    fs.renameSync(tempPath, filePath)
  } catch (e) {
    // Clean up temp file on failure
    try {
      fs.unlinkSync(tempPath)
    } catch (_) {}
    throw e
  }
}

// Read current status or create empty
function readStatus() {
  try {
    if (fs.existsSync(STATUS_FILE)) {
      return JSON.parse(fs.readFileSync(STATUS_FILE, 'utf-8'))
    }
  } catch (e) {
    // Ignore parse errors
  }
  return { version: 1, lastUpdated: Date.now(), sessions: {} }
}

// Update session status
function updateSession(sessionId, updates) {
  ensureDirs()

  // Update per-session file
  const sessionFile = path.join(SESSIONS_DIR, sessionId.replace(/[/\\:]/g, '_') + '.json')
  let session = { sessionId, startedAt: Date.now() }
  try {
    if (fs.existsSync(sessionFile)) {
      session = JSON.parse(fs.readFileSync(sessionFile, 'utf-8'))
    }
  } catch (e) {
    // Ignore parse errors
  }

  Object.assign(session, updates, { lastUpdated: Date.now() })
  writeStatusAtomic(sessionFile, session)

  // Update main status file
  const status = readStatus()
  status.sessions[sessionId] = session
  status.lastUpdated = Date.now()

  // Clean up old sessions (older than 24h)
  const cutoff = Date.now() - 24 * 60 * 60 * 1000
  for (const [id, sess] of Object.entries(status.sessions)) {
    if (sess.endedAt && sess.endedAt < cutoff) {
      delete status.sessions[id]
      try {
        fs.unlinkSync(path.join(SESSIONS_DIR, id.replace(/[/\\:]/g, '_') + '.json'))
      } catch (e) {
        // Ignore
      }
    }
  }

  writeStatusAtomic(STATUS_FILE, status)
}

// Extract session title from input messages
function extractSessionTitle(inputMessages) {
  if (!inputMessages || !Array.isArray(inputMessages)) return undefined

  // Find the first user message
  for (const msg of inputMessages) {
    if (msg.role === 'user' && msg.content) {
      // Handle string content
      if (typeof msg.content === 'string') {
        return msg.content.slice(0, 100).split('\n')[0].trim()
      }
      // Handle array content
      if (Array.isArray(msg.content)) {
        for (const part of msg.content) {
          if (part.type === 'text' && part.text) {
            return part.text.slice(0, 100).split('\n')[0].trim()
          }
          if (part.type === 'input_text' && part.text) {
            return part.text.slice(0, 100).split('\n')[0].trim()
          }
        }
      }
    }
  }
  return undefined
}

// Forward notification to user's original notify command if configured
function forwardToOriginalNotify(jsonArg) {
  try {
    if (!fs.existsSync(ORIGINAL_NOTIFY_FILE)) return

    const saved = JSON.parse(fs.readFileSync(ORIGINAL_NOTIFY_FILE, 'utf-8'))
    if (!saved || !Array.isArray(saved.notify) || saved.notify.length === 0) return

    const [command, ...args] = saved.notify
    // Append the JSON arg that Codex passed to us
    spawnSync(command, [...args, jsonArg], {
      stdio: 'ignore',
      timeout: 30000
    })
  } catch (e) {
    // Silently ignore errors from user's original notify
    // so Confirmo's hook always completes successfully
  }
}

function parseInteger(value, fallback) {
  const parsed = Number.parseInt(String(value), 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}

function normalizeRemoteTarget(target, defaultToken) {
  let url = ''
  let token = defaultToken

  if (typeof target === 'string') {
    url = target.trim()
  } else if (target && typeof target === 'object') {
    url = typeof target.url === 'string' ? target.url.trim() : ''
    if (typeof target.token === 'string') {
      token = target.token
    }
  }

  if (!url) return null

  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return null
    }
  } catch (_) {
    return null
  }

  return { url, token: token || '' }
}

function parseRemoteTargetList(value, defaultToken) {
  if (!value) return []
  return String(value)
    .split(/[\n,]/)
    .map((item) => normalizeRemoteTarget(item, defaultToken))
    .filter(Boolean)
}

function loadRemoteConfig() {
  try {
    if (!fs.existsSync(REMOTE_CONFIG_FILE)) return {}
    return JSON.parse(fs.readFileSync(REMOTE_CONFIG_FILE, 'utf-8'))
  } catch (_) {
    return {}
  }
}

function resolveRemoteSettings() {
  const fileConfig = loadRemoteConfig()
  const envToken = process.env.CONFIRMO_REMOTE_TOKEN
  const defaultToken = typeof envToken === 'string'
    ? envToken
    : (typeof fileConfig.token === 'string' ? fileConfig.token : '')

  const targets = []

  if (Array.isArray(fileConfig.targets)) {
    for (const target of fileConfig.targets) {
      const normalized = normalizeRemoteTarget(target, defaultToken)
      if (normalized) targets.push(normalized)
    }
  }

  const envSingle = process.env.CONFIRMO_REMOTE_URL
  if (envSingle) {
    const normalized = normalizeRemoteTarget(envSingle, defaultToken)
    if (normalized) targets.push(normalized)
  }

  const envTargets = parseRemoteTargetList(process.env.CONFIRMO_REMOTE_TARGETS, defaultToken)
  if (envTargets.length > 0) {
    targets.push(...envTargets)
  }

  const dedupedTargets = []
  const seen = new Set()
  for (const target of targets) {
    const key = `${target.url}\n${target.token}`
    if (seen.has(key)) continue
    seen.add(key)
    dedupedTargets.push(target)
  }

  const timeoutMs = parseInteger(
    process.env.CONFIRMO_REMOTE_TIMEOUT_MS || fileConfig.timeoutMs,
    DEFAULT_REMOTE_TIMEOUT_MS
  )

  return {
    targets: dedupedTargets,
    timeoutMs
  }
}

async function postRemoteStatus(target, jsonArg, timeoutMs) {
  const headers = { 'content-type': 'application/json' }
  if (target.token) {
    headers.authorization = `Bearer ${target.token}`
  }

  // Prefer fetch when available (Node 18+), fallback to http(s).request for older Node.
  if (typeof fetch === 'function') {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)

    try {
      await fetch(target.url, {
        method: 'POST',
        headers,
        body: jsonArg,
        signal: controller.signal
      })
    } catch (_) {
      // Ignore remote errors
    } finally {
      clearTimeout(timer)
    }
    return
  }

  await postRemoteStatusLegacy(target.url, headers, jsonArg, timeoutMs)
}

function postRemoteStatusLegacy(url, headers, body, timeoutMs) {
  return new Promise((resolve) => {
    let parsed
    try {
      parsed = new URL(url)
    } catch (_) {
      resolve()
      return
    }

    const client = parsed.protocol === 'https:'
      ? https
      : (parsed.protocol === 'http:' ? http : null)

    if (!client) {
      resolve()
      return
    }

    const req = client.request(
      parsed,
      {
        method: 'POST',
        headers,
        timeout: timeoutMs
      },
      (res) => {
        res.on('data', () => {}) // Drain response to avoid socket hangups.
        res.on('end', resolve)
      }
    )

    req.on('timeout', () => req.destroy(new Error('timeout')))
    req.on('error', () => resolve())
    req.write(body)
    req.end()
  })
}

async function fanoutRemoteStatus(jsonArg) {
  const { targets, timeoutMs } = resolveRemoteSettings()
  if (!targets || targets.length === 0) return

  await Promise.allSettled(targets.map((target) => postRemoteStatus(target, jsonArg, timeoutMs)))
}

// Main
async function main() {
  // Codex notify hook passes JSON as first command-line argument
  const jsonArg = process.argv[2]

  if (!jsonArg) {
    // Still forward even if no JSON arg (original hook may handle differently)
    forwardToOriginalNotify('')
    return
  }

  // Always forward to user's original notify command first
  forwardToOriginalNotify(jsonArg)

  let data
  try {
    data = JSON.parse(jsonArg)
  } catch (e) {
    // Invalid JSON input, exit silently
    return
  }

  const {
    type,
    'thread-id': threadId,
    'turn-id': turnId,
    cwd,
    'input-messages': inputMessages,
    'last-assistant-message': lastAssistantMessage
  } = data

  // Codex only sends agent-turn-complete events via notify
  if (type !== 'agent-turn-complete') {
    return
  }

  const sessionId = threadId || 'unknown'
  const now = Date.now()

  // Extract session title from first user message
  const title = extractSessionTitle(inputMessages)

  // Extract preview from last assistant message
  let details = ''
  if (lastAssistantMessage) {
    details = typeof lastAssistantMessage === 'string'
      ? lastAssistantMessage.slice(0, 100)
      : ''
  }

  updateSession(sessionId, {
    status: 'completed',
    workingDirectory: cwd,
    sessionTitle: title,
    lastEvent: {
      type: 'turn_complete',
      timestamp: now,
      details: details,
      turnId: turnId
    }
  })

  await fanoutRemoteStatus(jsonArg)
}

main().catch(() => process.exit(0)) // Silent failures
EMBEDDED_HOOK
  chmod +x "$HOOK_FILE"
}

install_hook_file() {
  local script_dir=""
  local local_hook=""
  local tmp_file=""

  if [[ "$FORCE_INSTALL_HOOK" != "true" ]] && [[ -s "$HOOK_FILE" ]]; then
    echo "hook: existing file found at $HOOK_FILE"
    return 0
  fi

  # If running from a checked out repository, prefer local hook file.
  if script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"; then
    local_hook="${script_dir}/../hooks/confirmo-codex-hook.js"
    if [[ -s "$local_hook" ]]; then
      cp "$local_hook" "$HOOK_FILE"
      chmod +x "$HOOK_FILE"
      echo "hook: installed from local path $local_hook"
      return 0
    fi
  fi

  if [[ "$HOOK_URL" == http://* || "$HOOK_URL" == https://* ]]; then
    tmp_file="$(mktemp)"
    if curl -fsSL "$HOOK_URL" -o "$tmp_file" && grep -q 'Confirmo Codex Status Hook' "$tmp_file"; then
      mv "$tmp_file" "$HOOK_FILE"
      chmod +x "$HOOK_FILE"
      echo "hook: installed from $HOOK_URL"
      return 0
    fi
    rm -f "$tmp_file"
    echo "hook: download failed from $HOOK_URL, falling back to embedded hook"
  else
    echo "hook: invalid --hook-url ($HOOK_URL), falling back to embedded hook"
  fi

  write_embedded_hook
  echo "hook: installed from embedded fallback"
}

patch_codex_notify() {
  CODEX_CONFIG="$CODEX_CONFIG" NODE_BIN="$NODE_BIN" HOOK_FILE="$HOOK_FILE" node <<'NOTIFY_NODE'
const fs = require('fs')

const configPath = process.env.CODEX_CONFIG
const nodeBin = process.env.NODE_BIN
const hookFile = process.env.HOOK_FILE

function escapeTomlString(input) {
  return String(input).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}

const notifyBlock = [
  'notify = [',
  '  "' + escapeTomlString(nodeBin) + '",',
  '  "' + escapeTomlString(hookFile) + '"',
  ']'
]

let content = ''
if (fs.existsSync(configPath)) {
  content = fs.readFileSync(configPath, 'utf8')
}

if (!content.trim()) {
  fs.writeFileSync(configPath, notifyBlock.join('\n') + '\n')
  process.stdout.write('notify: created in ' + configPath + '\n')
  process.exit(0)
}

const lines = content.split(/\r?\n/)
const out = []
let replaced = false

for (let i = 0; i < lines.length; i++) {
  const line = lines[i]

  if (!replaced && /^\s*notify\s*=/.test(line)) {
    replaced = true
    out.push(...notifyBlock)

    if (line.includes('[') && !line.includes(']')) {
      while (i + 1 < lines.length) {
        i += 1
        if (lines[i].includes(']')) break
      }
    }
    continue
  }

  out.push(line)
}

if (replaced) {
  let next = out.join('\n')
  if (!next.endsWith('\n')) next += '\n'
  fs.writeFileSync(configPath, next)
  process.stdout.write('notify: updated in ' + configPath + '\n')
  process.exit(0)
}

let next = notifyBlock.join('\n') + '\n\n' + content
if (!next.endsWith('\n')) next += '\n'
fs.writeFileSync(configPath, next)
process.stdout.write('notify: inserted in ' + configPath + '\n')
NOTIFY_NODE
}

install_hook_file
patch_codex_notify

TARGET_URL="$TARGET_URL" \
TOKEN="$TOKEN" \
TIMEOUT_MS="$TIMEOUT_MS" \
HAS_TIMEOUT_OVERRIDE="$HAS_TIMEOUT_OVERRIDE" \
REPLACE_TARGETS="$REPLACE_TARGETS" \
CONF_FILE="$CONF_FILE" \
node <<'CONFIG_NODE'
const fs = require('fs')

const confFile = process.env.CONF_FILE
const targetUrl = process.env.TARGET_URL
const token = process.env.TOKEN || ''
const timeoutMsRaw = process.env.TIMEOUT_MS || ''
const hasTimeoutOverride = process.env.HAS_TIMEOUT_OVERRIDE === 'true'
const replaceTargets = process.env.REPLACE_TARGETS === 'true'

if (!/^https?:\/\//.test(targetUrl)) {
  process.stderr.write('Invalid target URL: ' + targetUrl + '\n')
  process.exit(1)
}

let parsed
try {
  parsed = new URL(targetUrl)
} catch (_) {
  process.stderr.write('Invalid target URL: ' + targetUrl + '\n')
  process.exit(1)
}

if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
  process.stderr.write('Invalid target URL protocol: ' + parsed.protocol + '\n')
  process.exit(1)
}

let config = {}
if (fs.existsSync(confFile)) {
  try {
    config = JSON.parse(fs.readFileSync(confFile, 'utf8'))
  } catch (e) {
    process.stderr.write('Failed to parse existing config: ' + confFile + '\n')
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

if (hasTimeoutOverride) {
  config.timeoutMs = Number(timeoutMsRaw)
} else if (!Number.isFinite(Number(config.timeoutMs)) || Number(config.timeoutMs) <= 0) {
  config.timeoutMs = 1800
}

const out = JSON.stringify(config, null, 2) + '\n'
fs.writeFileSync(confFile, out)
CONFIG_NODE

echo "remote: configured Codex targets"
echo "  config: $CONF_FILE"
echo "  target: $TARGET_URL"
if [[ -n "$TOKEN" ]]; then
  echo "  token:  [updated]"
else
  echo "  token:  [unchanged]"
fi
if [[ "$HAS_TIMEOUT_OVERRIDE" == "true" ]]; then
  echo "  timeoutMs: $TIMEOUT_MS"
else
  echo "  timeoutMs: [unchanged]"
fi
