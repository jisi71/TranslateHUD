'use strict'

const fs = require('fs')
const path = require('path')
const {
  applyCharge,
  assignDisplayNumbers,
  credit,
  normalizeRecord,
  openAccount,
  readDisplayNo,
  releaseFeedbackSlot,
  reserveFeedbackSlot,
  settleCharge
} = require('./trialPolicy')
const { decideRedeem, publicInviteStatus } = require('./invite')
const { acquireSlot, releaseSlot } = require('./inflight')

function clone(record) {
  const normalized = normalizeRecord(record)
  return normalized ? { ...normalized } : null
}

// Up to 19 other accounts that still need a number, oldest first, plus the
// account being opened. Callers that cannot list anyone pass null and only
// the current account is numbered.
function backfillEntries(listed, uid, record) {
  const others = Array.isArray(listed) ? listed : []
  const older = others
    .filter((entry) => entry && entry.uid != null && String(entry.uid) !== String(uid))
    .filter((entry) => readDisplayNo(entry.record) <= 0)
    .sort((a, b) => {
      const createdA = Number(a.record && a.record.createdAt) || 0
      const createdB = Number(b.record && b.record.createdAt) || 0
      if (createdA !== createdB) return createdA - createdB
      const uidA = String(a.uid)
      const uidB = String(b.uid)
      if (uidA < uidB) return -1
      if (uidA > uidB) return 1
      return 0
    })
    .slice(0, 19)
  return [...older, { uid: String(uid), record }]
}

class MemoryAccountStore {
  constructor() {
    this.users = new Map()
    this.chains = new Map()
    this.invite = { redeemedCount: 0 }
    this.inviteChain = Promise.resolve()
  }

  lock(uid, fn) {
    const prev = this.chains.get(uid) || Promise.resolve()
    const run = prev.then(fn, fn)
    this.chains.set(uid, run.then(() => {}, () => {}))
    return run
  }

  inviteLock(fn) {
    const run = this.inviteChain.then(fn, fn)
    this.inviteChain = run.then(() => {}, () => {})
    return run
  }

