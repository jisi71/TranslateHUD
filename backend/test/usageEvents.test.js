'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const http = require('http')
const { Readable } = require('stream')
const fs = require('fs/promises')
const os = require('os')
const path = require('path')
const { MemoryAccountStore } = require('../src/accountStore')
const { createRequestListener } = require('../src/httpApp')
const { dispatch } = require('../src/cloudEntry')
const { GIFT_MICRO_YUAN } = require('../src/trialPolicy')
const {
  USAGE_COLLECTION, MemoryUsageEventStore, FileUsageEventStore,
  createCloudBaseUsageEvent, createUsageEventStoreFromEnv
} = require('../src/usageEventStore')

const usage = { prompt_tokens: 100, completion_tokens: 10, prompt_cache_hit_tokens: 50, total_tokens: 115 }

async function fixture(usageEvents, stream, { missing = false, backwards = false } = {}) {
  const store = new MemoryAccountStore()
  await store.redeem('uid-1', 'translatehud-200', 1, {})
  let clock = 1000
  const deps = {
    store, usageEvents,
    env: { apiKey: 'test', baseURL: 'https://example.com/v1', model: 'm' },
    verifyUser: async () => ({ uid: 'uid-1' }),
    now: () => clock,
    forward: async () => {
      clock = backwards ? 900 : 1250
      const body = { choices: [{ message: { content: 'private-translation' } }], ...(!missing && { usage }) }
      return stream
        ? { status: 200, stream: Readable.from([`data: ${JSON.stringify(body)}\n\ndata: [DONE]\n\n`]) }
        : { status: 200, text: JSON.stringify(body) }
    }
  }
  const event = {
    httpMethod: 'POST', path: '/v1/chat/completions',
    headers: { authorization: 'Bearer test', 'x-translatehud-source': Buffer.from('private-source').toString('base64') },
    body: JSON.stringify({ stream, messages: [{ role: 'user', content: 'private-source' }] })
  }
  return { store, deps, event }
}

for (const stream of [false, true]) {
  test(`successful ${stream ? 'streaming' : 'JSON'} HTTP settlement records accounting fields once`, async (t) => {
    const usageEvents = new MemoryUsageEventStore()
    const { deps, event, store } = await fixture(usageEvents, stream)
    const server = http.createServer(createRequestListener(deps))
    t.after(() => server.close())
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
    const response = await fetch(`http://127.0.0.1:${server.address().port}${event.path}`, {
      method: 'POST', headers: event.headers, body: event.body
    })
    assert.equal(response.status, 200)
    const body = await response.text()
    assert.match(body, /translatehud_trial/)
    assert.deepEqual(usageEvents.events, [{
      userId: 'uid-1', displayNo: 1, displayId: '00001',
      promptTokens: 100, completionTokens: 10, cacheHitTokens: 50, extraTokens: 5,
      costMicroYuan: 222, chargedMicroYuan: 222, costFen: 0, chargedFen: 0,
      durationMs: 250, createdAt: 1250
    }])
    assert.equal((await store.ensure('uid-1')).record.balanceMicroYuan, GIFT_MICRO_YUAN - 222)
    assert.equal(JSON.stringify(usageEvents.events).includes('private-'), false)
  })

  test(`usage write failure preserves ${stream ? 'streaming' : 'JSON'} cloud response and charge`, async (t) => {
    const errors = []
    t.mock.method(console, 'error', message => errors.push(message))
    const { deps, event, store } = await fixture({ insert: async () => { throw new Error('write failed') } }, stream)
    const result = await dispatch(event, deps)
    assert.equal(result.statusCode, 200)
    assert.match(result.body, /translatehud_trial/)
    assert.doesNotMatch(result.body, /trial_store/)
    assert.equal((await store.ensure('uid-1')).record.balanceMicroYuan, GIFT_MICRO_YUAN - 222)
    assert.equal(errors.length, 1)
    assert.match(errors[0], /trial usage event failed/)
  })

  test(`missing usage writes no ${stream ? 'streaming' : 'JSON'} event and makes no charge`, async () => {
    const usageEvents = new MemoryUsageEventStore()
    const { deps, event, store } = await fixture(usageEvents, stream, { missing: true })
    const result = await dispatch(event, deps)
    assert.match(result.body, /trial_usage_missing/)
    assert.deepEqual(usageEvents.events, [])
    assert.equal((await store.ensure('uid-1')).record.balanceMicroYuan, GIFT_MICRO_YUAN)
  })
}

test('duration never goes below zero', async () => {
  const usageEvents = new MemoryUsageEventStore()
  const { deps, event } = await fixture(usageEvents, false, { backwards: true })
  await dispatch(event, deps)
  assert.equal(usageEvents.events[0].durationMs, 0)
})

test('file store appends JSONL beside the accounts file', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'trial-usage-'))
  t.after(() => fs.rm(dir, { recursive: true, force: true }))
  const store = createUsageEventStoreFromEnv({ TRIAL_STORE: 'file', TRIAL_DATA_FILE: path.join(dir, 'accounts.json') })
  assert.ok(store instanceof FileUsageEventStore)
  await store.insert({ userId: 'one' })
  await store.insert({ userId: 'two' })
  assert.equal(await fs.readFile(path.join(dir, 'usage-events.jsonl'), 'utf8'), '{"userId":"one"}\n{"userId":"two"}\n')
  assert.ok(createUsageEventStoreFromEnv({ TRIAL_STORE: 'memory' }) instanceof MemoryUsageEventStore)
})

test('CloudBase ensures the usage collection and retries a missing-collection add once', async () => {
  const created = []
  const saved = []
  let attempts = 0
  const db = {
    createCollection: async name => { created.push(name) },
    collection(name) {
      assert.equal(name, USAGE_COLLECTION)
      return { async add(event) {
        attempts++
        if (attempts === 1) throw Object.assign(new Error('collection not exist'), { code: 'DATABASE_COLLECTION_NOT_EXIST' })
        saved.push(event)
      } }
    }
  }
  await createCloudBaseUsageEvent(db).insert({ userId: 'uid-1' })
  assert.deepEqual(created, ['trial_usage_events'])
  assert.equal(attempts, 2)
  assert.deepEqual(saved, [{ userId: 'uid-1' }])
})

test('CloudBase does not retry unrelated write failures', async () => {
  let attempts = 0
  const store = createCloudBaseUsageEvent({
    createCollection: async () => {},
    collection: () => ({ add: async () => { attempts++; throw new Error('permission denied') } })
  })
  await assert.rejects(store.insert({}), /permission denied/)
  assert.equal(attempts, 1)
})
