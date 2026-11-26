'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { existsSync } = require('node:fs')
const { Readable } = require('node:stream')
const { setTimeout: delay } = require('node:timers/promises')
const path = require('node:path')

const src = process.env.TRIAL_SPEED_TEST_ROOT || path.join(__dirname, '..', 'src')
const baseline = process.env.TRIAL_SPEED_BASELINE_ROOT
const hasDailyQuota = root => existsSync(path.join(root, 'dailyQuota.js'))
const startsAt = Date.UTC(2026, 10, 24, 8)
const tokenWithExpiry = exp => `fixture.${Buffer.from(JSON.stringify({ exp })).toString('base64url')}.signature`

function fixture(root = src, { free = false, latency = false, ttl = '3600000', token = tokenWithExpiry((startsAt + 7200000) / 1000) } = {}) {
  const service = require(path.join(root, 'trialService'))
  const { TransactionalAccountStore } = require(path.join(root, 'accountStore'))
  const records = new Map([['private-owner', { balanceMicroYuan: free ? 0 : 1000000, displayNo: 1, inflight: [] }]])
  const counts = { auth: 0, transactions: 0, dbCalls: 0, upstream: 0, usageWrites: 0, releases: 0 }
  let now = startsAt
  let invite = { nextDisplayNo: 2, redeemedCount: 0 }
  const stats = []
  const timing = []
  const rpc = fn => async (...args) => {
    counts.dbCalls++
    if (latency) await delay(2)
    return fn(...args)
  }
  const store = new TransactionalAccountStore(rpc(() => {
    counts.transactions++
    const writes = new Map()
    let nextInvite
    return {
      get: rpc(uid => structuredClone(records.get(uid) ?? null)),
      save: rpc((uid, value) => writes.set(uid, structuredClone(value))),
      create: rpc((uid, value) => writes.set(uid, structuredClone(value))),
      getInvite: rpc(() => structuredClone(invite)),
      saveInvite: rpc(value => { nextInvite = value }),
      commit: rpc(() => {
        for (const [uid, value] of writes) records.set(uid, value)
        if (nextInvite) invite = nextInvite
      }),
      rollback: rpc(() => {})
    }
  }))
  const release = store.releaseInflight.bind(store)
  store.releaseInflight = (...args) => { counts.releases++; return release(...args) }
  let accepted = true
  let uid = 'private-owner'
  const source = 'private source sentence'
  const ctx = {
    headers: { authorization: `Bearer ${token}`, 'x-translatehud-source': Buffer.from(source).toString('base64') },
    env: { gateway: 'https://example.test', apiKey: 'fixture', baseURL: 'https://example.test/v1',
      model: 'fixture', TRIAL_AUTH_CACHE_TTL_MS: ttl, TRIAL_TRANSLATE_TIMING: '1' },
    verifyUser: async () => {
      counts.auth++
      if (latency) await delay(8)
      if (!accepted) throw new Error('revoked fixture')
      return { uid, hasEligiblePhone: true }
    },
    now: () => now, store,
    usageEvents: {
      async insert(value) {
        counts.usageWrites++
        if (latency) await delay(6)
        stats.push(value)
      }
    },
    logTranslationTiming: raw => timing.push(JSON.parse(raw))
  }
  function translate({ stream = false, upstreamError = false, missingUsage = false } = {}) {
    return service.handleTranslate({
      ...ctx, rawBody: JSON.stringify({ stream, messages: [{ role: 'user', content: source }] }),
      forward: async () => {
        counts.upstream++
        if (latency) await delay(12)
        if (upstreamError) return { status: 503 }
        const text = JSON.stringify({
          choices: [{ message: { content: 'fixture output' } }],
          ...(!missingUsage && { usage: { prompt_tokens: 1000, completion_tokens: 100 } })
        })
        return stream ? { status: 200, stream: Readable.from([`data: ${text}\n\ndata: [DONE]\n\n`]) }
          : { status: 200, text }
      }
    })
  }
  return { records, counts, timing, stats, ctx, translate, service,
    advance: ms => { now += ms }, revoke: () => { accepted = false }, setUid: value => { uid = value } }
}

async function drain(response) {
  if (response.stream) {
    let body = ''
    for await (const chunk of response.stream) body += chunk.toString()
    await response.release()
    return body
  }
  return response.body
}

for (const stream of [false, true]) {
  test(`successful ${stream ? 'SSE' : 'JSON'} uses one admission and one settlement without another release`, async () => {
    const f = fixture()
    const response = await f.translate({ stream })
    const body = await drain(response)
    assert.equal(response.status, 200)
    assert.match(body, /translatehud_trial/)
    assert.equal(f.counts.transactions, 2)
    assert.equal(f.counts.releases, 0)
    assert.equal(f.records.get('private-owner').inflight.length, 0)
    assert.equal(f.stats.length, 1)
    const timing = f.timing[0]
    assert.equal(timing.stream, stream)
    for (const stage of ['authMs', 'acquireMs', 'upstreamMs', 'settleMs', 'totalMs']) {
      assert.ok(Number.isFinite(timing[stage]) && timing[stage] >= 0, stage)
    }
    assert.doesNotMatch(JSON.stringify(timing), /private|fixture|signature/)
  })
}

