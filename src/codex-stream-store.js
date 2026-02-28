const fs = require('fs')
const os = require('os')
const path = require('path')

const DEFAULT_CODEX_SESSIONS_ROOT = path.join(os.homedir(), '.codex', 'sessions')

class CodexStreamStore {
  constructor(options = {}) {
    this.sessionsRoot = options.sessionsRoot || DEFAULT_CODEX_SESSIONS_ROOT
  }

  getTodayDir(now = new Date()) {
    const year = String(now.getFullYear())
    const month = String(now.getMonth() + 1).padStart(2, '0')
    const day = String(now.getDate()).padStart(2, '0')
    return path.join(this.sessionsRoot, year, month, day)
  }

  ensureTodayDir() {
    const todayDir = this.getTodayDir()
    if (!fs.existsSync(todayDir)) {
      fs.mkdirSync(todayDir, { recursive: true })
    }
    return todayDir
  }

  sanitizeSource(source) {
    const input = String(source || 'remote')
    const sanitized = input.replace(/[^a-zA-Z0-9._-]/g, '_').replace(/^_+|_+$/g, '')
    return sanitized || 'remote'
  }

  getStreamFile(source) {
    const todayDir = this.ensureTodayDir()
    const safeSource = this.sanitizeSource(source)
    return path.join(todayDir, `confirmo-remote-${safeSource}.jsonl`)
  }

  appendEntries(entries, source) {
    if (!Array.isArray(entries) || entries.length === 0) {
      return { written: 0, file: this.getStreamFile(source) }
    }

    const file = this.getStreamFile(source)
    const lines = entries.map((entry) => JSON.stringify(entry)).join('\n') + '\n'
    fs.appendFileSync(file, lines, 'utf8')
    return { written: entries.length, file }
  }
}

function isCodexStreamEntry(entry) {
  if (!entry || typeof entry !== 'object') return false
  if (typeof entry.timestamp !== 'string' || !entry.timestamp) return false
  if (typeof entry.type !== 'string' || !entry.type) return false

  if (entry.type === 'turn_context' || entry.type === 'session_meta' || entry.type === 'compacted') {
    return true
  }

  if (entry.type === 'event_msg') {
    return Boolean(entry.payload && typeof entry.payload.type === 'string')
  }

  if (entry.type === 'response_item') {
    return Boolean(entry.payload && typeof entry.payload.type === 'string')
  }

  return false
}

function normalizeStreamEntries(payload) {
  if (payload && typeof payload === 'object' && Array.isArray(payload.entries)) {
    return payload.entries
  }
  if (payload && typeof payload === 'object' && payload.entry && typeof payload.entry === 'object') {
    return [payload.entry]
  }
  if (isCodexStreamEntry(payload)) {
    return [payload]
  }
  return []
}

module.exports = {
  CodexStreamStore,
  DEFAULT_CODEX_SESSIONS_ROOT,
  isCodexStreamEntry,
  normalizeStreamEntries
}
