const fs = require('fs')
const os = require('os')
const path = require('path')

class StatusStore {
  constructor(options = {}) {
    this.statusRoot = options.statusRoot || path.join(os.homedir(), '.confirmo', 'codex-status')
    this.statusFile = path.join(this.statusRoot, 'status.json')
    this.sessionsDir = path.join(this.statusRoot, 'sessions')
    this.retentionMs = options.retentionMs || 24 * 60 * 60 * 1000
  }

  ensureDirs() {
    if (!fs.existsSync(this.statusRoot)) {
      fs.mkdirSync(this.statusRoot, { recursive: true })
    }
    if (!fs.existsSync(this.sessionsDir)) {
      fs.mkdirSync(this.sessionsDir, { recursive: true })
    }
  }

  writeJsonAtomic(filePath, data) {
    const tempPath = `${filePath}.tmp.${process.pid}`
    try {
      fs.writeFileSync(tempPath, JSON.stringify(data, null, 2))
      fs.renameSync(tempPath, filePath)
    } catch (e) {
      try {
        fs.unlinkSync(tempPath)
      } catch (_) {}
      throw e
    }
  }

  readMainStatus() {
    try {
      if (fs.existsSync(this.statusFile)) {
        return JSON.parse(fs.readFileSync(this.statusFile, 'utf-8'))
      }
    } catch (_) {}
    return { version: 1, lastUpdated: Date.now(), sessions: {} }
  }

  getSessionFile(sessionId) {
    const safeId = String(sessionId || 'unknown').replace(/[/\\:]/g, '_')
    return path.join(this.sessionsDir, `${safeId}.json`)
  }

  updateSession(sessionId, updates) {
    this.ensureDirs()

    const now = Date.now()
    const sessionFile = this.getSessionFile(sessionId)
    let session = { sessionId, startedAt: now }

    try {
      if (fs.existsSync(sessionFile)) {
        session = JSON.parse(fs.readFileSync(sessionFile, 'utf-8'))
      }
    } catch (_) {}

    Object.assign(session, updates, { lastUpdated: now })
    this.writeJsonAtomic(sessionFile, session)

    const status = this.readMainStatus()
    status.sessions[sessionId] = session
    status.lastUpdated = now

    this.cleanupEndedSessions(status)
    this.writeJsonAtomic(this.statusFile, status)
  }

  cleanupEndedSessions(status) {
    const cutoff = Date.now() - this.retentionMs
    for (const [id, session] of Object.entries(status.sessions)) {
      if (session && session.endedAt && session.endedAt < cutoff) {
        delete status.sessions[id]
        try {
          fs.unlinkSync(this.getSessionFile(id))
        } catch (_) {}
      }
    }
  }
}

module.exports = {
  StatusStore
}
