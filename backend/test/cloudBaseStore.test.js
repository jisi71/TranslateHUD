'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { createCloudBaseStore } = require('../src/cloudBaseStore')
const { GIFT_FEN, GIFT_MICRO_YUAN, MESSAGES } = require('../src/trialPolicy')

function documentDatabase(options = {}) {
  const docs = new Map()
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
        collection() {
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
                  if (!docs.has(uid)) return { data: {} }
                  return { data: { ...docs.get(uid) } }
                },
                async set(record) {
                  staged.set(uid, { ...record })
                }
              }
            }
          }
        },
        async commit() {
          for (const [uid, record] of staged) docs.set(uid, { ...record })
        },
        async rollback() {}
      }
    }
  }
}

test('a fresh document database gets trial_accounts before the first gift', async () => {
  const db = documentDatabase()
  const store = createCloudBaseStore(db)
  const first = await store.ensure('user-1', 10)
  assert.equal(first.giftedNow, true)
  assert.equal(first.record.balanceMicroYuan, GIFT_MICRO_YUAN)
  assert.equal(first.record.balanceFen, GIFT_FEN)
  assert.equal(db.stats().createCalls, 1)
  assert.equal(db.docs.get('user-1').balanceMicroYuan, GIFT_MICRO_YUAN)
  assert.equal(db.docs.get('user-1').balanceFen, GIFT_FEN)

  const second = await store.ensure('user-1', 11)
  assert.equal(second.giftedNow, false)
  assert.equal(second.record.balanceMicroYuan, GIFT_MICRO_YUAN)
  assert.equal(second.record.balanceFen, GIFT_FEN)
  assert.equal(db.stats().createCalls, 1)
})

test('an existing collection is not an error and is not gifted twice', async () => {
  const db = documentDatabase({
    exists: true,
    createResult: { code: 'DATABASE_COLLECTION_ALREADY_EXIST', message: 'already exists' }
  })
  const store = createCloudBaseStore(db)
  const opened = await store.ensure('user-2', 1)
  assert.equal(opened.giftedNow, true)
  const again = await store.ensure('user-2', 2)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceMicroYuan, GIFT_MICRO_YUAN)
  assert.equal(again.record.balanceFen, GIFT_FEN)
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

test('a missing collection seen during the first read is created and then gifted once', async () => {
  const db = documentDatabase({ exists: true, failGets: 1 })
  const store = createCloudBaseStore(db)
  const opened = await store.ensure('user-4', 4)
  assert.equal(opened.giftedNow, true)
  assert.equal(opened.record.balanceMicroYuan, GIFT_MICRO_YUAN)
  assert.equal(opened.record.balanceFen, GIFT_FEN)
  assert.equal(db.docs.get('user-4').giftGranted, true)
})
