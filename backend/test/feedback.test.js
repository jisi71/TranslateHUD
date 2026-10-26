'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const http = require('http')
const { FileAccountStore, MemoryAccountStore } = require('../src/accountStore')
const { createRequestListener, routeOf } = require('../src/httpApp')
const { FEEDBACK_MESSAGES, MAX_TITLE, MAX_BODY } = require('../src/feedbackService')
const {
  FEEDBACK_COLLECTION,
  FileFeedbackStore,
  MemoryFeedbackStore,
  createCloudBaseFeedbackStore
} = require('../src/feedbackStore')

function jpegBuffer() {
  const bytes = Buffer.alloc(32, 0x11)
  bytes[0] = 0xFF
  bytes[1] = 0xD8
  bytes[2] = 0xFF
  return bytes
}

function pngBuffer() {
  const bytes = Buffer.alloc(32, 0x22)
  Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).copy(bytes)
  return bytes
}

function listen(feedbackStore, options = {}) {
  const accountStore = options.store || new MemoryAccountStore()
  const env = {
    envId: 'translatehud-d4gl951eo8bef4702',
    gateway: 'https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com',
    apiKey: 'server-secret-key',
    baseURL: 'https://api.deepseek.com/v1',
    model: 'server-model',
    FEEDBACK_DAILY_LIMIT: options.dailyLimit == null ? '' : String(options.dailyLimit)
  }
  let verifications = 0
  const verifyUser = options.verifyUser || (async ({ token }) => {
    verifications += 1
    if (token !== 'good-token') throw new Error('nope')
    return { uid: 'uid-1' }
  })
  const server = http.createServer(createRequestListener({
    store: accountStore,
    feedbackStore,
    env,
    verifyUser,
    now: options.now || (() => Date.parse('2026-10-26T00:00:00.000Z')),
    feedbackBodyLimit: options.feedbackBodyLimit
  }))
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({
        server,
        accountStore,
        base: `http://127.0.0.1:${server.address().port}`,
        verifications: () => verifications
      })
    })
  })
}

async function post(base, body, { token, method } = {}) {
  const verb = method || 'POST'
  const response = await fetch(`${base}/v1/trial/feedback`, {
    method: verb,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {})
    },
    body: verb === 'GET' ? undefined : (body == null ? JSON.stringify({}) : (typeof body === 'string' ? body : JSON.stringify(body)))
  })
  const text = await response.text()
  let json = null
  try { json = JSON.parse(text) } catch { json = null }
  return { status: response.status, text, json }
}

function draft(extra = {}) {
  return {
    title: '划词没有出译文',
    body: '选中一段英文后按快捷键，浮窗停在原文。',
    appVersion: '0.4.0 (10)',
    deviceId: 'device-1',
    images: [],
    ...extra
  }
}

test('feedback route is its own path', () => {
  assert.equal(routeOf('/v1/trial/feedback'), 'feedback')
  assert.equal(routeOf('/v1/trial/feedback?x=1'), 'feedback')
  assert.equal(routeOf('/v1/trial/account'), 'account')
})

test('feedback copy does not ask for an email address', () => {
  const blob = JSON.stringify(FEEDBACK_MESSAGES).toLowerCase()
  assert.equal(blob.includes('mailto'), false)
  assert.equal(blob.includes('email'), false)
  assert.equal(blob.includes('邮箱'), false)
})

test('feedback without a login is refused and nothing is stored', async () => {
  const store = new MemoryFeedbackStore()
  const { server, base, verifications, accountStore } = await listen(store)
  try {
    const result = await post(base, draft({
      email: 'person@example.com',
      images: [{ contentType: 'image/jpeg', data: jpegBuffer().toString('base64') }]
    }))
    assert.equal(result.status, 401)
    assert.equal(result.json.error.code, 'feedback_login')
    assert.equal(result.json.error.message, FEEDBACK_MESSAGES.login)
    assert.equal(verifications(), 0)
    assert.equal(store.docs.length, 0)
    assert.equal(accountStore.users.size, 0)
    assert.equal(result.text.includes('person@example.com'), false)
  } finally {
    server.close()
  }
})

