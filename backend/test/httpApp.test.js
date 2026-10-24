'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const http = require('http')
const { PassThrough } = require('stream')
const { MemoryAccountStore } = require('../src/accountStore')
const { createRequestListener } = require('../src/httpApp')
const { GIFT_FEN, MESSAGES } = require('../src/trialPolicy')
const { prepareUpstreamPayload } = require('../src/upstream')

function sourceHeader(text) {
  return Buffer.from(text, 'utf8').toString('base64')
}

function listen(store, options = {}) {
  const calls = []
  const env = {
    envId: 'translatehud-d4gl951eo8bef4702',
    gateway: 'https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com',
    apiKey: 'server-secret-key',
    baseURL: 'https://api.deepseek.com/v1',
    model: 'server-model',
    ...options.env
  }
  const verifyUser = options.verifyUser || (async ({ token }) => {
    if (token !== 'good-token') throw new Error('nope')
    return { uid: 'uid-1' }
  })
  const forward = options.forward || (async ({ endpoint, apiKey, payload, signal }) => {
    if (signal && signal.aborted) {
      throw new Error('request body completion aborted the upstream call')
    }
    calls.push({ endpoint, apiKey, payload })
    return {
      status: 200,
      text: JSON.stringify({ choices: [{ message: { content: '你好' } }] })
    }
  })
  const server = http.createServer(createRequestListener({
    store,
    env,
    verifyUser,
    forward,
    now: () => 1234
  }))
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      resolve({
        server,
        calls,
        base: `http://127.0.0.1:${port}`
      })
    })
  })
}

async function request(base, path, { token, source, body, method } = {}) {
  const payload = body == null ? null : Buffer.from(JSON.stringify(body))
  const response = await fetch(`${base}${path}`, {
    method: method || 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(source != null ? { 'X-TranslateHUD-Source': sourceHeader(source) } : {})
    },
    body: payload
  })
  const text = await response.text()
  let json = null
  try { json = JSON.parse(text) } catch { json = null }
  return { status: response.status, text, json, headers: response.headers }
}

test('first account call gifts ¥2 once and the second call does not', async () => {
  const store = new MemoryAccountStore()
  const { server, base } = await listen(store)
  try {
    const first = await request(base, '/v1/trial/account', { token: 'good-token', body: {} })
    assert.equal(first.status, 200)
    assert.equal(first.json.giftedNow, true)
    assert.equal(first.json.balanceFen, GIFT_FEN)
    assert.equal(first.json.userId, 'uid-1')

    const second = await request(base, '/v1/trial/account', { token: 'good-token', body: {} })
    assert.equal(second.json.giftedNow, false)
    assert.equal(second.json.balanceFen, GIFT_FEN)
  } finally {
    server.close()
  }
})

test('trial translation bills the source, hides the server key, and lowers the balance', async () => {
  const store = new MemoryAccountStore()
  const { server, base, calls } = await listen(store)
  try {
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好世界',
      body: { model: 'client-model', messages: [{ role: 'user', content: 'prompt' }] }
    })
    assert.equal(result.status, 200)
    assert.equal(result.headers.get('x-trial-balance-fen'), String(GIFT_FEN - 1))
    assert.equal(calls.length, 1)
    assert.equal(calls[0].apiKey, 'server-secret-key')
    assert.equal(calls[0].payload.model, 'server-model')
    assert.equal(calls[0].endpoint, 'https://api.deepseek.com/v1/chat/completions')
    assert.equal(JSON.stringify(calls[0].payload).includes('good-token'), false)
    assert.equal(calls[0].payload.thinking.type, 'disabled')
    const saved = await store.ensure('uid-1')
    assert.equal(saved.giftedNow, false)
    assert.equal(saved.record.balanceFen, GIFT_FEN - 1)
  } finally {
    server.close()
  }
})

test('over 500 graphemes is rejected, the upstream is not called, and nothing is gifted or charged', async () => {
  const store = new MemoryAccountStore()
  const { server, base, calls } = await listen(store)
  try {
    const source = '字'.repeat(501)
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source,
      body: { model: 'client-model', messages: [] }
    })
    assert.equal(result.status, 400)
    assert.equal(result.json.error.code, 'trial_length_limit')
    assert.equal(result.json.error.message, MESSAGES.length)
    assert.equal(result.text.includes('字'.repeat(50)), false)
    assert.equal(calls.length, 0)
    assert.equal(store.users.has('uid-1'), false)
  } finally {
    server.close()
  }
})

