'use strict'

// Length rules stay in sync with TranslateHUD/Trial/TrialPricing.swift.
// Length is Unicode extended grapheme clusters (Intl.Segmenter), same as Swift String.count.
// Chinese characters are one grapheme each. A base letter plus a combining mark is one.
// Newlines count. The cap is the source text only, not the prompt around it.
// Grapheme length gates the request. It is not the price. Successful calls settle
// from upstream token usage in usageBilling.js.
//
// The ledger unit is the micro-yuan (微元, ¥0.000001). 1 fen = 10,000 micro-yuan.
// The ¥2.00 invite gift is 2,000,000 micro-yuan. It is not applied when the
// account is first opened. balanceFen on a record is only the half-up display
// value. A document that still has balanceFen and no balanceMicroYuan is an
// older fen ledger and is converted on read. A document that already has
// giftGranted (or omits it, which older gifts did) has already received ¥2
// and cannot redeem an invite code.

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
  store: '体验余额暂时读不出来。请在设置里点余额旁的刷新。',
  concurrency: '同时进行的翻译太多了（同一账号最多 3 个）。请等当前翻译结束后再试。',
  inviteRequired: '还没有体验额度。请在设置里输入邀请码领取，或填写你自己的 API Key。',
  inviteClaimed: '这个账号已经领过体验额度。',
  inviteInvalid: '邀请码不正确。',
  inviteExhausted: '邀请码次数用尽',
  inviteUnconfigured: '邀请码还没配置好。请稍后再试。'
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

function sanitizeSlots(slots) {
  if (!Array.isArray(slots)) return []
  const clean = []
  for (const slot of slots) {
    if (!slot || typeof slot !== 'object') continue
    const id = String(slot.id || '').trim()
    const until = Math.floor(Number(slot.until))
    if (!id || !Number.isFinite(until)) continue
    clean.push({ id, until })
    if (clean.length >= 20) break
  }
  return clean
}

// Shown in the app instead of the CloudBase uid. 1 is "00001". Past 99999 the
// text grows ("100000") and earlier numbers stay five digits. 0 means unassigned.
function readDisplayNo(record) {
  const n = Math.floor(Number(record && record.displayNo))
  if (!Number.isSafeInteger(n) || n <= 0) return 0
  return n
}

function formatDisplayId(displayNo) {
  const n = Math.floor(Number(displayNo))
  if (!Number.isSafeInteger(n) || n <= 0) return ''
  const text = String(n)
  return text.length >= 5 ? text : text.padStart(5, '0')
}

function readNextDisplayNo(counter) {
  const n = Math.floor(Number(counter && counter.nextDisplayNo))
  if (!Number.isSafeInteger(n) || n <= 0) return 1
  return n
}

function withNextDisplayNo(counter, nextDisplayNo) {
  const base = counter && typeof counter === 'object' ? { ...counter } : { redeemedCount: 0 }
  base.nextDisplayNo = nextDisplayNo
  if (!Number.isFinite(Number(base.redeemedCount))) base.redeemedCount = 0
  return base
}

function compareAccountOrder(a, b) {
  const createdA = Number(a.record && a.record.createdAt) || 0
  const createdB = Number(b.record && b.record.createdAt) || 0
  if (createdA !== createdB) return createdA - createdB
  const uidA = String(a.uid)
  const uidB = String(b.uid)
  if (uidA < uidB) return -1
  if (uidA > uidB) return 1
  return 0
}

// Give each account without a displayNo the next integer. When several are
// visible, earlier createdAt gets the smaller number. The account passed as
// focusUid is always included, even if older accounts would fill the batch.
// Already assigned numbers are never changed.
const DISPLAY_BACKFILL_LIMIT = 20

function assignDisplayNumbers(entries, counter, focusUid) {
  const list = Array.isArray(entries) ? entries : []
  let next = readNextDisplayNo(counter)
  let maxAssigned = 0
  for (const entry of list) {
    const n = readDisplayNo(entry && entry.record)
    if (n > maxAssigned) maxAssigned = n
  }
  if (next <= maxAssigned) next = maxAssigned + 1

  let missing = list
    .filter((entry) => entry && entry.uid != null && entry.record && readDisplayNo(entry.record) <= 0)
    .map((entry) => ({ uid: String(entry.uid), record: normalizeRecord(entry.record) }))
    .sort(compareAccountOrder)
  if (missing.length > DISPLAY_BACKFILL_LIMIT) {
    const focusKey = focusUid == null ? null : String(focusUid)
    const focus = focusKey ? missing.filter((entry) => entry.uid === focusKey) : []
    const others = missing
      .filter((entry) => entry.uid !== focusKey)
      .slice(0, DISPLAY_BACKFILL_LIMIT - focus.length)
    missing = [...others, ...focus].sort(compareAccountOrder)
  }

  const updates = []
  for (const entry of missing) {
    const record = ledgerRecord(entry.record.balanceMicroYuan, { ...entry.record, displayNo: next })
    updates.push({ uid: entry.uid, record })
    next += 1
  }
  return { updates, counter: withNextDisplayNo(counter, next) }
}

