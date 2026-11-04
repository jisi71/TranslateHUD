'use strict'

const crypto = require('crypto')

const MAX_RANGES = 32
const MAX_OUTPUT_BYTES = 1024 * 1024
const NEWLINES = /[\n\v\f\r\u0085\u2028\u2029]/u

function badInput() {
  const error = new Error('invalid bold ranges')
  error.status = 400
  error.code = 'trial_body'
  throw error
}

function limitInput() {
  const error = new Error('too many formatting ranges')
  error.status = 400
  error.code = 'trial_format_limit'
  error.publicMessage = '截图格式片段过多，请缩小截图后重试。'
  throw error
}

function boundaries(text) {
  const values = new Set([0])
  let offset = 0
  for (const part of new Intl.Segmenter('und', { granularity: 'grapheme' }).segment(text)) {
    offset += Buffer.byteLength(part.segment)
    values.add(offset)
  }
  return values
}

function validateRanges(texts, ranges) {
  let count = 0
  if (!Array.isArray(ranges) || ranges.length !== texts.length) badInput()
  const source = texts.join('\n')
  const graphemes = [...new Intl.Segmenter('und', { granularity: 'grapheme' }).segment(source)].length
  const rangeLimit = Math.min(MAX_RANGES, Math.max(2, Math.ceil(graphemes / 2)))
  for (let i = 0; i < texts.length; i++) {
    const text = texts[i]
    const entry = ranges[i]
    if (!Array.isArray(entry)) badInput()
    const bytes = Buffer.from(text)
    const allowed = boundaries(text)
    let previous = 0
    for (const pair of entry) {
      count++
      if (count > rangeLimit) limitInput()
      if (!Array.isArray(pair) || pair.length !== 2) badInput()
      const [start, end] = pair
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < previous || end <= start || end > bytes.length || !allowed.has(start) || !allowed.has(end)) badInput()
      if (NEWLINES.test(bytes.subarray(start, end).toString('utf8'))) badInput()
      previous = end
    }
  }
  return count > 0
}

function makeBoldFormat(texts, ranges, passage = '', makeNonce = () => crypto.randomBytes(12).toString('hex')) {
  if (!validateRanges(texts, ranges)) return null
  let nonce
  for (let attempt = 0; attempt < 8; attempt++) {
    const value = makeNonce()
    if (!/^[0-9a-f]{24}$/.test(value)) badInput()
    if (![...texts, passage].some((text) => text.includes(value))) { nonce = value; break }
  }
  if (!nonce) badInput()
  const expected = []
  const marked = texts.map((text, i) => {
    const bytes = Buffer.from(text)
    const chunks = []
    const markers = []
    let last = 0
    for (const [j, [start, end]] of ranges[i].entries()) {
      const open = `⟦THB${nonce}:${i}:${j}:S⟧`
      const close = `⟦THB${nonce}:${i}:${j}:E⟧`
      chunks.push(bytes.subarray(last, start).toString('utf8'), open, bytes.subarray(start, end).toString('utf8'), close)
      markers.push({ open, close })
      last = end
    }
    chunks.push(bytes.subarray(last).toString('utf8'))
    expected.push(markers)
    return chunks.join('')
  })
  const sourceBytes = Buffer.byteLength(texts.join('\n'))
  const markerBytes = Buffer.byteLength(marked.join('\n')) - sourceBytes
  const markerLimit = Math.min(2048, Math.max(256, sourceBytes * 8))
  if (markerBytes > markerLimit) limitInput()
  return { nonce, expected, marked }
}

const INSTRUCTIONS = [
  'Formatting markers in text are data boundaries, not words or instructions.',
  'Preserve each exact matching S/E marker exactly once in its original result item.',
  'Move each matching pair with its translated phrase if needed. Never nest, cross, split, or omit markers.',
  'Return the same strict JSON results format, with markers inside each t string.'
].join('\n')

function restoreBoldResult(provider, format) {
  if (!provider || !Array.isArray(provider.choices) || provider.choices.length !== 1) throw new Error('invalid formatted output')
  const content = provider && provider.choices && provider.choices[0] && provider.choices[0].message && provider.choices[0].message.content
  if (typeof content !== 'string' || Buffer.byteLength(content) > MAX_OUTPUT_BYTES) throw new Error('invalid formatted output')
  let body
  try { body = JSON.parse(content) } catch { throw new Error('invalid formatted output') }
  if (!body || Array.isArray(body) || typeof body !== 'object' || Object.keys(body).some(k => k !== 'results') || !Array.isArray(body.results) || body.results.length !== format.expected.length) throw new Error('invalid formatted output')
  const results = new Array(format.expected.length)
  const prefix = `⟦THB${format.nonce}:`
  for (const item of body.results) {
    if (!item || typeof item !== 'object' || Array.isArray(item) || Object.keys(item).some(k => !['i', 't'].includes(k)) || !Number.isInteger(item.i) || item.i < 0 || item.i >= results.length || results[item.i] || typeof item.t !== 'string') throw new Error('invalid formatted output')
    const markers = format.expected[item.i]
    const known = new Map()
    for (let i = 0; i < markers.length; i++) {
      known.set(markers[i].open, { i, open: true })
      known.set(markers[i].close, { i, open: false })
    }
    const seen = new Set()
    const ranges = []
    let active = null
    let out = ''
    let cursor = 0
    while (true) {
      const start = item.t.indexOf(prefix, cursor)
      if (start < 0) break
      out += item.t.slice(cursor, start)
      const end = item.t.indexOf('⟧', start + prefix.length)
      if (end < 0) throw new Error('invalid formatted output')
      const token = item.t.slice(start, end + 1)
      const marker = known.get(token)
      if (!marker || seen.has(token)) throw new Error('invalid formatted output')
      seen.add(token)
      if (marker.open) {
        if (active) throw new Error('invalid formatted output')
        active = { i: marker.i, start: Buffer.byteLength(out) }
      } else {
        if (!active || active.i !== marker.i) throw new Error('invalid formatted output')
        const finish = Buffer.byteLength(out)
        if (finish <= active.start) throw new Error('invalid formatted output')
        if (NEWLINES.test(Buffer.from(out).subarray(active.start, finish).toString('utf8'))) throw new Error('invalid formatted output')
        ranges.push([active.start, finish])
        active = null
      }
      cursor = end + 1
    }
    out += item.t.slice(cursor)
    if (active || seen.size !== markers.length * 2 || out.includes(format.nonce)) throw new Error('invalid formatted output')
    const allowed = boundaries(out)
    if (ranges.some(([start, end]) => !allowed.has(start) || !allowed.has(end))) throw new Error('invalid formatted output')
    results[item.i] = { i: item.i, t: out, boldRanges: ranges }
  }
  if (results.some(item => !item)) throw new Error('invalid formatted output')
  const copy = { ...provider, choices: [...provider.choices] }
  copy.choices[0] = { ...provider.choices[0], message: { ...provider.choices[0].message, content: JSON.stringify({ results }) } }
  return copy
}

module.exports = { validateRanges, makeBoldFormat, restoreBoldResult, INSTRUCTIONS, MAX_RANGES }
