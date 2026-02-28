const http = require('http')
const https = require('https')

async function postJson(url, body, options = {}) {
  const timeoutMs = Number(options.timeoutMs || 2000)
  const headers = Object.assign({}, options.headers || {}, {
    'content-type': 'application/json'
  })

  const payload = JSON.stringify(body)

  if (typeof fetch === 'function') {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers,
        body: payload,
        signal: controller.signal
      })
      return { ok: response.ok, status: response.status }
    } catch (error) {
      return { ok: false, status: 0, error }
    } finally {
      clearTimeout(timer)
    }
  }

  return postJsonLegacy(url, payload, headers, timeoutMs)
}

function postJsonLegacy(url, payload, headers, timeoutMs) {
  return new Promise((resolve) => {
    let parsed
    try {
      parsed = new URL(url)
    } catch (error) {
      resolve({ ok: false, status: 0, error })
      return
    }

    const client = parsed.protocol === 'https:'
      ? https
      : (parsed.protocol === 'http:' ? http : null)

    if (!client) {
      resolve({ ok: false, status: 0, error: new Error('unsupported_protocol') })
      return
    }

    const request = client.request(
      parsed,
      {
        method: 'POST',
        headers,
        timeout: timeoutMs
      },
      (response) => {
        response.on('data', () => {}) // Drain body.
        response.on('end', () => {
          resolve({ ok: response.statusCode >= 200 && response.statusCode < 300, status: response.statusCode || 0 })
        })
      }
    )

    request.on('timeout', () => request.destroy(new Error('timeout')))
    request.on('error', (error) => resolve({ ok: false, status: 0, error }))
    request.write(payload)
    request.end()
  })
}

module.exports = {
  postJson
}
