'use strict'

const { graphemeLength } = require('./trialPolicy')

const MAX_TITLE = 80
const MAX_BODY = 2000
const MAX_IMAGES = 4
const MAX_IMAGE_BYTES = 2 * 1024 * 1024
const MAX_IMAGE_BASE64 = 3_000_000
const MIN_IMAGE_BYTES = 24
const MAX_APP_VERSION = 40
const MAX_DEVICE_ID = 80
const MAX_FEEDBACK_BODY = 12 * 1024 * 1024

// Fixed sentences. The Mac app maps the codes and does not show the raw body.
// There is no email field and this service does not send mail.
const FEEDBACK_MESSAGES = {
  title: '请填写标题。',
  body: '请填写问题描述。',
  titleLong: '标题太长了，请缩短后再提交。',
  bodyLong: '描述太长了，请缩短后再提交。',
  images: '最多添加 4 张图片。',
  imageType: '图片格式无法使用，请换一张。',
  imageLarge: '有图片太大了，请换一张小一点的。',
  tooLarge: '这次提交太大了，请少传几张图片。',
  store: '提交没有成功，请稍后再试。',
  auth: '登录已失效。请重新登录后再提交，或退出登录后直接提交。',
  badJson: '提交内容无法读取，请稍后再试。'
}

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

function cleanText(value, newlines) {
  let text = String(value ?? '').replace(/\u0000/g, '')
  if (newlines) text = text.replace(/[\u0001-\u0008\u000B\u000C\u000E-\u001F]/g, '')
  else text = text.replace(/[\u0000-\u001F]+/g, ' ')
  return text.trim()
}

function clip(value, max, stripSpace) {
  let text = cleanText(value, false)
  if (stripSpace) text = text.replace(/\s+/g, '')
  if (!text) return ''
  let count = 0
  let end = 0
  for (const char of text) {
    if (count === max) break
    count += 1
    end += char.length
  }
  return text.slice(0, end)
}

function sniffImage(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < MIN_IMAGE_BYTES || bytes.length > MAX_IMAGE_BYTES) {
    return null
  }
  if (bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
    return { contentType: 'image/jpeg', ext: 'jpg' }
  }
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
    return { contentType: 'image/png', ext: 'png' }
  }
  if (bytes.slice(0, 6).toString('ascii') === 'GIF87a' || bytes.slice(0, 6).toString('ascii') === 'GIF89a') {
    return { contentType: 'image/gif', ext: 'gif' }
  }
  if (bytes.slice(0, 4).toString('ascii') === 'RIFF' && bytes.slice(8, 12).toString('ascii') === 'WEBP') {
    return { contentType: 'image/webp', ext: 'webp' }
  }
  return null
}

function decodeImage(entry) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return { error: 'type' }
  let text = String(entry.data || entry.base64 || '').trim()
  const comma = text.indexOf(',')
  if (text.startsWith('data:') && comma !== -1) text = text.slice(comma + 1)
  text = text.replace(/\s+/g, '')
  if (!text) return { error: 'type' }
  if (text.length > MAX_IMAGE_BASE64) return { error: 'large' }
  const bytes = Buffer.from(text, 'base64')
  if (bytes.length > MAX_IMAGE_BYTES) return { error: 'large' }
  const sniffed = sniffImage(bytes)
  if (!sniffed) return { error: 'type' }
  return { bytes, contentType: sniffed.contentType, ext: sniffed.ext }
}

async function resolveIdentity(ctx) {
  const token = bearerToken(ctx.headers || {})
  if (!token) return { anonymous: true, accountId: '' }
  try {
    const user = await ctx.verifyUser({ gateway: ctx.env.gateway, token })
    if (!user || !user.uid) return { error: errorResult(401, 'feedback_auth', FEEDBACK_MESSAGES.auth) }
    return { anonymous: false, accountId: String(user.uid) }
  } catch {
    return { error: errorResult(401, 'feedback_auth', FEEDBACK_MESSAGES.auth) }
  }
}

function imageFailure(kind) {
  if (kind === 'large') return errorResult(400, 'feedback_image_large', FEEDBACK_MESSAGES.imageLarge)
  return errorResult(400, 'feedback_image_type', FEEDBACK_MESSAGES.imageType)
}

async function acceptFeedback(ctx) {
  if (!ctx.feedbackStore || typeof ctx.feedbackStore.save !== 'function') {
    return errorResult(503, 'feedback_store', FEEDBACK_MESSAGES.store)
  }
  const rawBody = ctx.rawBody || ''
  if (Buffer.byteLength(rawBody) > MAX_FEEDBACK_BODY) {
    return errorResult(413, 'feedback_too_large', FEEDBACK_MESSAGES.tooLarge)
  }
  let payload
  try {
    payload = rawBody.trim() ? JSON.parse(rawBody) : {}
  } catch {
    return errorResult(400, 'feedback_bad_json', FEEDBACK_MESSAGES.badJson)
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return errorResult(400, 'feedback_bad_json', FEEDBACK_MESSAGES.badJson)
  }

  const identity = await resolveIdentity(ctx)
  if (identity.error) return identity.error

  const title = cleanText(payload.title, false)
  const body = cleanText(payload.body, true)
  if (!title) return errorResult(400, 'feedback_title', FEEDBACK_MESSAGES.title)
  if (graphemeLength(title) > MAX_TITLE) return errorResult(400, 'feedback_title_long', FEEDBACK_MESSAGES.titleLong)
  if (!body) return errorResult(400, 'feedback_body', FEEDBACK_MESSAGES.body)
  if (graphemeLength(body) > MAX_BODY) return errorResult(400, 'feedback_body_long', FEEDBACK_MESSAGES.bodyLong)

  const incoming = payload.images == null ? [] : payload.images
  if (!Array.isArray(incoming)) return errorResult(400, 'feedback_image_type', FEEDBACK_MESSAGES.imageType)
  if (incoming.length > MAX_IMAGES) return errorResult(400, 'feedback_image_count', FEEDBACK_MESSAGES.images)

  const images = []
  for (const entry of incoming) {
    const decoded = decodeImage(entry)
    if (decoded.error) return imageFailure(decoded.error)
    images.push(decoded)
  }

  const now = typeof ctx.now === 'function' ? ctx.now() : Date.now()
  const createdAt = new Date(now).toISOString()
  // Email, phone, and any other contact field on the request are ignored.
  const record = {
    title,
    body,
    createdAt,
    appVersion: clip(payload.appVersion, MAX_APP_VERSION, false),
    accountId: identity.accountId,
    anonymous: identity.anonymous,
    deviceId: clip(payload.deviceId, MAX_DEVICE_ID, true)
  }
  const saved = await ctx.feedbackStore.save(record, images)
  if (!saved || !saved.id) {
    const error = new Error('feedback save missing id')
    error.code = 'feedback_store'
    throw error
  }
  return {
    status: 200,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    body: JSON.stringify({ ok: true, id: saved.id })
  }
}

async function handleFeedback(ctx) {
  try {
    return await acceptFeedback(ctx)
  } catch (error) {
    console.error(`feedback store failed code=${(error && (error.causeCode || error.code)) || 'unknown'}`)
    return errorResult(503, 'feedback_store', FEEDBACK_MESSAGES.store)
  }
}

module.exports = {
  MAX_TITLE,
  MAX_BODY,
  MAX_IMAGES,
  MAX_IMAGE_BYTES,
  MAX_FEEDBACK_BODY,
  FEEDBACK_MESSAGES,
  sniffImage,
  handleFeedback
}
