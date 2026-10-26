'use strict'

const { MESSAGES } = require('./trialPolicy')
const { bearerToken, errorResult } = require('./trialService')

const SURFACES = new Set([
  'selection_translate',
  'screenshot_ocr_translate',
  'tts',
  'term_explanation',
  'login',
  'invite_redeem'
])

const CATEGORIES = new Set([
  'network',
  'timeout',
  'quota',
  'rate_limit',
  'permission',
  'config',
  'length',
  'unavailable',
  'invite',
  'quality',
  'empty_input',
  'selection',
  'auth',
  'ocr',
  'parse',
  'empty_output',
  'invariant',
  'unknown'
])

const SUMMARY_PATTERN = /^[A-Za-z][A-Za-z0-9]{0,40}(\.[A-Za-z][A-Za-z0-9]{0,40}){0,3}$/
const VERSION_PATTERN = /^[0-9]+(\.[0-9]+){0,3}$/
const BUILD_PATTERN = /^[0-9]{1,8}$/
const OS_PATTERN = /^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$/
const DISPLAY_ID_PATTERN = /^[0-9]{5,12}$/
const PHONE_PATTERN = /^(\+?86)?1[3-9][0-9]{9}$/
const USER_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/
const WEEK_MS = 7 * 24 * 60 * 60 * 1000
const SKEW_MS = 5 * 60 * 1000

function safeUserId(uid) {
  const value = String(uid || '').trim()
  if (!USER_ID_PATTERN.test(value)) return null
  if (PHONE_PATTERN.test(value)) return null
  return value
}

function safeDisplayId(value, uid) {
  if (!uid) return null
  const text = String(value || '').trim()
  if (!DISPLAY_ID_PATTERN.test(text)) return null
  if (PHONE_PATTERN.test(text)) return null
  return text
}

function safeSummary(kind, value) {
  if (kind !== 'bug') return null
  const text = String(value || '').trim()
  if (!SUMMARY_PATTERN.test(text)) return null
  return text
}

function safeDeviceHash(value) {
  const text = String(value || '').trim().toLowerCase()
  if (!/^[a-f0-9]{64}$/.test(text)) return null
  return text
}

function clampOccurredAt(value, now) {
  const parsed = Date.parse(value)
  const current = Number(now) || Date.now()
  if (!Number.isFinite(parsed)) return new Date(current).toISOString()
  const clamped = Math.min(current + SKEW_MS, Math.max(current - WEEK_MS, parsed))
  return new Date(clamped).toISOString()
}

function httpStatus(value) {
  if (typeof value !== 'number' || !Number.isInteger(value)) return null
  if (value < 100 || value > 599) return null
  return value
}

// Copies only the allowlisted fields. Source text, prompts, keys, tokens,
// phones, and any other property on the request are dropped on the floor.
function buildErrorDocument(input, { uid, now } = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { ok: false, status: 400, code: 'trial_error_invalid' }
  }
  const surface = input.surface
  const path = input.path
  const kind = input.kind
  const category = input.category
  const appVersion = String(input.appVersion || '').trim()
  const appBuild = String(input.appBuild || '').trim()
  if (!SURFACES.has(surface) || (path !== 'trial' && path !== 'own_key')) {
    return { ok: false, status: 400, code: 'trial_error_invalid' }
  }
  if (kind !== 'business' && kind !== 'bug') {
    return { ok: false, status: 400, code: 'trial_error_invalid' }
  }
  if (!CATEGORIES.has(category)) {
    return { ok: false, status: 400, code: 'trial_error_invalid' }
  }
  if (!VERSION_PATTERN.test(appVersion) || appVersion.length > 20 || !BUILD_PATTERN.test(appBuild)) {
    return { ok: false, status: 400, code: 'trial_error_invalid' }
  }
  const userId = safeUserId(uid)
  const deviceHash = safeDeviceHash(input.deviceHash)
  if (!userId && !deviceHash) {
    return { ok: false, status: 401, code: 'trial_auth' }
  }
  const osRaw = input.osVersion == null ? '' : String(input.osVersion).trim()
  const osVersion = OS_PATTERN.test(osRaw) ? osRaw : null
  const current = Number(now) || Date.now()
  return {
    ok: true,
    event: {
      occurredAt: clampOccurredAt(input.occurredAt, current),
      receivedAt: current,
      surface,
      appVersion,
      appBuild,
      osVersion,
      path,
      userId,
      displayId: safeDisplayId(input.displayId, userId),
      deviceHash,
      kind,
      category,
      httpStatus: httpStatus(input.httpStatus),
      summary: safeSummary(kind, input.summary)
    }
  }
}

