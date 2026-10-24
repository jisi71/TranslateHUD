'use strict'

const { MESSAGES, decodeSourceHeader, quoteSource } = require('./trialPolicy')
const { prepareUpstreamPayload, readUpstreamConfig } = require('./upstream')

const MAX_BODY_BYTES = 48 * 1024

function errorResult(status, code, message) {
  return {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    body: JSON.stringify({ error: { code, message } })
  }
}

function bearerToken(headers) {
  const raw = headers.authorization || headers.Authorization || ''
  const match = String(raw).match(/^Bearer\s+(\S+)/i)
  return match ? match[1] : ''
}

function sourceHeader(headers) {
  return headers['x-translatehud-source'] || headers['X-TranslateHUD-Source'] || ''
}

function readEnv(source = process.env) {
  const envId = String(source.CLOUDBASE_ENV_ID || 'translatehud-d4gl951eo8bef4702').trim()
  return {
    envId,
    gateway: `https://${envId}.api.tcloudbasegateway.com`,
    apiKey: source.TRANSLATION_API_KEY || '',
    baseURL: source.TRANSLATION_BASE_URL || '',
    model: source.TRANSLATION_MODEL || ''
  }
}

async function defaultVerifyUser({ gateway, token, fetchImpl }) {
  const doFetch = fetchImpl || fetch
  const response = await doFetch(`${gateway}/auth/v1/user/me`, {
    headers: { Authorization: `Bearer ${token}` }
  })
  if (!response.ok) {
    const error = new Error('unauthorized')
    error.status = 401
    error.code = 'trial_auth'
    throw error
  }
  const body = await response.json()
  const uid = String(body.sub || body.user_id || '').trim()
  if (!uid) {
    const error = new Error('unauthorized')
    error.status = 401
    error.code = 'trial_auth'
    throw error
  }
  return { uid }
}

async function identify(ctx) {
  const token = bearerToken(ctx.headers || {})
  if (!token) return errorResult(401, 'trial_auth', MESSAGES.auth)
  try {
    const user = await ctx.verifyUser({ gateway: ctx.env.gateway, token })
    if (!user || !user.uid) return errorResult(401, 'trial_auth', MESSAGES.auth)
    return { uid: String(user.uid) }
  } catch {
    return errorResult(401, 'trial_auth', MESSAGES.auth)
  }
}

function storeFailure(error) {
  console.error(`trial store failed code=${(error && (error.causeCode || error.code)) || 'unknown'}`)
  return errorResult(503, 'trial_store', MESSAGES.store)
}

async function handleAccount(ctx) {
  const identified = await identify(ctx)
  if (identified.status) return identified
  try {
    const opened = await ctx.store.ensure(identified.uid, ctx.now())
    return {
      status: 200,
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
      body: JSON.stringify({
        userId: identified.uid,
        balanceFen: opened.record.balanceFen,
        giftedNow: opened.giftedNow,
        giftFen: opened.giftedNow ? opened.record.balanceFen : 0
      })
    }
  } catch (error) {
    return storeFailure(error)
  }
}

async function handleTranslate(ctx) {
  const rawBody = ctx.rawBody || ''
  if (Buffer.byteLength(rawBody) > MAX_BODY_BYTES) {
    return errorResult(413, 'trial_body_limit', MESSAGES.body)
  }
  const identified = await identify(ctx)
  if (identified.status) return identified

  const decoded = decodeSourceHeader(sourceHeader(ctx.headers || {}))
  if (!decoded.ok) return errorResult(decoded.status, decoded.code, decoded.message)
  const quote = quoteSource(decoded.text)
  if (!quote.ok) return errorResult(quote.status, quote.code, quote.message)

  const config = readUpstreamConfig(ctx.env)
  if (!config.ok) return errorResult(config.status, config.code, config.message)

  let payload
  let stream
  try {
    const prepared = prepareUpstreamPayload(rawBody, config)
    payload = prepared.payload
    stream = prepared.stream
  } catch (error) {
    return errorResult(error.status || 400, error.code || 'trial_body', error.publicMessage || MESSAGES.body)
  }

  // Gift first, then charge. A rejected request above does not create the gift.
  let charged
  try {
    await ctx.store.ensure(identified.uid, ctx.now())
    charged = await ctx.store.charge(identified.uid, quote.costFen)
  } catch (error) {
    return storeFailure(error)
  }
  if (!charged.ok) return errorResult(charged.status, charged.code, charged.message)

  let refunded = false
  const refund = async () => {
    if (refunded) return
    refunded = true
    await ctx.store.refund(identified.uid, quote.costFen)
  }

  try {
    const upstream = await ctx.forward({
      endpoint: config.endpoint,
      apiKey: config.apiKey,
      payload,
      signal: ctx.signal
    })
    if (!upstream || upstream.status < 200 || upstream.status >= 300) {
      await refund()
      console.error(`trial upstream failed status=${upstream && upstream.status} uid=${identified.uid}`)
      return errorResult(502, 'trial_upstream', MESSAGES.upstream)
    }
    const headers = {
      'Cache-Control': 'no-cache, no-transform',
      'X-Accel-Buffering': 'no',
      'X-Trial-Balance-Fen': String(charged.balanceFen)
    }
    if (stream) {
      if (!upstream.stream) {
        await refund()
        return errorResult(502, 'trial_upstream', MESSAGES.upstream)
      }
      headers['Content-Type'] = 'text/event-stream; charset=utf-8'
      return { status: 200, headers, stream: upstream.stream, refund }
    }
    const text = upstream.text || ''
    let parsed = null
    try { parsed = JSON.parse(text) } catch { parsed = null }
    if (parsed && parsed.error) {
      await refund()
      console.error(`trial upstream error object uid=${identified.uid}`)
      return errorResult(502, 'trial_upstream', MESSAGES.upstream)
    }
    headers['Content-Type'] = 'application/json; charset=utf-8'
    return { status: 200, headers, body: text }
  } catch (error) {
    await refund()
    if (ctx.signal && ctx.signal.aborted) return { status: 499, aborted: true, headers: {}, body: '' }
    console.error(`trial upstream threw uid=${identified.uid}`)
    return errorResult(502, 'trial_upstream', MESSAGES.upstream)
  }
}

module.exports = {
  MAX_BODY_BYTES,
  bearerToken,
  readEnv,
  defaultVerifyUser,
  handleAccount,
  handleTranslate,
  errorResult,
  storeFailure
}
