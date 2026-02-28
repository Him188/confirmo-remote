const fs = require('fs')
const os = require('os')
const path = require('path')

const { postJson } = require('./http-client')

const DEFAULT_SESSIONS_ROOT = path.join(os.homedir(), '.codex', 'sessions')
const DEFAULT_POLL_MS = 700
const DEFAULT_SEND_TIMEOUT_MS = 1800
const DEFAULT_INITIAL_BACKFILL_BYTES = 64 * 1024
const DEFAULT_STREAM_PATH = '/v1/codex/stream'

function parseArgs(argv) {
  const args = {
    target: process.env.CONFIRMO_REMOTE_STREAM_URL || '',
    token: process.env.CONFIRMO_REMOTE_TOKEN || '',
    sessionsRoot: process.env.CONFIRMO_CODEX_SESSIONS_ROOT || DEFAULT_SESSIONS_ROOT,
    source: process.env.CONFIRMO_SOURCE || os.hostname(),
    pollMs: Number(process.env.CONFIRMO_BRIDGE_POLL_MS || DEFAULT_POLL_MS),
    timeoutMs: Number(process.env.CONFIRMO_BRIDGE_TIMEOUT_MS || DEFAULT_SEND_TIMEOUT_MS),
    initialBackfillBytes: Number(process.env.CONFIRMO_BRIDGE_INITIAL_BACKFILL_BYTES || DEFAULT_INITIAL_BACKFILL_BYTES),
    command: 'run'
  }

  const [, , ...rest] = argv
  let i = 0
  if (rest[0] && !rest[0].startsWith('-')) {
    args.command = rest[0]
    i = 1
  }

  while (i < rest.length) {
    const key = rest[i]
    const value = rest[i + 1]
    switch (key) {
      case '--target':
        args.target = String(value || '')
        i += 2
        break
      case '--token':
        args.token = String(value || '')
        i += 2
        break
      case '--sessions-root':
        args.sessionsRoot = String(value || args.sessionsRoot)
        i += 2
        break
      case '--source':
        args.source = String(value || args.source)
        i += 2
        break
      case '--poll-ms':
        args.pollMs = Number(value || args.pollMs)
        i += 2
        break
      case '--timeout-ms':
        args.timeoutMs = Number(value || args.timeoutMs)
        i += 2
        break
      case '--initial-backfill-bytes':
        args.initialBackfillBytes = Number(value || args.initialBackfillBytes)
        i += 2
        break
      case '-h':
      case '--help':
        args.command = 'help'
        i += 1
        break
      default:
        throw new Error(`unknown option: ${key}`)
    }
  }

  return args
}

function usage() {
  return [
    'confirmo-codex-activity-bridge [run] [options]',
    '',
    'Options:',
    '  --target <url>            Target stream endpoint, e.g. https://host/v1/codex/stream',
    '  --token <token>           Bearer token',
    '  --sessions-root <dir>     Codex sessions root. Default: ~/.codex/sessions',
    '  --source <name>           Source label. Default: hostname',
    '  --poll-ms <ms>            Poll interval. Default: 700',
    '  --timeout-ms <ms>         HTTP timeout. Default: 1800',
    '  --initial-backfill-bytes  Read this many tail bytes on first seen file. Default: 65536',
    '',
    'Environment:',
    '  CONFIRMO_REMOTE_STREAM_URL',
    '  CONFIRMO_REMOTE_TOKEN',
    '  CONFIRMO_CODEX_SESSIONS_ROOT',
    '  CONFIRMO_SOURCE',
    '  CONFIRMO_BRIDGE_POLL_MS',
    '  CONFIRMO_BRIDGE_TIMEOUT_MS',
    '  CONFIRMO_BRIDGE_INITIAL_BACKFILL_BYTES'
  ].join('\n')
}

function normalizeTarget(url) {
  if (!url) return ''
  let value = String(url).trim()
  if (value.endsWith('/v1/codex/event')) {
    value = value.slice(0, -'/v1/codex/event'.length) + DEFAULT_STREAM_PATH
  } else if (/^https?:\/\/[^/]+\/?$/.test(value)) {
    value = value.replace(/\/?$/, DEFAULT_STREAM_PATH)
  }
  return value
}

function validateArgs(args) {
  if (args.command === 'help') return
  if (args.command !== 'run') {
    throw new Error(`unsupported command: ${args.command}`)
  }
  args.target = normalizeTarget(args.target)

  if (!args.target) throw new Error('missing --target or CONFIRMO_REMOTE_STREAM_URL')
  try {
    const parsed = new URL(args.target)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new Error('invalid target protocol')
    }
  } catch (error) {
    throw new Error(`invalid target url: ${args.target}`)
  }
  if (!args.token) throw new Error('missing --token or CONFIRMO_REMOTE_TOKEN')
  if (!Number.isFinite(args.pollMs) || args.pollMs < 200) throw new Error(`invalid --poll-ms: ${args.pollMs}`)
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs <= 0) throw new Error(`invalid --timeout-ms: ${args.timeoutMs}`)
  if (!Number.isFinite(args.initialBackfillBytes) || args.initialBackfillBytes < 0) {
    throw new Error(`invalid --initial-backfill-bytes: ${args.initialBackfillBytes}`)
  }
}

