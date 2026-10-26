'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { FileAccountStore, MemoryAccountStore, TransactionalAccountStore } = require('../src/accountStore')
const { GIFT_FEN, GIFT_MICRO_YUAN, MICRO_YUAN_PER_FEN } = require('../src/trialPolicy')

test('memory store gifts once under concurrent ensure and keeps a zero balance', async () => {
  const store = new MemoryAccountStore()
  const results = await Promise.all([
    store.ensure('user-1', 10),
    store.ensure('user-1', 11),
    store.ensure('user-1', 12)
  ])
  assert.equal(results.filter((item) => item.giftedNow).length, 1)
  assert.equal(results.every((item) => item.record.balanceMicroYuan === GIFT_MICRO_YUAN), true)
  assert.equal(results.every((item) => item.record.balanceFen === GIFT_FEN), true)

  await store.charge('user-1', GIFT_MICRO_YUAN)
  const again = await store.ensure('user-1', 20)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceMicroYuan, 0)
  assert.equal(again.record.balanceFen, 0)
})

test('memory store lets only one of two overlapping charges spend the same fen', async () => {
  const store = new MemoryAccountStore()
  await store.ensure('user-2', 1)
  await store.charge('user-2', GIFT_MICRO_YUAN - 10 * MICRO_YUAN_PER_FEN)
  const results = await Promise.all([
    store.charge('user-2', 6 * MICRO_YUAN_PER_FEN),
    store.charge('user-2', 6 * MICRO_YUAN_PER_FEN)
  ])
  const wins = results.filter((item) => item.ok)
  assert.equal(wins.length, 1)
  const saved = await store.ensure('user-2', 2)
  assert.equal(saved.record.balanceMicroYuan, 4 * MICRO_YUAN_PER_FEN)
  assert.equal(saved.record.balanceFen, 4)
  assert.equal(saved.giftedNow, false)
})

test('settle deducts the given fen and a second settle cannot go negative', async () => {
  const store = new MemoryAccountStore()
  await store.ensure('user-3', 1)
  const first = await store.settle('user-3', 50 * MICRO_YUAN_PER_FEN)
  assert.equal(first.chargedMicroYuan, 50 * MICRO_YUAN_PER_FEN)
  assert.equal(first.chargedFen, 50)
  assert.equal(first.balanceMicroYuan, GIFT_MICRO_YUAN - 50 * MICRO_YUAN_PER_FEN)
  assert.equal(first.balanceFen, GIFT_FEN - 50)
  const second = await store.settle('user-3', GIFT_MICRO_YUAN)
  assert.equal(second.costMicroYuan, GIFT_MICRO_YUAN)
  assert.equal(second.chargedMicroYuan, GIFT_MICRO_YUAN - 50 * MICRO_YUAN_PER_FEN)
  assert.equal(second.balanceMicroYuan, 0)
  assert.equal(second.balanceFen, 0)
  assert.equal(second.clamped, true)
  const saved = await store.ensure('user-3', 2)
  assert.equal(saved.record.balanceMicroYuan, 0)
})

test('file store keeps the gift across a new process object', async () => {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'translatehud-trial-'))
  const file = path.join(dir, 'accounts.json')
  const first = new FileAccountStore(file)
  const gifted = await first.ensure('phone-user', 5)
  assert.equal(gifted.giftedNow, true)
  await first.charge('phone-user', 30 * MICRO_YUAN_PER_FEN)

  const second = new FileAccountStore(file)
  const again = await second.ensure('phone-user', 6)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceMicroYuan, GIFT_MICRO_YUAN - 30 * MICRO_YUAN_PER_FEN)
  assert.equal(again.record.balanceFen, GIFT_FEN - 30)
})

test('a file written in fen is read as micro-yuan and is not treated as already micro-yuan', async () => {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'translatehud-trial-'))
  const file = path.join(dir, 'accounts.json')
  await fs.promises.writeFile(file, JSON.stringify({
    users: { legacy: { balanceFen: 150, giftGranted: true, createdAt: 1 } }
  }), 'utf8')
  const store = new FileAccountStore(file)
  const opened = await store.ensure('legacy', 2)
  assert.equal(opened.giftedNow, false)
  assert.equal(opened.record.balanceMicroYuan, 150 * MICRO_YUAN_PER_FEN)
  assert.equal(opened.record.balanceFen, 150)
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
          seen.set(uid, current ? current.balanceMicroYuan : null)
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
                if (!current || current.balanceMicroYuan !== record.__seen) {
                  const error = new Error('conflict')
                  error.code = 'CONFLICT'
                  throw error
                }
              }
            }
            for (const [uid, record] of writes) {
              docs.set(uid, {
                balanceMicroYuan: record.balanceMicroYuan,
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
  assert.equal(results.every((item) => item.record.balanceMicroYuan === GIFT_MICRO_YUAN), true)
  assert.equal(results.every((item) => item.record.balanceFen === GIFT_FEN), true)
})

test('transactional store retries a lost charge instead of double spending', async () => {
  const db = createConflictDatabase()
  const store = new TransactionalAccountStore(() => db.begin())
  await store.ensure('user-4', 1)
  await store.charge('user-4', GIFT_MICRO_YUAN - 10 * MICRO_YUAN_PER_FEN)
  const results = await Promise.all([
    store.charge('user-4', 6 * MICRO_YUAN_PER_FEN),
    store.charge('user-4', 6 * MICRO_YUAN_PER_FEN)
  ])
  assert.equal(results.filter((item) => item.ok).length, 1)
  const saved = await store.ensure('user-4', 3)
  assert.equal(saved.record.balanceMicroYuan, 4 * MICRO_YUAN_PER_FEN)
  assert.equal(saved.record.balanceFen, 4)
})

test('transactional store does not let two calls spend the same sub-fen remainder', async () => {
  const db = createConflictDatabase()
  const store = new TransactionalAccountStore(() => db.begin())
  await store.ensure('user-sub', 1)
  await store.charge('user-sub', GIFT_MICRO_YUAN - 100)
  const results = await Promise.all([
    store.charge('user-sub', 80),
    store.charge('user-sub', 80)
  ])
  assert.equal(results.filter((item) => item.ok).length, 1)
  const saved = await store.ensure('user-sub', 2)
  assert.equal(saved.record.balanceMicroYuan, 20)
  assert.equal(saved.record.balanceFen, 0)
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
      async get() { return { balanceMicroYuan: 0, giftGranted: true, createdAt: 1 } },
      async create() { throw new Error('should not create') },
      async save() {},
      async commit() {},
      async rollback() {}
    }
  })
  const result = await store.ensure('user-5', 9)
  assert.equal(result.giftedNow, false)
  assert.equal(result.record.balanceMicroYuan, 0)
  assert.equal(result.record.balanceFen, 0)
})
