'use strict'

const { PassThrough } = require('stream')
const { parseUsage } = require('./usageBilling')

const MAX_PENDING_BYTES = 4 * 1024 * 1024

function formatSSE(value) {
  return `data: ${JSON.stringify(value)}\n\n`
}

function findSeparator(buffer) {
  const crlf = buffer.indexOf('\r\n\r\n')
  const lf = buffer.indexOf('\n\n')
  if (crlf === -1 && lf === -1) return null
  if (crlf !== -1 && (lf === -1 || crlf < lf)) return { index: crlf, length: 4 }
  return { index: lf, length: 2 }
}

function dataPayload(eventText) {
  const lines = String(eventText).split(/\r?\n/)
  const data = []
  for (const line of lines) {
    if (!line.startsWith('data:')) continue
    let value = line.slice(5)
    if (value.startsWith(' ')) value = value.slice(1)
    data.push(value)
  }
  if (data.length === 0) return null
  return data.join('\n')
}

function inspectEvent(eventBuffer) {
  const payload = dataPayload(eventBuffer.toString('utf8'))
  if (payload == null) return { done: false, usage: null }
  if (payload === '[DONE]') return { done: true, usage: null }
  try {
    const json = JSON.parse(payload)
    return { done: false, usage: parseUsage(json && json.usage) }
  } catch {
    return { done: false, usage: null }
  }
}

// Forwards upstream SSE as it arrives, holds back [DONE], then lets the caller
// append a settlement event before the terminal [DONE]. Byte chunks are not
// re-encoded, so a multibyte character split across packets stays intact.
function createSettlingStream(upstream, settle) {
  const out = new PassThrough()
  let pending = Buffer.alloc(0)
  let usage = null
  let sawDone = false
  let closed = false

  function forward(chunk) {
    if (closed || out.destroyed) return
    const flowing = out.write(chunk)
    if (!flowing && upstream && typeof upstream.pause === 'function') upstream.pause()
  }

  function take(eventBuffer) {
    const inspected = inspectEvent(eventBuffer)
    if (inspected.usage) usage = inspected.usage
    if (inspected.done) {
      sawDone = true
      return
    }
    forward(eventBuffer)
  }

  function consume(flush) {
    while (!closed) {
      const sep = findSeparator(pending)
      if (!sep) break
      const event = pending.subarray(0, sep.index)
      const marked = Buffer.concat([event, pending.subarray(sep.index, sep.index + sep.length)])
      pending = pending.subarray(sep.index + sep.length)
      take(marked)
    }
    if (flush && pending.length && !closed) {
      const tail = pending
      pending = Buffer.alloc(0)
      take(tail)
    }
  }

  function fail(error) {
    if (closed) return
    closed = true
    if (typeof upstream.destroy === 'function') upstream.destroy()
    if (!out.destroyed) out.destroy(error || new Error('trial stream failed'))
  }

  upstream.on('data', (chunk) => {
    if (closed) return
    pending = pending.length ? Buffer.concat([pending, chunk]) : Buffer.from(chunk)
    if (pending.length > MAX_PENDING_BYTES) {
      fail(new Error('trial stream too large'))
      return
    }
    consume(false)
  })
  upstream.on('end', () => {
    if (closed) return
    consume(true)
    closed = true
    Promise.resolve()
      .then(() => settle(usage))
      .then((extra) => {
        if (out.destroyed) return
        if (extra) out.write(extra)
        if (sawDone) out.write('data: [DONE]\n\n')
        out.end()
      })
      .catch((error) => {
        if (!out.destroyed) out.destroy(error)
      })
  })
  upstream.on('error', (error) => fail(error))
  out.on('drain', () => {
    if (!closed && upstream && typeof upstream.resume === 'function') upstream.resume()
  })
  out.on('error', () => {
    if (closed) return
    closed = true
    if (typeof upstream.destroy === 'function') upstream.destroy()
  })
  return out
}

module.exports = {
  createSettlingStream,
  formatSSE,
  dataPayload,
  inspectEvent
}
