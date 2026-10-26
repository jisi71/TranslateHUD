'use strict'

const http = require('http')
const { createAccountStoreFromEnv } = require('./src/accountStore')
const { createErrorLogStoreFromEnv } = require('./src/errorLogStore')
const { createFeedbackStoreFromEnv } = require('./src/feedbackStore')
const { createRequestListener } = require('./src/httpApp')
const { readEnv } = require('./src/trialService')

const env = readEnv()
const store = createAccountStoreFromEnv()
const errorLog = createErrorLogStoreFromEnv()
const feedbackStore = createFeedbackStoreFromEnv()
const port = Number(process.env.PORT || 8787)
const server = http.createServer(createRequestListener({ store, feedbackStore, env, errorLog }))

server.listen(port, () => {
  const keyState = String(env.apiKey || '').trim() ? 'configured' : 'MISSING'
  const storeState = process.env.TRIAL_STORE || 'file'
  console.log(`trial proxy listening on ${port} store=${storeState} translationKey=${keyState}`)
})
