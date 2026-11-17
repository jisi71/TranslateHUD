'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('crypto')
const { Readable, Writable } = require('stream')
const { handleQualityFeedback, qualityFeedbackConfig, MAX_BYTES } = require('../src/qualityFeedbackService')
const { createMemoryQualityFeedbackStore, createCloudQualityFeedbackStore, SNAPSHOTS, QUOTAS, HOUR } = require('../src/qualityFeedbackStore')
const { dispatch } = require('../src/cloudEntry')
const { createRequestListener } = require('../src/httpApp')
const config = { enabled: true, maxBytes: MAX_BYTES, hourlyLimit: 10, retentionDays: 30 }
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`
const sha = s => crypto.createHash('sha256').update(s).digest('hex')
function fixture(n = 1, ownerID = 'account-a') {
  return { schemaVersion: 1, resultID: id(n), ownerID, sourceItems: ['alpha bravo charlie delta'],
    providerCandidates: ['alpha bravo charlie 德尔塔'], displaySources: ['alpha bravo charlie delta'],
    displayCandidates: ['alpha bravo charlie 德尔塔'], target: 'zh-Hans', itemFailures: [['underTranslated']],
    additionalFailures: [], appVersion: 'MANUAL-test', origin: 'offline-manual-fixture', providerModel: 'NOT-A-PROVIDER' }
}
function context(store, payload = fixture(), options = {}) {
  const raw = JSON.stringify(payload)
  return { method: 'POST', headers: { authorization: 'Bearer OFFLINE-FAKE', 'x-feedback-snapshot': sha(raw) }, rawBody: raw,
    verifyUser: async () => ({ uid: 'account-a' }), env: { gateway: 'https://offline.invalid' }, now: () => 100000,
    qualityFeedbackStore: store, qualityFeedbackConfig: config, ...options }
}
const body = result => JSON.parse(result.body)

test('auth, capability, default-off and method guards never expose submitted text', async () => {
  const store = createMemoryQualityFeedbackStore()
  assert.equal(qualityFeedbackConfig({}).enabled, false)
  assert.equal(qualityFeedbackConfig({}).retentionDays, 30)
  assert.equal(qualityFeedbackConfig({}).hourlyLimit, 10)
  assert.equal((await handleQualityFeedback(context(store, fixture(), { headers: {} }))).status, 401)
  assert.equal((await handleQualityFeedback(context(store, fixture(), { verifyUser: async () => { throw Error('secret') } }))).status, 401)
  assert.equal((await handleQualityFeedback(context(store, fixture(), { qualityFeedbackConfig: { ...config, enabled: false } }))).status, 503)
  const cap = await handleQualityFeedback(context(store, fixture(), { method: 'GET', rawBody: '', capability: true }))
  assert.equal(cap.status, 200); assert.equal(body(cap).ownerID, 'account-a')
  assert.equal(body(cap).contentTrust, 'authenticated-submitter')
  assert.equal((await handleQualityFeedback(context(store, fixture(), { method: 'POST', capability: true }))).status, 405)
  assert.equal(store.inspect()[SNAPSHOTS].length, 0)
})

test('strict schema, owner, digest and multibyte full-envelope byte limits', async () => {
  const store = createMemoryQualityFeedbackStore()
  for (const mutation of [p => { p.images = [] }, p => { p.accountId = 'account-a' }, p => { p.schemaVersion = 2 },
    p => { p.itemFailures = [] }, p => { p.providerCandidates = [] }, p => { p.sourceItems = ['\ud800'] },
    p => { p.itemFailures = [['unknown']] }]) {
    const p = fixture(); mutation(p)
    const result = await handleQualityFeedback(context(store, p))
    assert.equal(result.status, 400); assert(!result.body.includes('alpha'))
  }
  assert.equal((await handleQualityFeedback(context(store, fixture(2, 'other')))).status, 403)
  const badDigest = context(store); badDigest.headers['x-feedback-snapshot'] = '0'.repeat(64)
  assert.equal((await handleQualityFeedback(badDigest)).status, 400)
  const exact = fixture(9); exact.providerCandidates = ['汉']
  const missingBytes = MAX_BYTES - Buffer.byteLength(JSON.stringify(exact))
  exact.providerCandidates[0] += 'a'.repeat(missingBytes)
  assert.equal(Buffer.byteLength(JSON.stringify(exact)), MAX_BYTES)
  assert.equal((await handleQualityFeedback(context(store, exact))).status, 200)
  exact.providerCandidates[0] += '字'
  assert.equal((await handleQualityFeedback(context(store, exact))).status, 413)
  const small = fixture(10); small.providerCandidates = ['汉字汉字']
  const raw = JSON.stringify(small)
  assert(Buffer.byteLength(raw) > raw.length)
  assert.equal((await handleQualityFeedback(context(store, small, { qualityFeedbackConfig: { ...config, maxBytes: raw.length } }))).status, 413)
})

test('same immutable retry is free of quota, collisions reject and accounts isolate', async () => {
  const store = createMemoryQualityFeedbackStore()
  const first = await handleQualityFeedback(context(store))
  const retry = await handleQualityFeedback(context(store))
  assert.equal(first.status, 200); assert.deepEqual(body(first), body(retry))
  assert.equal(store.inspect()[QUOTAS][0].events.length, 1)
  const changed = fixture(); changed.providerCandidates[0] += ' changed'
  assert.equal((await handleQualityFeedback(context(store, changed))).status, 409)
  const foreign = fixture(1, 'account-b')
  assert.equal((await handleQualityFeedback(context(store, foreign))).status, 403)
  const ownB = await handleQualityFeedback(context(store, foreign, { verifyUser: async () => ({ uid: 'account-b' }) }))
  assert.equal(ownB.status, 200); assert.equal(store.inspect()[SNAPSHOTS].length, 2)
  assert.equal(body(first).snapshotSHA256, sha(JSON.stringify(fixture())))
})

test('rolling hour and concurrent final slot cannot exceed quota; idempotent retry still works', async () => {
  const store = createMemoryQualityFeedbackStore()
  const results = await Promise.all(Array.from({ length: 12 }, (_, i) => handleQualityFeedback(context(store, fixture(i + 1)))))
  assert.equal(results.filter(r => r.status === 200).length, 10)
  assert.equal(results.filter(r => r.status === 429).length, 2)
  assert.equal((await handleQualityFeedback(context(store, fixture(1)))).status, 200)
  assert.equal((await handleQualityFeedback(context(store, fixture(99), { now: () => 100000 + HOUR - 1 }))).status, 429)
  assert.equal((await handleQualityFeedback(context(store, fixture(99), { now: () => 100000 + HOUR }))).status, 200)
})

test('bounded purge deletes expired bodies and quotas, keeps unexpired and enforces bounds', async () => {
  const store = createMemoryQualityFeedbackStore()
  await handleQualityFeedback(context(store, fixture(1), { now: () => 0 }))
  const later = 30 * 86400000
  await handleQualityFeedback(context(store, fixture(2), { now: () => later - 1000 }))
  const removed = await store.purge(later, 1)
  assert(removed.removed >= 1 && removed.removed <= 2)
  const docs = store.inspect()[SNAPSHOTS]
  assert.equal(docs.length, 1); assert.equal(docs[0].payload.resultID, id(2))
  assert.equal(store.inspect()[QUOTAS][0].events.length, 1)
  await assert.rejects(store.purge(later, 101))
})

// Optimistic transaction API fake, NOT a claim of actual CloudBase IAM/SDK execution.
function databaseFake() {
  const rows = new Map(); const versions = new Map()
  const key = (c, id) => `${c}:${id}`
  return { rows, command: { lte: n => ({ lte: n }) }, async createCollection() { return {} },
    collection(c) { return { where(query) { return { limit(n) { return { async get() {
      return { data: [...rows].filter(([k, v]) => k.startsWith(c + ':') && v.expiresAt <= query.expiresAt.lte)
        .slice(0, n).map(([k, v]) => ({ ...v, _id: k.slice(c.length + 1) })) }
    } } } } } } },
    async startTransaction() {
      const reads = new Map(); const writes = new Map()
      return {
        collection(c) { return { doc(id) { const k = key(c, id); return {
          async get() { reads.set(k, versions.get(k) || 0); return { data: rows.has(k) ? structuredClone(rows.get(k)) : {} } },
          async set(v) { writes.set(k, structuredClone(v)) }, async remove() { writes.set(k, null) }
        } } } },
        async commit() {
          for (const [k, v] of reads) if ((versions.get(k) || 0) !== v) throw Object.assign(Error('conflict'), { code: 'CONFLICT' })
          for (const [k, v] of writes) { if (v) rows.set(k, v); else rows.delete(k); versions.set(k, (versions.get(k) || 0) + 1) }
        }, async rollback() {}
      }
    }
  }
}

test('two independent CloudBase adapters share real transaction contention key and bounded purge shape', async () => {
  const db = databaseFake(); const a = createCloudQualityFeedbackStore(db); const b = createCloudQualityFeedbackStore(db)
  assert.equal(await a.available(), true)
  const limited = { ...config, hourlyLimit: 1 }
  const results = await Promise.all([a, b].map((s, i) => handleQualityFeedback(context(s, fixture(i + 1), { qualityFeedbackConfig: limited }))))
  assert.deepEqual(results.map(r => r.status).sort(), [200, 429])
  assert.equal([...db.rows.keys()].filter(k => k.startsWith(SNAPSHOTS + ':')).length, 1)
  const purged = await a.purge(31 * 86400000)
  assert.equal(purged.removed, 2); assert.equal(db.rows.size, 0)
  const duplicate = await Promise.all([a, b].map(s => handleQualityFeedback(context(s, fixture(3)))))
  assert(duplicate.every(r => r.status === 200)); assert.deepEqual(body(duplicate[0]), body(duplicate[1]))
  assert.equal([...db.rows.values()].find(v => v.events).events.length, 1)

})

test('cloud dispatch and direct HTTP listener route feedback only, without upstream, billing or body logs', async () => {
  const store = createMemoryQualityFeedbackStore(); const ctx = context(store)
  let forwarded = 0; const logs = []; const oldError = console.error
  console.error = (...args) => logs.push(args.join(' '))
  try {
    const deps = { qualityFeedbackStore: store, qualityFeedbackConfig: config, env: ctx.env, verifyUser: ctx.verifyUser,
      now: ctx.now, forward: async () => { forwarded++; throw Error('must not forward') } }
    const cloud = await dispatch({ httpMethod: 'POST', path: '/v1/trial/quality-feedback', headers: ctx.headers, body: ctx.rawBody }, deps)
    assert.equal(cloud.statusCode, 200)
    const cap = await dispatch({ httpMethod: 'GET', path: '/v1/trial/quality-feedback/capability', headers: ctx.headers }, deps)
    assert.equal(cap.statusCode, 200)
    const purge = await dispatch({ httpMethod: 'POST', path: '/v1/trial/quality-feedback/purge', headers: ctx.headers }, deps)
    assert.equal(purge.statusCode, 404)
    class Response extends Writable {
      constructor() { super(); this.chunks = [] }
      _write(chunk, _, done) { this.chunks.push(Buffer.from(chunk)); done() }
      writeHead(status) { this.status = status }
    }
    const req = Readable.from([Buffer.from(ctx.rawBody)]); req.method = 'POST'; req.url = '/v1/trial/quality-feedback'; req.headers = ctx.headers
    const res = new Response()
    await createRequestListener(deps)(req, res)
    assert.equal(res.status, 200)
    assert.equal(JSON.parse(Buffer.concat(res.chunks)).status, 'submitted')
    assert.equal(forwarded, 0); assert.equal(logs.length, 0)
  } finally { console.error = oldError }
})


test('storage exceptions have fixed public errors and no private body logs; unknown methods remain closed', async () => {
  const logs = []; const old = console.error
  console.error = (...args) => logs.push(args.join(' '))
  try {
    const store = { async submit() { throw Error('SENSITIVE BODY must not escape') } }
    const result = await handleQualityFeedback(context(store))
    assert.equal(result.status, 503); assert(!result.body.includes('SENSITIVE')); assert(!result.body.includes('alpha'))
    assert.equal(logs.length, 0)
    assert.equal((await handleQualityFeedback(context(store, fixture(), { method: 'GET' }))).status, 405)
  } finally { console.error = old }
})
