'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const http = require('http')
const { PassThrough } = require('stream')
const { MemoryAccountStore } = require('../src/accountStore')
const { createRequestListener } = require('../src/httpApp')
const { GIFT_MICRO_YUAN, MESSAGES } = require('../src/trialPolicy')
const { DEFAULT_INVITE_CODE } = require('../src/invite')

function sourceHeader(text) {
  return Buffer.from(text, 'utf8').toString('base64')
}

function modelJSON(content) {
  return JSON.stringify({
    choices: [{ message: { content }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
  })
}

function listen(store, options = {}) {
  const calls = []
  let entered = 0
  const env = {
    envId: 'translatehud-d4gl951eo8bef4702',
    gateway: 'https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com',
    apiKey: 'server-secret-key',
    baseURL: 'https://api.deepseek.com/v1',
    model: 'server-model',
    ...options.env
  }
  const verifyUser = options.verifyUser || (async ({ token }) => {
    if (token === 'good-token') return { uid: 'uid-1' }
    if (token === 'other-token') return { uid: 'uid-2' }
    throw new Error('nope')
  })
  const inner = options.forward || (async () => ({ status: 200, text: modelJSON('你好') }))
  const forward = async (args) => {
    entered += 1
    calls.push(args)
    return inner(args)
  }
  const server = http.createServer(createRequestListener({
    store,
    env,
    verifyUser,
    forward,
    now: options.now || (() => 1_000)
  }))
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      resolve({
        server,
        calls,
        entered: () => entered,
        base: `http://127.0.0.1:${port}`
      })
    })
  })
}

async function request(base, path, { token, source, body, method } = {}) {
  const response = await fetch(`${base}${path}`, {
    method: method || 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(source != null ? { 'X-TranslateHUD-Source': sourceHeader(source) } : {})
    },
    body: method === 'GET' || method === 'OPTIONS' ? undefined : JSON.stringify(body == null ? {} : body)
  })
  const text = await response.text()
  let json = null
  try { json = JSON.parse(text) } catch { json = null }
  return { status: response.status, text, json, headers: response.headers }
}

test('the default invite code gifts ¥2 once and a repeat does not', async () => {
  const store = new MemoryAccountStore()
  const { server, base } = await listen(store)
  try {
    assert.equal(DEFAULT_INVITE_CODE, 'translatehud-200')
    const ok = await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: '  translatehud-200  ' }
    })
    assert.equal(ok.status, 200)
    assert.equal(ok.json.giftedNow, true)
    assert.equal(ok.json.inviteRedeemed, true)
    assert.equal(ok.json.balanceMicroYuan, GIFT_MICRO_YUAN)
    assert.equal(ok.json.giftMicroYuan, GIFT_MICRO_YUAN)

    const again = await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: 'translatehud-200' }
    })
    assert.equal(again.status, 409)
    assert.equal(again.json.error.code, 'trial_invite_claimed')
    assert.equal(again.json.error.message, MESSAGES.inviteClaimed)
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceMicroYuan, GIFT_MICRO_YUAN)
    assert.equal(store.invite.redeemedCount, 1)
  } finally {
    server.close()
  }
})

test('redeem without a login is rejected and does not count', async () => {
  const store = new MemoryAccountStore()
  const { server, base } = await listen(store)
  try {
    const missing = await request(base, '/v1/trial/redeem', { body: { code: 'translatehud-200' } })
    assert.equal(missing.status, 401)
    assert.equal(missing.json.error.code, 'trial_auth')
    const bad = await request(base, '/v1/trial/redeem', {
      token: 'nope',
      body: { code: 'translatehud-200' }
    })
    assert.equal(bad.status, 401)
    assert.equal(store.invite.redeemedCount, 0)
    assert.equal(store.users.size, 0)
  } finally {
    server.close()
  }
})

test('a wrong code does not gift, and an exhausted code does not gift the next account', async () => {
  const store = new MemoryAccountStore()
  const { server, base } = await listen(store, {
    env: { TRIAL_INVITE_MAX_REDEEMS: '1' }
  })
  try {
    const wrong = await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: 'not-the-code' }
    })
    assert.equal(wrong.status, 400)
    assert.equal(wrong.json.error.code, 'trial_invite_invalid')
    assert.equal(store.invite.redeemedCount, 0)

    const ok = await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: 'translatehud-200' }
    })
    assert.equal(ok.status, 200)

    const exhausted = await request(base, '/v1/trial/redeem', {
      token: 'other-token',
      body: { code: 'translatehud-200' }
    })
    assert.equal(exhausted.status, 403)
    assert.equal(exhausted.json.error.code, 'trial_invite_exhausted')
    assert.equal(exhausted.json.error.message, '邀请码次数用尽')
    const other = await store.ensure('uid-2')
    assert.equal(other.record.balanceMicroYuan, 0)
    assert.equal(other.record.giftGranted, false)
    assert.equal(store.invite.redeemedCount, 1)
  } finally {
    server.close()
  }
})

test('an older gifted account cannot take a second ¥2', async () => {
  const store = new MemoryAccountStore()
  store.users.set('uid-1', {
    balanceFen: 80,
    createdAt: 5
  })
  const { server, base } = await listen(store)
  try {
    const result = await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: 'translatehud-200' }
    })
    assert.equal(result.status, 409)
    assert.equal(result.json.error.code, 'trial_invite_claimed')
    assert.equal(store.invite.redeemedCount, 0)
    const saved = await store.ensure('uid-1')
    assert.equal(saved.record.balanceMicroYuan, 80 * 10000)
    assert.equal(saved.record.giftGranted, true)
  } finally {
    server.close()
  }
})

