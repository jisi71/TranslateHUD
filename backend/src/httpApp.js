'use strict'

const { defaultForward } = require('./upstream')
const { defaultVerifyUser, handleAccount, handleTranslate, readEnv } = require('./trialService')

function routeOf(urlPath) {
  const clean = String(urlPath || '/').split('?')[0]
  if (clean === '/healthz' || clean.endsWith('/healthz')) return 'health'
  if (clean.endsWith('/trial/account')) return 'account'
  if (clean.endsWith('/chat/completions')) return 'translate'
  return null
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        reject(Object.assign(new Error('too large'), { code: 'LIMIT' }))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

function createRequestListener(deps = {}) {
  const store = deps.store
  const verifyUser = deps.verifyUser || defaultVerifyUser
  const forward = deps.forward || defaultForward
  const env = deps.env || readEnv()
  const now = deps.now || (() => Date.now())
  const bodyLimit = deps.bodyLimit || 48 * 1024

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
    if (req.method !== 'POST' && !(route === 'account' && req.method === 'GET')) {
      res.writeHead(405, { 'Content-Type': 'application/json; charset=utf-8' })
      res.end(JSON.stringify({ error: { code: 'method', message: '请用 POST。' } }))
      return
    }

    // req "close" also fires when the body has been read, while the response
    // is still open. Aborting there cancels every upstream call. Only stop
    // the upstream when the client goes away before the response finishes.
    const abort = new AbortController()
    res.on('close', () => {
      if (!res.writableEnded) abort.abort()
    })

    try {
      const rawBody = req.method === 'GET' ? '' : await readBody(req, bodyLimit)
      const ctx = {
        headers: req.headers,
        rawBody,
        store,
        verifyUser,
        forward,
        env,
        now,
        signal: abort.signal
      }
      const result = route === 'account' ? await handleAccount(ctx) : await handleTranslate(ctx)
      if (result.aborted || res.writableEnded) return
      res.writeHead(result.status, result.headers || { 'Content-Type': 'application/json; charset=utf-8' })
      if (result.stream) {
        result.stream.on('error', async () => {
          // Headers are already on the wire. A client disconnect is not a
          // failed translation, so the charge stays. An upstream break before
          // the client leaves is refunded.
          const clientLeft = abort.signal.aborted && res.headersSent
          if (!clientLeft && typeof result.refund === 'function') {
            await result.refund().catch(() => {})
          }
          if (!res.writableEnded) res.destroy()
        })
        result.stream.pipe(res)
        return
      }
      res.end(result.body || '')
    } catch (error) {
      if (res.writableEnded) return
      const tooLarge = error && error.code === 'LIMIT'
      const status = tooLarge ? 413 : 500
      const code = tooLarge ? 'trial_body_limit' : 'trial_upstream'
      const message = tooLarge
        ? '这次请求太长了，请缩短原文后再试。'
        : '体验翻译暂时没有完成，额度已退回。请稍后再试。'
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' })
      res.end(JSON.stringify({ error: { code, message } }))
    }
  }
}

module.exports = { createRequestListener, routeOf }
