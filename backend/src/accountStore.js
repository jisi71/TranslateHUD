'use strict'

const fs = require('fs')
const path = require('path')
const { applyCharge, normalizeRecord, openAccount } = require('./trialPolicy')

function clone(record) {
  const normalized = normalizeRecord(record)
  return normalized ? { ...normalized } : null
}

class MemoryAccountStore {
  constructor() {
    this.users = new Map()
    this.chains = new Map()
  }

  lock(uid, fn) {
    const prev = this.chains.get(uid) || Promise.resolve()
    const run = prev.then(fn, fn)
    this.chains.set(uid, run.then(() => {}, () => {}))
    return run
  }

  async ensure(uid, now = Date.now()) {
    return this.lock(uid, async () => {
      const existing = this.users.get(uid)
      const opened = openAccount(existing ? clone(existing) : null, now)
      if (opened.giftedNow) this.users.set(uid, clone(opened.record))
      return { record: clone(opened.record), giftedNow: opened.giftedNow }
    })
  }

  async charge(uid, costFen) {
    return this.lock(uid, async () => {
      const existing = this.users.get(uid)
      const decision = applyCharge(existing ? clone(existing) : null, costFen)
      if (decision.ok) this.users.set(uid, clone(decision.record))
      return decision
    })
  }

  async refund(uid, fen) {
    const amount = Math.floor(Number(fen) || 0)
    if (amount <= 0) return null
    return this.lock(uid, async () => {
      const existing = this.users.get(uid)
      if (!existing) return null
      const next = clone(existing)
      next.balanceFen += amount
      this.users.set(uid, next)
      return next.balanceFen
    })
  }
}

class FileAccountStore {
  constructor(filePath) {
    this.filePath = filePath
    this.users = new Map()
    this.chain = Promise.resolve()
    this.ready = this.load()
  }

  lock(fn) {
    const run = this.chain.then(async () => {
      await this.ready
      return fn()
    }, async () => {
      await this.ready
      return fn()
    })
    this.chain = run.then(() => {}, () => {})
    return run
  }

  async load() {
    await fs.promises.mkdir(path.dirname(this.filePath), { recursive: true })
    let raw = ''
    try {
      raw = await fs.promises.readFile(this.filePath, 'utf8')
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
    }
    if (!raw.trim()) return
    const parsed = JSON.parse(raw)
    const users = parsed.users || {}
    for (const [uid, record] of Object.entries(users)) {
      const normalized = clone(record)
      if (normalized) this.users.set(uid, normalized)
    }
  }

  async persist() {
    const users = {}
    for (const [uid, record] of this.users) users[uid] = clone(record)
    const tmp = `${this.filePath}.${process.pid}.tmp`
    await fs.promises.writeFile(tmp, JSON.stringify({ users }), 'utf8')
    await fs.promises.rename(tmp, this.filePath)
  }

  async ensure(uid, now = Date.now()) {
    return this.lock(async () => {
      const opened = openAccount(this.users.has(uid) ? clone(this.users.get(uid)) : null, now)
      if (opened.giftedNow) {
        this.users.set(uid, clone(opened.record))
        await this.persist()
      }
      return { record: clone(opened.record), giftedNow: opened.giftedNow }
    })
  }

  async charge(uid, costFen) {
    return this.lock(async () => {
      const decision = applyCharge(this.users.has(uid) ? clone(this.users.get(uid)) : null, costFen)
      if (decision.ok) {
        this.users.set(uid, clone(decision.record))
        await this.persist()
      }
      return decision
    })
  }

  async refund(uid, fen) {
    const amount = Math.floor(Number(fen) || 0)
    if (amount <= 0) return null
    return this.lock(async () => {
      const existing = this.users.get(uid)
      if (!existing) return null
      const next = clone(existing)
      next.balanceFen += amount
      this.users.set(uid, next)
      await this.persist()
      return next.balanceFen
    })
  }
}

function conflict(error) {
  const text = `${error && error.code ? error.code : ''} ${error && error.message ? error.message : error}`
  if (error && error.code === 'CONFLICT') return error
  if (/conflict|冲突|transaction/i.test(text)) {
    const wrapped = new Error('conflict')
    wrapped.code = 'CONFLICT'
    return wrapped
  }
  return null
}

class TransactionalAccountStore {
  constructor(begin) {
    this.begin = begin
  }

  async ensure(uid, now = Date.now()) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        const opened = openAccount(existing, now)
        if (opened.giftedNow) await tx.create(uid, opened.record)
        await tx.commit()
        return { record: clone(opened.record), giftedNow: opened.giftedNow }
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async charge(uid, costFen) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        const decision = applyCharge(existing, costFen)
        if (decision.ok && decision.record !== existing) await tx.save(uid, decision.record)
        await tx.commit()
        return decision
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async refund(uid, fen) {
    const amount = Math.floor(Number(fen) || 0)
    if (amount <= 0) return null
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        if (!existing) {
          await tx.commit()
          return null
        }
        const next = clone(existing)
        next.balanceFen += amount
        await tx.save(uid, next)
        await tx.commit()
        return next.balanceFen
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async withRetry(fn) {
    let last
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        return await fn()
      } catch (error) {
        last = conflict(error) || error
        if (!conflict(error) || attempt === 2) throw last
      }
    }
    throw last
  }
}

function createAccountStoreFromEnv(env = process.env) {
  if (env.TRIAL_STORE === 'cloudbase') {
    const { createCloudBaseStore } = require('./cloudBaseStore')
    return createCloudBaseStore()
  }
  if (env.TRIAL_STORE === 'memory') return new MemoryAccountStore()
  const filePath = env.TRIAL_DATA_FILE || path.join(__dirname, '..', 'data', 'accounts.json')
  return new FileAccountStore(filePath)
}

module.exports = {
  MemoryAccountStore,
  FileAccountStore,
  TransactionalAccountStore,
  createAccountStoreFromEnv
}
