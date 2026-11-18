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
const now = () => Date.parse('2026-11-18T00:00:00Z')
const uid = 'fixture-user'
const source = 'Hello quota timing fixture'

async function fixture(root) {
  const { createRequestListener } = require(path.join(root, 'src/httpApp'))
  const { createCloudBaseStore } = require(path.join(root, 'src/cloudBaseStore'))
  const { MemoryAccountStore } = require(path.join(root, 'src/accountStore'))
  const memory = new MemoryAccountStore()
  const { record } = await memory.ensure(uid, now())
  const accountKey = `trial_accounts/${uid}`
  const records = new Map([[accountKey, record]])
  const calls = []
  async function operation(name) {
    calls.push(name)
    await wait(8)
  }
  const database = {
    async createCollection(name) { await operation(`collection:${name}`) },
    async startTransaction() {
      await operation('begin')
      const writes = new Map()
      return {
        collection(name) {
          return { doc(id) {
            const key = `${name}/${id}`
            return {
              async get() { await operation('get'); return { data: structuredClone(records.get(key) ?? []) } },
              async set(value) { await operation('set'); writes.set(key, structuredClone(value)) }
            }
          } }
        },
        async commit() {
          await operation('commit')
          for (const [key, value] of writes) records.set(key, value)
        },
        async rollback() { await operation('rollback') }
      }
    }
  }
  let modelCalls = 0
  const listener = createRequestListener({
    store: createCloudBaseStore(database), now,
    env: { gateway: 'https://auth.invalid', baseURL: 'https://translation.invalid/v1', apiKey: 'fixture-key', model: 'test' },
    verifyUser: async () => ({ uid }),
    forward: async () => {
      modelCalls += 1
      return {
        status: 200,
        text: JSON.stringify({
          choices: [{ message: { content: '你好' } }],
          usage: { prompt_tokens: 5, completion_tokens: 7, total_tokens: 12 }
        })
      }
    }
  })

  return async function send() {
    calls.length = 0
    modelCalls = 0
    const req = Readable.from([Buffer.from(JSON.stringify({ messages: [{ role: 'user', content: source }] }))])
    req.url = '/v1/chat/completions'
    req.method = 'POST'
    req.headers = { authorization: 'Bearer fixture-credential', 'x-translatehud-source': Buffer.from(source).toString('base64') }
    const chunks = []
    const res = new Writable({ write(chunk, _encoding, next) { chunks.push(chunk); next() } })
    res.writeHead = (status, headers) => { res.statusCode = status; res.headers = headers }
    const finished = once(res, 'finish')
    const logs = []
    const info = console.info
    console.info = line => {
      assert.equal(res.writableFinished, true)
      logs.push(JSON.parse(line))
    }
    try {
      await listener(req, res)
      await finished
    } finally {
      console.info = info
    }
    assert.equal(res.statusCode, 200)
    assert.equal(modelCalls, 1)
    assert.equal(logs.length, 1)
    return {
      response: { status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() },
      account: structuredClone(records.get(accountKey)),
      operations: [...calls],
      timing: logs[0]
    }
  }
}

test('quota log separates tokenizer initialization, encoding, database and slot decisions', async () => {
  const original = await fixture(baseline)
  const instrumented = await fixture(candidate)
  for (const cold of [true, false]) {
    const before = await original()
    const after = await instrumented()
    assert.deepEqual(after.response, before.response)
    assert.deepEqual(after.account, before.account)
    assert.deepEqual(after.operations, before.operations)
    const t = after.timing
    for (const phase of ['quota_token_encode_ms', 'quota_db_ready_ms', 'quota_db_begin_ms',
      'quota_db_read_ms', 'quota_db_write_ms', 'quota_db_commit_ms', 'quota_slot_decision_ms']) {
      assert.ok(Number.isFinite(t[phase]) && t[phase] >= 0, phase)
    }
    for (const phase of ['quota_db_begin_ms', 'quota_db_read_ms', 'quota_db_write_ms', 'quota_db_commit_ms']) {
      assert.ok(t[phase] >= 6, phase)
    }
    if (cold) assert.ok(t.quota_tokenizer_init_ms > 0)
    else assert.equal(t.quota_tokenizer_init_ms, undefined)
    const subtotal = Object.entries(t)
      .filter(([k]) => /^quota_.+_ms$/.test(k))
      .reduce((sum, [, value]) => sum + value, 0)
    assert.ok(subtotal <= t.quota_ms + 0.01)
  }
})
