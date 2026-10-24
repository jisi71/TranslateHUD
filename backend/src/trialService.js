'use strict'

const { MESSAGES, decodeSourceHeader, quoteSource } = require('./trialPolicy')
const { prepareUpstreamPayload, readUpstreamConfig } = require('./upstream')
const { costFenFromUsage, parseUsage, readTrialPrices, settlementFields } = require('./usageBilling')
const { createSettlingStream, formatSSE } = require('./usageStream')

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

function usageMissingSSE() {
  return formatSSE({ error: { code: 'trial_usage_missing', message: MESSAGES.usageMissing } })
}

function settlementSSE(settled, usage) {
  return formatSSE({ choices: [], translatehud_trial: settlementFields(settled, usage) })
}

// Balance is only known after usage arrives. Streaming therefore announces the
// charge in a trailing SSE event (choices: [] so an older app skips it) rather
// than in the headers, which have to leave before the first token.
function billingHeaders(settled, usage) {
  const fields = settlementFields(settled, usage)
  return {
    'Cache-Control': 'no-cache, no-transform',
    'X-Accel-Buffering': 'no',
    'X-Trial-Cost-Fen': String(fields.costFen),
    'X-Trial-Charged-Fen': String(fields.chargedFen),
    'X-Trial-Balance-Fen': String(fields.balanceFen),
    'X-Trial-Prompt-Tokens': String(fields.promptTokens),
    'X-Trial-Completion-Tokens': String(fields.completionTokens)
  }
}

async function settleUsage(ctx, uid, usage, prices) {
  const cost = costFenFromUsage(usage, prices)
  if (cost == null) return null
  const settled = await ctx.store.settle(uid, cost)
  return settled
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
  const prices = readTrialPrices(ctx.env)
  if (!prices.ok) return errorResult(prices.status, prices.code, prices.message)

  let payload
  let stream
  try {
    const prepared = prepareUpstreamPayload(rawBody, config, decoded.text)
    payload = prepared.payload
    stream = prepared.stream
  } catch (error) {
    return errorResult(error.status || 400, error.code || 'trial_body', error.publicMessage || MESSAGES.body)
  }

  // Gift first. A rejected request above does not create the gift.
  // Exact tokens are unknown until the upstream responds, so a balance above
  // zero may start the call. Zero does not: that would be an unpaid run.
  let opened
  try {
    opened = await ctx.store.ensure(identified.uid, ctx.now())
  } catch (error) {
    return storeFailure(error)
  }
  if (!opened.record || opened.record.balanceFen <= 0) {
    return errorResult(402, 'trial_balance_exhausted', MESSAGES.exhausted)
  }

  try {
    const upstream = await ctx.forward({
      endpoint: config.endpoint,
      apiKey: config.apiKey,
      payload,
      signal: ctx.signal
    })
    if (!upstream || upstream.status < 200 || upstream.status >= 300) {
      console.error(`trial upstream failed status=${upstream && upstream.status} uid=${identified.uid}`)
      return errorResult(502, 'trial_upstream', MESSAGES.upstream)
    }
    if (stream) {
      if (!upstream.stream) return errorResult(502, 'trial_upstream', MESSAGES.upstream)
      const billed = createSettlingStream(upstream.stream, async (usage) => {
        if (!usage) return usageMissingSSE()
        try {
          const settled = await settleUsage(ctx, identified.uid, usage, prices)
          if (!settled) return usageMissingSSE()
          return settlementSSE(settled, usage)
        } catch (error) {
          console.error(`trial settle failed code=${(error && (error.causeCode || error.code)) || 'unknown'}`)
          return formatSSE({ error: { code: 'trial_store', message: MESSAGES.store } })
        }
      })
      return {
        status: 200,
        headers: {
          'Cache-Control': 'no-cache, no-transform',
          'X-Accel-Buffering': 'no',
          'Content-Type': 'text/event-stream; charset=utf-8'
        },
        stream: billed
      }
    }
    const text = upstream.text || ''
    let parsed = null
    try { parsed = JSON.parse(text) } catch { parsed = null }
    if (parsed && parsed.error) {
      console.error(`trial upstream error object uid=${identified.uid}`)
      return errorResult(502, 'trial_upstream', MESSAGES.upstream)
    }
    const usage = parseUsage(parsed && parsed.usage)
    if (!usage) return errorResult(502, 'trial_usage_missing', MESSAGES.usageMissing)
    let settled
    try {
      settled = await settleUsage(ctx, identified.uid, usage, prices)
    } catch (error) {
      return storeFailure(error)
    }
    if (!settled) return errorResult(502, 'trial_usage_missing', MESSAGES.usageMissing)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      parsed.translatehud_trial = settlementFields(settled, usage)
    }
    return {
      status: 200,
      headers: {
        ...billingHeaders(settled, usage),
        'Content-Type': 'application/json; charset=utf-8'
      },
      body: JSON.stringify(parsed)
    }
  } catch (error) {
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
