'use strict'

const { Readable } = require('stream')
const { MESSAGES } = require('./trialPolicy')

const JSON_RESPONSE_HOSTS = new Set([
  'api.openai.com',
  'api.deepseek.com',
  'api.moonshot.cn',
  'open.bigmodel.cn',
  'dashscope.aliyuncs.com',
  'openrouter.ai'
])

function chatCompletionsURL(baseURL) {
  const raw = String(baseURL || '').trim()
  if (!raw) return null
  let url
  try {
    url = new URL(raw)
  } catch {
    return null
  }
  if (!['http:', 'https:'].includes(url.protocol)) return null
  if (url.username || url.password) return null
  if (!url.hostname) return null
  let pathname = url.pathname.replace(/\/+$/, '')
  if (!pathname.endsWith('/chat/completions')) pathname += '/chat/completions'
  url.pathname = pathname || '/chat/completions'
  url.search = ''
  url.hash = ''
  return url.toString()
}

function readUpstreamConfig(env) {
  const apiKey = String(env.apiKey || '').trim()
  const model = String(env.model || '').trim()
  const endpoint = chatCompletionsURL(env.baseURL)
  if (!apiKey || !model || !endpoint) {
    return {
      ok: false,
      status: 503,
      code: 'trial_not_configured',
      message: MESSAGES.notConfigured
    }
  }
  return { ok: true, apiKey, model, endpoint }
}

function prepareUpstreamPayload(rawBody, config) {
  let payload
  try {
    payload = JSON.parse(rawBody || '{}')
  } catch {
    const error = new Error('bad json')
    error.status = 400
    error.code = 'trial_body'
    error.publicMessage = MESSAGES.body
    throw error
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    const error = new Error('bad body')
    error.status = 400
    error.code = 'trial_body'
    error.publicMessage = MESSAGES.body
    throw error
  }
  const stream = payload.stream === true
  payload.model = config.model
  let host = ''
  try {
    host = new URL(config.endpoint).hostname.toLowerCase()
  } catch {
    host = ''
  }
  if (host === 'api.deepseek.com') payload.thinking = { type: 'disabled' }
  if (!stream && JSON_RESPONSE_HOSTS.has(host) && !payload.response_format) {
    payload.response_format = { type: 'json_object' }
  }
  return { payload, stream }
}

async function defaultForward({ endpoint, apiKey, payload, signal }) {
  const headers = {
    'Content-Type': 'application/json',
    Accept: payload.stream ? 'text/event-stream' : 'application/json'
  }
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`
  const response = await fetch(endpoint, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload),
    signal
  })
  if (!response.ok || payload.stream !== true) {
    const text = await response.text()
    return { status: response.status, text }
  }
  if (!response.body) return { status: response.status, text: '' }
  return { status: response.status, stream: Readable.fromWeb(response.body) }
}

module.exports = {
  JSON_RESPONSE_HOSTS,
  chatCompletionsURL,
  readUpstreamConfig,
  prepareUpstreamPayload,
  defaultForward
}
