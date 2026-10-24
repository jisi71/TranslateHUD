'use strict'

// A successful call is priced from the upstream usage object, not from the
// source length. The ledger unit is the micro-yuan (微元): ¥0.000001.
// 1 fen = 10,000 micro-yuan. The ¥2.00 gift is 2,000,000 micro-yuan.
//
// Prices are yuan per 1,000,000 tokens and are stored as integer micro-yuan
// per 1,000,000 tokens (the yuan figure times 1,000,000). The charge is
//
//   floor(tokens × micro-yuan-per-million / 1,000,000)
//
// That floor drops less than 1 micro-yuan. It does not round up to fen, and
// there is no 1-fen minimum. Display fen is computed separately in trialPolicy
// and is not what gets deducted.
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
const MICRO_YUAN_PER_YUAN = 1_000_000
const MAX_TOKENS = 100_000_000

function configError() {
  return {
    ok: false,
    status: 503,
    code: 'trial_not_configured',
    message: MESSAGES.notConfigured
  }
}

// "2" → 2,000,000, "0.04" → 40,000, "0.021" → 21,000. Six decimal places of
// yuan are one micro-yuan, so the default prices are exact integers.
function parseYuanPerMillion(raw, fallback) {
  const text = raw == null || String(raw).trim() === '' ? fallback : String(raw).trim()
  if (!/^\d+(\.\d{1,6})?$/.test(text)) return null
  const [whole, frac = ''] = text.split('.')
  const digits = (frac + '000000').slice(0, 6)
  const micro = Number(whole) * MICRO_YUAN_PER_YUAN + Number(digits)
  if (!Number.isSafeInteger(micro) || micro < 0) return null
  return micro
}

function readTrialPrices(env = {}) {
  const inputMicroYuanPerMillion = parseYuanPerMillion(env.TRIAL_PRICE_INPUT_YUAN_PER_MILLION, DEFAULT_INPUT_YUAN)
  const cacheHitMicroYuanPerMillion = parseYuanPerMillion(env.TRIAL_PRICE_CACHE_HIT_YUAN_PER_MILLION, DEFAULT_CACHE_HIT_YUAN)
  const outputMicroYuanPerMillion = parseYuanPerMillion(env.TRIAL_PRICE_OUTPUT_YUAN_PER_MILLION, DEFAULT_OUTPUT_YUAN)
  if (inputMicroYuanPerMillion == null || cacheHitMicroYuanPerMillion == null || outputMicroYuanPerMillion == null) {
    return configError()
  }
  return { ok: true, inputMicroYuanPerMillion, cacheHitMicroYuanPerMillion, outputMicroYuanPerMillion }
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

function rate(value) {
  if (!Number.isSafeInteger(value) || value < 0) return null
  return value
}

function costMicroYuanFromUsage(parsed, prices) {
  if (!parsed || !prices) return null
  const input = rate(prices.inputMicroYuanPerMillion)
  const cacheHit = rate(prices.cacheHitMicroYuanPerMillion)
  const output = rate(prices.outputMicroYuanPerMillion)
  if (input == null || cacheHit == null || output == null) return null
  const hit = parsed.cacheHitTokens == null ? 0 : parsed.cacheHitTokens
  if (hit > parsed.promptTokens) return null
  const miss = parsed.promptTokens - hit
  const highest = Math.max(input, output, cacheHit)
  const numerator = (BigInt(miss) * BigInt(input))
    + (BigInt(hit) * BigInt(cacheHit))
    + (BigInt(parsed.completionTokens) * BigInt(output))
    + (BigInt(parsed.extraTokens || 0) * BigInt(highest))
  if (numerator < 0n) return null
  const cost = numerator / BigInt(TOKENS_PER_MILLION)
  if (cost > BigInt(Number.MAX_SAFE_INTEGER)) return null
  return Number(cost)
}

function settlementFields(settled, usage) {
  return {
    costMicroYuan: settled.costMicroYuan,
    chargedMicroYuan: settled.chargedMicroYuan,
    balanceMicroYuan: settled.balanceMicroYuan,
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
  costMicroYuanFromUsage,
  settlementFields
}
