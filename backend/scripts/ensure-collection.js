'use strict'

// Creates the document-database collection trial_accounts if it is missing.
// From backend/: npm install && npm run ensure-collection
// The running service also does this on the first balance read.

const { ensureCollection, initApp } = require('../src/cloudBaseStore')

async function main() {
  const db = initApp().database()
  await ensureCollection(db)
  console.log('trial_accounts 已就绪')
}

main().catch((error) => {
  const code = (error && (error.causeCode || error.code)) || 'trial_store'
  console.error(`没能准备账本集合（${code}）。请确认 CLOUDBASE_ENV_ID、TENCENT_SECRET_ID 和 TENCENT_SECRET_KEY。`)
  process.exit(1)
})
