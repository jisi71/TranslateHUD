'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { randomUUID } = require('node:crypto')
const { Readable } = require('node:stream')
const path = require('node:path')
const src = process.env.TRIAL_RETRY_TEST_ROOT || path.join(__dirname, '..', 'src')
const { handleTranslate } = require(path.join(src, 'trialService'))
const { MemoryAccountStore, TransactionalAccountStore } = require(path.join(src, 'accountStore'))
const { MemoryUsageEventStore } = require(path.join(src, 'usageEventStore'))
const { RETRY_WINDOW_MS } = require(path.join(src, 'retryWaiver'))

async function fixture({ daily = false, stream = false } = {}) {
  const store = new MemoryAccountStore()
  const usageEvents = new MemoryUsageEventStore()
  let calls = 0
  let now = Date.UTC(2026, 10, 19, 8)
  const uid = 'owner'
  if (!daily) await store.redeem(uid, 'translatehud-200', now, {})
  async function send(headers = {}, options = {}) {
    const text = options.text || 'A small translation sample'
    return handleTranslate({
      headers: { Authorization: 'Bearer example', 'X-TranslateHUD-Source': Buffer.from(text).toString('base64'), ...headers },
      rawBody: JSON.stringify({
        stream,
        messages: [{ role: 'system', content: 'Translate into Simplified Chinese' }, { role: 'user', content: text }],
        ...(options.requiresWaiver && { translatehud_quality_retry: true })
      }),
      store, usageEvents, now: () => now,
      env: { apiKey: 'test', baseURL: 'https://example.test/v1', model: 'test' },
      verifyUser: async () => ({ uid: options.uid || uid }),
      forward: async () => {
        calls += 1
        if (options.providerError) return { status: 502 }
        const output = { choices: [{ message: { content: '测试译文' }, finish_reason: 'stop' }],
          ...(!options.noUsage && { usage: { prompt_tokens: 1000, completion_tokens: 100 } }) }
        return stream
          ? { status: 200, stream: Readable.from([`data: ${JSON.stringify(output)}\n\ndata: [DONE]\n\n`]) }
          : { status: 200, text: JSON.stringify(output) }
      }
    })
  }
  async function receipt(response) {
    assert.equal(response.status, 200)
    if (!stream) return JSON.parse(response.body).translatehud_trial
    let content = ''
    for await (const chunk of response.stream) content += chunk.toString()
    return content.split('\n').filter(row => row.startsWith('data: {'))
      .map(row => JSON.parse(row.slice(6))).find(row => row.translatehud_trial)?.translatehud_trial
  }
  return { send, receipt, usageEvents, store, uid, advance: ms => { now += ms }, calls: () => calls }
}

async function issue(f, id) {
  const first = await f.receipt(await f.send({ 'X-TranslateHUD-Request-Id': id }))
  assert.equal(first.retryRequestId, id)
  return first
}

for (const stream of [false, true]) {
  test(`one ${stream ? 'SSE' : 'JSON'} quality retry is free and concurrent replay is rejected`, async () => {
    const f = await fixture({ stream })
    const id = randomUUID()
    const first = await issue(f, id)
    const retry = () => f.send({ 'X-TranslateHUD-Retry-Of': id }, { requiresWaiver: true })
    const responses = await Promise.all([retry(), retry()])
    assert.deepEqual(responses.map(r => r.status).sort(), [200, 409])
    const final = await f.receipt(responses.find(r => r.status === 200))
    assert.equal(final.retryWaived, true)
    assert.equal(final.chargedMicroYuan, 0)
    assert.ok(final.costMicroYuan > 0)
    assert.equal(final.balanceMicroYuan, first.balanceMicroYuan)
    assert.equal(f.usageEvents.events.length, 2)
    assert.equal(f.usageEvents.events[1].retryWaived, true)
    assert.equal(f.calls(), 2)
    await f.receipt(await f.send({ 'X-TranslateHUD-Request-Id': id }))
    assert.equal((await retry()).status, 409)
  })
}

test('waiver rejects another account, different source, lost headers and an expired original', async () => {
  const f = await fixture()
  const id = randomUUID()
  await issue(f, id)
  const header = { 'X-TranslateHUD-Retry-Of': id }
  assert.equal((await f.send(header, { uid: 'other' })).status, 409)
  assert.equal((await f.send(header, { text: 'A different but valid source' })).status, 409)
  assert.equal((await f.send({}, { requiresWaiver: true })).status, 400)
  assert.equal((await f.send({ ...header, 'x-translatehud-retry-of': id })).status, 400)
  f.advance(RETRY_WINDOW_MS)
  assert.equal((await f.send(header)).status, 409)
  assert.equal(f.calls(), 1)
})

test('unsettled first attempts cannot be claimed and failed retries cannot be replayed', async () => {
  const f = await fixture()
  const id = randomUUID()
  const header = { 'X-TranslateHUD-Retry-Of': id }
  assert.equal((await f.send({ 'X-TranslateHUD-Request-Id': id }, { noUsage: true })).status, 502)
  assert.equal((await f.send(header)).status, 409)
  await issue(f, id)
  assert.equal((await f.send(header, { providerError: true })).status, 502)
  assert.equal((await f.send(header)).status, 409)
  assert.equal(f.usageEvents.events.length, 1)
})

if (process.env.TRIAL_RETRY_TEST_ROOT) {
  test('daily quota and balance are unchanged by an eligible waived retry', async () => {
    const f = await fixture({ daily: true })
    const id = randomUUID()
    const first = await issue(f, id)
    assert.ok(first.dailyTokens > 0)
    const final = await f.receipt(await f.send({ 'X-TranslateHUD-Retry-Of': id }))
    assert.equal(final.dailyTokens, first.dailyTokens)
    assert.equal(final.balanceMicroYuan, 0)
    assert.equal(final.chargedMicroYuan, 0)
    assert.equal(f.usageEvents.events[1].retryWaived, true)
  })
}

test('two independent workers atomically contend for the same waiver', async () => {
  const now = Date.UTC(2026, 10, 19, 8)
  const f = await fixture()
  const id = randomUUID()
  await issue(f, id)
  let record = (await f.store.ensure(f.uid)).record
  let revision = 0
  const begin = async () => {
    const startRevision = revision
    const snapshot = structuredClone(record)
    let saved
    return {
      get: async () => snapshot,
      save: async (_uid, next) => { saved = next },
      commit: async () => {
        if (revision !== startRevision) throw Object.assign(new Error('conflict'), { code: 'CONFLICT' })
        if (saved) {
          record = saved
          revision += 1
        }
      },
      rollback: async () => {}
    }
  }
  const attempt = { ...record.retryReceipts[0], retry: true }
  const claim = () => {
    const store = new TransactionalAccountStore(begin)
    return process.env.TRIAL_RETRY_TEST_ROOT
      ? (process.env.TRIAL_RETRY_TEST_ROOT.includes('trial-stream-shared')
        ? store.acquireInflight(f.uid, now, 0, undefined, attempt)
        : store.acquireInflight(f.uid, now, 0, attempt))
      : store.acquireInflight(f.uid, now, attempt)
  }
  const claims = await Promise.all([claim(), claim()])
  assert.equal(claims.filter(result => result.ok).length, 1)
  assert.equal(claims.find(result => !result.ok).status, 409)
})
