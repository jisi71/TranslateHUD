'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { createCloudBaseStore } = require('../src/cloudBaseStore')
const { GIFT_FEN, GIFT_MICRO_YUAN, MESSAGES } = require('../src/trialPolicy')

function documentDatabase(options = {}) {
  const docs = new Map()
  const inviteDocs = new Map()
  let exists = options.exists === true
  let createCalls = 0
  let gets = 0
  return {
    docs,
    stats() { return { createCalls, gets, exists } },
    async createCollection() {
      createCalls += 1
      if (options.createResult) return options.createResult
      if (options.createError) throw options.createError
      exists = true
      return { requestId: 'created' }
    },
    async startTransaction() {
      if (!exists) {
        const error = new Error('Db or Table not exist')
        error.code = 'DATABASE_COLLECTION_NOT_EXIST'
        throw error
      }
      const staged = new Map()
      return {
        collection(name = 'trial_accounts') {
          const table = name === 'trial_invite' ? inviteDocs : docs
          return {
            doc(uid) {
              return {
                async get() {
                  gets += 1
                  if (options.failGets && gets <= options.failGets) {
                    const error = new Error('collection missing on first read')
                    error.code = 'DATABASE_COLLECTION_NOT_EXIST'
                    throw error
                  }
                  if (!table.has(uid)) return { data: {} }
                  return { data: { ...table.get(uid) } }
                },
                async set(record) {
                  staged.set(`${name}:${uid}`, { table, id: uid, record: { ...record } })
                }
              }
            }
          }
        },
        async commit() {
          for (const entry of staged.values()) entry.table.set(entry.id, { ...entry.record })
        },
        async rollback() {}
      }
    }
  }
}

test('a feedback submit writes the China-day count onto the account document', async () => {
  const db = documentDatabase({ exists: true })
  const store = createCloudBaseStore(db)
  const now = Date.parse('2026-10-26T01:00:00.000Z')
  const taken = await store.takeFeedback('uid-9', now, 10)
  assert.equal(taken.ok, true)
  assert.equal(db.docs.get('uid-9').feedbackDay, '2026-10-26')
  assert.equal(db.docs.get('uid-9').feedbackCount, 1)
  assert.equal(db.docs.get('uid-9').balanceMicroYuan, 0)
  await store.settle('uid-9', 0)
  assert.equal(db.docs.get('uid-9').feedbackCount, 1)
  const blocked = await store.takeFeedback('uid-9', now, 1)
  assert.equal(blocked.ok, false)
  assert.equal(blocked.code, 'feedback_daily_limit')
  await store.releaseFeedback('uid-9', now)
  assert.equal(db.docs.get('uid-9').feedbackCount, undefined)
  assert.equal(db.docs.get('uid-9').feedbackDay, undefined)
})

test('a fresh document database gets both collections before the first account', async () => {
  const db = documentDatabase()
  const store = createCloudBaseStore(db)
  const first = await store.ensure('user-1', 10)
  assert.equal(first.giftedNow, false)
  assert.equal(first.record.balanceMicroYuan, 0)
  assert.equal(first.record.balanceFen, 0)
  assert.equal(first.record.giftGranted, false)
  assert.equal(db.stats().createCalls, 2)
  assert.equal(db.docs.get('user-1').balanceMicroYuan, 0)
  assert.equal(db.docs.get('user-1').giftGranted, false)

  const second = await store.ensure('user-1', 11)
  assert.equal(second.giftedNow, false)
  assert.equal(second.record.balanceMicroYuan, 0)
  assert.equal(second.record.balanceFen, 0)
  assert.equal(db.stats().createCalls, 2)
})

test('an existing collection is not an error and is not gifted twice', async () => {
  const db = documentDatabase({
    exists: true,
    createResult: { code: 'DATABASE_COLLECTION_ALREADY_EXIST', message: 'already exists' }
  })
  const store = createCloudBaseStore(db)
  const opened = await store.ensure('user-2', 1)
  assert.equal(opened.giftedNow, false)
  assert.equal(opened.record.giftGranted, false)
  const again = await store.ensure('user-2', 2)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceMicroYuan, 0)
  assert.equal(again.record.balanceFen, 0)
})

test('a collection permission failure stays a trial_store error and does not write', async () => {
  const db = documentDatabase({
    createResult: { code: 'ACCESS_DENIED', message: 'secret-db-detail' }
  })
  const store = createCloudBaseStore(db)
  await assert.rejects(store.ensure('user-3', 1), (error) => {
    assert.equal(error.code, 'trial_store')
    assert.equal(error.publicMessage, MESSAGES.store)
    assert.equal(String(error.message).includes('secret-db-detail'), false)
    assert.equal(String(error.publicMessage).includes('secret-db-detail'), false)
    return true
  })
  assert.equal(db.docs.size, 0)
})

test('trial_accounts, trial_invite, and trial_feedback are created as separate collections', async () => {
  const names = []
  const db = {
    async createCollection(name) { names.push(name) }
  }
  const { ensureCollection, COLLECTION, INVITE_COLLECTION } = require('../src/cloudBaseStore')
  const { FEEDBACK_COLLECTION } = require('../src/feedbackStore')
  await ensureCollection(db, COLLECTION)
  await ensureCollection(db, INVITE_COLLECTION)
  await ensureCollection(db, FEEDBACK_COLLECTION)
  await ensureCollection(db, COLLECTION)
  assert.deepEqual(names, ['trial_accounts', 'trial_invite', 'trial_feedback'])
})

test('a missing collection seen during the first read is created and the account starts empty', async () => {
  const db = documentDatabase({ exists: true, failGets: 1 })
  const store = createCloudBaseStore(db)
  const opened = await store.ensure('user-4', 4)
  assert.equal(opened.giftedNow, false)
  assert.equal(opened.record.balanceMicroYuan, 0)
  assert.equal(opened.record.balanceFen, 0)
  assert.equal(db.docs.get('user-4').giftGranted, false)
})

test('a document that already has a gift cannot redeem a second one', async () => {
  const db = documentDatabase({ exists: true })
  db.docs.set('old', { balanceFen: 200, createdAt: 1 })
  const store = createCloudBaseStore(db)
  const legacy = await store.redeem('old', 'translatehud-200', 7, {})
  assert.equal(legacy.ok, false)
  assert.equal(legacy.code, 'trial_invite_claimed')
  const fresh = await store.redeem('new-user', 'translatehud-200', 8, {})
  assert.equal(fresh.ok, true)
  assert.equal(fresh.record.balanceMicroYuan, GIFT_MICRO_YUAN)
  const again = await store.redeem('new-user', 'translatehud-200', 9, {})
  assert.equal(again.code, 'trial_invite_claimed')
  const status = await store.inviteStatus({})
  assert.equal(status.code, 'translatehud-200')
  assert.equal(status.redeemedCount, 1)
  assert.equal(status.remaining, 199)
  assert.equal(status.exhausted, false)
})
