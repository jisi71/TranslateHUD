'use strict'

const { createAccountStoreFromEnv } = require('./accountStore')
const { handleAccount, handleTranslate, readEnv } = require('./trialService')
const { defaultForward } = require('./upstream')
const { defaultVerifyUser } = require('./trialService')
const { MESSAGES } = require('./trialPolicy')

function decodeEventBody(event) {
  const body = event && event.body != null ? event.body : ''
  if (event && event.isBase64Encoded) return Buffer.from(String(body), 'base64').toString('utf8')
  return typeof body === 'string' ? body : JSON.stringify(body || {})
}

async function bufferStream(stream) {
  const chunks = []
  for await (const chunk of stream) chunks.push(Buffer.from(chunk))
  return Buffer.concat(chunks).toString('utf8')
}

function storeFailureBody() {
  return {
    statusCode: 503,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    body: JSON.stringify({ error: { code: 'trial_store', message: MESSAGES.store } })
  }
}

async function dispatch(event, deps) {
  try {
    return await dispatchUnsafe(event, deps)
  } catch (error) {
    console.error(`trial dispatch failed code=${(error && (error.causeCode || error.code)) || 'unknown'}`)
    return storeFailureBody()
  }
}

async function dispatchUnsafe(event, deps) {
  const method = event.httpMethod || event.method || 'POST'
  const path = event.path || event.requestContext && event.requestContext.path || '/'
  const headers = {}
  for (const [key, value] of Object.entries(event.headers || {})) {
    headers[String(key).toLowerCase()] = Array.isArray(value) ? value[0] : value
  }
  const store = deps.store || createAccountStoreFromEnv()
  const ctx = {
    headers,
    rawBody: method === 'GET' ? '' : decodeEventBody(event),
    store,
    verifyUser: deps.verifyUser || defaultVerifyUser,
    forward: deps.forward || defaultForward,
    env: deps.env || readEnv(),
    now: deps.now || (() => Date.now())
  }
  const clean = String(path).split('?')[0]
  const isAccount = clean.endsWith('/trial/account') || (event.action === 'account')
  const result = isAccount ? await handleAccount(ctx) : await handleTranslate(ctx)
  let body = result.body || ''
  if (result.stream) body = await bufferStream(result.stream)
  return {
    statusCode: result.status,
    headers: result.headers || { 'Content-Type': 'application/json; charset=utf-8' },
    body
  }
}

async function main(event = {}) {
  if (!event.httpMethod && !event.path && !event.action && !event.body) {
    return {
      error: {
        code: 'trial_not_configured',
        message: '请通过 HTTP 访问服务调用试用接口。'
      }
    }
  }
  return dispatch(event, {})
}

module.exports = { main, dispatch, bufferStream }
