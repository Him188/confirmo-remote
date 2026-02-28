#!/usr/bin/env node
// Confirmo Codex Activity Bridge

const { main } = require('../src/codex-activity-bridge')

main().catch((err) => {
  const message = err && err.message ? err.message : String(err)
  process.stderr.write(`codex-activity-bridge error: ${message}\n`)
  process.exit(1)
})
