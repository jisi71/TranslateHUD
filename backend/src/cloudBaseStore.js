'use strict'

const { TransactionalAccountStore } = require('./accountStore')
const { normalizeRecord } = require('./trialPolicy')

const COLLECTION = 'trial_accounts'

function normalizeSnap(snap) {
  if (!snap) return null
  const data = Object.prototype.hasOwnProperty.call(snap, 'data') ? snap.data : snap
  if (!data || Array.isArray(data)) return null
  if (typeof data === 'object' && Object.keys(data).length === 0) return null
  return normalizeRecord(data)
}

function isMissingDocument(error) {
  const text = `${error && error.code ? error.code : ''} ${error && error.message ? error.message : error}`
  return /not exist|not found|不存在|DOCUMENT_NOT_FOUND|document not/i.test(text)
}

function initApp() {
  const tcb = require('@cloudbase/node-sdk')
  const envId = process.env.CLOUDBASE_ENV_ID || 'liusheng-d0g430h1f486532bd'
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
  return new TransactionalAccountStore(async () => {
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
}

module.exports = {
  COLLECTION,
  normalizeSnap,
  createCloudBaseStore
}
