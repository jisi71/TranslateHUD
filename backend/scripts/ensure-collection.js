'use strict'

// Creates the document-database collections if they are missing.
// From backend/: npm install && npm run ensure-collection
// The running service also does this on the first balance read and the first
// feedback submit. Failure records use trial_error_events, created here and
// again on the first error write, not during a balance read.
// Usage records use trial_usage_events, created on the first settled call.

const { COLLECTION, ERROR_COLLECTION, USAGE_COLLECTION, INVITE_COLLECTION, ensureCollection, initApp } = require('../src/cloudBaseStore')
const { FEEDBACK_COLLECTION } = require('../src/feedbackStore')

async function main() {
  const db = initApp().database()
  await ensureCollection(db, COLLECTION)
  await ensureCollection(db, INVITE_COLLECTION)
  await ensureCollection(db, FEEDBACK_COLLECTION)
  await ensureCollection(db, ERROR_COLLECTION)
  await ensureCollection(db, USAGE_COLLECTION)
  console.log('trial_accounts、trial_invite、trial_feedback、trial_error_events 和 trial_usage_events 已就绪')
}

main().catch((error) => {
  const code = (error && (error.causeCode || error.code)) || 'trial_store'
  console.error(`没能准备账本集合（${code}）。请确认 CLOUDBASE_ENV_ID、TENCENT_SECRET_ID 和 TENCENT_SECRET_KEY。`)
  process.exit(1)
})
