'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const http = require('http')
const { MemoryAccountStore } = require('../src/accountStore')
const { createRequestListener } = require('../src/httpApp')
const { dispatch } = require('../src/cloudEntry')
const { ErrorReportLimiter, buildErrorDocument } = require('../src/errorLog')
const { MemoryErrorLogStore } = require('../src/errorLogStore')

const NOW = Date.parse('2026-10-26T00:00:00.000Z')
const DEVICE = 'e479ad3e385f0b98932bc2d9e76121146b155bfc6e75e619e7d3f8efcaa20521'
const SENTINELS = ['private-source', 'sk-secret', '13800138000', '原文句子不要入库']

function eventBody(overrides = {}) {
  return {
    occurredAt: '2026-10-26T00:00:00.000Z',
    surface: 'selection_translate',
    appVersion: '0.4.0',
    appBuild: '10',
    osVersion: '15.1.0',
    path: 'trial',
    displayId: '00001',
    deviceHash: DEVICE,
    kind: 'business',
    category: 'quota',
    httpStatus: 429,
    ...overrides
  }
}

function listen(errorLog, options = {}) {
  const store = new MemoryAccountStore()
  const server = http.createServer(createRequestListener({
    store,
    errorLog,
    errorRateLimiter: options.limiter || new ErrorReportLimiter(),
    env: {
      envId: 'translatehud-d4gl951eo8bef4702',
      gateway: 'https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com',
      apiKey: 'server-secret-key',
      baseURL: 'https://api.deepseek.com/v1',
      model: 'server-model'
    },
    verifyUser: options.verifyUser || (async ({ token }) => {
      if (token !== 'good-token') throw new Error('nope')
      return { uid: options.uid || 'uid-1' }
    }),
    forward: async () => {
      throw new Error('translator must not run')
    },
    now: () => NOW
  }))
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      resolve({ server, base: `http://127.0.0.1:${port}` })
    })
  })
}

async function post(base, body, token) {
  const response = await fetch(`${base}/v1/trial/errors`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {})
    },
    body: JSON.stringify(body)
  })
  const text = await response.text()
  let json = null
  try { json = text ? JSON.parse(text) : null } catch { json = null }
  return { status: response.status, json, text }
}

function assertNoSentinels(value) {
  const encoded = JSON.stringify(value)
  for (const secret of SENTINELS) {
    assert.equal(encoded.includes(secret), false, secret)
  }
}

test('authenticated report stores the account id and drops source text', async () => {
  const errorLog = new MemoryErrorLogStore()
  const { server, base } = await listen(errorLog)
  try {
    const result = await post(base, eventBody({
      source: 'private-source 原文句子不要入库',
      text: '原文句子不要入库',
      translation: 'do not keep',
      apiKey: 'sk-secret',
      phone: '13800138000',
      prompt: '原文句子不要入库',
      userId: 'attacker-id',
      summary: 'private-source sk-secret'
    }), 'good-token')
    assert.equal(result.status, 200)
    assert.equal(result.json.ok, true)
    assert.equal(errorLog.events.length, 1)
    const saved = errorLog.events[0]
    assert.equal(saved.userId, 'uid-1')
    assert.equal(saved.displayId, '00001')
    assert.equal(saved.path, 'trial')
    assert.equal(saved.kind, 'business')
    assert.equal(saved.category, 'quota')
    assert.equal(saved.httpStatus, 429)
    assert.equal(saved.summary, null)
    assert.equal(saved.surface, 'selection_translate')
    assert.equal(saved.appVersion, '0.4.0')
    assert.equal(saved.appBuild, '10')
    assert.equal(saved.osVersion, '15.1.0')
    assert.equal(Object.hasOwn(saved, 'source'), false)
    assert.equal(Object.hasOwn(saved, 'apiKey'), false)
    assert.equal(Object.hasOwn(saved, 'phone'), false)
    assertNoSentinels(saved)
  } finally {
    server.close()
  }
})

test('bug summary keeps a module tag and rejects plaintext', () => {
  const kept = buildErrorDocument(eventBody({
    path: 'own_key',
    kind: 'bug',
    category: 'parse',
    summary: 'TranslationError.parse',
    source: 'private-source',
    messages: [{ content: '原文句子不要入库 sk-secret' }]
  }), { uid: null, now: NOW })
  assert.equal(kept.ok, true)
  assert.equal(kept.event.summary, 'TranslationError.parse')
  assert.equal(kept.event.userId, null)
  assert.equal(kept.event.displayId, null)
  assertNoSentinels(kept.event)

  const leaked = buildErrorDocument(eventBody({
    path: 'own_key',
    kind: 'bug',
    category: 'parse',
    summary: 'TranslationError.parse private-source 原文句子不要入库'
  }), { uid: null, now: NOW })
  assert.equal(leaked.ok, true)
  assert.equal(leaked.event.summary, null)
  assertNoSentinels(leaked.event)
})

