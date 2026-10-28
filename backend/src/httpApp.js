'use strict'

const { defaultForward } = require('./upstream')
const {
  PUBLIC_HEADERS,
  defaultVerifyUser,
  handleAccount,
  handleInviteStatus,
  handleRedeem,
  handleTranslate,
  readEnv
} = require('./trialService')
const { handleFeedback, FEEDBACK_MESSAGES, MAX_FEEDBACK_BODY } = require('./feedbackService')
const { MESSAGES } = require('./trialPolicy')
const { ErrorReportLimiter, handleErrorReport } = require('./errorLog')

function routeOf(urlPath) {
  const clean = String(urlPath || '/').split('?')[0]
  if (clean === '/healthz' || clean.endsWith('/healthz')) return 'health'
  if (clean.endsWith('/trial/invite-status')) return 'invite-status'
  if (clean.endsWith('/trial/errors')) return 'errors'
  if (clean.endsWith('/trial/redeem')) return 'redeem'
  if (clean.endsWith('/trial/account')) return 'account'
  if (clean.endsWith('/trial/feedback')) return 'feedback'
  if (clean.endsWith('/chat/completions')) return 'translate'
  return null
}

function readBody(req, limit, limitCode) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let settled = false
    const fail = (error) => {
      if (settled) return
      settled = true
      reject(error)
    }
    const succeed = (value) => {
      if (settled) return
      settled = true
      resolve(value)
    }
    req.on('data', (chunk) => {
      if (settled) return
      size += chunk.length
      if (size > limit) {
        fail(Object.assign(new Error('too large'), { code: limitCode || 'LIMIT' }))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => succeed(Buffer.concat(chunks).toString('utf8')))
    req.on('error', fail)
  })
}

function createRequestListener(deps = {}) {
  const store = deps.store
  const verifyUser = deps.verifyUser || defaultVerifyUser
  const forward = deps.forward || defaultForward
  const env = deps.env || readEnv()
  const now = deps.now || (() => Date.now())
  const bodyLimit = deps.bodyLimit || 48 * 1024
  const feedbackBodyLimit = deps.feedbackBodyLimit || MAX_FEEDBACK_BODY
  const feedbackStore = deps.feedbackStore
  const errorLog = deps.errorLog || null
  const errorRateLimiter = deps.errorRateLimiter || new ErrorReportLimiter()
  const errorBodyLimit = 2 * 1024

  return async function listener(req, res) {
    const route = routeOf(req.url || '/')
    if (!route) {
      res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' })
      res.end(JSON.stringify({ error: { code: 'not_found', message: '没有这个接口。' } }))
      return
    }
    if (route === 'health') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' })
      res.end(JSON.stringify({ ok: true }))
      return
    }
    if (route === 'invite-status' && req.method === 'OPTIONS') {
      res.writeHead(204, PUBLIC_HEADERS)
      res.end()
      return
    }
    const methodOk = req.method === 'POST'
      || (route === 'account' && req.method === 'GET')
      || (route === 'invite-status' && req.method === 'GET')
    if (!methodOk) {
      res.writeHead(405, { 'Content-Type': 'application/json; charset=utf-8' })
      res.end(JSON.stringify({ error: { code: 'method', message: '请用 POST。' } }))
      return
    }

    // req "close" also fires when the body has been read, while the response
    // is still open. Aborting there cancels every upstream call. Only stop
    // the upstream when the client goes away before the response finishes.
    let releaseInflight = async () => {}
    const abort = new AbortController()
    res.on('close', () => {
      if (!res.writableEnded) abort.abort()
      releaseInflight().catch(() => {})
    })

    try {
      const isFeedback = route === 'feedback'
      const isErrors = route === 'errors'
      const rawBody = req.method === 'GET'
        ? ''
        : await readBody(
          req,
          isFeedback ? feedbackBodyLimit : (isErrors ? errorBodyLimit : bodyLimit),
          isFeedback ? 'FEEDBACK_LIMIT' : 'LIMIT'
        )
      const ctx = {
        headers: req.headers,
        rawBody,
        store,
        feedbackStore,
        verifyUser,
        forward,
        env,
        now,
        signal: abort.signal,
        usageEvents: deps.usageEvents || null,
        errorLog,
        errorRateLimiter
      }
      let result
      if (route === 'errors') result = await handleErrorReport(ctx)
      else if (route === 'account') result = await handleAccount(ctx)
      else if (route === 'redeem') result = await handleRedeem(ctx)
      else if (route === 'invite-status') result = await handleInviteStatus(ctx)
      else if (isFeedback) result = await handleFeedback(ctx)
      else result = await handleTranslate(ctx)
      if (typeof result.release === 'function') releaseInflight = result.release
      if (result.aborted || res.writableEnded) {
        await releaseInflight()
        return
      }
      res.writeHead(result.status, result.headers || { 'Content-Type': 'application/json; charset=utf-8' })
      if (result.stream) {
        result.stream.on('error', () => {
          // Settlement runs only after the upstream stream ends with usage.
          // An error here means that settlement did not commit, so there is
          // nothing to refund and no grapheme price to fall back to.
          if (!res.writableEnded) res.destroy()
        })
        result.stream.pipe(res)
        return
      }
      res.end(result.body || '')
    } catch (error) {
      if (res.writableEnded) return
      const feedbackTooLarge = error && error.code === 'FEEDBACK_LIMIT'
      const tooLarge = error && error.code === 'LIMIT'
      const storeFailed = error && error.code === 'trial_store'
      const status = (tooLarge || feedbackTooLarge) ? 413 : (storeFailed ? 503 : 500)
      const code = feedbackTooLarge
        ? 'feedback_too_large'
        : (tooLarge ? 'trial_body_limit' : (storeFailed ? 'trial_store' : 'trial_upstream'))
      const message = feedbackTooLarge
        ? FEEDBACK_MESSAGES.tooLarge
        : (tooLarge ? MESSAGES.body : (storeFailed ? MESSAGES.store : MESSAGES.upstream))
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' })
      res.end(JSON.stringify({ error: { code, message } }))
      req.destroy()
    }
  }
}

module.exports = { createRequestListener, routeOf }
