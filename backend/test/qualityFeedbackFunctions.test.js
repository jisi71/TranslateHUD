'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('crypto')
const { createFeedbackReceiver, SUBMIT, CAPABILITY } = require('../functions/quality-feedback-receiver/src/qualityFeedbackReceiver')
const { createMemoryQualityFeedbackStore, SNAPSHOTS, QUOTAS } = require('../functions/quality-feedback-receiver/src/qualityFeedbackStore')
const { createCleanupHandler, cleanupConfig } = require('../functions/quality-feedback-cleanup/src/qualityFeedbackCleanup')
const { verifyFeedbackUser } = require('../functions/quality-feedback-receiver/src/qualityFeedbackAuth')

const env = { CLOUDBASE_ENV_ID: 'acceptance-offline', QUALITY_FEEDBACK_ENABLED: 'true' }
const payload = {
  schemaVersion: 1, resultID: '00000000-0000-4000-8000-000000000001', ownerID: 'offline-user',
  sourceItems: ['Synthetic source sentence'], providerCandidates: ['合成译文。'],
  displaySources: ['Synthetic source sentence'], displayCandidates: ['合成译文。'],
  target: 'zh-Hans', itemFailures: [['underTranslated']], additionalFailures: [],
  appVersion: 'offline', origin: 'offline', providerModel: 'no-model'
}
const raw = JSON.stringify(payload)
const digest = crypto.createHash('sha256').update(raw).digest('hex')
const event = overrides => ({ httpMethod: 'POST', path: SUBMIT, body: raw,
  headers: { Authorization: 'Bearer OFFLINE', 'X-Feedback-Snapshot': digest }, ...overrides })

test('deployed receiver packages preserve exact UTF8 bytes and idempotent quota', async () => {
  const store = createMemoryQualityFeedbackStore()
  const handler = createFeedbackReceiver({ readEnvironment: () => env, now: () => 1000,
    verifyUser: async () => ({ uid: 'offline-user' }), storeFactory: () => store })
  const first = await handler(event())
  const again = await handler(event({ body: Buffer.from(raw).toString('base64'), isBase64Encoded: true }))
  assert.equal(first.statusCode, 200)
  assert.deepEqual(again, first)
  assert.equal(store.inspect()[SNAPSHOTS].length, 1)
  assert.equal(store.inspect()[QUOTAS][0].events.length, 1)
  const capability = await handler(event({ httpMethod: 'GET', path: CAPABILITY, body: '' }))
  assert.equal(capability.statusCode, 200)
  assert.equal(JSON.parse(capability.body).retentionDays, 30)
})

test('deployed receiver refuses ambiguous envelopes before touching the database', async () => {
  let dbCalls = 0
  const handler = createFeedbackReceiver({ readEnvironment: () => env,
    verifyUser: async () => ({ uid: 'offline-user' }), storeFactory: () => { dbCalls++; throw Error('PRIVATE') } })
  for (const mutation of [
    { body: payload }, { body: raw, isBase64Encoded: 'false' },
    { body: Buffer.from(raw).toString('base64') + '\n', isBase64Encoded: true },
    { body: '/w==', isBase64Encoded: true }, { body: '\ud800' },
    { body: 'a'.repeat(262145) },
    { headers: { Authorization: 'Bearer OFFLINE', authorization: 'Bearer OTHER' } },
    { headers: { authorization: ['Bearer OFFLINE'] } }
  ]) {
    const result = await handler(event(mutation))
    assert.equal(result.statusCode, 400)
    assert(!result.body.includes('PRIVATE'))
    assert(!result.body.includes('Synthetic'))
  }
  assert.equal((await handler(event({ httpMethod: 'DELETE' }))).statusCode, 405)
  assert.equal((await handler(event({ path: SUBMIT + '/purge' }))).statusCode, 404)
  assert.equal((await handler(event({ method: 'GET' }))).statusCode, 405)
  assert.equal(dbCalls, 0)
})

test('disabled and unauthorized deployed receiver cannot initialize database', async () => {
  let verified = 0
  const deps = { readEnvironment: () => ({ ...env, QUALITY_FEEDBACK_ENABLED: 'false' }),
    verifyUser: async () => { verified++; throw Error('PRIVATE') },
    storeFactory: () => { throw Error('must not reach database') } }
  assert.equal((await createFeedbackReceiver(deps)(event())).statusCode, 503)
  assert.equal(verified, 0)
  const active = createFeedbackReceiver({ ...deps, readEnvironment: () => env })
  assert.equal((await active(event({ headers: {} }))).statusCode, 401)
  assert.equal((await active(event())).statusCode, 401)
  assert.equal(verified, 1)
})

test('managed authentication rejects redirects, failures and missing identities', async () => {
  let request
  const user = await verifyFeedbackUser({ gateway: 'https://offline.invalid', token: 'OFFLINE',
    fetchImpl: async (url, options) => {
      request = { url, options }
      return { ok: true, json: async () => ({ sub: 'offline-user' }) }
    } })
  assert.equal(user.uid, 'offline-user')
  assert.equal(request.url, 'https://offline.invalid/auth/v1/user/me')
  assert.equal(request.options.redirect, 'error')
  for (const response of [{ ok: false }, { ok: true, json: async () => ({}) }]) {
    await assert.rejects(verifyFeedbackUser({ gateway: 'https://offline.invalid', token: 'OFFLINE', fetchImpl: async () => response }))
  }
})

test('cleanup uses server time and fixed configuration, ignoring all supplied event fields', async () => {
  const active = { CLOUDBASE_ENV_ID: 'acceptance-offline', QUALITY_FEEDBACK_CLEANUP_ENABLED: 'true' }
  let call
  const handler = createCleanupHandler({ readEnvironment: () => active, now: () => 1000,
    storeFactory: config => ({ purge: async (now, limit) => { call = { config, now, limit }; return { removed: 2 } } }) })
  const result = await handler({ now: Number.MAX_SAFE_INTEGER, limit: 10000, envId: 'other-environment' })
  assert.equal(result.status, 'completed')
  assert.equal(call.now, 1000)
  assert.equal(call.limit, 100)
  assert.equal(call.config.envId, active.CLOUDBASE_ENV_ID)
  assert.deepEqual(cleanupConfig({}), { enabled: false })
  assert.throws(() => cleanupConfig({ ...active, QUALITY_FEEDBACK_CLEANUP_BATCH_LIMIT: '101' }))
  const failed = createCleanupHandler({ readEnvironment: () => active,
    storeFactory: () => ({ purge: async () => { throw Error('PRIVATE DATA') } }) })
  await assert.rejects(failed({}), error => error.message === 'quality_feedback_cleanup_failed')
})
