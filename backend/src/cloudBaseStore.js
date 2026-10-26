'use strict'

const { TransactionalAccountStore } = require('./accountStore')
const { MESSAGES, normalizeRecord } = require('./trialPolicy')

const COLLECTION = 'trial_accounts'
const INVITE_COLLECTION = 'trial_invite'
const INVITE_DOC = 'config'
const readyByDatabase = new WeakMap()

function errorText(error) {
  return `${error && error.code != null ? error.code : ''} ${error && error.message ? error.message : error || ''}`
}

function isCollectionAlreadyExists(error) {
  return /already exist|已存在|DATABASE_COLLECTION_ALREADY_EXIST|ResourceInUse|CollectionExist/i.test(errorText(error))
}

function isCollectionMissing(error) {
  return /DATABASE_COLLECTION_NOT_EXIST|COLLECTION_NOT_EXIST|collection.*not exist|集合不存在|Db or Table not exist|table not exist/i.test(errorText(error))
}

function isMissingDocument(error) {
  if (isCollectionMissing(error)) return false
  return /not exist|not found|不存在|DOCUMENT_NOT_FOUND|document not/i.test(errorText(error))
}

function causeCode(error) {
  if (!error || error.code == null || error.code === '') return 'unknown'
  return String(error.code)
}

function asStoreError(error) {
  if (error && error.code === 'trial_store') return error
  const wrapped = new Error('trial store failed')
  wrapped.code = 'trial_store'
  wrapped.status = 503
  wrapped.publicMessage = MESSAGES.store
  wrapped.causeCode = causeCode(error)
  return wrapped
}

function createResultFailed(result) {
  if (!result || typeof result !== 'object') return false
  const code = result.code
  if (code == null || code === '' || code === 0 || code === '0') return false
  if (isCollectionAlreadyExists(result)) return false
  return true
}

// Document databases do not create a collection on the first write.
// createCollection is idempotent: "already exists" is success.
async function createCollectionOnce(database, name) {
  if (!database || typeof database.createCollection !== 'function') {
    const error = new Error('createCollection unavailable')
    error.code = 'createCollection-missing'
    throw asStoreError(error)
  }
  let result
  try {
    result = await database.createCollection(name)
  } catch (error) {
    if (isCollectionAlreadyExists(error)) return
    throw asStoreError(error)
  }
  if (createResultFailed(result)) throw asStoreError(result)
}

function collectionPromises(database) {
  let byName = readyByDatabase.get(database)
  if (!byName) {
    byName = new Map()
    readyByDatabase.set(database, byName)
  }
  return byName
}

function ensureCollection(database, name = COLLECTION) {
  const byName = collectionPromises(database)
  let pending = byName.get(name)
  if (!pending) {
    pending = createCollectionOnce(database, name).catch((error) => {
      byName.delete(name)
      throw error
    })
    byName.set(name, pending)
  }
  return pending
}

function ensureRuntimeCollections(database) {
  return Promise.all([
    ensureCollection(database, COLLECTION),
    ensureCollection(database, INVITE_COLLECTION)
  ])
}

function normalizeInvite(snap) {
  if (!snap) return { redeemedCount: 0 }
  const data = Object.prototype.hasOwnProperty.call(snap, 'data') ? snap.data : snap
  if (!data || Array.isArray(data) || typeof data !== 'object') return { redeemedCount: 0 }
  if (Object.keys(data).length === 0) return { redeemedCount: 0 }
  const count = Math.max(0, Math.floor(Number(data.redeemedCount) || 0))
  const invite = { redeemedCount: count }
  if (data.maxRedeems != null && data.maxRedeems !== '') invite.maxRedeems = data.maxRedeems
  if (data.codes != null) invite.codes = data.codes
  const nextDisplayNo = Math.floor(Number(data.nextDisplayNo))
  if (Number.isSafeInteger(nextDisplayNo) && nextDisplayNo > 0) invite.nextDisplayNo = nextDisplayNo
  return invite
}

function normalizeSnap(snap) {
  if (!snap) return null
  const data = Object.prototype.hasOwnProperty.call(snap, 'data') ? snap.data : snap
  if (!data || Array.isArray(data)) return null
  if (typeof data === 'object' && Object.keys(data).length === 0) return null
  return normalizeRecord(data)
}

