'use strict'

// Trial gifts are still stored in fen (¥0.01). A successful call is priced from
// the upstream usage object, not from the source length.
//
// Prices are yuan per 1,000,000 tokens. They convert to integer fen per
// 1,000,000 tokens; any leftover fraction of a fen rounds up. When the reported
// usage is greater than zero, the charge is at least 1 fen.
//
// Defaults match DeepSeek Flash peak rates (2026-10): cache-miss input ¥2,
// cache-hit input ¥0.04, output ¥8. Peak is the higher published rate, so a
// weekday afternoon does not cost the operator more than the gift is charged.
// Off-peak is about half; set the env vars to the figures on the operator bill.

const { MESSAGES } = require('./trialPolicy')

const DEFAULT_INPUT_YUAN = '2'
const DEFAULT_CACHE_HIT_YUAN = '0.04'
const DEFAULT_OUTPUT_YUAN = '8'
const TOKENS_PER_MILLION = 1_000_000
const MAX_TOKENS = 100_000_000

function configError() {
  return {
    ok: false,
    status: 503,
    code: 'trial_not_configured',
    message: MESSAGES.notConfigured
  }
}

// "2" → 200 fen, "0.04" → 4 fen, "0.021" → 3 fen (2.1 fen, rounded up).
function parseYuanPerMillion(raw, fallback) {
  const text = raw == null || String(raw).trim() === '' ? fallback : String(raw).trim()
  if (!/^\d+(\.\d{1,6})?$/.test(text)) return null
  const [whole, frac = ''] = text.split('.')
  const fenDigits = (frac + '00').slice(0, 2)
  const extra = frac.slice(2)
  let fen = Number(whole) * 100 + Number(fenDigits)
  if (extra && /[1-9]/.test(extra)) fen += 1
  if (!Number.isSafeInteger(fen) || fen < 0) return null
  return fen
}

function readTrialPrices(env = {}) {
  const inputFenPerMillion = parseYuanPerMillion(env.TRIAL_PRICE_INPUT_YUAN_PER_MILLION, DEFAULT_INPUT_YUAN)
  const cacheHitFenPerMillion = parseYuanPerMillion(env.TRIAL_PRICE_CACHE_HIT_YUAN_PER_MILLION, DEFAULT_CACHE_HIT_YUAN)
  const outputFenPerMillion = parseYuanPerMillion(env.TRIAL_PRICE_OUTPUT_YUAN_PER_MILLION, DEFAULT_OUTPUT_YUAN)
  if (inputFenPerMillion == null || cacheHitFenPerMillion == null || outputFenPerMillion == null) {
    return configError()
  }
  return { ok: true, inputFenPerMillion, cacheHitFenPerMillion, outputFenPerMillion }
}

function tokenCount(value) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > MAX_TOKENS) return null
  return value
}

// Discount only tokens the provider explicitly marks as cache hits.
// Otherwise the whole prompt is billed at the input (cache-miss) price.
function cacheHitCount(usage, prompt) {
  if (!usage || typeof usage !== 'object') return null
  const direct = tokenCount(usage.prompt_cache_hit_tokens)
  if (direct != null) return Math.min(direct, prompt)
  const details = usage.prompt_tokens_details
  if (details && typeof details === 'object') {
    const cached = tokenCount(details.cached_tokens)
    if (cached != null) return Math.min(cached, prompt)
  }
  return null
}

function parseUsage(usage) {
  if (!usage || typeof usage !== 'object') return null
  const prompt = tokenCount(usage.prompt_tokens)
  const completion = tokenCount(usage.completion_tokens)
  if (prompt == null || completion == null) return null
  if (prompt + completion <= 0) return null
  const total = tokenCount(usage.total_tokens)
  const extra = total != null && total > prompt + completion ? total - prompt - completion : 0
  return {
    promptTokens: prompt,
    completionTokens: completion,
    cacheHitTokens: cacheHitCount(usage, prompt),
    extraTokens: extra
  }
}

function divCeil(numerator, denominator) {
  return Math.floor((numerator + denominator - 1) / denominator)
}

function costFenFromUsage(parsed, prices) {
  if (!parsed || !prices) return null
  const hit = parsed.cacheHitTokens == null ? 0 : parsed.cacheHitTokens
  if (hit > parsed.promptTokens) return null
  const miss = parsed.promptTokens - hit
  const highest = Math.max(prices.inputFenPerMillion, prices.outputFenPerMillion, prices.cacheHitFenPerMillion)
  const numerator = (miss * prices.inputFenPerMillion)
    + (hit * prices.cacheHitFenPerMillion)
    + (parsed.completionTokens * prices.outputFenPerMillion)
    + ((parsed.extraTokens || 0) * highest)
  if (!Number.isSafeInteger(numerator) || numerator < 0) return null
  const rounded = divCeil(numerator, TOKENS_PER_MILLION)
  const tokens = parsed.promptTokens + parsed.completionTokens + (parsed.extraTokens || 0)
  if (tokens <= 0) return 0
  return Math.max(1, rounded)
}

function settlementFields(settled, usage) {
  return {
    costFen: settled.costFen,
    chargedFen: settled.chargedFen,
    balanceFen: settled.balanceFen,
    promptTokens: usage.promptTokens,
    completionTokens: usage.completionTokens
  }
}

module.exports = {
  DEFAULT_INPUT_YUAN,
  DEFAULT_CACHE_HIT_YUAN,
  DEFAULT_OUTPUT_YUAN,
  parseYuanPerMillion,
  readTrialPrices,
  parseUsage,
  costFenFromUsage,
  settlementFields,
  divCeil
}
