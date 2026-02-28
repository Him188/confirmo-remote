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