function getTodayDir(sessionsRoot, now = new Date()) {
  const year = String(now.getFullYear())
  const month = String(now.getMonth() + 1).padStart(2, '0')
  const day = String(now.getDate()).padStart(2, '0')
  return path.join(sessionsRoot, year, month, day)
}

function selectLatestJsonl(todayDir) {
  if (!fs.existsSync(todayDir)) return null
  const files = fs.readdirSync(todayDir).filter((name) => name.endsWith('.jsonl'))
  if (files.length === 0) return null

  let latestFile = null
  let latestMtime = 0
  for (const name of files) {
    const full = path.join(todayDir, name)
    try {
      const stat = fs.statSync(full)
      if (stat.mtimeMs > latestMtime) {
        latestMtime = stat.mtimeMs
        latestFile = full
      }
    } catch (_) {}
  }
  return latestFile
}

function parseJsonLines(raw) {
  const entries = []
  const lines = raw.split('\n')
  for (const line of lines) {
    const text = line.trim()
    if (!text) continue
    try {
      entries.push(JSON.parse(text))
    } catch (_) {}
  }
  return entries
}

function isForwardableEntry(entry) {
  if (!entry || typeof entry !== 'object') return false
  if (typeof entry.type !== 'string' || !entry.type) return false
  if (typeof entry.timestamp !== 'string' || !entry.timestamp) return false

  if (entry.type === 'session_meta' || entry.type === 'turn_context' || entry.type === 'compacted') return true

  if (entry.type === 'event_msg') {
    return entry.payload && entry.payload.type === 'user_message'
  }
  if (entry.type === 'response_item') {
    if (!entry.payload || typeof entry.payload.type !== 'string') return false
    if (entry.payload.type === 'function_call') return true
    if (entry.payload.type === 'function_call_output') return true
    if (entry.payload.type === 'message' && entry.payload.role === 'assistant') return true
  }

  return false
}

class CodexActivityBridge {
  constructor(options) {
    this.target = options.target
    this.token = options.token
    this.sessionsRoot = options.sessionsRoot
    this.source = options.source
    this.pollMs = options.pollMs
    this.timeoutMs = options.timeoutMs
    this.initialBackfillBytes = options.initialBackfillBytes

    this.currentFile = null
    this.currentOffset = 0
    this.offsetByFile = new Map()
    this.pending = []
    this.timer = null
    this.inFlight = false
  }

  async start() {
    process.stdout.write(
      `codex-activity-bridge started\n` +
      `target: ${this.target}\n` +
      `sessions: ${this.sessionsRoot}\n` +
      `source: ${this.source}\n`
    )

    await this.tick()
    this.timer = setInterval(() => {
      this.tick().catch(() => {})
    }, this.pollMs)
  }

  stop() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  async tick() {
    if (this.inFlight) return
    this.inFlight = true
    try {
      this.collectNewEntries()
      if (this.pending.length > 0) {
        await this.flushPending()
      }
    } finally {
      this.inFlight = false
    }
  }

  collectNewEntries() {
    const todayDir = getTodayDir(this.sessionsRoot)
    const latest = selectLatestJsonl(todayDir)
    if (!latest) return

    if (latest !== this.currentFile) {
      this.currentFile = latest
      if (this.offsetByFile.has(latest)) {
        this.currentOffset = this.offsetByFile.get(latest)
      } else {
        const size = this.getFileSize(latest)
        this.currentOffset = Math.max(0, size - this.initialBackfillBytes)
        this.offsetByFile.set(latest, this.currentOffset)
      }
    }

    const size = this.getFileSize(latest)
    if (size <= this.currentOffset) return

    const chunk = this.readRange(latest, this.currentOffset, size)
    this.currentOffset = size
    this.offsetByFile.set(latest, size)

    const parsed = parseJsonLines(chunk)
    for (const entry of parsed) {
      if (isForwardableEntry(entry)) {
        this.pending.push(entry)
      }
    }
  }

  getFileSize(file) {
    try {
      return fs.statSync(file).size
    } catch (_) {
      return 0
    }
  }

  readRange(file, start, end) {
    if (end <= start) return ''
    const fd = fs.openSync(file, 'r')
    try {
      const len = end - start
      const buf = Buffer.alloc(len)
      const read = fs.readSync(fd, buf, 0, len, start)
      return buf.slice(0, read).toString('utf8')
    } finally {
      fs.closeSync(fd)
    }
  }

  async flushPending() {
    const batch = this.pending.slice(0, 100)
    const response = await postJson(
      this.target,
      {
        source: this.source,
        entries: batch
      },
      {
        timeoutMs: this.timeoutMs,
        headers: { authorization: `Bearer ${this.token}` }
      }
    )

    if (!response.ok) return
    this.pending.splice(0, batch.length)
  }
}

async function main() {
  const args = parseArgs(process.argv)
  validateArgs(args)

  if (args.command === 'help') {
    process.stdout.write(`${usage()}\n`)
    return
  }

  const bridge = new CodexActivityBridge(args)

  process.on('SIGINT', () => {
    bridge.stop()
    process.exit(0)
  })
  process.on('SIGTERM', () => {
    bridge.stop()
    process.exit(0)
  })

  await bridge.start()
}

module.exports = {
  main,
  CodexActivityBridge,
  isForwardableEntry,
  normalizeTarget
}
