'use strict'

const { TextDecoder } = require('util')
const { MAX_BYTES, qualityFeedbackConfig, handleQualityFeedback } = require('./qualityFeedbackService')
const { createCloudQualityFeedbackStore } = require('./qualityFeedbackStore')
const { verifyFeedbackUser } = require('./qualityFeedbackAuth')
const SUBMIT = '/v1/trial/quality-feedback'
const CAPABILITY = `${SUBMIT}/capability`
const failure = (statusCode, code) => ({ statusCode, headers: {
  'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store'
}, body: JSON.stringify({ error: { code } }) })

function rawBody(event, maximum) {
  if (event.body == null) return ''
  // Object bodies have already lost their wire representation. Never stringify
  // them and pretend the result is the client's signed snapshot bytes.
  if (typeof event.body !== 'string' || (event.isBase64Encoded != null && typeof event.isBase64Encoded !== 'boolean')) throw Error()
  if (event.isBase64Encoded) {
    if (event.body.length > 4 * Math.ceil(maximum / 3) ||
        !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(event.body)) throw Error()
    const bytes = Buffer.from(event.body, 'base64')
    if (bytes.length > maximum || bytes.toString('base64') !== event.body) throw Error()
    return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes)
  }
  if (Buffer.byteLength(event.body, 'utf8') > maximum ||
      Buffer.from(event.body, 'utf8').toString('utf8') !== event.body) throw Error()
  return event.body
}

function cloudStore(envId) {
  const db = require('@cloudbase/node-sdk').init({ env: envId }).database()
  return createCloudQualityFeedbackStore(db, { createCollections: false })
}

function createFeedbackReceiver({ readEnvironment = () => process.env, now = () => Date.now(),
  verifyUser = verifyFeedbackUser, storeFactory = cloudStore } = {}) {
  return async function main(event = {}) {
    try {
      const method = event.httpMethod || event.method
      const path = event.path || event.requestContext?.path
      if (typeof path !== 'string' || ![SUBMIT, CAPABILITY].includes(path.split('?')[0])) return failure(404, 'quality_feedback_route')
      const capability = path.split('?')[0] === CAPABILITY
      if (method !== (capability ? 'GET' : 'POST') ||
          (event.method && event.httpMethod && event.method !== event.httpMethod)) return failure(405, 'quality_feedback_method')
      const env = readEnvironment()
      const config = qualityFeedbackConfig(env)
      if (!config.enabled) return failure(503, 'quality_feedback_unavailable')
      const envId = env.CLOUDBASE_ENV_ID
      if (typeof envId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(envId)) return failure(503, 'quality_feedback_unavailable')
      const headers = {}
      for (const [key, value] of Object.entries(event.headers || {})) {
        const normalized = key.toLowerCase()
        if (Object.hasOwn(headers, normalized) || typeof value !== 'string') return failure(400, 'quality_feedback_headers')
        headers[normalized] = value
      }
      let raw
      try { raw = rawBody(event, Math.min(config.maxBytes, MAX_BYTES)) } catch { return failure(400, 'quality_feedback_body') }
      if (capability && raw) return failure(405, 'quality_feedback_method')
      // Lazy factory: unauthorized, malformed and disabled calls cannot touch DB.
      const store = {
        available: async () => storeFactory(envId).available(),
        submit: async (...args) => storeFactory(envId).submit(...args)
      }
      const result = await handleQualityFeedback({ method, capability, headers, rawBody: raw,
        verifyUser, now, env: { gateway: `https://${envId}.api.tcloudbasegateway.com` },
        qualityFeedbackStore: store, qualityFeedbackConfig: config })
      return { statusCode: result.status, headers: result.headers, body: result.body }
    } catch { return failure(503, 'quality_feedback_unavailable') }
  }
}

module.exports = { SUBMIT, CAPABILITY, createFeedbackReceiver, main: createFeedbackReceiver() }
