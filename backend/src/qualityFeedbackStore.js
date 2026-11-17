'use strict'

const crypto = require('crypto')
const { ensureCollection, initApp } = require('./cloudBaseStore')
const SNAPSHOTS = 'trial_quality_feedback'
const QUOTAS = 'trial_quality_feedback_quota'
const HOUR = 60 * 60 * 1000
const hash = text => crypto.createHash('sha256').update(text).digest('hex')
const clone = value => value == null ? null : JSON.parse(JSON.stringify(value))

// All decisions and both writes share one database transaction/account contention key.
function transactionalStore(adapter) {
  return {
    async submit(uid, payload, digest, now, config) {
      return adapter.transaction(async tx => {
        const id = hash(`${uid}\0${payload.resultID}`)
        const previous = await tx.get(SNAPSHOTS, id)
        if (previous && previous.expiresAt > now) {
          return previous.digest === digest ? { code: 'ok', ...previous.ack } : { code: 'collision' }
        }
        const quotaId = hash(uid)
        const quota = await tx.get(QUOTAS, quotaId)
        const events = (quota?.events || []).filter(time => time > now - HOUR)
        if (events.length >= config.hourlyLimit) return { code: 'limited' }
        const expiresAt = now + config.retentionDays * 86400000
        const ack = { schemaVersion: 1, resultID: payload.resultID, snapshotSHA256: digest, ownerID: uid, status: 'submitted', expiresAt }
        await tx.set(SNAPSHOTS, id, { accountId: uid, payload, digest, createdAt: now, expiresAt, ack })
        await tx.set(QUOTAS, quotaId, { events: [...events, now], expiresAt: now + HOUR })
        return { code: 'ok', ...ack }
      })
    },
    // Scheduler/internal API only. Never routed through the public user handler.
    async purge(now, limit = 100) {
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new Error('invalid purge bound')
      let removed = 0
      for (const collection of [SNAPSHOTS, QUOTAS]) {
        const ids = await adapter.expired(collection, now, limit)
        for (const id of ids) {
          removed += await adapter.transaction(async tx => {
            const current = await tx.get(collection, id)
            if (!current || current.expiresAt > now) return 0
            await tx.remove(collection, id)
            return 1
          })
        }
      }
      return { removed, maximumInspected: limit * 2 }
    }
  }
}

// Offline/test adapter only: this lock is NOT a cross-instance production database.
function createMemoryQualityFeedbackStore() {
  const collections = new Map([[SNAPSHOTS, new Map()], [QUOTAS, new Map()]])
  let chain = Promise.resolve()
  const adapter = {
    transaction(fn) {
      const run = chain.then(async () => {
        const staged = new Map([...collections].map(([k, rows]) => [k, new Map([...rows].map(([id, doc]) => [id, clone(doc)]))]))
        const result = await fn({
          get: async (c, id) => clone(staged.get(c).get(id)),
          set: async (c, id, doc) => { staged.get(c).set(id, clone(doc)) },
          remove: async (c, id) => { staged.get(c).delete(id) }
        })
        for (const [c, rows] of staged) collections.set(c, rows)
        return result
      })
      chain = run.catch(() => {})
      return run
    },
    async expired(c, now, limit) {
      await chain
      return [...collections.get(c)].filter(([, d]) => d.expiresAt <= now).slice(0, limit).map(([id]) => id)
    }
  }
  return { ...transactionalStore(adapter), available: async () => true, inspect: () => clone(Object.fromEntries([...collections].map(([k, rows]) => [k, [...rows.values()]]))) }
}

function createCloudQualityFeedbackStore(database) {
  const db = database || initApp().database()
  const ready = () => Promise.all([ensureCollection(db, SNAPSHOTS), ensureCollection(db, QUOTAS)])
  const store = transactionalStore({
    async transaction(fn) {
      await ready()
      for (let attempt = 0; attempt < 4; attempt++) {
        const transaction = await db.startTransaction()
        try {
          const result = await fn({
            async get(c, id) {
              try {
                const snap = await transaction.collection(c).doc(id).get()
                const data = Array.isArray(snap.data) ? snap.data[0] : snap.data
                return data && Object.keys(data).length ? data : null
              } catch (error) {
                if (/DOCUMENT_NOT_FOUND/.test(String(error.code))) return null
                throw error
              }
            },
            set: (c, id, doc) => transaction.collection(c).doc(id).set(doc),
            remove: (c, id) => transaction.collection(c).doc(id).remove()
          })
          await transaction.commit()
          return result
        } catch (error) {
          await transaction.rollback().catch(() => {})
          if (attempt === 3 || !/^(CONFLICT|TRANSACTION_CONFLICT|DATABASE_TRANSACTION_CONFLICT|ABORTED)$/.test(String(error.code))) throw error
        }
      }
    },
    async expired(c, now, limit) {
      await ready()
      const result = await db.collection(c).where({ expiresAt: db.command.lte(now) }).limit(limit).get()
      return (result.data || []).map(doc => doc._id)
    }
  })
  return { ...store, async available() {
    await ready()
    if (typeof db.command?.lte !== 'function' || typeof db.collection(SNAPSHOTS).where !== 'function') return false
    const transaction = await db.startTransaction()
    try {
      const doc = transaction.collection(SNAPSHOTS).doc('__capability_probe__')
      if (typeof doc.set !== 'function' || typeof doc.remove !== 'function') return false
      await doc.get() // No user body, no write; write IAM still must be verified before activation.
      return true
    } finally { await transaction.rollback() }
  } }
}

// No in-memory fallback in a real runtime. Activation and DB setup are explicit.
let cloudStore
function configuredQualityFeedbackStore() {
  if (process.env.QUALITY_FEEDBACK_ENABLED !== 'true' || process.env.TRIAL_STORE !== 'cloudbase') return null
  if (!cloudStore) cloudStore = createCloudQualityFeedbackStore()
  return cloudStore
}

module.exports = { SNAPSHOTS, QUOTAS, HOUR, transactionalStore, createMemoryQualityFeedbackStore, createCloudQualityFeedbackStore, configuredQualityFeedbackStore }