  async ensure(uid, now = Date.now()) {
    return this.inviteLock(() => this.lock(uid, async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const opened = openAccount(existing, now)
      const entries = []
      for (const [id, record] of this.users) {
        if (id === uid) continue
        entries.push({ uid: id, record: clone(record) })
      }
      entries.push({ uid, record: opened.record })
      const plan = assignDisplayNumbers(entries, this.invite, uid)
      for (const update of plan.updates) this.users.set(update.uid, clone(update.record))
      if (!this.users.has(uid)) this.users.set(uid, clone(opened.record))
      if (plan.updates.length > 0) this.invite = plan.counter
      return { record: clone(this.users.get(uid)), giftedNow: false }
    }))
  }

  async inviteStatus(env = process.env) {
    return this.inviteLock(async () => publicInviteStatus(this.invite, env))
  }

  async redeem(uid, code, now = Date.now(), env = process.env) {
    return this.inviteLock(() => this.lock(uid, async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const prepared = this.prepareNumber(uid, existing, now)
      const decision = decideRedeem({ record: prepared.record, counter: prepared.counter, code, now, env })
      if (!decision.ok) return decision
      for (const update of prepared.others) this.users.set(update.uid, clone(update.record))
      this.users.set(uid, clone(decision.record))
      this.invite = decision.counter
      return decision
    }))
  }

  prepareNumber(uid, existing, now) {
    const opened = openAccount(existing, now)
    if (readDisplayNo(opened.record) > 0) return { record: opened.record, counter: this.invite, others: [] }
    const entries = []
    for (const [id, record] of this.users) {
      if (id === uid) continue
      entries.push({ uid: id, record: clone(record) })
    }
    entries.push({ uid, record: opened.record })
    const plan = assignDisplayNumbers(entries, this.invite, uid)
    const mine = plan.updates.find((update) => update.uid === uid)
    return {
      record: mine ? mine.record : opened.record,
      counter: plan.updates.length > 0 ? plan.counter : this.invite,
      others: plan.updates.filter((update) => update.uid !== uid)
    }
  }

  async acquireInflight(uid, now = Date.now()) {
    return this.lock(uid, async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const decision = acquireSlot(existing, now)
      if (decision.record && (decision.ok || decision.record.inflight !== (existing && existing.inflight))) {
        if (existing || decision.ok) this.users.set(uid, clone(decision.record))
      }
      return decision
    })
  }

  async releaseInflight(uid, slotId) {
    if (!slotId) return null
    return this.lock(uid, async () => {
      const existing = this.users.get(uid)
      if (!existing) return null
      const next = releaseSlot(existing, slotId)
      if (next) this.users.set(uid, clone(next))
      return next
    })
  }

  async charge(uid, costMicroYuan) {
    return this.lock(uid, async () => {
      const existing = this.users.get(uid)
      const decision = applyCharge(existing ? clone(existing) : null, costMicroYuan)
      if (decision.ok) this.users.set(uid, clone(decision.record))
      return decision
    })
  }

  async settle(uid, costMicroYuan) {
    return this.lock(uid, async () => {
      const existing = this.users.get(uid)
      const decision = settleCharge(existing ? clone(existing) : null, costMicroYuan)
      if (decision.record) this.users.set(uid, clone(decision.record))
      return decision
    })
  }

  async refund(uid, microYuan) {
    const amount = Math.floor(Number(microYuan) || 0)
    if (amount <= 0) return null
    return this.lock(uid, async () => {
      const existing = this.users.get(uid)
      if (!existing) return null
      const next = credit(existing, amount)
      this.users.set(uid, next)
      return next.balanceMicroYuan
    })
  }

  async takeFeedback(uid, now = Date.now(), limit = 10) {
    return this.lock(uid, async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const opened = openAccount(existing, now)
      const decision = reserveFeedbackSlot(opened.record, now, limit)
      if (!decision.ok) return decision
      this.users.set(uid, clone(decision.record))
      return decision
    })
  }

  async releaseFeedback(uid, now = Date.now()) {
    return this.lock(uid, async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      if (!existing) return null
      const next = releaseFeedbackSlot(existing, now)
      this.users.set(uid, clone(next))
      return next
    })
  }
}

class FileAccountStore {
  constructor(filePath) {
    this.filePath = filePath
    this.users = new Map()
    this.invite = { redeemedCount: 0 }
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
    if (parsed.invite && typeof parsed.invite === 'object') {
      const count = Math.max(0, Math.floor(Number(parsed.invite.redeemedCount) || 0))
      this.invite = { ...parsed.invite, redeemedCount: count }
    }
  }

  async persist() {
    const users = {}
    for (const [uid, record] of this.users) users[uid] = clone(record)
    const tmp = `${this.filePath}.${process.pid}.tmp`
    await fs.promises.writeFile(tmp, JSON.stringify({ users, invite: this.invite }), 'utf8')
    await fs.promises.rename(tmp, this.filePath)
  }

