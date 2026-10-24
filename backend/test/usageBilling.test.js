'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { PassThrough } = require('stream')
const {
  costFenFromUsage,
  parseUsage,
  parseYuanPerMillion,
  readTrialPrices
} = require('../src/usageBilling')
const { createSettlingStream } = require('../src/usageStream')

function prices(overrides = {}) {
  return {
    inputFenPerMillion: 200,
    cacheHitFenPerMillion: 4,
    outputFenPerMillion: 800,
    ...overrides
  }
}

test('yuan prices become integer fen and round a fraction of a fen up', () => {
  assert.equal(parseYuanPerMillion('2', '0'), 200)
  assert.equal(parseYuanPerMillion('0.04', '0'), 4)
  assert.equal(parseYuanPerMillion('8', '0'), 800)
  assert.equal(parseYuanPerMillion('0.021', '0'), 3)
  assert.equal(parseYuanPerMillion('', '0.04'), 4)
  assert.equal(parseYuanPerMillion('nope', '2'), null)
  const defaults = readTrialPrices({})
  assert.equal(defaults.ok, true)
  assert.equal(defaults.inputFenPerMillion, 200)
  assert.equal(defaults.cacheHitFenPerMillion, 4)
  assert.equal(defaults.outputFenPerMillion, 800)
  assert.equal(readTrialPrices({ TRIAL_PRICE_INPUT_YUAN_PER_MILLION: '-1' }).ok, false)
})

test('token usage converts to fen, rounds up, and charges at least one fen', () => {
  const rate = prices()
  const one = parseUsage({ prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 })
  assert.equal(costFenFromUsage(one, rate), 1)

  const exact = parseUsage({ prompt_tokens: 10_000, completion_tokens: 0, total_tokens: 10_000 })
  assert.equal(costFenFromUsage(exact, rate), 2)

  const roundUp = parseUsage({ prompt_tokens: 10_001, completion_tokens: 0, total_tokens: 10_001 })
  assert.equal(costFenFromUsage(roundUp, rate), 3)

  const freePrice = costFenFromUsage(one, prices({
    inputFenPerMillion: 0,
    cacheHitFenPerMillion: 0,
    outputFenPerMillion: 0
  }))
  assert.equal(freePrice, 1)
})

test('cache hits use the lower price and a missing split does not', () => {
  const rate = prices()
  const hit = parseUsage({
    prompt_tokens: 1_000_000,
    completion_tokens: 0,
    total_tokens: 1_000_000,
    prompt_cache_hit_tokens: 1_000_000
  })
  assert.equal(costFenFromUsage(hit, rate), 4)

  const openai = parseUsage({
    prompt_tokens: 1_000_000,
    completion_tokens: 0,
    total_tokens: 1_000_000,
    prompt_tokens_details: { cached_tokens: 750_000 }
  })
  assert.equal(costFenFromUsage(openai, rate), 53)

  const unknown = parseUsage({
    prompt_tokens: 1_000_000,
    completion_tokens: 0,
    total_tokens: 1_000_000
  })
  assert.equal(costFenFromUsage(unknown, rate), 200)
})

test('tokens reported only in total_tokens are billed at the higher unit price', () => {
  const usage = parseUsage({ prompt_tokens: 1_000_000, completion_tokens: 0, total_tokens: 2_000_000 })
  assert.equal(usage.extraTokens, 1_000_000)
  assert.equal(costFenFromUsage(usage, prices()), 1000)
})

test('missing or empty usage cannot be priced', () => {
  assert.equal(parseUsage(null), null)
  assert.equal(parseUsage({ prompt_tokens: 1 }), null)
  assert.equal(parseUsage({ prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }), null)
  assert.equal(parseUsage({ prompt_tokens: 1.5, completion_tokens: 1, total_tokens: 2.5 }), null)
  assert.equal(parseUsage({ prompt_tokens: -1, completion_tokens: 1, total_tokens: 0 }), null)
})

test('the settling stream keeps the first event ahead of usage and the receipt ahead of DONE', async () => {
  const upstream = new PassThrough()
  const out = createSettlingStream(upstream, async (usage) => {
    assert.equal(usage.promptTokens, 3)
    assert.equal(usage.completionTokens, 4)
    return 'data: {"choices":[],"translatehud_trial":{"costFen":6}}\n\n'
  })
  const chunks = []
  const done = new Promise((resolve, reject) => {
    out.on('data', (chunk) => chunks.push(Buffer.from(chunk).toString('utf8')))
    out.on('end', resolve)
    out.on('error', reject)
  })
  upstream.write('data: {"choices":[{"delta":{"content":"你"}}]}\n\n')
  await new Promise((resolve) => setImmediate(resolve))
  assert.match(chunks.join(''), /你/)
  assert.equal(chunks.join('').includes('[DONE]'), false)
  upstream.write('data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}\n\n')
  upstream.write('data: [DONE]\n\n')
  upstream.end()
  await done
  const text = chunks.join('')
  assert.ok(text.indexOf('你') < text.indexOf('translatehud_trial'))
  assert.ok(text.indexOf('translatehud_trial') < text.indexOf('[DONE]'))
})
