'use strict'

const fs = require('fs')
const path = require('path')

class MemoryErrorLogStore {
  constructor() {
    this.events = []
  }

  async insert(event) {
    this.events.push({ ...event })
  }
}

class FileErrorLogStore {
  constructor(filePath) {
    this.filePath = filePath
  }

  async insert(event) {
    await fs.promises.mkdir(path.dirname(this.filePath), { recursive: true })
    await fs.promises.appendFile(this.filePath, `${JSON.stringify(event)}\n`, 'utf8')
  }
}

function errorLogPath(env = process.env) {
  if (env.TRIAL_ERROR_LOG_FILE) return env.TRIAL_ERROR_LOG_FILE
  const accounts = env.TRIAL_DATA_FILE || path.join(__dirname, '..', 'data', 'accounts.json')
  return path.join(path.dirname(accounts), 'error-events.jsonl')
}

function createCloudBaseErrorLog(db) {
  const {
    ERROR_COLLECTION,
    ensureCollection,
    initApp,
    isCollectionMissing
  } = require('./cloudBaseStore')
  const database = db || initApp().database()

  async function add(event) {
    await ensureCollection(database, ERROR_COLLECTION)
    await database.collection(ERROR_COLLECTION).add({ ...event })
  }

  return {
    async insert(event) {
      try {
        await add(event)
      } catch (error) {
        if (!isCollectionMissing(error)) throw error
        await add(event)
      }
    }
  }
}

function createErrorLogStoreFromEnv(env = process.env) {
  if (env.TRIAL_STORE === 'cloudbase') return createCloudBaseErrorLog()
  if (env.TRIAL_STORE === 'memory') return new MemoryErrorLogStore()
  return new FileErrorLogStore(errorLogPath(env))
}

module.exports = {
  MemoryErrorLogStore,
  FileErrorLogStore,
  errorLogPath,
  createCloudBaseErrorLog,
  createErrorLogStoreFromEnv
}