test('a valid login is recorded as the cloud account id', async () => {
  const store = new MemoryFeedbackStore()
  const { server, base, verifications, accountStore } = await listen(store)
  try {
    const jpeg = jpegBuffer()
    const result = await post(base, draft({
      email: 'person@example.com',
      mail: 'person@example.com',
      images: [{ contentType: 'image/jpeg', data: jpeg.toString('base64') }]
    }), { token: 'good-token' })
    assert.equal(result.status, 200)
    assert.equal(result.json.ok, true)
    assert.equal(verifications(), 1)
    const doc = store.docs[0]
    assert.equal(doc.anonymous, false)
    assert.equal(doc.accountId, 'uid-1')
    assert.equal(doc.appVersion, '0.4.0 (10)')
    assert.equal(doc.deviceId, 'device-1')
    assert.equal(doc.createdAt, '2026-10-26T00:00:00.000Z')
    assert.equal(doc.email, undefined)
    assert.equal(JSON.stringify(doc).includes('person@example.com'), false)
    assert.equal(doc.images.length, 1)
    assert.equal(doc.images[0].contentType, 'image/jpeg')
    assert.match(doc.images[0].cloudPath, /^feedback\/[a-f0-9]+\/0\.jpg$/)
    assert.equal(store.files[0].bytes, jpeg.length)
    assert.equal(result.text.includes(jpeg.toString('base64')), false)
    assert.equal(accountStore.users.get('uid-1').feedbackDay, '2026-10-26')
    assert.equal(accountStore.users.get('uid-1').feedbackCount, 1)
  } finally {
    server.close()
  }
})

test('each account can submit ten times per China day, then again the next day', async () => {
  let now = Date.parse('2026-10-26T15:30:00.000Z')
  const store = new MemoryFeedbackStore()
  const { server, base, accountStore } = await listen(store, {
    dailyLimit: 2,
    now: () => now
  })
  try {
    const first = await post(base, draft(), { token: 'good-token' })
    const second = await post(base, draft({ title: '第二条' }), { token: 'good-token' })
    const third = await post(base, draft({ title: '第三条' }), { token: 'good-token' })
    assert.equal(first.status, 200)
    assert.equal(second.status, 200)
    assert.equal(third.status, 429)
    assert.equal(third.json.error.code, 'feedback_daily_limit')
    assert.equal(third.json.error.message, FEEDBACK_MESSAGES.dailyLimit)
    assert.equal(store.docs.length, 2)
    assert.equal(accountStore.users.get('uid-1').feedbackDay, '2026-10-26')
    assert.equal(accountStore.users.get('uid-1').feedbackCount, 2)
    now = Date.parse('2026-10-26T16:30:00.000Z')
    const nextDay = await post(base, draft({ title: '第二天' }), { token: 'good-token' })
    assert.equal(nextDay.status, 200)
    assert.equal(accountStore.users.get('uid-1').feedbackDay, '2026-10-27')
    assert.equal(accountStore.users.get('uid-1').feedbackCount, 1)
  } finally {
    server.close()
  }
})

test('a bad login token is refused and nothing is stored', async () => {
  const store = new MemoryFeedbackStore()
  const { server, base } = await listen(store)
  try {
    const result = await post(base, draft({ title: 'SECRET_TITLE' }), { token: 'bad-token' })
    assert.equal(result.status, 401)
    assert.equal(result.json.error.code, 'feedback_auth')
    assert.equal(result.json.error.message, FEEDBACK_MESSAGES.auth)
    assert.equal(result.text.includes('SECRET_TITLE'), false)
    assert.equal(store.docs.length, 0)
  } finally {
    server.close()
  }
})

test('missing text and too many or unusable images are rejected', async () => {
  const store = new MemoryFeedbackStore()
  const { server, base } = await listen(store)
  try {
    const missingTitle = await post(base, draft({ title: '   ' }), { token: 'good-token' })
    assert.equal(missingTitle.status, 400)
    assert.equal(missingTitle.json.error.code, 'feedback_title')
    assert.equal(missingTitle.json.error.message, FEEDBACK_MESSAGES.title)

    const longTitle = await post(base, draft({ title: '题'.repeat(MAX_TITLE + 1) }), { token: 'good-token' })
    assert.equal(longTitle.json.error.code, 'feedback_title_long')

    const longBody = await post(base, draft({ body: '文'.repeat(MAX_BODY + 1) }), { token: 'good-token' })
    assert.equal(longBody.json.error.code, 'feedback_body_long')

    const html = await post(base, draft({
      images: [{ data: Buffer.from('<html>not-an-image-file!!</html>').toString('base64') }]
    }), { token: 'good-token' })
    assert.equal(html.status, 400)
    assert.equal(html.json.error.code, 'feedback_image_type')
    assert.equal(html.text.includes('not-an-image'), false)

    const png = pngBuffer()
    const tooMany = await post(base, draft({
      images: Array.from({ length: 5 }, () => ({ data: png.toString('base64') }))
    }), { token: 'good-token' })
    assert.equal(tooMany.json.error.code, 'feedback_image_count')
    assert.equal(tooMany.json.error.message, FEEDBACK_MESSAGES.images)

    const ok = await post(base, draft({
      images: [{ data: png.toString('base64') }]
    }), { token: 'good-token' })
    assert.equal(ok.status, 200)
    assert.equal(store.docs.length, 1)
    assert.equal(store.docs[0].images[0].contentType, 'image/png')
    assert.match(store.docs[0].images[0].cloudPath, /0\.png$/)
  } finally {
    server.close()
  }
})