  async ensure(uid, now = Date.now()) {
    return this.lock(async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const opened = openAccount(existing, now)
      const entries = []
      for (const [id, record] of this.users) {
        if (id === uid) continue
        entries.push({ uid: id, record: clone(record) })
      }
      entries.push({ uid, record: opened.record })
      const plan = assignDisplayNumbers(entries, this.invite, uid)
      if (plan.updates.length === 0 && existing) {
        return { record: clone(existing), giftedNow: false }
      }
      for (const update of plan.updates) this.users.set(update.uid, clone(update.record))
      if (!this.users.has(uid)) this.users.set(uid, clone(opened.record))
      this.invite = plan.counter
      await this.persist()
      return { record: clone(this.users.get(uid)), giftedNow: false }
    })
  }

  async inviteStatus(env = process.env) {
    return this.lock(async () => publicInviteStatus(this.invite, env))
  }

  async redeem(uid, code, now = Date.now(), env = process.env) {
    return this.lock(async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const opened = openAccount(existing, now)
      let record = opened.record
      let counter = this.invite
      let others = []
      if (readDisplayNo(record) <= 0) {
        const entries = []
        for (const [id, saved] of this.users) {
          if (id === uid) continue
          entries.push({ uid: id, record: clone(saved) })
        }
        entries.push({ uid, record })
        const plan = assignDisplayNumbers(entries, counter, uid)
        const mine = plan.updates.find((update) => update.uid === uid)
        if (mine) record = mine.record
        if (plan.updates.length > 0) counter = plan.counter
        others = plan.updates.filter((update) => update.uid !== uid)
      }
      const decision = decideRedeem({ record, counter, code, now, env })
      if (!decision.ok) return decision
      for (const update of others) this.users.set(update.uid, clone(update.record))
      this.users.set(uid, clone(decision.record))
      this.invite = decision.counter
      await this.persist()
      return decision
    })
  }

  async acquireInflight(uid, now = Date.now()) {
    return this.lock(async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const decision = acquireSlot(existing, now)
      if (decision.record && (decision.ok || JSON.stringify(decision.record.inflight) !== JSON.stringify(existing && existing.inflight))) {
        if (existing || decision.ok) {
          this.users.set(uid, clone(decision.record))
          await this.persist()
        }
      }
      return decision
    })
  }

  async releaseInflight(uid, slotId) {
    if (!slotId) return null
    return this.lock(async () => {
      const existing = this.users.get(uid)
      if (!existing) return null
      const next = releaseSlot(existing, slotId)
      if (next) {
        this.users.set(uid, clone(next))
        await this.persist()
      }
      return next
    })
  }

  async charge(uid, costMicroYuan) {
    return this.lock(async () => {
      const decision = applyCharge(this.users.has(uid) ? clone(this.users.get(uid)) : null, costMicroYuan)
      if (decision.ok) {
        this.users.set(uid, clone(decision.record))
        await this.persist()
      }
      return decision
    })
  }

  async settle(uid, costMicroYuan) {
    return this.lock(async () => {
      const decision = settleCharge(this.users.has(uid) ? clone(this.users.get(uid)) : null, costMicroYuan)
      if (decision.record) {
        this.users.set(uid, clone(decision.record))
        await this.persist()
      }
      return decision
    })
  }

  async refund(uid, microYuan) {
    const amount = Math.floor(Number(microYuan) || 0)
    if (amount <= 0) return null
    return this.lock(async () => {
      const existing = this.users.get(uid)
      if (!existing) return null
      const next = credit(existing, amount)
      this.users.set(uid, next)
      await this.persist()
      return next.balanceMicroYuan
    })
  }

  async takeFeedback(uid, now = Date.now(), limit = 10) {
    return this.lock(async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      const opened = openAccount(existing, now)
      const decision = reserveFeedbackSlot(opened.record, now, limit)
      if (!decision.ok) return decision
      this.users.set(uid, clone(decision.record))
      await this.persist()
      return decision
    })
  }

  async releaseFeedback(uid, now = Date.now()) {
    return this.lock(async () => {
      const existing = this.users.has(uid) ? clone(this.users.get(uid)) : null
      if (!existing) return null
      const next = releaseFeedbackSlot(existing, now)
      this.users.set(uid, clone(next))
      await this.persist()
      return next
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
        if (existing && readDisplayNo(opened.record) > 0) {
          await tx.rollback().catch(() => {})
          return { record: clone(opened.record), giftedNow: false }
        }
        let listed = null
        if (typeof tx.listUsers === 'function') {
          try {
            listed = await tx.listUsers()
          } catch {
            listed = null
          }
        }
        const entries = backfillEntries(listed, uid, opened.record)
        const fresh = []
        for (const entry of entries) {
          if (String(entry.uid) === String(uid)) {
            fresh.push({ uid: String(uid), record: opened.record })
            continue
          }
          const current = await tx.get(entry.uid)
          if (!current || readDisplayNo(current) > 0) continue
          fresh.push({ uid: String(entry.uid), record: current })
        }
        const invite = await tx.getInvite()
        const plan = assignDisplayNumbers(fresh, invite, uid)
        for (const update of plan.updates) {
          if (update.uid === String(uid) && !existing) await tx.create(update.uid, update.record)
          else await tx.save(update.uid, update.record)
        }
        if (plan.updates.length === 0 && !existing) await tx.create(uid, opened.record)
        if (plan.updates.length > 0) await tx.saveInvite(plan.counter)
        await tx.commit()
        const mine = plan.updates.find((update) => update.uid === String(uid))
        return { record: clone(mine ? mine.record : opened.record), giftedNow: false }
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async inviteStatus(env = process.env) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const invite = await tx.getInvite()
        await tx.rollback().catch(() => {})
        return publicInviteStatus(invite, env)
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async redeem(uid, code, now = Date.now(), env = process.env) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        const opened = openAccount(existing, now)
        let record = opened.record
        let invite = await tx.getInvite()
        if (readDisplayNo(record) <= 0) {
          const plan = assignDisplayNumbers([{ uid: String(uid), record }], invite, uid)
          const mine = plan.updates.find((update) => update.uid === String(uid))
          if (mine) record = mine.record
          if (plan.updates.length > 0) invite = plan.counter
        }
        const decision = decideRedeem({ record, counter: invite, code, now, env })
        if (!decision.ok) {
          await tx.rollback().catch(() => {})
          return decision
        }
        if (existing) await tx.save(uid, decision.record)
        else await tx.create(uid, decision.record)
        await tx.saveInvite(decision.counter)
        await tx.commit()
        return decision
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async acquireInflight(uid, now = Date.now()) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        const decision = acquireSlot(existing, now)
        const changed = decision.record && JSON.stringify((decision.record && decision.record.inflight) || []) !== JSON.stringify((existing && existing.inflight) || [])
        if (decision.ok || changed) {
          if (existing) await tx.save(uid, decision.record)
          else if (decision.ok) await tx.create(uid, decision.record)
        }
        await tx.commit()
        return decision
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async releaseInflight(uid, slotId) {
    if (!slotId) return null
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        if (!existing) {
          await tx.rollback().catch(() => {})
          return null
        }
        const next = releaseSlot(existing, slotId)
        await tx.save(uid, next)
        await tx.commit()
        return next
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async charge(uid, costMicroYuan) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        const decision = applyCharge(existing, costMicroYuan)
        if (decision.ok && decision.record !== existing) await tx.save(uid, decision.record)
        await tx.commit()
        return decision
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async settle(uid, costMicroYuan) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        const decision = settleCharge(existing, costMicroYuan)
        if (decision.record) await tx.save(uid, decision.record)
        await tx.commit()
        return decision
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async refund(uid, microYuan) {
    const amount = Math.floor(Number(microYuan) || 0)
    if (amount <= 0) return null
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        if (!existing) {
          await tx.commit()
          return null
        }
        const next = credit(existing, amount)
        await tx.save(uid, next)
        await tx.commit()
        return next.balanceMicroYuan
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async takeFeedback(uid, now = Date.now(), limit = 10) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        const opened = openAccount(existing, now)
        const decision = reserveFeedbackSlot(opened.record, now, limit)
        if (!decision.ok) {
          await tx.rollback().catch(() => {})
          return decision
        }
        if (existing) await tx.save(uid, decision.record)
        else await tx.create(uid, decision.record)
        await tx.commit()
        return decision
      } catch (error) {
        await tx.rollback().catch(() => {})
        throw error
      }
    })
  }

  async releaseFeedback(uid, now = Date.now()) {
    return this.withRetry(async () => {
      const tx = await this.begin()
      try {
        const existing = await tx.get(uid)
        if (!existing) {
          await tx.rollback().catch(() => {})
          return null
        }
        const next = releaseFeedbackSlot(existing, now)
        await tx.save(uid, next)
        await tx.commit()
        return next
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
