'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { FileAccountStore, MemoryAccountStore, TransactionalAccountStore } = require('../src/accountStore')
const { formatDisplayId } = require('../src/trialPolicy')

test('display ids stay five digits through 99999 and grow after that', () => {
  assert.equal(formatDisplayId(1), '00001')
  assert.equal(formatDisplayId(2), '00002')
  assert.equal(formatDisplayId(99999), '99999')
  assert.equal(formatDisplayId(100000), '100000')
  assert.equal(formatDisplayId(0), '')
  assert.equal(formatDisplayId(-3), '')
})

test('new accounts take the next number and keep it', async () => {
  const store = new MemoryAccountStore()
  const first = await store.ensure('user-a', 10)
  const second = await store.ensure('user-b', 20)
  const third = await store.ensure('user-c', 30)
  assert.equal(first.record.displayNo, 1)
  assert.equal(formatDisplayId(first.record.displayNo), '00001')
  assert.equal(second.record.displayNo, 2)
  assert.equal(formatDisplayId(second.record.displayNo), '00002')
  assert.equal(third.record.displayNo, 3)
  assert.equal(formatDisplayId(third.record.displayNo), '00003')

  const again = await store.ensure('user-a', 40)
  assert.equal(again.record.displayNo, 1)
  assert.equal(again.record.createdAt, 10)
  const settled = await store.settle('user-a', 0)
  assert.equal(settled.record.displayNo, 1)
  const reread = await store.ensure('user-a', 50)
  assert.equal(reread.record.displayNo, 1)
})

test('overlapping signups do not share a number', async () => {
  const store = new MemoryAccountStore()
  const results = await Promise.all([
    store.ensure('left', 1),
    store.ensure('right', 2)
  ])
  const numbers = results.map((item) => item.record.displayNo).sort((a, b) => a - b)
  assert.deepEqual(numbers, [1, 2])
  const left = await store.ensure('left', 3)
  const right = await store.ensure('right', 4)
  assert.equal(left.record.displayNo, results.find((item) => item.record.createdAt === 1).record.displayNo)
  assert.equal(right.record.displayNo, results.find((item) => item.record.createdAt === 2).record.displayNo)
})

test('older accounts already on disk get the smaller numbers', async () => {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'translatehud-display-'))
  const file = path.join(dir, 'accounts.json')
  await fs.promises.writeFile(file, JSON.stringify({
    users: {
      late: { balanceMicroYuan: 0, giftGranted: true, createdAt: 200 },
      early: { balanceMicroYuan: 5, giftGranted: false, createdAt: 100 }
    },
    invite: { redeemedCount: 4 }
  }), 'utf8')
  const store = new FileAccountStore(file)
  const opened = await store.ensure('late', 999)
  assert.equal(opened.record.displayNo, 2)
  assert.equal(formatDisplayId(opened.record.displayNo), '00002')
  const early = await store.ensure('early', 1000)
  assert.equal(early.record.displayNo, 1)
  assert.equal(formatDisplayId(early.record.displayNo), '00001')
  const status = await store.inviteStatus({})
  assert.equal(status.redeemedCount, 4)
  assert.equal(status.userId, undefined)
  assert.equal(status.nextDisplayNo, undefined)

  const reloaded = new FileAccountStore(file)
  const again = await reloaded.ensure('late', 1001)
  assert.equal(again.record.displayNo, 2)
  const newbie = await reloaded.ensure('newbie', 5000)
  assert.equal(newbie.record.displayNo, 3)
  assert.equal(formatDisplayId(newbie.record.displayNo), '00003')
})

test('a transactional list gives the earlier account the smaller number', async () => {
  const docs = new Map([
    ['late', { balanceMicroYuan: 0, giftGranted: true, createdAt: 200 }],
    ['early', { balanceMicroYuan: 0, giftGranted: true, createdAt: 100 }]
  ])
  let invite = { redeemedCount: 2 }
  const store = new TransactionalAccountStore(async () => ({
    async get(uid) {
      const current = docs.get(uid)
      return current ? { ...current } : null
    },
    async create(uid, record) { docs.set(uid, { ...record }) },
    async save(uid, record) { docs.set(uid, { ...record }) },
    async getInvite() { return { ...invite } },
    async saveInvite(doc) { invite = { ...doc } },
    async listUsers() {
      return [...docs].map(([uid, record]) => ({ uid, record: { ...record } }))
    },
    async commit() {},
    async rollback() {}
  }))
  const opened = await store.ensure('late', 999)
  assert.equal(opened.record.displayNo, 2)
  assert.equal(formatDisplayId(opened.record.displayNo), '00002')
  assert.equal(docs.get('early').displayNo, 1)
  assert.equal(formatDisplayId(docs.get('early').displayNo), '00001')
  assert.equal(invite.nextDisplayNo, 3)
  assert.equal(invite.redeemedCount, 2)
  const again = await store.ensure('late', 1000)
  assert.equal(again.record.displayNo, 2)
  assert.equal(docs.get('late').displayNo, 2)
})

test('redeem keeps the internal user id and returns the short number', async () => {
  const store = new MemoryAccountStore()
  const result = await store.redeem('cloudbase-uid-very-long', 'translatehud-200', 5, {})
  assert.equal(result.ok, true)
  assert.equal(result.record.displayNo, 1)
  assert.equal(formatDisplayId(result.record.displayNo), '00001')
  const again = await store.ensure('cloudbase-uid-very-long', 6)
  assert.equal(again.record.displayNo, 1)
  const next = await store.ensure('second', 7)
  assert.equal(next.record.displayNo, 2)
  assert.equal(store.invite.redeemedCount, 1)
  assert.equal(store.invite.nextDisplayNo, 3)
})
