'use strict'

const crypto = require('crypto')
const { configuredQualityFeedbackStore } = require('./qualityFeedbackStore')
const MAX_BYTES = 256 * 1024
const KEYS = ['schemaVersion', 'resultID', 'ownerID', 'sourceItems', 'providerCandidates', 'displaySources', 'displayCandidates', 'target', 'itemFailures', 'additionalFailures', 'appVersion', 'origin', 'providerModel']
const FLAGS = ['emptyOutput', 'echoedInput', 'refusalDetected', 'codeFenceWrapped', 'underTranslated', 'missingTargetLanguageContent']
const TARGETS = ['en', 'zh-Hans', 'ja', 'ko', 'fr', 'de', 'es', 'it', 'pt', 'ru', 'ar']
const HEADERS = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }
const response = (status, body) => ({ status, headers: HEADERS, body: JSON.stringify(body) })
const failure = (status, code) => response(status, { error: { code } }) // No source/candidate/error reflection or body logging.
function bounded(value, fallback, min, max) {
  const number = Number(value)
  return Number.isSafeInteger(number) && number >= min && number <= max ? number : fallback
}
function qualityFeedbackConfig(env = process.env) {
  return {
    enabled: env.QUALITY_FEEDBACK_ENABLED === 'true',
    maxBytes: bounded(env.QUALITY_FEEDBACK_MAX_BYTES, MAX_BYTES, 1024, MAX_BYTES),
    hourlyLimit: bounded(env.QUALITY_FEEDBACK_HOURLY_LIMIT, 10, 1, 100),
    retentionDays: bounded(env.QUALITY_FEEDBACK_RETENTION_DAYS, 30, 1, 90)
  }
}
function validText(s, max = MAX_BYTES) {
  return typeof s === 'string' && s.trim().length > 0 && !s.includes('\0') && Buffer.byteLength(s, 'utf8') <= max && Buffer.from(s, 'utf8').toString('utf8') === s
}
function schema(p) {
  if (!p || typeof p !== 'object' || Array.isArray(p) || Object.keys(p).length !== KEYS.length || KEYS.some(k => !Object.hasOwn(p, k))) return false
  if (p.schemaVersion !== 1 || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(p.resultID)) return false
  if (!validText(p.ownerID, 256) || !TARGETS.includes(p.target) || !validText(p.appVersion, 80) || !validText(p.origin, 128) || !validText(p.providerModel, 256)) return false
  if (!Array.isArray(p.sourceItems) || p.sourceItems.length < 1 || p.sourceItems.length > 256 || !Array.isArray(p.providerCandidates) || p.providerCandidates.length !== p.sourceItems.length) return false
  if (!Array.isArray(p.displaySources) || !p.displaySources.length || p.displaySources.length > 256 || !Array.isArray(p.displayCandidates) || p.displayCandidates.length !== p.displaySources.length) return false
  if (![...p.sourceItems, ...p.providerCandidates, ...p.displaySources, ...p.displayCandidates].every(s => validText(s))) return false
  if (!Array.isArray(p.itemFailures) || p.itemFailures.length !== p.sourceItems.length || !Array.isArray(p.additionalFailures)) return false
  const groups = [...p.itemFailures, p.additionalFailures]
  return groups.every(g => Array.isArray(g) && g.length <= 32 && g.every(f => FLAGS.includes(f))) && groups.some(g => g.length)
}

async function handleQualityFeedback(ctx) {
  try {
    const token = String(ctx.headers?.authorization || ctx.headers?.Authorization || '').match(/^Bearer\s+(\S+)$/i)?.[1]
    if (!token) return failure(401, 'quality_feedback_auth')
    let user
    try { user = await ctx.verifyUser({ gateway: ctx.env?.gateway, token }) } catch { return failure(401, 'quality_feedback_auth') }
    if (!user || !validText(user.uid, 256)) return failure(401, 'quality_feedback_auth')
    const uid = user.uid
    const config = ctx.qualityFeedbackConfig || qualityFeedbackConfig()
    if (!config.enabled) return failure(503, 'quality_feedback_unavailable')
    const store = ctx.qualityFeedbackStore || configuredQualityFeedbackStore()
    if (!store) return failure(503, 'quality_feedback_unavailable')
    if (ctx.capability === true) {
      if (ctx.method !== 'GET' || ctx.rawBody) return failure(405, 'quality_feedback_method')
      if (typeof store.available !== 'function' || !await store.available()) return failure(503, 'quality_feedback_unavailable')
      return response(200, { schemaVersion: 1, enabled: true, ownerID: uid, maxBytes: config.maxBytes, hourlyLimit: config.hourlyLimit, retentionDays: config.retentionDays, contentTrust: 'authenticated-submitter' })
    }
    if (ctx.method !== 'POST') return failure(405, 'quality_feedback_method')
    const raw = ctx.rawBody || ''
    if (Buffer.byteLength(raw, 'utf8') > config.maxBytes) return failure(413, 'quality_feedback_size')
    let payload
    try { payload = JSON.parse(raw) } catch { return failure(400, 'quality_feedback_schema') }
    if (!schema(payload)) return failure(400, 'quality_feedback_schema')
    if (payload.ownerID !== uid) return failure(403, 'quality_feedback_owner')
    const digest = crypto.createHash('sha256').update(raw, 'utf8').digest('hex')
    if (ctx.headers['x-feedback-snapshot'] !== digest) return failure(400, 'quality_feedback_identity')
    const now = ctx.now()
    if (!Number.isSafeInteger(now) || now < 0) return failure(503, 'quality_feedback_store')
    const saved = await store.submit(uid, payload, digest, now, config)
    if (saved.code === 'collision') return failure(409, 'quality_feedback_collision')
    if (saved.code === 'limited') return failure(429, 'quality_feedback_limit')
    if (saved.code !== 'ok') return failure(503, 'quality_feedback_store')
    const { code, ...ack } = saved
    return response(200, ack)
  } catch { return failure(503, 'quality_feedback_store') }
}

module.exports = { MAX_BYTES, qualityFeedbackConfig, handleQualityFeedback, schema }