test('an oversized feedback body uses the feedback sentence', async () => {
  const store = new MemoryFeedbackStore()
  const { server, base } = await listen(store, { feedbackBodyLimit: 40 })
  try {
    const result = await post(base, draft())
    assert.equal(result.status, 413)
    assert.equal(result.json.error.code, 'feedback_too_large')
    assert.equal(result.json.error.message, FEEDBACK_MESSAGES.tooLarge)
    assert.equal(result.text.includes('原文'), false)
    assert.equal(store.docs.length, 0)
  } finally {
    server.close()
  }
})

test('a store failure stays feedback_store and hides the driver message', async () => {
  const store = {
    async save() {
      const error = new Error('secret-db-detail')
      error.code = 'DATABASE_REQUEST_FAILED'
      error.publicMessage = '体验余额暂时读不出来。请在设置里点「重新读取」。'
      throw error
    }
  }
  const { server, base, accountStore } = await listen(store)
  try {
    const result = await post(base, draft({ title: 'SECRET_TITLE' }), { token: 'good-token' })
    assert.equal(result.status, 503)
    assert.equal(result.json.error.code, 'feedback_store')
    assert.equal(result.json.error.message, FEEDBACK_MESSAGES.store)
    assert.equal(result.text.includes('secret-db-detail'), false)
    assert.equal(result.text.includes('体验余额'), false)
    assert.equal(result.text.includes('SECRET_TITLE'), false)
    assert.equal(accountStore.users.get('uid-1').feedbackCount, undefined)
  } finally {
    server.close()
  }
})

test('GET feedback is refused', async () => {
  const { server, base } = await listen(new MemoryFeedbackStore())
  try {
    const result = await post(base, null, { method: 'GET' })
    assert.equal(result.status, 405)
  } finally {
    server.close()
  }
})

test('cloud function dispatch refuses anonymous feedback', async () => {
  const { dispatch } = require('../src/cloudEntry')
  const store = new MemoryFeedbackStore()
  const accounts = new MemoryAccountStore()
  const result = await dispatch({
    httpMethod: 'POST',
    path: '/v1/trial/feedback',
    headers: {},
    body: JSON.stringify(draft({ email: 'person@example.com' }))
  }, {
    feedbackStore: store,
    store: accounts,
    env: {
      envId: 'translatehud-d4gl951eo8bef4702',
      gateway: 'https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com'
    },
    verifyUser: async () => { throw new Error('should not be called') },
    now: () => Date.parse('2026-10-26T00:00:00.000Z')
  })
  assert.equal(result.statusCode, 401)
  const body = JSON.parse(result.body)
  assert.equal(body.error.code, 'feedback_login')
  assert.equal(store.docs.length, 0)
  assert.equal(accounts.users.size, 0)
})

test('cloud function dispatch stores signed-in feedback and counts it', async () => {
  const { dispatch } = require('../src/cloudEntry')
  const store = new MemoryFeedbackStore()
  const accounts = new MemoryAccountStore()
  const result = await dispatch({
    httpMethod: 'POST',
    path: '/v1/trial/feedback',
    headers: { Authorization: 'Bearer good-token' },
    body: JSON.stringify(draft({ email: 'person@example.com' }))
  }, {
    feedbackStore: store,
    store: accounts,
    env: {
      envId: 'translatehud-d4gl951eo8bef4702',
      gateway: 'https://translatehud-d4gl951eo8bef4702.api.tcloudbasegateway.com',
      FEEDBACK_DAILY_LIMIT: '10'
    },
    verifyUser: async () => ({ uid: 'uid-1' }),
    now: () => Date.parse('2026-10-26T00:00:00.000Z')
  })
  assert.equal(result.statusCode, 200)
  const body = JSON.parse(result.body)
  assert.equal(body.ok, true)
  assert.equal(store.docs[0].anonymous, false)
  assert.equal(store.docs[0].accountId, 'uid-1')
  assert.equal(JSON.stringify(store.docs[0]).includes('person@example.com'), false)
  assert.equal(accounts.users.get('uid-1').feedbackCount, 1)
})

