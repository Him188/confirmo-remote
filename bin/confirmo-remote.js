#!/usr/bin/env node

const { main } = require('../src/server')

main().catch((err) => {
  const message = err && err.message ? err.message : String(err)
  process.stderr.write(`confirmo-remote error: ${message}\n`)
  process.exit(1)
})