const DEFAULT_FEEDBACK_DAILY_LIMIT = 10
const SHANGHAI_OFFSET_MS = 8 * 60 * 60 * 1000

function readFeedbackDay(record) {
  const day = String(record && record.feedbackDay || '').trim()
  return /^\d{4}-\d{2}-\d{2}$/.test(day) ? day : ''
}

function readFeedbackCount(record) {
  const n = Math.floor(Number(record && record.feedbackCount))
  if (!Number.isSafeInteger(n) || n <= 0) return 0
  return Math.min(n, 100000)
}

// Calendar day in China (UTC+8, no daylight saving). 16:00 UTC is the next day.
function feedbackDayKey(now) {
  const ms = Number(now)
  const instant = Number.isFinite(ms) ? ms : Date.now()
  const shifted = new Date(instant + SHANGHAI_OFFSET_MS)
  const month = String(shifted.getUTCMonth() + 1).padStart(2, '0')
  const day = String(shifted.getUTCDate()).padStart(2, '0')
  return `${shifted.getUTCFullYear()}-${month}-${day}`
}

function feedbackDailyLimit(env) {
  const raw = env && env.FEEDBACK_DAILY_LIMIT
  if (raw == null || String(raw).trim() === '') return DEFAULT_FEEDBACK_DAILY_LIMIT
  const n = Math.floor(Number(raw))
  if (!Number.isSafeInteger(n) || n < 1 || n > 1000) return DEFAULT_FEEDBACK_DAILY_LIMIT
  return n
}

function reserveFeedbackSlot(record, now, limit) {
  const current = record ? normalizeRecord(record) : null
  if (!current) return { ok: false, status: 503, code: 'feedback_store' }
  const cap = feedbackDailyLimit({ FEEDBACK_DAILY_LIMIT: limit })
  const day = feedbackDayKey(now)
  const count = current.feedbackDay === day ? current.feedbackCount : 0
  if (count >= cap) return { ok: false, status: 429, code: 'feedback_daily_limit' }
  const next = ledgerRecord(current.balanceMicroYuan, {
    ...current,
    feedbackDay: day,
    feedbackCount: count + 1
  })
  return { ok: true, record: next, count: count + 1, day }
}

function releaseFeedbackSlot(record, now) {
  const current = record ? normalizeRecord(record) : null
  if (!current) return null
  const day = feedbackDayKey(now)
  if (current.feedbackDay !== day || current.feedbackCount <= 0) return current
  return ledgerRecord(current.balanceMicroYuan, {
    ...current,
    feedbackDay: day,
    feedbackCount: current.feedbackCount - 1
  })
}

function ledgerRecord(microYuan, record) {
  const balanceMicroYuan = Math.max(0, Math.floor(Number(microYuan) || 0))
  const redeemedAt = record && record.inviteRedeemedAt ? Math.floor(Number(record.inviteRedeemedAt) || 0) : 0
  const saved = {
    balanceMicroYuan,
    balanceFen: displayFen(balanceMicroYuan),
    // Missing giftGranted means an older auto-gift. Those accounts already
    // received ¥2 and must not redeem again. New accounts set this to false.
    giftGranted: !record || record.giftGranted !== false,
    createdAt: record && record.createdAt ? record.createdAt : 0,
    inviteRedeemedAt: redeemedAt > 0 ? redeemedAt : 0,
    displayNo: readDisplayNo(record),
    inflight: sanitizeSlots(record && record.inflight)
  }
  const feedbackDay = readFeedbackDay(record)
  const feedbackCount = readFeedbackCount(record)
  if (feedbackDay && feedbackCount > 0) {
    saved.feedbackDay = feedbackDay
    saved.feedbackCount = feedbackCount
  }
  return saved
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
    giftedNow: false,
    record: ledgerRecord(0, { giftGranted: false, createdAt: now })
  }
}

// One successful invite per account. Legacy auto-gifts already have giftGranted.
function grantInviteGift(record, now) {
  const current = record ? normalizeRecord(record) : ledgerRecord(0, { giftGranted: false, createdAt: now })
  if (current.giftGranted || current.inviteRedeemedAt > 0) return { ok: false, record: current }
  const next = ledgerRecord(current.balanceMicroYuan + GIFT_MICRO_YUAN, {
    ...current,
    giftGranted: true,
    inviteRedeemedAt: now,
    createdAt: current.createdAt || now
  })
  return { ok: true, record: next }
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
  grantInviteGift,
  applyCharge,
  credit,
  settleCharge,
  normalizeRecord,
  decodeSourceHeader,
  readDisplayNo,
  formatDisplayId,
  assignDisplayNumbers,
  DISPLAY_BACKFILL_LIMIT,
  DEFAULT_FEEDBACK_DAILY_LIMIT,
  feedbackDayKey,
  feedbackDailyLimit,
  reserveFeedbackSlot,
  releaseFeedbackSlot
}
