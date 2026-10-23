'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { FileAccountStore, MemoryAccountStore, TransactionalAccountStore } = require('../src/accountStore')
const { GIFT_FEN } = require('../src/trialPolicy')

test('memory store gifts once under concurrent ensure and keeps a zero balance', async () => {
  const store = new MemoryAccountStore()
  const results = await Promise.all([
    store.ensure('user-1', 10),
    store.ensure('user-1', 11),
    store.ensure('user-1', 12)
  ])
  assert.equal(results.filter((item) => item.giftedNow).length, 1)
  assert.equal(results.every((item) => item.record.balanceFen === GIFT_FEN), true)

  await store.charge('user-1', GIFT_FEN)
  const again = await store.ensure('user-1', 20)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceFen, 0)
})

test('memory store lets only one of two overlapping charges spend the same fen', async () => {
  const store = new MemoryAccountStore()
  await store.ensure('user-2', 1)
  await store.charge('user-2', GIFT_FEN - 10)
  const results = await Promise.all([store.charge('user-2', 6), store.charge('user-2', 6)])
  const wins = results.filter((item) => item.ok)
  assert.equal(wins.length, 1)
  const saved = await store.ensure('user-2', 2)
  assert.equal(saved.record.balanceFen, 4)
  assert.equal(saved.giftedNow, false)
})

test('file store keeps the gift across a new process object', async () => {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'translatehud-trial-'))
  const file = path.join(dir, 'accounts.json')
  const first = new FileAccountStore(file)
  const gifted = await first.ensure('phone-user', 5)
  assert.equal(gifted.giftedNow, true)
  await first.charge('phone-user', 30)

  const second = new FileAccountStore(file)
  const again = await second.ensure('phone-user', 6)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceFen, GIFT_FEN - 30)
})

function createConflictDatabase() {
  const docs = new Map()
  let tail = Promise.resolve()
  return {
    begin() {
      const writes = new Map()
      const seen = new Map()
      const tx = {
        async get(uid) {
          if (writes.has(uid)) return writes.get(uid)
          const current = docs.get(uid) || null
          seen.set(uid, current ? current.balanceFen : null)
          return current ? { ...current } : null
        },
        async create(uid, record) {
          writes.set(uid, { ...record, __create: true })
        },
        async save(uid, record) {
          writes.set(uid, { ...record, __replace: true, __seen: seen.get(uid) })
        },
        commit() {
          const run = tail.then(() => {
            for (const [uid, record] of writes) {
              const current = docs.get(uid) || null
              if (record.__create && current) {
                const error = new Error('conflict')
                error.code = 'CONFLICT'
                throw error
              }
              if (record.__replace) {
                if (!current || current.balanceFen !== record.__seen) {
                  const error = new Error('conflict')
                  error.code = 'CONFLICT'
                  throw error
                }
              }
            }
            for (const [uid, record] of writes) {
              docs.set(uid, {
                balanceFen: record.balanceFen,
                giftGranted: record.giftGranted,
                createdAt: record.createdAt
              })
            }
          })
          tail = run.then(() => {}, () => {})
          return run
        },
        async rollback() {}
      }
      return tx
    }
  }
}

test('transactional store retries a gift conflict and does not grant twice', async () => {
  const db = createConflictDatabase()
  const store = new TransactionalAccountStore(() => db.begin())
  const results = await Promise.all([
    store.ensure('user-3', 1),
    store.ensure('user-3', 2)
  ])
  assert.equal(results.filter((item) => item.giftedNow).length, 1)
  assert.equal(results.every((item) => item.record.balanceFen === GIFT_FEN), true)
})

test('transactional store retries a lost charge instead of double spending', async () => {
  const db = createConflictDatabase()
  const store = new TransactionalAccountStore(() => db.begin())
  await store.ensure('user-4', 1)
  await store.charge('user-4', GIFT_FEN - 10)
  const results = await Promise.all([store.charge('user-4', 6), store.charge('user-4', 6)])
  assert.equal(results.filter((item) => item.ok).length, 1)
  const saved = await store.ensure('user-4', 3)
  assert.equal(saved.record.balanceFen, 4)
})

test('a scripted conflict on create reads the winner and does not gift again', async () => {
  let calls = 0
  const store = new TransactionalAccountStore(async () => {
    calls += 1
    if (calls === 1) {
      return {
        async get() { return null },
        async create() {
          const error = new Error('write conflict')
          error.code = 'CONFLICT'
          throw error
        },
        async save() {},
        async commit() {},
        async rollback() {}
      }
    }
    return {
      async get() { return { balanceFen: 0, giftGranted: true, createdAt: 1 } },
      async create() { throw new Error('should not create') },
      async save() {},
      async commit() {},
      async rollback() {}
    }
  })
  const result = await store.ensure('user-5', 9)
  assert.equal(result.giftedNow, false)
  assert.equal(result.record.balanceFen, 0)
})
