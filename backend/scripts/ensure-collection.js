'use strict'

// Creates the document-database collections if they are missing.
// From backend/: npm install && npm run ensure-collection
// The running service also does this on the first balance read and the first
// feedback submit.

const { COLLECTION, INVITE_COLLECTION, ensureCollection, initApp } = require('../src/cloudBaseStore')
const { FEEDBACK_COLLECTION } = require('../src/feedbackStore')

async function main() {
  const db = initApp().database()
  await ensureCollection(db, COLLECTION)
  await ensureCollection(db, INVITE_COLLECTION)
  await ensureCollection(db, FEEDBACK_COLLECTION)
  console.log('trial_accounts、trial_invite 和 trial_feedback 已就绪')
}

main().catch((error) => {
  const code = (error && (error.causeCode || error.code)) || 'trial_store'
  console.error(`没能准备账本集合（${code}）。请确认 CLOUDBASE_ENV_ID、TENCENT_SECRET_ID 和 TENCENT_SECRET_KEY。`)
  process.exit(1)
})
