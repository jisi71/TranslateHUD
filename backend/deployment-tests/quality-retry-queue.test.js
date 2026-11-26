'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { EventEmitter, once } = require('node:events')
const { Readable } = require('node:stream')
const http = require('node:http')
const https = require('node:https')
const path = require('node:path')
const root = process.env.TRIAL_RETRY_QUEUE_ROOT

test('production queue forwards only retry protocol headers and preserves the body', { skip: !root }, async t => {
  const { createListener } = require(path.join(root, 'index.js'))
  const forwarded = []
  t.mock.method(https, 'request', (_url, options, callback) => {
    const request = new EventEmitter()
    request.end = body => {
      forwarded.push({ headers: options.headers, body: body.toString() })
      const response = Readable.from(['fixture'])
      response.headers = { 'x-translatehud-worker-ack': options.headers['X-TranslateHUD-Queue-Job'] }
      response.statusCode = 200
      response.complete = true
      callback(response)
      request.emit('close')
    }
    return request
  })
  const productionQueue = {
    enqueue: async () => ({ waitUntil: Date.now() + 5000 }),
    waitForSlot: async () => ({ leaseUntil: Date.now() + 180000 }),
    release: async () => {}
  }
  const listener = createListener({ productionQueue, workerSecret: Buffer.from('local-test-key'), onEvent() {} })
  const server = http.createServer(listener).listen(0, '127.0.0.1')
  t.after(() => server.close())
  await once(server, 'listening')
  for (const route of ['/v1/chat/completions', '/v1-screenshot/chat/completions']) {
    const body = '{"translatehud_quality_retry":true}'
    const headers = { Authorization: 'Bearer example', 'X-TranslateHUD-Retry-Of': 'retry',
      'X-TranslateHUD-Request-Id': 'first', 'X-Do-Not-Forward': 'example' }
    const response = await fetch(`http://127.0.0.1:${server.address().port}${route}`, { method: 'POST', headers, body })
    assert.equal(response.status, 200)
    assert.equal(await response.text(), 'fixture')
    const observed = forwarded.at(-1)
    assert.equal(observed.headers['x-translatehud-retry-of'], 'retry')
    assert.equal(observed.headers['x-translatehud-request-id'], 'first')
    assert.equal(observed.headers['x-do-not-forward'], undefined)
    assert.equal(observed.body, body)
  }
})
