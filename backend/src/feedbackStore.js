'use strict'

const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const { ensureCollection, initApp } = require('./cloudBaseStore')

const FEEDBACK_COLLECTION = 'trial_feedback'

function newId() {
  return crypto.randomBytes(12).toString('hex')
}

function storedImages(id, images, fileIdFor) {
  return images.map((image, index) => {
    const cloudPath = `feedback/${id}/${index}.${image.ext}`
    return {
      fileId: fileIdFor(cloudPath, image),
      cloudPath,
      contentType: image.contentType
    }
  })
}

class MemoryFeedbackStore {
  constructor() {
    this.docs = []
    this.files = []
  }

  async save(record, images) {
    const id = newId()
    const imagesMeta = storedImages(id, images, (cloudPath) => `memory://${cloudPath}`)
    images.forEach((image, index) => {
      this.files.push({
        cloudPath: imagesMeta[index].cloudPath,
        bytes: image.bytes.length,
        contentType: image.contentType
      })
    })
    const doc = { ...record, id, images: imagesMeta }
    this.docs.push(doc)
    return { id, images: imagesMeta }
  }
}

class FileFeedbackStore {
  constructor(filePath) {
    this.filePath = filePath
    this.chain = Promise.resolve()
  }

  lock(fn) {
    const run = this.chain.then(fn, fn)
    this.chain = run.then(() => {}, () => {})
    return run
  }

  async save(record, images) {
    return this.lock(async () => {
      const id = newId()
      const dir = path.join(path.dirname(this.filePath), 'feedback-files', id)
      await fs.promises.mkdir(dir, { recursive: true })
      const imagesMeta = []
      for (let index = 0; index < images.length; index += 1) {
        const image = images[index]
        const filename = `${index}.${image.ext}`
        await fs.promises.writeFile(path.join(dir, filename), image.bytes)
        const cloudPath = `feedback/${id}/${filename}`
        imagesMeta.push({
          fileId: cloudPath,
          cloudPath,
          contentType: image.contentType
        })
      }
      const doc = { ...record, id, images: imagesMeta }
      const all = await readDocs(this.filePath)
      all.push(doc)
      await fs.promises.mkdir(path.dirname(this.filePath), { recursive: true })
      const tmp = `${this.filePath}.${process.pid}.tmp`
      await fs.promises.writeFile(tmp, JSON.stringify(all))
      await fs.promises.rename(tmp, this.filePath)
      return { id, images: imagesMeta }
    })
  }
}

async function readDocs(filePath) {
  try {
    const raw = await fs.promises.readFile(filePath, 'utf8')
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch (error) {
    if (error && error.code === 'ENOENT') return []
    throw error
  }
}

function addResultFailed(result) {
  if (!result || typeof result !== 'object') return false
  const code = result.code
  if (code == null || code === '' || code === 0 || code === '0') return false
  return true
}

function createCloudBaseFeedbackStore(options = {}) {
  let app = options.app || null
  const database = options.database || null
  const uploadFile = options.uploadFile || null
  const deleteFile = options.deleteFile || null

  return {
    async save(record, images) {
      const application = app || (database ? null : initApp())
      if (application) app = application
      const db = database || application.database()
      const upload = uploadFile || ((args) => application.uploadFile(args))
      const remove = deleteFile || (application && typeof application.deleteFile === 'function'
        ? ((args) => application.deleteFile(args))
        : null)
      await ensureCollection(db, FEEDBACK_COLLECTION)
      const id = newId()
      const imagesMeta = []
      try {
        for (let index = 0; index < images.length; index += 1) {
          const image = images[index]
          const cloudPath = `feedback/${id}/${index}.${image.ext}`
          const uploaded = await upload({ cloudPath, fileContent: image.bytes })
          const fileId = uploaded && (uploaded.fileID || uploaded.fileId)
          if (!fileId) {
            const error = new Error('feedback upload missing fileID')
            error.code = 'feedback_upload'
            throw error
          }
          imagesMeta.push({
            fileId: String(fileId),
            cloudPath,
            contentType: image.contentType
          })
        }
        const doc = { ...record, id, images: imagesMeta }
        const collection = db.collection(FEEDBACK_COLLECTION)
        const result = await collection.add({ ...doc })
        if (addResultFailed(result)) {
          const error = new Error('feedback add failed')
          error.code = String(result.code)
          throw error
        }
        return { id, images: imagesMeta }
      } catch (error) {
        if (remove && imagesMeta.length) {
          try {
            await remove({ fileList: imagesMeta.map((image) => image.fileId) })
          } catch {
            // The document was not written. Leftover files stay under feedback/.
          }
        }
        throw error
      }
    }
  }
}

function defaultFeedbackPath(env) {
  if (env.FEEDBACK_DATA_FILE) return env.FEEDBACK_DATA_FILE
  if (env.TRIAL_DATA_FILE) return path.join(path.dirname(env.TRIAL_DATA_FILE), 'feedback.json')
  return path.join(__dirname, '..', 'data', 'feedback.json')
}

function createFeedbackStoreFromEnv(env = process.env) {
  if (env.TRIAL_STORE === 'cloudbase') return createCloudBaseFeedbackStore()
  if (env.TRIAL_STORE === 'memory') return new MemoryFeedbackStore()
  return new FileFeedbackStore(defaultFeedbackPath(env))
}

module.exports = {
  FEEDBACK_COLLECTION,
  MemoryFeedbackStore,
  FileFeedbackStore,
  createCloudBaseFeedbackStore,
  createFeedbackStoreFromEnv
}
