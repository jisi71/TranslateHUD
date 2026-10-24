'use strict'

// Length rules stay in sync with TranslateHUD/Trial/TrialPricing.swift.
// Length is Unicode extended grapheme clusters (Intl.Segmenter), same as Swift String.count.
// Chinese characters are one grapheme each. A base letter plus a combining mark is one.
// Newlines count. The cap is the source text only, not the prompt around it.
// Grapheme length gates the request. It is not the price. Successful calls settle
// from upstream token usage in usageBilling.js.
//
// The ledger unit is the micro-yuan (微元, ¥0.000001). 1 fen = 10,000 micro-yuan.
// The ¥2.00 gift is 2,000,000 micro-yuan. balanceFen on a record is only the
// half-up display value. A document that still has balanceFen and no
// balanceMicroYuan is an older fen ledger and is converted on read.

const MICRO_YUAN_PER_FEN = 10_000
const GIFT_FEN = 200
const GIFT_MICRO_YUAN = GIFT_FEN * MICRO_YUAN_PER_FEN
const MAX_GRAPHEMES = 500

const MESSAGES = {
  length: '超出单次翻译上限（体验额度单次最多 500 字）',
  exhausted: '体验额度已用完。请在设置里填写你自己的 API Key，之后会直接使用你的接口。',
  insufficient: '体验额度不够支付这次翻译。请在设置里填写你自己的 API Key。',
  auth: '体验登录已失效，请在设置里重新登录。',
  notConfigured: '体验翻译服务还没配置好。请稍后再试，或在设置里填写你自己的 API Key。',
  upstream: '体验翻译暂时没有完成，这次没有扣体验额度。请稍后再试。',
  usageMissing: '这次翻译没有返回用量，没有扣体验额度。请稍后再试。',
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

function quoteSource(text) {
  const graphemes = graphemeLength(text)
  if (graphemes > MAX_GRAPHEMES) {
    return { ok: false, status: 400, code: 'trial_length_limit', message: MESSAGES.length, graphemes }
  }
  if (graphemes <= 0) {
    return { ok: false, status: 400, code: 'trial_empty', message: MESSAGES.empty, graphemes }
  }
  return { ok: true, graphemes }
}

// Half-up to fen for display only. 0.5 fen (5,000 micro-yuan) rounds up.
// This number is not deducted and is not the exhaustion check.
function displayFen(microYuan) {
  const raw = Number(microYuan)
  if (!Number.isFinite(raw)) return 0
  const negative = raw < 0
  const magnitude = Math.floor(Math.abs(raw))
  const fen = Math.floor((magnitude + MICRO_YUAN_PER_FEN / 2) / MICRO_YUAN_PER_FEN)
  return negative ? -fen : fen
}

function microFromRecord(record) {
  if (record.balanceMicroYuan != null && record.balanceMicroYuan !== '') {
    const micro = Number(record.balanceMicroYuan)
    if (Number.isFinite(micro)) return Math.max(0, Math.floor(micro))
    return 0
  }
  const fen = Number(record.balanceFen)
  if (Number.isFinite(fen)) return Math.max(0, Math.floor(fen)) * MICRO_YUAN_PER_FEN
  return 0
}

function ledgerRecord(microYuan, record) {
  const balanceMicroYuan = Math.max(0, Math.floor(microYuan))
  return {
    balanceMicroYuan,
    balanceFen: displayFen(balanceMicroYuan),
    giftGranted: !record || record.giftGranted !== false,
    createdAt: record && record.createdAt ? record.createdAt : 0
  }
}

// Post-success settlement. costMicroYuan is the precise ledger amount.
// The balance never goes negative: a last request that costs more than the
// gift has left is charged down to zero, and the unpaid remainder stays with
// the operator. A later request sees an empty balance.
function settleCharge(record, costMicroYuan) {
  const current = record ? normalizeRecord(record) : null
  const raw = Number(costMicroYuan)
  const cost = Number.isFinite(raw) ? Math.max(0, Math.floor(raw)) : 0
  if (!current) {
    return {
      ok: true,
      costMicroYuan: cost,
      chargedMicroYuan: 0,
      balanceMicroYuan: 0,
      costFen: displayFen(cost),
      chargedFen: 0,
      balanceFen: 0,
      clamped: cost > 0,
      record: null
    }
  }
  const charged = Math.min(current.balanceMicroYuan, cost)
  const next = ledgerRecord(current.balanceMicroYuan - charged, current)
  return {
    ok: true,
    costMicroYuan: cost,
    chargedMicroYuan: charged,
    balanceMicroYuan: next.balanceMicroYuan,
    costFen: displayFen(cost),
    chargedFen: displayFen(charged),
    balanceFen: next.balanceFen,
    clamped: charged < cost,
    record: next
  }
}

function openAccount(existing, now) {
  if (existing) return { record: normalizeRecord(existing), giftedNow: false }
  return {
    giftedNow: true,
    record: ledgerRecord(GIFT_MICRO_YUAN, { giftGranted: true, createdAt: now })
  }
}

function applyCharge(record, costMicroYuan) {
  const current = record ? normalizeRecord(record) : null
  const cost = Math.max(0, Math.floor(Number(costMicroYuan) || 0))
  if (!current || current.balanceMicroYuan <= 0) {
    return {
      ok: false,
      status: 402,
      code: 'trial_balance_exhausted',
      message: MESSAGES.exhausted,
      balanceMicroYuan: current ? current.balanceMicroYuan : 0,
      balanceFen: current ? current.balanceFen : 0
    }
  }
  if (cost <= 0) {
    return {
      ok: true,
      record: current,
      balanceMicroYuan: current.balanceMicroYuan,
      balanceFen: current.balanceFen
    }
  }
  if (current.balanceMicroYuan < cost) {
    return {
      ok: false,
      status: 402,
      code: 'trial_balance_insufficient',
      message: MESSAGES.insufficient,
      balanceMicroYuan: current.balanceMicroYuan,
      balanceFen: current.balanceFen
    }
  }
  const next = ledgerRecord(current.balanceMicroYuan - cost, { ...current, giftGranted: true })
  return { ok: true, record: next, balanceMicroYuan: next.balanceMicroYuan, balanceFen: next.balanceFen }
}

function credit(record, microYuan) {
  const current = normalizeRecord(record)
  if (!current) return null
  const amount = Math.max(0, Math.floor(Number(microYuan) || 0))
  return ledgerRecord(current.balanceMicroYuan + amount, current)
}

function normalizeRecord(record) {
  if (!record || typeof record !== 'object') return null
  return ledgerRecord(microFromRecord(record), record)
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
  MICRO_YUAN_PER_FEN,
  GIFT_FEN,
  GIFT_MICRO_YUAN,
  MAX_GRAPHEMES,
  MESSAGES,
  displayFen,
  graphemeLength,
  quoteSource,
  openAccount,
  applyCharge,
  credit,
  settleCharge,
  normalizeRecord,
  decodeSourceHeader
}
