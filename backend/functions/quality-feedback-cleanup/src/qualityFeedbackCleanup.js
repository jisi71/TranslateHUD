'use strict'

const { createCloudQualityFeedbackStore } = require('./qualityFeedbackStore')

function configError() {
  return Object.assign(new Error('quality_feedback_cleanup_config'), { code: 'quality_feedback_cleanup_config' })
}

function cleanupConfig(env) {
  // Deliberately independent of the receiving endpoint's QUALITY_FEEDBACK_ENABLED.
  if (env.QUALITY_FEEDBACK_CLEANUP_ENABLED !== 'true') return { enabled: false }
  const batchLimit = env.QUALITY_FEEDBACK_CLEANUP_BATCH_LIMIT == null ? 100 : Number(env.QUALITY_FEEDBACK_CLEANUP_BATCH_LIMIT)
  const envId = env.CLOUDBASE_ENV_ID
  if (!Number.isSafeInteger(batchLimit) || batchLimit < 1 || batchLimit > 100 ||
      typeof envId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(envId)) throw configError()
  return { enabled: true, batchLimit, envId }
}

function cloudStore(config) {
  // Runtime identity is provided by the platform. No supplied event credentials,
  // current-env guess, receiver flag, account store or collection creation.
  const sdk = require('@cloudbase/node-sdk')
  const database = sdk.init({ env: config.envId }).database()
  return createCloudQualityFeedbackStore(database, { createCollections: false })
}

function createCleanupHandler({ readEnvironment = () => process.env, now = () => Date.now(), storeFactory = cloudStore } = {}) {
  return async function main() {
    // No event fields are interpreted, including Type/TriggerName/httpMethod.
    // This is NOT authentication: deployment must permit only private IAM invocation.
    const config = cleanupConfig(readEnvironment())
    if (!config.enabled) return { schemaVersion: 1, status: 'disabled' }
    const cutoff = now()
    if (!Number.isSafeInteger(cutoff) || cutoff < 0) throw configError()
    try {
      const result = await storeFactory(config).purge(cutoff, config.batchLimit)
      return { schemaVersion: 1, status: 'completed', cutoff, batchLimit: config.batchLimit, ...result }
    } catch {
      // Mark invocation failed for scheduler monitoring, without reflecting a
      // driver exception, document body or event into function logs/results.
      throw Object.assign(new Error('quality_feedback_cleanup_failed'), { code: 'quality_feedback_cleanup_failed' })
    }
  }
}

module.exports = { cleanupConfig, createCleanupHandler, main: createCleanupHandler() }