test('own-key failures can be anonymous and a phone-shaped display id is dropped', async () => {
  const errorLog = new MemoryErrorLogStore()
  const { server, base } = await listen(errorLog)
  try {
    const result = await post(base, eventBody({
      path: 'own_key',
      surface: 'selection_translate',
      kind: 'bug',
      category: 'parse',
      summary: 'TranslationError.parse',
      displayId: '13800138000',
      httpStatus: null
    }))
    assert.equal(result.status, 200)
    assert.equal(errorLog.events.length, 1)
    assert.equal(errorLog.events[0].userId, null)
    assert.equal(errorLog.events[0].displayId, null)
    assert.equal(errorLog.events[0].path, 'own_key')
    assert.equal(errorLog.events[0].summary, 'TranslationError.parse')
    assert.equal(errorLog.events[0].deviceHash, DEVICE)
    assertNoSentinels(errorLog.events[0])
  } finally {
    server.close()
  }
})

test('a presented token that fails verification is not stored as anonymous', async () => {
  const errorLog = new MemoryErrorLogStore()
  const { server, base } = await listen(errorLog)
  try {
    const result = await post(base, eventBody({ path: 'own_key' }), 'bad-token')
    assert.equal(result.status, 401)
    assert.equal(errorLog.events.length, 0)
    assertNoSentinels(result.json)
  } finally {
    server.close()
  }
})

test('anonymous reports without a device hash are rejected', async () => {
  const errorLog = new MemoryErrorLogStore()
  const { server, base } = await listen(errorLog)
  try {
    const result = await post(base, eventBody({ deviceHash: 'nope', path: 'trial' }))
    assert.equal(result.status, 401)
    assert.equal(errorLog.events.length, 0)
  } finally {
    server.close()
  }
})

test('the same bug is kept only a few times per account per day', async () => {
  const errorLog = new MemoryErrorLogStore()
  const limiter = new ErrorReportLimiter({ bugCap: 3, businessCap: 12, hourlyCap: 300 })
  const { server, base } = await listen(errorLog, { limiter })
  try {
    const body = eventBody({ kind: 'bug', category: 'parse', summary: 'TranslationError.parse' })
    for (let i = 0; i < 3; i += 1) {
      const result = await post(base, body, 'good-token')
      assert.equal(result.status, 200)
      assert.equal(result.json.dropped, undefined)
    }
    const dropped = await post(base, body, 'good-token')
    assert.equal(dropped.status, 200)
    assert.equal(dropped.json.dropped, true)
    assert.equal(errorLog.events.length, 3)
    assertNoSentinels(errorLog.events)
  } finally {
    server.close()
  }
})

test('cloud entry records an error without calling the translator', async () => {
  const errorLog = new MemoryErrorLogStore()
  const result = await dispatch({
    httpMethod: 'POST',
    path: '/v1/trial/errors',
    headers: { Authorization: 'Bearer good-token' },
    body: JSON.stringify(eventBody({
      kind: 'bug',
      category: 'unknown',
      summary: 'LeakyError',
      source: 'private-source 原文句子不要入库',
      apiKey: 'sk-secret'
    }))
  }, {
    store: new MemoryAccountStore(),
    errorLog,
    errorRateLimiter: new ErrorReportLimiter(),
    verifyUser: async ({ token }) => {
      if (token !== 'good-token') throw new Error('nope')
      return { uid: 'uid-9' }
    },
    forward: async () => {
      throw new Error('translator must not run')
    },
    env: {
      gateway: 'https://example.invalid',
      apiKey: 'server-secret-key',
      baseURL: 'https://api.deepseek.com/v1',
      model: 'server-model'
    },
    now: () => NOW
  })
  assert.equal(result.statusCode, 200)
  assert.equal(errorLog.events.length, 1)
  assert.equal(errorLog.events[0].userId, 'uid-9')
  assert.equal(errorLog.events[0].summary, 'LeakyError')
  assertNoSentinels(errorLog.events[0])
  assert.equal(result.body.includes('private-source'), false)
  assert.equal(result.body.includes('server-secret-key'), false)
})

test('a phone-shaped account id from the auth provider is not stored', () => {
  const built = buildErrorDocument(eventBody(), { uid: '13800138000', now: NOW })
  assert.equal(built.ok, true)
  assert.equal(built.event.userId, null)
  assert.equal(built.event.displayId, null)
  assert.equal(built.event.deviceHash, DEVICE)
  assertNoSentinels(built.event)
})
