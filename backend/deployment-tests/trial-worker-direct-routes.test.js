'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { once } = require('node:events')
const http = require('node:http')
const path = require('node:path')

const root = process.env.TRIAL_DIRECT_WORKER_ROOT

test('direct translation reaches JWT verification and the internal path still requires its signature', { skip: !root }, async t => {
  const { restrictWorker, signJob, workerKey } = require(path.join(root, 'workerGate.js'))
  const { createRequestListener } = require(path.join(root, 'src/httpApp.js'))
  const key = 'fixture-only'
  const authorization = 'Bearer fixture-user'
  let providerCalls = 0

  const listener = createRequestListener({
    env: {},
    verifyUser: async ({ token }) => token === 'fixture-user' ? { uid: 'fixture' } : null,
    forward: async () => { providerCalls += 1; throw new Error('unexpected translation') }
  })
  const server = http.createServer(restrictWorker(listener, key)).listen(0, '127.0.0.1')
  t.after(() => server.close())
  await once(server, 'listening')
  const gateway = 'http://127.0.0.1:' + server.address().port
  const post = (route, headers = {}) => fetch(gateway + route, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: '{}'
  })

  for (const route of ['/v1/chat/completions', '/v1-screenshot/chat/completions?fixture=1']) {
    for (const headers of [{}, { Authorization: 'Bearer fixture-invalid' }]) {
      const denied = await post(route, headers)
      assert.equal(denied.status, 401)
      assert.equal((await denied.json()).error.code, 'trial_auth')
    }
    const empty = await post(route, { Authorization: authorization })
    assert.equal(empty.status, 400)
    assert.equal((await empty.json()).error.code, 'trial_source_required')
    assert.equal(empty.headers.get('x-translatehud-worker-ack'), null)
  }
  for (const route of ['/v1/trial/account', '/other/chat/completions', '/v1/chat/completions/']) {
    const blocked = await post(route, { Authorization: authorization })
    assert.equal(blocked.status, 404)
    await blocked.json()
  }
  const get = await fetch(gateway + '/v1/chat/completions')
  assert.equal(get.status, 404)
  await get.json()

  const internal = '/v1-queued-worker/chat/completions'
  const jobId = '59d05f7d-8ba0-4605-a80c-8f274047ee31'
  const timestamp = String(Date.now())
  const internalHeaders = {
    Authorization: authorization, 'X-TranslateHUD-Queue-Job': jobId, 'X-TranslateHUD-Worker-Time': timestamp
  }
  for (const signature of [undefined, 'a'.repeat(64)]) {
    const response = await post(internal, { ...internalHeaders, ...(signature && { 'X-TranslateHUD-Worker-Signature': signature }) })
    assert.equal(response.status, 404)
    await response.json()
  }
  const signed = await post(internal, {
    ...internalHeaders, 'X-TranslateHUD-Worker-Signature': signJob(workerKey(key), jobId, timestamp, authorization)
  })
  assert.equal(signed.headers.get('x-translatehud-worker-ack'), jobId)
  assert.equal(signed.status, 400)
  assert.equal((await signed.json()).error.code, 'trial_source_required')
  assert.equal(providerCalls, 0)
})