test('invite status is public, counts real redeems, and hides secrets', async () => {
  const store = new MemoryAccountStore()
  store.invite = { redeemedCount: 0, codes: ['private-extra-code'] }
  const { server, base } = await listen(store, {
    env: { TRIAL_INVITE_MAX_REDEEMS: '200' }
  })
  try {
    const before = await request(base, '/v1/trial/invite-status', { method: 'GET' })
    assert.equal(before.status, 200)
    assert.equal(before.headers.get('access-control-allow-origin'), '*')
    assert.equal(before.json.code, 'translatehud-200')
    assert.equal(before.json.remaining, 200)
    assert.equal(before.json.maxRedeems, 200)
    assert.equal(before.json.redeemedCount, 0)
    assert.equal(before.json.exhausted, false)
    assert.equal(before.text.includes('server-secret-key'), false)
    assert.equal(before.text.includes('private-extra-code'), false)
    assert.equal(before.json.codes, undefined)

    await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: 'translatehud-200' }
    })
    const after = await request(base, '/v1/trial/invite-status', { method: 'GET' })
    assert.equal(after.json.remaining, 199)
    assert.equal(after.json.redeemedCount, 1)
    assert.equal(after.json.exhausted, false)
    assert.equal(after.text.includes('server-secret-key'), false)
  } finally {
    server.close()
  }
})

test('raising maxRedeems in the env or the document adds remaining slots', async () => {
  const store = new MemoryAccountStore()
  store.invite = { redeemedCount: 1, maxRedeems: 1 }
  const low = await store.inviteStatus({ TRIAL_INVITE_MAX_REDEEMS: '1' })
  assert.equal(low.remaining, 0)
  assert.equal(low.exhausted, true)

  const raisedEnv = await store.inviteStatus({ TRIAL_INVITE_MAX_REDEEMS: '50' })
  assert.equal(raisedEnv.maxRedeems, 50)
  assert.equal(raisedEnv.remaining, 49)
  assert.equal(raisedEnv.exhausted, false)

  store.invite.maxRedeems = 80
  const raisedDoc = await store.inviteStatus({ TRIAL_INVITE_MAX_REDEEMS: '50' })
  assert.equal(raisedDoc.maxRedeems, 80)
  assert.equal(raisedDoc.remaining, 79)
})

test('an env invite code replaces the public default', async () => {
  const store = new MemoryAccountStore()
  const { server, base } = await listen(store, {
    env: { TRIAL_INVITE_CODE: 'HUD-PRIVATE' }
  })
  try {
    const status = await request(base, '/v1/trial/invite-status', { method: 'GET' })
    assert.equal(status.json.code, 'HUD-PRIVATE')
    const rejected = await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: 'translatehud-200' }
    })
    assert.equal(rejected.status, 400)
    const ok = await request(base, '/v1/trial/redeem', {
      token: 'good-token',
      body: { code: 'HUD-PRIVATE' }
    })
    assert.equal(ok.status, 200)
    assert.equal(ok.json.balanceMicroYuan, GIFT_MICRO_YUAN)
  } finally {
    server.close()
  }
})

test('a fourth in-flight translation is refused until a stream finishes', async () => {
  const store = new MemoryAccountStore()
  await store.redeem('uid-1', 'translatehud-200', 1, {})
  const streams = []
  let opened = 0
  let markReady
  const ready = new Promise((resolve) => { markReady = resolve })
  const { server, base, calls } = await listen(store, {
    forward: async ({ payload }) => {
      if (!payload.stream) return { status: 200, text: modelJSON('你好') }
      const stream = new PassThrough()
      streams.push(stream)
      opened += 1
      if (opened === 3) markReady()
      return { status: 200, stream }
    }
  })
  const pending = [1, 2, 3].map(() => fetch(`${base}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      Authorization: 'Bearer good-token',
      'Content-Type': 'application/json',
      'X-TranslateHUD-Source': sourceHeader('你好')
    },
    body: JSON.stringify({ model: 'client', stream: true, messages: [{ role: 'user', content: '你好' }] })
  }))
  try {
    await ready
    const blocked = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好',
      body: { model: 'm', stream: true, messages: [{ role: 'user', content: '你好' }] }
    })
    assert.equal(blocked.status, 429)
    assert.equal(blocked.json.error.code, 'trial_concurrency')
    assert.equal(blocked.json.error.message, MESSAGES.concurrency)
    assert.equal(calls.length, 3)

    for (const stream of streams) stream.end()
    const responses = await Promise.all(pending)
    assert.equal(responses.every((response) => response.status === 200), true)
    await Promise.all(responses.map((response) => response.text()))
    for (let i = 0; i < 50; i += 1) {
      const saved = await store.ensure('uid-1')
      if ((saved.record.inflight || []).length === 0) break
      await new Promise((resolve) => setTimeout(resolve, 10))
    }
    const next = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好',
      body: { model: 'm', messages: [{ role: 'user', content: '你好' }] }
    })
    assert.equal(next.status, 200)
    assert.equal(calls.length, 4)
  } finally {
    for (const stream of streams) stream.destroy()
    server.close()
  }
})

test('a signed-in account with no invite gift does not call the upstream', async () => {
  const store = new MemoryAccountStore()
  const { server, base, calls } = await listen(store)
  try {
    const result = await request(base, '/v1/chat/completions', {
      token: 'good-token',
      source: '你好',
      body: { model: 'm', messages: [{ role: 'user', content: '你好' }] }
    })
    assert.equal(result.status, 402)
    assert.equal(result.json.error.code, 'trial_invite_required')
    assert.equal(result.json.error.message, MESSAGES.inviteRequired)
    assert.equal(calls.length, 0)
  } finally {
    server.close()
  }
})
