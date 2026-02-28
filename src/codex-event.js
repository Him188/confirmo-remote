function extractSessionTitle(inputMessages) {
  if (!Array.isArray(inputMessages)) return undefined

  for (const msg of inputMessages) {
    if (msg.role !== 'user' || !msg.content) continue

    if (typeof msg.content === 'string') {
      return msg.content.slice(0, 100).split('\n')[0].trim()
    }

    if (Array.isArray(msg.content)) {
      for (const part of msg.content) {
        if (!part || typeof part !== 'object') continue
        if ((part.type === 'text' || part.type === 'input_text') && part.text) {
          return String(part.text).slice(0, 100).split('\n')[0].trim()
        }
      }
    }
  }

  return undefined
}

function extractAssistantPreview(lastAssistantMessage) {
  if (typeof lastAssistantMessage !== 'string') return ''
  return lastAssistantMessage.slice(0, 100)
}

function applyCodexEvent(data, store) {
  if (!data || typeof data !== 'object') return { applied: false, reason: 'invalid_payload' }
  if (data.type !== 'agent-turn-complete') return { applied: false, reason: 'ignored_event_type' }

  const sessionId = data['thread-id'] || 'unknown'
  const now = Date.now()

  store.updateSession(sessionId, {
    status: 'completed',
    workingDirectory: data.cwd,
    sessionTitle: extractSessionTitle(data['input-messages']),
    lastEvent: {
      type: 'turn_complete',
      timestamp: now,
      details: extractAssistantPreview(data['last-assistant-message']),
      turnId: data['turn-id']
    }
  })

  return { applied: true, reason: 'updated', sessionId }
}

module.exports = {
  applyCodexEvent
}