function initApp() {
  const tcb = require('@cloudbase/node-sdk')
  const envId = process.env.CLOUDBASE_ENV_ID || 'translatehud-d4gl951eo8bef4702'
  if (process.env.TENCENT_SECRET_ID && process.env.TENCENT_SECRET_KEY) {
    return tcb.init({
      env: envId,
      secretId: process.env.TENCENT_SECRET_ID,
      secretKey: process.env.TENCENT_SECRET_KEY
    })
  }
  return tcb.init({ env: tcb.SYMBOL_CURRENT_ENV || envId })
}

// Best-effort list so older accounts can receive smaller numbers. A query
// failure falls back to numbering only the account being saved.
async function listAccountEntries(database) {
  if (!database || typeof database.collection !== 'function') return null
  const rows = []
  const pageSize = 100
  try {
    for (let offset = 0; offset < 500; offset += pageSize) {
      let query = database.collection(COLLECTION)
      if (typeof query.skip === 'function') query = query.skip(offset)
      if (typeof query.limit === 'function') query = query.limit(pageSize)
      if (typeof query.get !== 'function') return null
      const snap = await query.get()
      const data = Array.isArray(snap && snap.data) ? snap.data : []
      for (const doc of data) {
        if (!doc || typeof doc !== 'object') continue
        const uid = doc._id || doc.id
        if (!uid) continue
        const record = normalizeRecord(doc)
        if (!record) continue
        rows.push({ uid: String(uid), record })
      }
      if (data.length < pageSize) break
    }
    return rows
  } catch {
    return null
  }
}

function createCloudBaseStore(db) {
  const database = db || initApp().database()
  const inner = new TransactionalAccountStore(async () => {
    const transaction = await database.startTransaction()
    return {
      async get(uid) {
        try {
          const snap = await transaction.collection(COLLECTION).doc(uid).get()
          return normalizeSnap(snap)
        } catch (error) {
          if (isMissingDocument(error)) return null
          throw error
        }
      },
      async create(uid, record) {
        await transaction.collection(COLLECTION).doc(String(uid)).set({ ...record })
      },
      async save(uid, record) {
        await transaction.collection(COLLECTION).doc(String(uid)).set({ ...record })
      },
      async getInvite() {
        try {
          const snap = await transaction.collection(INVITE_COLLECTION).doc(INVITE_DOC).get()
          return normalizeInvite(snap)
        } catch (error) {
          if (isMissingDocument(error)) return { redeemedCount: 0 }
          throw error
        }
      },
      async saveInvite(doc) {
        const saved = { redeemedCount: Math.max(0, Math.floor(Number(doc.redeemedCount) || 0)) }
        if (doc.maxRedeems != null && doc.maxRedeems !== '') saved.maxRedeems = doc.maxRedeems
        if (doc.codes != null) saved.codes = doc.codes
        const nextDisplayNo = Math.floor(Number(doc.nextDisplayNo))
        if (Number.isSafeInteger(nextDisplayNo) && nextDisplayNo > 0) saved.nextDisplayNo = nextDisplayNo
        await transaction.collection(INVITE_COLLECTION).doc(INVITE_DOC).set(saved)
      },
      async listUsers() {
        return listAccountEntries(database)
      },
      async commit() {
        await transaction.commit()
      },
      async rollback() {
        try {
          await transaction.rollback()
        } catch {
          // The transaction may already be closed after a conflict.
        }
      }
    }
  })

  async function run(method, args) {
    try {
      await ensureRuntimeCollections(database)
      return await inner[method](...args)
    } catch (error) {
      if (!isCollectionMissing(error)) throw asStoreError(error)
      readyByDatabase.delete(database)
      try {
        await ensureRuntimeCollections(database)
        return await inner[method](...args)
      } catch (retryError) {
        throw asStoreError(retryError)
      }
    }
  }

  return {
    ensure: (uid, now) => run('ensure', [uid, now]),
    inviteStatus: (env) => run('inviteStatus', [env]),
    redeem: (uid, code, now, env) => run('redeem', [uid, code, now, env]),
    acquireInflight: (uid, now) => run('acquireInflight', [uid, now]),
    releaseInflight: (uid, slotId) => run('releaseInflight', [uid, slotId]),
    charge: (uid, costMicroYuan) => run('charge', [uid, costMicroYuan]),
    settle: (uid, costMicroYuan) => run('settle', [uid, costMicroYuan]),
    refund: (uid, microYuan) => run('refund', [uid, microYuan])
  }
}

module.exports = {
  COLLECTION,
  INVITE_COLLECTION,
  INVITE_DOC,
  normalizeSnap,
  normalizeInvite,
  ensureCollection,
  isCollectionMissing,
  isCollectionAlreadyExists,
  asStoreError,
  initApp,
  createCloudBaseStore
}
