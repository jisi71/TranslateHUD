'use strict'

const { performance } = require('node:perf_hooks')

function createTranslationTiming(enabled, log = console.info) {
  if (enabled !== '1') return null
  const started = performance.now()
  const fields = {}
  const pending = new Map()
  let finished = false
  function end(stage, start) {
    if (fields[stage] === undefined) fields[stage] = Math.round((performance.now() - start) * 1000) / 1000
    pending.delete(stage)
  }
  return {
    start(stage) {
      const start = performance.now()
      pending.set(stage, start)
      return () => end(stage, start)
    },
    finish(status, stream) {
      if (finished) return
      finished = true
      for (const [stage, start] of pending) end(stage, start)
      end('totalMs', started)
      try {
        log(JSON.stringify({ event: 'trial_translation_stages', status, stream, ...fields }))
      } catch {
        // Diagnostics must never affect the response.
      }
    }
  }
}

module.exports = { createTranslationTiming }
