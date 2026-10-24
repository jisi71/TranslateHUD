'use strict'

const { TransactionalAccountStore } = require('./accountStore')
const { MESSAGES, normalizeRecord } = require('./trialPolicy')

const COLLECTION = 'trial_accounts'
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

function ensureCollection(database, name = COLLECTION) {
  let pending = readyByDatabase.get(database)
  if (!pending) {
    pending = createCollectionOnce(database, name).catch((error) => {
      readyByDatabase.delete(database)
      throw error
    })
    readyByDatabase.set(database, pending)
  }
  return pending
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
      await ensureCollection(database)
      return await inner[method](...args)
    } catch (error) {
      if (!isCollectionMissing(error)) throw asStoreError(error)
      readyByDatabase.delete(database)
      try {
        await ensureCollection(database)
        return await inner[method](...args)
      } catch (retryError) {
        throw asStoreError(retryError)
      }
    }
  }

  return {
    ensure: (uid, now) => run('ensure', [uid, now]),
    charge: (uid, costFen) => run('charge', [uid, costFen]),
    refund: (uid, fen) => run('refund', [uid, fen])
  }
}

module.exports = {
  COLLECTION,
  normalizeSnap,
  ensureCollection,
  isCollectionMissing,
  isCollectionAlreadyExists,
  asStoreError,
  initApp,
  createCloudBaseStore
}