test('new accounts open and receive a display number during admission without granting a gift', async () => {
  const f = fixture()
  f.setUid('new')
  const response = await f.translate()
  const account = f.records.get('new')
  assert.equal(account.displayNo, 2)
  assert.equal(account.giftGranted, false)
  assert.equal(account.balanceMicroYuan, 0)
  const daily = hasDailyQuota(src)
  assert.equal(response.status, daily ? 200 : 402)
  assert.equal(f.counts.transactions, daily ? 2 : 1)
  assert.equal(f.counts.upstream, daily ? 1 : 0)
  if (daily) assert.ok(account.dailyTokens > 0)
})

test('upstream failure and missing stream usage each release their slot once', async () => {
  for (const options of [{ upstreamError: true }, { stream: true, missingUsage: true }]) {
    const f = fixture()
    await drain(await f.translate(options))
    assert.equal(f.counts.releases, 1)
    assert.equal(f.stats.length, 0)
    assert.deepEqual(f.records.get('private-owner').inflight, [])
    assert.equal(f.records.get('private-owner').balanceMicroYuan, 1000000)
  }
})

test('JSON response waits for usage log but the ledger has settled and released the slot first', async () => {
  const f = fixture()
  let finishWrite
  let markStarted
  const started = new Promise(resolve => { markStarted = resolve })
  f.ctx.usageEvents.insert = () => new Promise(resolve => {
    finishWrite = resolve
    markStarted()
  })
  let returned = false
  const pending = f.translate().then(value => { returned = true; return value })
  await Promise.race([
    started,
    pending.then(response => assert.fail(`Responded before starting the usage write (${response.status})`))
  ])
  assert.equal(returned, false)
  assert.equal(f.counts.transactions, 2)
  assert.deepEqual(f.records.get('private-owner').inflight, [])
  finishWrite()
  assert.equal((await pending).status, 200)
})

test('translation cache hits and expires at configured TTL while account and redeem verify live', async () => {
  const f = fixture(src, { ttl: '1000' })
  assert.equal((await f.translate()).status, 200)
  f.advance(999)
  assert.equal((await f.translate()).status, 200)
  assert.equal(f.counts.auth, 1)
  f.revoke()
  assert.equal((await f.service.handleAccount(f.ctx)).status, 401)
  assert.equal((await f.service.handleRedeem(f.ctx)).status, 401)
  assert.equal(f.counts.auth, 3)
  f.advance(1)
  assert.equal((await f.translate()).status, 401)
  assert.equal(f.counts.auth, 4)
  assert.equal((await f.translate()).status, 401)
  assert.equal(f.counts.auth, 5)
})

test('cache respects JWT expiry minus 30 seconds, the one-hour cap, opaque fallback and opt-out', async () => {
  const cases = [
    { ttl: '3600000', token: tokenWithExpiry((startsAt + 90000) / 1000), end: 60000 },
    { ttl: '99999999', end: 3600000 },
    { ttl: '', end: 300000 },
    { ttl: '3600000', token: 'opaque-token', end: 300000 }
  ]
  for (const { end, ...options } of cases) {
    const f = fixture(src, options)
    await f.translate()
    f.advance(end - 1)
    await f.translate()
    assert.equal(f.counts.auth, 1)
    f.advance(1)
    await f.translate()
    assert.equal(f.counts.auth, 2)
  }
  const disabled = fixture(src, { ttl: '0' })
  await disabled.translate()
  await disabled.translate()
  assert.equal(disabled.counts.auth, 2)
})

test('a client disconnect during settlement waits for the outcome and cleans up only on failure', async () => {
  const { holdTranslationSlot } = require(path.join(src, 'translationSlot'))
  for (const settled of [true, false]) {
    let releases = 0
    let finishSettlement
    const slot = holdTranslationSlot(async () => { releases++ })
    const settlement = slot.settle(() => new Promise(resolve => { finishSettlement = resolve }))
    const cleanup = slot.release()
    assert.equal(slot.release(), cleanup)
    assert.equal(releases, 0)
    finishSettlement(settled ? { ok: true } : null)
    await settlement
    await cleanup
    assert.equal(releases, settled ? 0 : 1)
  }
})

test('auth cache evicts the least recently used entry at 2000 entries', async () => {
  const { verifyTranslationUser } = require(path.join(src, 'translationAuthCache'))
  let verifications = 0
  const verifyUser = async () => { verifications++; return { uid: 'fixture' } }
  const lookup = i => verifyTranslationUser({
    gateway: 'https://example.test', token: `capacity-test-${i}`, verifyUser, ttlValue: '10000', now: () => startsAt
  })
  for (let i = 0; i < 2000; i++) await lookup(i)
  await lookup(0)
  await lookup(2000)
  await lookup(0)
  assert.equal(verifications, 2001)
  await lookup(1)
  assert.equal(verifications, 2002)
})

if (baseline) {
  test('records baseline and optimized call counts with fixed mock latency', async t => {
    for (const free of hasDailyQuota(src) ? [false, true] : [false]) {
      for (const [phase, root] of [['baseline', baseline], ['optimized', src]]) {
        const f = fixture(root, { free, latency: true })
        const result = await f.translate()
        await drain(result)
        assert.equal(result.status, 200)
        const cold = { ...f.counts, ...f.timing.at(-1) }
        const latencies = []
        let warm
        for (let i = 0; i < 5; i++) {
          const before = { ...f.counts }
          assert.equal((await f.translate()).status, 200)
          warm = Object.fromEntries(Object.keys(before).map(key => [key, f.counts[key] - before[key]]))
          latencies.push(f.timing.at(-1).totalMs)
        }
        const medianMs = latencies.sort((a, b) => a - b)[2]
        t.diagnostic(JSON.stringify({ phase, free, cold, warm, medianMs }))
      }
    }
  })
}