test('a zero balance does not call the upstream', async () => {
  const store = new MemoryAccountStore()
  await store.ensure('uid-1', 1)
  await store.charge('uid-1', GIFT_FEN)
  const { server, base, calls } = await listen(store)
  try {
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好',
      body: { model: 'm', messages: [] }
    })
    assert.equal(result.status, 402)
    assert.equal(result.json.error.code, 'trial_balance_exhausted')
    assert.equal(result.json.error.message, MESSAGES.exhausted)
    assert.equal(calls.length, 0)
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceFen, 0)
  } finally {
    server.close()
  }
})

test('a short balance does not call the upstream', async () => {
  const store = new MemoryAccountStore()
  await store.ensure('uid-1', 1)
  await store.charge('uid-1', GIFT_FEN - 1)
  const { server, base, calls } = await listen(store)
  try {
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '字'.repeat(20),
      body: { model: 'm', messages: [] }
    })
    assert.equal(result.status, 402)
    assert.equal(result.json.error.code, 'trial_balance_insufficient')
    assert.equal(calls.length, 0)
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceFen, 1)
  } finally {
    server.close()
  }
})

test('upstream failure refunds the charge', async () => {
  const store = new MemoryAccountStore()
  const { server, base } = await listen(store, {
    forward: async () => ({ status: 500, text: '{"error":{"message":"secret upstream"}}' })
  })
  try {
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好',
      body: { model: 'm', messages: [{ role: 'user', content: '你好' }] }
    })
    assert.equal(result.status, 502)
    assert.equal(result.json.error.code, 'trial_upstream')
    assert.equal(result.text.includes('secret upstream'), false)
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceFen, GIFT_FEN)
  } finally {
    server.close()
  }
})

test('reading the request body does not cancel the upstream call', async () => {
  const store = new MemoryAccountStore()
  let abortedDuringCall = true
  const { server, base } = await listen(store, {
    forward: async ({ signal }) => {
      await new Promise((resolve) => setTimeout(resolve, 40))
      abortedDuringCall = Boolean(signal && signal.aborted)
      return {
        status: 200,
        text: JSON.stringify({ choices: [{ message: { content: 'ok' } }] })
      }
    }
  })
  try {
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好',
      body: { model: 'client', messages: [] }
    })
    assert.equal(result.status, 200)
    assert.equal(abortedDuringCall, false)
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceFen, GIFT_FEN - 1)
  } finally {
    server.close()
  }
})

test('closing the client after streaming starts does not refund the charge', async () => {
  const store = new MemoryAccountStore()
  const stream = new PassThrough()
  const { server, base } = await listen(store, {
    forward: async () => {
      setTimeout(() => {
        stream.write('data: {"choices":[{"delta":{"content":"你"}}]}\n\n')
      }, 15)
      return { status: 200, stream }
    }
  })
  const controller = new AbortController()
  try {
    const response = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer good-token',
        'Content-Type': 'application/json',
        'X-TranslateHUD-Source': sourceHeader('Hi')
      },
      body: JSON.stringify({ model: 'client', stream: true, messages: [] }),
      signal: controller.signal
    })
    assert.equal(response.status, 200)
    const reader = response.body.getReader()
    let seen = ''
    while (!seen.includes('你')) {
      const chunk = await reader.read()
      if (chunk.done) break
      seen += Buffer.from(chunk.value).toString('utf8')
    }
    controller.abort()
    try { await reader.read() } catch { /* client is gone */ }
    await new Promise((resolve) => setTimeout(resolve, 40))
    stream.destroy(new Error('upstream reset after the client left'))
    await new Promise((resolve) => setTimeout(resolve, 40))
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceFen, GIFT_FEN - 1)
  } finally {
    controller.abort()
    server.close()
  }
})

