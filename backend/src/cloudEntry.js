'use strict'

const { createAccountStoreFromEnv } = require('./accountStore')
const { createFeedbackStoreFromEnv } = require('./feedbackStore')
const {
  handleAccount,
  handleInviteStatus,
  handleRedeem,
  handleTranslate,
  readEnv,
  defaultVerifyUser
} = require('./trialService')
const { handleFeedback, FEEDBACK_MESSAGES } = require('./feedbackService')
const { defaultForward } = require('./upstream')
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
  const clean = String(path).split('?')[0]
  const isFeedback = clean.endsWith('/trial/feedback') || event.action === 'feedback'
  const shared = {
    headers,
    rawBody: method === 'GET' ? '' : decodeEventBody(event),
    verifyUser: deps.verifyUser || defaultVerifyUser,
    env: deps.env || readEnv(),
    now: deps.now || (() => Date.now())
  }
  if (isFeedback) {
    try {
      if (method !== 'POST') {
        return {
          statusCode: 405,
          headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
          body: JSON.stringify({ error: { code: 'method', message: '请用 POST。' } })
        }
      }
      const result = await handleFeedback({
        ...shared,
        feedbackStore: deps.feedbackStore || createFeedbackStoreFromEnv()
      })
      return {
        statusCode: result.status,
        headers: result.headers || { 'Content-Type': 'application/json; charset=utf-8' },
        body: result.body || ''
      }
    } catch (error) {
      console.error(`feedback dispatch failed code=${(error && (error.causeCode || error.code)) || 'unknown'}`)
      return {
        statusCode: 503,
        headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
        body: JSON.stringify({ error: { code: 'feedback_store', message: FEEDBACK_MESSAGES.store } })
      }
    }
  }
  const store = deps.store || createAccountStoreFromEnv()
  const ctx = {
    ...shared,
    store,
    forward: deps.forward || defaultForward
  }
  const isAccount = clean.endsWith('/trial/account') || (event.action === 'account')
  const isRedeem = clean.endsWith('/trial/redeem') || event.action === 'redeem'
  const isInviteStatus = clean.endsWith('/trial/invite-status') || event.action === 'invite-status'
  let result
  if (isInviteStatus) result = await handleInviteStatus(ctx)
  else if (isRedeem) result = await handleRedeem(ctx)
  else if (isAccount) result = await handleAccount(ctx)
  else result = await handleTranslate(ctx)
  if (typeof result.release === 'function') {
    if (result.stream) result.stream.once('close', () => { result.release() })
    else await result.release()
  }
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
