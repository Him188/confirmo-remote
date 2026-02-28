const crypto = require('crypto')
const http = require('http')
const os = require('os')
const path = require('path')

const { applyCodexEvent } = require('./codex-event')
const { StatusStore } = require('./status-store')

const DEFAULT_HOST = '127.0.0.1'
const DEFAULT_PORT = 17890
const DEFAULT_PATH = '/v1/codex/event'
const DEFAULT_STATUS_DIR = path.join(os.homedir(), '.confirmo', 'codex-status')
const DEFAULT_BODY_LIMIT = 256 * 1024

function parseArgs(argv) {
  const args = {
    command: 'serve',
    host: DEFAULT_HOST,
    port: DEFAULT_PORT,
    path: DEFAULT_PATH,
    token: process.env.CONFIRMO_REMOTE_TOKEN || '',
    statusDir: process.env.CONFIRMO_REMOTE_STATUS_DIR || DEFAULT_STATUS_DIR,
    retentionHours: Number(process.env.CONFIRMO_REMOTE_RETENTION_HOURS || 24),
    bodyLimitBytes: Number(process.env.CONFIRMO_REMOTE_MAX_BODY_BYTES || DEFAULT_BODY_LIMIT)
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
      case '--listen':
        applyListen(args, value)
        i += 2
        break
      case '--host':
        args.host = value || args.host
        i += 2
        break
      case '--port':
        args.port = Number(value || args.port)
        i += 2
        break
      case '--path':
        args.path = normalizePath(value || args.path)
        i += 2
        break
      case '--token':
        args.token = value || ''
        i += 2
        break
      case '--status-dir':
        args.statusDir = value || args.statusDir
        i += 2
        break
      case '--retention-hours':
        args.retentionHours = Number(value || args.retentionHours)
        i += 2
        break
      case '--max-body-bytes':
        args.bodyLimitBytes = Number(value || args.bodyLimitBytes)
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

function applyListen(args, listen) {
  if (!listen) return

  const idx = listen.lastIndexOf(':')
  if (idx > 0) {
    args.host = listen.slice(0, idx)
    args.port = Number(listen.slice(idx + 1))
    return
  }

  args.port = Number(listen)
}

function normalizePath(inputPath) {
  if (!inputPath) return DEFAULT_PATH
  return inputPath.startsWith('/') ? inputPath : `/${inputPath}`
}

function secureTokenEqual(expected, actual) {
  const exp = Buffer.from(expected)
  const got = Buffer.from(actual || '')
  return exp.length === got.length && crypto.timingSafeEqual(exp, got)
}

function parseBearerToken(req) {
  const auth = String(req.headers.authorization || '')
  const prefix = 'Bearer '
  if (!auth.startsWith(prefix)) return ''
  return auth.slice(prefix.length).trim()
}

function readJsonBody(req, limitBytes) {
  return new Promise((resolve, reject) => {
    let total = 0
    let body = ''

    req.setEncoding('utf8')
    req.on('data', (chunk) => {
      total += Buffer.byteLength(chunk)
      if (total > limitBytes) {
        reject(Object.assign(new Error('payload_too_large'), { code: 413 }))
        req.destroy()
        return
      }
      body += chunk
    })

    req.on('end', () => {
      if (!body.trim()) {
        reject(Object.assign(new Error('empty_body'), { code: 400 }))
        return
      }

      try {
        resolve(JSON.parse(body))
      } catch (_) {
        reject(Object.assign(new Error('invalid_json'), { code: 400 }))
      }
    })

    req.on('error', reject)
  })
}

function writeJson(res, statusCode, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body)
  })
  res.end(body)
}

function usage() {
  return [
    'confirmo-remote serve [options]',
    '',
    'Options:',
    '  --listen <host:port>      Listen address. Default: 127.0.0.1:17890',
    '  --path <path>             Endpoint path. Default: /v1/codex/event',
    '  --token <token>           Bearer token for authentication (required)',
    '  --status-dir <dir>        Status directory. Default: ~/.confirmo/codex-status',
    '  --retention-hours <n>     Ended session retention hours. Default: 24',
    '  --max-body-bytes <n>      Max request body size. Default: 262144',
    '',
    'Environment variables:',
    '  CONFIRMO_REMOTE_TOKEN',
    '  CONFIRMO_REMOTE_STATUS_DIR',
    '  CONFIRMO_REMOTE_RETENTION_HOURS',
    '  CONFIRMO_REMOTE_MAX_BODY_BYTES'
  ].join('\n')
}

function validateArgs(args) {
  if (args.command === 'help') return
  if (args.command !== 'serve') {
    throw new Error(`unsupported command: ${args.command}`)
  }
  if (!args.token) {
    throw new Error('missing token: pass --token or CONFIRMO_REMOTE_TOKEN')
  }
  if (!Number.isInteger(args.port) || args.port <= 0 || args.port > 65535) {
    throw new Error(`invalid port: ${args.port}`)
  }
  if (!Number.isFinite(args.retentionHours) || args.retentionHours <= 0) {
    throw new Error(`invalid retention hours: ${args.retentionHours}`)
  }
  if (!Number.isFinite(args.bodyLimitBytes) || args.bodyLimitBytes <= 0) {
    throw new Error(`invalid max body bytes: ${args.bodyLimitBytes}`)
  }
}

function createServer(options) {
  const store = new StatusStore({
    statusRoot: options.statusDir,
    retentionMs: Math.round(options.retentionHours * 60 * 60 * 1000)
  })

  return http.createServer(async (req, res) => {
    try {
      const requestUrl = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`)
      if (req.method === 'GET' && requestUrl.pathname === '/healthz') {
        writeJson(res, 200, { ok: true })
        return
      }

      if (req.method !== 'POST' || requestUrl.pathname !== options.path) {
        writeJson(res, 404, { ok: false, error: 'not_found' })
        return
      }

      const actualToken = parseBearerToken(req)
      if (!secureTokenEqual(options.token, actualToken)) {
        writeJson(res, 401, { ok: false, error: 'unauthorized' })
        return
      }

      const payload = await readJsonBody(req, options.bodyLimitBytes)
      const result = applyCodexEvent(payload, store)

      writeJson(res, 202, {
        ok: true,
        applied: result.applied,
        reason: result.reason,
        sessionId: result.sessionId || null
      })
    } catch (err) {
      const status = typeof err.code === 'number' ? err.code : 500
      const code = status === 500 ? 'internal_error' : err.message
      writeJson(res, status, { ok: false, error: code })
    }
  })
}

async function main() {
  const args = parseArgs(process.argv)
  validateArgs(args)

  if (args.command === 'help') {
    process.stdout.write(`${usage()}\n`)
    return
  }

  const server = createServer(args)
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(args.port, args.host, resolve)
  })

  process.stdout.write(
    `confirmo-remote listening on http://${args.host}:${args.port}${args.path}\n` +
      `status dir: ${args.statusDir}\n` +
      'healthz: /healthz\n'
  )
}

module.exports = {
  main,
  createServer
}
