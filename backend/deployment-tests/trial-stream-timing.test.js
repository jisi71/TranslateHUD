'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { once } = require('node:events')
const { Readable, Writable } = require('node:stream')
const { setTimeout: wait } = require('node:timers/promises')
const path = require('node:path')

const baseline = process.env.TRIAL_BASELINE_ROOT
const candidate = process.env.TRIAL_CANDIDATE_ROOT
assert.ok(baseline && candidate && path.isAbsolute(baseline) && path.isAbsolute(candidate))
const source = 'Hello timing fixture'
const usage = { prompt_tokens: 5, completion_tokens: 7, total_tokens: 12 }

async function request(root, { stream = false, token = 'test-credential', delayed = false } = {}) {
  const { createRequestListener } = require(path.join(root, 'src/httpApp'))
  const { MemoryAccountStore } = require(path.join(root, 'src/accountStore'))
  const store = new MemoryAccountStore()
  const now = () => Date.parse('2026-11-18T00:00:00Z')
  const pause = async () => { if (delayed) await wait(10) }
  for (const method of ['acquireInflight', 'settle']) {
    const original = store[method].bind(store)
    store[method] = async (...args) => { await pause(); return original(...args) }
  }
  await store.ensure('fixture-user', now())
  let forwarded = 0
  const usageEvents = []
  const listener = createRequestListener({
    store, now,
    env: { gateway: 'https://auth.invalid', baseURL: 'https://translation.invalid/v1', model: 'test', apiKey: 'fixture-key' },
    verifyUser: async () => { await pause(); return { uid: 'fixture-user' } },
    forward: async () => {
      forwarded += 1
      await pause()
      if (stream) return { status: 200, stream: Readable.from([Buffer.from(
        `data: {"choices":[{"delta":{"content":"你好"}}]}\n\ndata: ${JSON.stringify({ choices: [], usage })}\n\ndata: [DONE]\n\n`
      )]) }
      return { status: 200, text: JSON.stringify({ choices: [{ message: { content: '你好' } }], usage }) }
    },
    usageEvents: { insert: async (event) => { await pause(); usageEvents.push(event) } }
  })

  const req = Readable.from([Buffer.from(JSON.stringify({ stream, messages: [{ role: 'user', content: source }] }))])
  req.url = '/v1/chat/completions'
  req.method = 'POST'
  req.headers = { 'x-translatehud-source': Buffer.from(source).toString('base64') }
  if (token) req.headers.authorization = `Bearer ${token}`
  const chunks = []
  const res = new Writable({ write(chunk, _encoding, next) { chunks.push(chunk); next() } })
  res.writeHead = (status, headers) => { res.statusCode = status; res.headers = headers }
  const finished = once(res, 'finish')
  const logs = []
  const info = console.info
  console.info = (line) => {
    assert.equal(res.writableFinished, true)
    logs.push(JSON.parse(line))
  }
  try {
    await listener(req, res)
    await finished
  } finally {
    console.info = info
  }
  return {
    response: { status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() },
    logs, forwarded, usageEvents
  }
}

test('batch timings follow response finish and preserve the response and settlement', async () => {
  const before = await request(baseline)
  const after = await request(candidate, { delayed: true })
  assert.equal(after.response.status, 200)
  assert.deepEqual(after.response, before.response)
  assert.deepEqual(after.usageEvents, before.usageEvents)
  assert.equal(after.usageEvents.length, 1)
  assert.equal(after.forwarded, 1)
  assert.equal(before.logs.length, 0)
  assert.equal(after.logs.length, 1)
  const [timing] = after.logs
  const phases = ['body_read_ms', 'body_check_ms', 'auth_ms', 'prepare_ms', 'quota_ms', 'upstream_ms',
    'parse_upstream_ms', 'settlement_ms', 'usage_event_ms', 'format_ms', 'release_ms', 'response_write_ms']
  assert.deepEqual(Object.keys(timing).sort(), ['event', 'status', 'total_ms', ...phases].sort())
  assert.equal(timing.event, 'trial_translate_timing')
  assert.equal(timing.status, 200)
  for (const phase of phases) assert.ok(Number.isFinite(timing[phase]) && timing[phase] >= 0, phase)
  for (const phase of ['auth_ms', 'quota_ms', 'upstream_ms', 'settlement_ms', 'usage_event_ms']) {
    assert.ok(timing[phase] >= 8, phase)
  }
  assert.ok(Math.abs(timing.total_ms - phases.reduce((sum, phase) => sum + timing[phase], 0)) < 0.015)
})

test('auth rejection keeps its response and logs only stages reached', async () => {
  const before = await request(baseline, { token: null })
  const after = await request(candidate, { token: null })
  assert.deepEqual(after.response, before.response)
  assert.equal(after.response.status, 401)
  assert.equal(after.forwarded, 0)
  assert.equal(after.logs.length, 1)
  assert.equal(after.logs[0].status, 401)
  assert.ok(Number.isFinite(after.logs[0].auth_ms))
  assert.equal(after.logs[0].upstream_ms, undefined)
})

test('SSE response and settlement remain byte-identical without a timing log', async () => {
  const before = await request(baseline, { stream: true })
  const after = await request(candidate, { stream: true })
  assert.equal(after.response.status, 200)
  assert.match(after.response.body, /translatehud_trial/)
  assert.deepEqual(after.response, before.response)
  assert.deepEqual(after.usageEvents, before.usageEvents)
  assert.equal(after.forwarded, 1)
  assert.equal(after.logs.length, 0)
})