test('a file account keeps the feedback count across a new store', async () => {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'translatehud-feedback-quota-'))
  const file = path.join(dir, 'accounts.json')
  const now = Date.parse('2026-10-26T02:00:00.000Z')
  const first = new FileAccountStore(file)
  const taken = await first.takeFeedback('uid-1', now, 1)
  assert.equal(taken.ok, true)
  const second = new FileAccountStore(file)
  const again = await second.takeFeedback('uid-1', now, 1)
  assert.equal(again.ok, false)
  assert.equal(again.code, 'feedback_daily_limit')
  const saved = JSON.parse(await fs.promises.readFile(file, 'utf8'))
  assert.equal(saved.users['uid-1'].feedbackDay, '2026-10-26')
  assert.equal(saved.users['uid-1'].feedbackCount, 1)
})

test('a file store writes the document and the image bytes', async () => {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'translatehud-feedback-'))
  const store = new FileFeedbackStore(path.join(dir, 'feedback.json'))
  const jpeg = jpegBuffer()
  const saved = await store.save({
    title: '标题',
    body: '正文',
    createdAt: '2026-10-26T00:00:00.000Z',
    appVersion: '0.4.0',
    accountId: '',
    anonymous: true,
    deviceId: 'device-1'
  }, [{ bytes: jpeg, contentType: 'image/jpeg', ext: 'jpg' }])
  const docs = JSON.parse(await fs.promises.readFile(path.join(dir, 'feedback.json'), 'utf8'))
  assert.equal(docs.length, 1)
  assert.equal(docs[0].id, saved.id)
  assert.equal(docs[0].email, undefined)
  const file = path.join(dir, 'feedback-files', saved.id, '0.jpg')
  const written = await fs.promises.readFile(file)
  assert.deepEqual(written, jpeg)
})

test('cloudbase feedback creates trial_feedback and uploads under feedback/', async () => {
  const created = []
  const added = []
  const uploaded = []
  const db = {
    async createCollection(name) { created.push(name) },
    collection(name) {
      return {
        async add(doc) {
          added.push({ name, doc })
          return { id: 'platform-id', requestId: 'r' }
        }
      }
    }
  }
  const store = createCloudBaseFeedbackStore({
    database: db,
    uploadFile: async ({ cloudPath, fileContent }) => {
      uploaded.push({ cloudPath, size: fileContent.length })
      return { fileID: `cloud://translatehud-d4gl951eo8bef4702/${cloudPath}` }
    }
  })
  const jpeg = jpegBuffer()
  const saved = await store.save({
    title: '标题',
    body: '正文',
    createdAt: '2026-10-26T00:00:00.000Z',
    appVersion: '0.4.0 (10)',
    accountId: 'uid-1',
    anonymous: false,
    deviceId: 'device-1'
  }, [{ bytes: jpeg, contentType: 'image/jpeg', ext: 'jpg' }])
  assert.deepEqual(created, [FEEDBACK_COLLECTION])
  assert.equal(added.length, 1)
  assert.equal(added[0].name, FEEDBACK_COLLECTION)
  assert.equal(added[0].doc.id, saved.id)
  assert.equal(added[0].doc.accountId, 'uid-1')
  assert.equal(added[0].doc.anonymous, false)
  assert.equal(added[0].doc.email, undefined)
  assert.equal(added[0].doc.images[0].fileId, `cloud://translatehud-d4gl951eo8bef4702/${uploaded[0].cloudPath}`)
  assert.match(uploaded[0].cloudPath, /^feedback\/[a-f0-9]+\/0\.jpg$/)
  assert.equal(uploaded[0].size, jpeg.length)

  await store.save({
    title: '第二条',
    body: '没有图片',
    createdAt: '2026-10-26T00:00:00.000Z',
    appVersion: '',
    accountId: '',
    anonymous: true,
    deviceId: ''
  }, [])
  assert.deepEqual(created, [FEEDBACK_COLLECTION])
  assert.equal(added.length, 2)
})

test('a failed document write deletes uploaded feedback images', async () => {
  const deleted = []
  const db = {
    async createCollection() {},
    collection() {
      return {
        async add() {
          const error = new Error('secret-db-detail')
          error.code = 'DATABASE_REQUEST_FAILED'
          throw error
        }
      }
    }
  }
  const store = createCloudBaseFeedbackStore({
    database: db,
    uploadFile: async ({ cloudPath }) => ({ fileID: `cloud://env/${cloudPath}` }),
    deleteFile: async ({ fileList }) => { deleted.push(...fileList) }
  })
  await assert.rejects(store.save({
    title: '标题',
    body: '正文',
    createdAt: '2026-10-26T00:00:00.000Z',
    appVersion: '',
    accountId: '',
    anonymous: true,
    deviceId: ''
  }, [{ bytes: jpegBuffer(), contentType: 'image/jpeg', ext: 'jpg' }]))
  assert.equal(deleted.length, 1)
  assert.match(deleted[0], /^cloud:\/\/env\/feedback\//)
})