class ErrorReportLimiter {
  constructor(options = {}) {
    this.bugCap = options.bugCap || 3
    this.businessCap = options.businessCap || 12
    this.hourlyCap = options.hourlyCap || 300
    this.counts = new Map()
    this.hour = null
    this.hourCount = 0
  }

  allow(identity, kind, surface, category, now) {
    const time = Number(now) || Date.now()
    const hour = Math.floor(time / 3600000)
    if (hour !== this.hour) {
      this.hour = hour
      this.hourCount = 0
    }
    if (this.hourCount >= this.hourlyCap) return false
    const day = new Date(time).toISOString().slice(0, 10)
    const key = `${day}|${identity}|${kind}|${surface}|${category}`
    const cap = kind === 'bug' ? this.bugCap : this.businessCap
    const count = this.counts.get(key) || 0
    if (count >= cap) return false
    this.counts.set(key, count + 1)
    this.hourCount += 1
    if (this.counts.size > 5000) {
      for (const existing of this.counts.keys()) {
        if (!existing.startsWith(day)) this.counts.delete(existing)
      }
    }
    return true
  }
}

const sharedLimiter = new ErrorReportLimiter()

async function resolveUser(ctx) {
  const token = bearerToken(ctx.headers || {})
  if (!token) return { uid: null }
  try {
    const user = await ctx.verifyUser({ gateway: ctx.env && ctx.env.gateway, token })
    const uid = safeUserId(user && user.uid)
    if (!uid) return { error: errorResult(401, 'trial_auth', MESSAGES.auth) }
    return { uid }
  } catch {
    return { error: errorResult(401, 'trial_auth', MESSAGES.auth) }
  }
}

async function handleErrorReport(ctx) {
  const raw = String(ctx.rawBody || '')
  if (Buffer.byteLength(raw, 'utf8') > 2048) {
    return errorResult(413, 'trial_body_limit', MESSAGES.body)
  }
  let input
  try {
    input = JSON.parse(raw)
  } catch {
    return errorResult(400, 'trial_error_invalid', '这次失败没有记下来。')
  }
  const identified = await resolveUser(ctx)
  if (identified.error) return identified.error
  const built = buildErrorDocument(input, { uid: identified.uid, now: ctx.now && ctx.now() })
  if (!built.ok) {
    const message = built.status === 401 ? MESSAGES.auth : '这次失败没有记下来。'
    return errorResult(built.status, built.code, message)
  }
  const event = built.event
  const identity = event.userId || event.deviceHash
  const limiter = ctx.errorRateLimiter || sharedLimiter
  if (!limiter.allow(identity, event.kind, event.surface, event.category, event.receivedAt)) {
    return {
      status: 200,
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
      body: JSON.stringify({ ok: true, dropped: true })
    }
  }
  if (!ctx.errorLog || typeof ctx.errorLog.insert !== 'function') {
    return { status: 204, headers: { 'Cache-Control': 'no-store' }, body: '' }
  }
  try {
    await ctx.errorLog.insert(event)
  } catch (error) {
    const code = (error && (error.causeCode || error.code)) || 'unknown'
    console.error(`error log failed code=${code}`)
    return { status: 204, headers: { 'Cache-Control': 'no-store' }, body: '' }
  }
  return {
    status: 200,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    body: JSON.stringify({ ok: true })
  }
}

module.exports = {
  SURFACES,
  CATEGORIES,
  SUMMARY_PATTERN,
  buildErrorDocument,
  safeUserId,
  safeDisplayId,
  safeSummary,
  ErrorReportLimiter,
  sharedLimiter,
  handleErrorReport
}