test('streaming proxy lets the client read the first chunk before the upstream finishes', async () => {
  const store = new MemoryAccountStore()
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const stream = new PassThrough()
  const { server, base } = await listen(store, {
    forward: async ({ payload, apiKey }) => {
      assert.equal(payload.stream, true)
      assert.equal(apiKey, 'server-secret-key')
      setTimeout(() => {
        stream.write('data: {"choices":[{"delta":{"content":"你"}}]}\n\n')
      }, 10)
      gate.then(() => {
        stream.write('data: [DONE]\n\n')
        stream.end()
      })
      return { status: 200, stream }
    }
  })
  try {
    const response = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer good-token',
        'Content-Type': 'application/json',
        'X-TranslateHUD-Source': sourceHeader('Hi')
      },
      body: JSON.stringify({ model: 'client', stream: true, messages: [] })
    })
    assert.equal(response.status, 200)
    assert.equal(response.headers.get('content-type').includes('text/event-stream'), true)
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let seen = ''
    const first = await Promise.race([
      (async () => {
        while (!seen.includes('你')) {
          const chunk = await reader.read()
          if (chunk.done) break
          seen += decoder.decode(chunk.value)
        }
        return seen
      })(),
      new Promise((_, reject) => setTimeout(() => reject(new Error('response was buffered')), 1000))
    ])
    assert.match(first, /你/)
    release()
    while (true) {
      const chunk = await reader.read()
      if (chunk.done) break
      seen += decoder.decode(chunk.value)
    }
    assert.match(seen, /\[DONE\]/)
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceFen, GIFT_FEN - 1)
  } finally {
    release()
    server.close()
  }
})

test('missing translation key refuses before charging', async () => {
  const store = new MemoryAccountStore()
  const { server, base, calls } = await listen(store, { env: { apiKey: '' } })
  try {
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好',
      body: { model: 'm', messages: [] }
    })
    assert.equal(result.status, 503)
    assert.equal(result.json.error.code, 'trial_not_configured')
    assert.equal(calls.length, 0)
    assert.equal(store.users.has('uid-1'), false)
  } finally {
    server.close()
  }
})

test('cloud function dispatch gifts once through the same account handler', async () => {
  const { dispatch } = require('../src/cloudEntry')
  const store = new MemoryAccountStore()
  const env = {
    envId: 'translatehud-d4gl951eo8bef4702',
    gateway: 'https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com',
    apiKey: 'server-secret-key',
    baseURL: 'https://api.deepseek.com/v1',
    model: 'server-model'
  }
  const result = await dispatch({
    httpMethod: 'POST',
    path: '/v1/trial/account',
    headers: { Authorization: 'Bearer good-token' },
    body: '{}'
  }, {
    store,
    env,
    verifyUser: async () => ({ uid: 'uid-9' }),
    now: () => 1
  })
  assert.equal(result.statusCode, 200)
  const body = JSON.parse(result.body)
  assert.equal(body.giftedNow, true)
  assert.equal(body.balanceFen, GIFT_FEN)
  assert.equal(body.userId, 'uid-9')
})

test('a database failure becomes trial_store and hides the driver message', async () => {
  const store = {
    async ensure() {
      const error = new Error('secret-db-detail')
      error.code = 'DATABASE_COLLECTION_NOT_EXIST'
      throw error
    }
  }
  const { server, base, calls } = await listen(store)
  try {
    const result = await request(base, '/v1/trial/account', { token: 'good-token', body: {} })
    assert.equal(result.status, 503)
    assert.equal(result.json.error.code, 'trial_store')
    assert.equal(result.json.error.message, MESSAGES.store)
    assert.equal(result.text.includes('secret-db-detail'), false)
    assert.equal(result.text.includes('DATABASE_COLLECTION_NOT_EXIST'), false)
    assert.equal(calls.length, 0)
  } finally {
    server.close()
  }
})

test('cloud dispatch turns an unexpected throw into trial_store', async () => {
  const { dispatch } = require('../src/cloudEntry')
  const result = await dispatch({
    httpMethod: 'POST',
    path: '/v1/trial/account',
    headers: { Authorization: 'Bearer good-token' },
    body: '{}'
  }, {
    get store() {
      throw Object.assign(new Error('secret-db-detail'), { code: 'BOOM' })
    },
    verifyUser: async () => ({ uid: 'uid-1' })
  })
  assert.equal(result.statusCode, 503)
  const body = JSON.parse(result.body)
  assert.equal(body.error.code, 'trial_store')
  assert.equal(body.error.message, MESSAGES.store)
  assert.equal(result.body.includes('secret-db-detail'), false)
})

test('prepareUpstreamPayload overwrites the client model', () => {
  const prepared = prepareUpstreamPayload(JSON.stringify({
    model: 'client-model',
    messages: [{ role: 'user', content: 'json please' }]
  }), {
    model: 'server-model',
    endpoint: 'https://api.deepseek.com/v1/chat/completions',
    apiKey: 'k'
  })
  assert.equal(prepared.payload.model, 'server-model')
  assert.equal(prepared.stream, false)
  assert.deepEqual(prepared.payload.thinking, { type: 'disabled' })
  assert.deepEqual(prepared.payload.response_format, { type: 'json_object' })
})
