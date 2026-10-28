'use strict'

const fs = require('fs')
const path = require('path')

class MemoryUsageEventStore {
  constructor() {
    this.events = []
  }

  async insert(event) {
    this.events.push({ ...event })
  }
}

class FileUsageEventStore {
  constructor(filePath) {
    this.filePath = filePath
  }

  async insert(event) {
    await fs.promises.mkdir(path.dirname(this.filePath), { recursive: true })
    await fs.promises.appendFile(this.filePath, `${JSON.stringify(event)}\n`, 'utf8')
  }
}

function usageEventPath(env = process.env) {
  if (env.TRIAL_USAGE_EVENTS_FILE) return env.TRIAL_USAGE_EVENTS_FILE
  const accounts = env.TRIAL_DATA_FILE || path.join(__dirname, '..', 'data', 'accounts.json')
  return path.join(path.dirname(accounts), 'usage-events.jsonl')
}

function createCloudBaseUsageEvent(db) {
  const {
    USAGE_COLLECTION,
    ensureCollection,
    initApp,
    isCollectionMissing
  } = require('./cloudBaseStore')
  const database = db || initApp().database()

  async function add(event) {
    await ensureCollection(database, USAGE_COLLECTION)
    await database.collection(USAGE_COLLECTION).add({ ...event })
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

function createUsageEventStoreFromEnv(env = process.env) {
  if (env.TRIAL_STORE === 'cloudbase') return createCloudBaseUsageEvent()
  if (env.TRIAL_STORE === 'memory') return new MemoryUsageEventStore()
  return new FileUsageEventStore(usageEventPath(env))
}

module.exports = {
  USAGE_COLLECTION: require('./cloudBaseStore').USAGE_COLLECTION,
  MemoryUsageEventStore,
  FileUsageEventStore,
  usageEventPath,
  createCloudBaseUsageEvent,
  createUsageEventStoreFromEnv
}
