'use strict'

// Keep these rules in sync with TranslateHUD/Trial/TrialPricing.swift.
// Length is Unicode extended grapheme clusters (Intl.Segmenter), same as Swift String.count.
// Chinese characters are one grapheme each. A base letter plus a combining mark is one.
// Newlines count. The cap is the source text only, not the prompt around it.

const GIFT_FEN = 200
const MAX_GRAPHEMES = 500

const MESSAGES = {
  length: '超出单次翻译上限（体验额度单次最多 500 字）',
  exhausted: '体验额度已用完。请在设置里填写你自己的 API Key，之后会直接使用你的接口。',
  insufficient: '体验额度不够支付这次翻译。请缩短原文，或在设置里填写你自己的 API Key。',
  auth: '体验登录已失效，请在设置里重新登录。',
  notConfigured: '体验翻译服务还没配置好。请稍后再试，或在设置里填写你自己的 API Key。',
  upstream: '体验翻译暂时没有完成，额度已退回。请稍后再试。',
  empty: '没有可翻译的文字，请重新选中文字或框选包含文字的区域。',
  body: '这次请求太长了，请缩短原文后再试。',
  source: '体验翻译需要原文。请更新到最新版 TranslateHUD。',
  store: '体验余额暂时读不出来。请在设置里点「重新读取」。'
}

function graphemeLength(text) {
  const value = String(text ?? '')
  if (typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function') {
    const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
    let count = 0
    for (const _segment of segmenter.segment(value)) count += 1
    return count
  }
  // Node 20+ has Intl.Segmenter. This fallback skips combining marks so the
  // common "letter + accent" case still counts as one if the runtime is old.
  let count = 0
  for (const char of value) {
    const code = char.codePointAt(0)
    if (code >= 0x0300 && code <= 0x036F) continue
    count += 1
  }
  return count
}

// ¥0.001 per grapheme = 0.1 fen, rounded up to a whole fen, at least 1 fen.
// 10 graphemes → ¥0.01, 500 graphemes → ¥0.50, the ¥2.00 gift covers 2000 graphemes.
function costFen(graphemes) {
  const count = Number(graphemes) || 0
  if (count <= 0) return 0
  return Math.max(1, Math.ceil(count / 10))
}

function quoteSource(text) {
  const graphemes = graphemeLength(text)
  if (graphemes > MAX_GRAPHEMES) {
    return { ok: false, status: 400, code: 'trial_length_limit', message: MESSAGES.length, graphemes }
  }
  if (graphemes <= 0) {
    return { ok: false, status: 400, code: 'trial_empty', message: MESSAGES.empty, graphemes }
  }
  return { ok: true, graphemes, costFen: costFen(graphemes) }
}

function openAccount(existing, now) {
  if (existing) return { record: normalizeRecord(existing), giftedNow: false }
  return {
    giftedNow: true,
    record: {
      balanceFen: GIFT_FEN,
      giftGranted: true,
      createdAt: now
    }
  }
}

function applyCharge(record, costFenValue) {
  const current = record ? normalizeRecord(record) : null
  const cost = Math.floor(Number(costFenValue) || 0)
  if (!current || current.balanceFen <= 0) {
    return {
      ok: false,
      status: 402,
      code: 'trial_balance_exhausted',
      message: MESSAGES.exhausted,
      balanceFen: current ? current.balanceFen : 0
    }
  }
  if (cost <= 0) {
    return { ok: true, record: current, balanceFen: current.balanceFen }
  }
  if (current.balanceFen < cost) {
    return {
      ok: false,
      status: 402,
      code: 'trial_balance_insufficient',
      message: MESSAGES.insufficient,
      balanceFen: current.balanceFen
    }
  }
  const next = {
    balanceFen: current.balanceFen - cost,
    giftGranted: true,
    createdAt: current.createdAt
  }
  return { ok: true, record: next, balanceFen: next.balanceFen }
}

function normalizeRecord(record) {
  if (!record || typeof record !== 'object') return null
  const balance = Number(record.balanceFen)
  if (!Number.isFinite(balance)) {
    return { balanceFen: 0, giftGranted: true, createdAt: record.createdAt || 0 }
  }
  return {
    balanceFen: Math.max(0, Math.floor(balance)),
    giftGranted: record.giftGranted !== false,
    createdAt: record.createdAt || 0
  }
}

function decodeSourceHeader(header) {
  if (header == null || String(header).trim() === '') {
    return { ok: false, status: 400, code: 'trial_source_required', message: MESSAGES.source }
  }
  const raw = String(header).trim()
  if (raw.length > 8192) {
    return { ok: false, status: 400, code: 'trial_length_limit', message: MESSAGES.length }
  }
  const decoded = Buffer.from(raw, 'base64').toString('utf8')
  if (!decoded) {
    return { ok: false, status: 400, code: 'trial_source_required', message: MESSAGES.source }
  }
  return { ok: true, text: decoded }
}

module.exports = {
  GIFT_FEN,
  MAX_GRAPHEMES,
  MESSAGES,
  graphemeLength,
  costFen,
  quoteSource,
  openAccount,
  applyCharge,
  normalizeRecord,
  decodeSourceHeader
}
