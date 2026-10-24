'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { PassThrough } = require('stream')
const {
  costMicroYuanFromUsage,
  parseUsage,
  parseYuanPerMillion,
  readTrialPrices
} = require('../src/usageBilling')
const { displayFen } = require('../src/trialPolicy')
const { createSettlingStream } = require('../src/usageStream')

function prices(overrides = {}) {
  return {
    inputMicroYuanPerMillion: 2_000_000,
    cacheHitMicroYuanPerMillion: 40_000,
    outputMicroYuanPerMillion: 8_000_000,
    ...overrides
  }
}

test('yuan prices become integer micro-yuan per million tokens', () => {
  assert.equal(parseYuanPerMillion('2', '0'), 2_000_000)
  assert.equal(parseYuanPerMillion('0.04', '0'), 40_000)
  assert.equal(parseYuanPerMillion('8', '0'), 8_000_000)
  assert.equal(parseYuanPerMillion('0.021', '0'), 21_000)
  assert.equal(parseYuanPerMillion('', '0.04'), 40_000)
  assert.equal(parseYuanPerMillion('nope', '2'), null)
  const defaults = readTrialPrices({})
  assert.equal(defaults.ok, true)
  assert.equal(defaults.inputMicroYuanPerMillion, 2_000_000)
  assert.equal(defaults.cacheHitMicroYuanPerMillion, 40_000)
  assert.equal(defaults.outputMicroYuanPerMillion, 8_000_000)
  assert.equal(readTrialPrices({ TRIAL_PRICE_INPUT_YUAN_PER_MILLION: '-1' }).ok, false)
})

test('a short call keeps its real micro-yuan cost and is not lifted to 1 fen', () => {
  const rate = prices()
  const one = parseUsage({ prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 })
  assert.equal(costMicroYuanFromUsage(one, rate), 10)
  assert.equal(displayFen(10), 0)

  const exactFen = parseUsage({ prompt_tokens: 5_000, completion_tokens: 0, total_tokens: 5_000 })
  assert.equal(costMicroYuanFromUsage(exactFen, rate), 10_000)
  assert.equal(displayFen(10_000), 1)

  const justUnder = parseUsage({ prompt_tokens: 4_999, completion_tokens: 0, total_tokens: 4_999 })
  assert.equal(costMicroYuanFromUsage(justUnder, rate), 9_998)
  assert.equal(displayFen(9_998), 1)

  const halfFen = parseUsage({ prompt_tokens: 2_500, completion_tokens: 0, total_tokens: 2_500 })
  assert.equal(costMicroYuanFromUsage(halfFen, rate), 5_000)
  assert.equal(displayFen(5_000), 1)

  const belowHalf = parseUsage({ prompt_tokens: 2_499, completion_tokens: 0, total_tokens: 2_499 })
  assert.equal(costMicroYuanFromUsage(belowHalf, rate), 4_998)
  assert.equal(displayFen(4_998), 0)

  const fractionOfAFen = parseUsage({ prompt_tokens: 10_001, completion_tokens: 0, total_tokens: 10_001 })
  assert.equal(costMicroYuanFromUsage(fractionOfAFen, rate), 20_002)
  assert.equal(displayFen(20_002), 2)

  const freePrice = costMicroYuanFromUsage(one, prices({
    inputMicroYuanPerMillion: 0,
    cacheHitMicroYuanPerMillion: 0,
    outputMicroYuanPerMillion: 0
  }))
  assert.equal(freePrice, 0)
  assert.equal(displayFen(0), 0)
})

test('display fen rounds half-up and does not change a larger exact amount', () => {
  assert.equal(displayFen(0), 0)
  assert.equal(displayFen(4_999), 0)
  assert.equal(displayFen(5_000), 1)
  assert.equal(displayFen(1_994_999), 199)
  assert.equal(displayFen(1_995_000), 200)
  assert.equal(displayFen(2_000_000), 200)
})

test('cache hits use the lower price and a missing split does not', () => {
  const rate = prices()
  const hit = parseUsage({
    prompt_tokens: 1_000_000,
    completion_tokens: 0,
    total_tokens: 1_000_000,
    prompt_cache_hit_tokens: 1_000_000
  })
  assert.equal(costMicroYuanFromUsage(hit, rate), 40_000)
  assert.equal(displayFen(40_000), 4)

  const oneHit = parseUsage({
    prompt_tokens: 1,
    completion_tokens: 0,
    total_tokens: 1,
    prompt_cache_hit_tokens: 1
  })
  assert.equal(costMicroYuanFromUsage(oneHit, rate), 0)

  const openai = parseUsage({
    prompt_tokens: 1_000_000,
    completion_tokens: 0,
    total_tokens: 1_000_000,
    prompt_tokens_details: { cached_tokens: 750_000 }
  })
  assert.equal(costMicroYuanFromUsage(openai, rate), 530_000)
  assert.equal(displayFen(530_000), 53)

  const unknown = parseUsage({
    prompt_tokens: 1_000_000,
    completion_tokens: 0,
    total_tokens: 1_000_000
  })
  assert.equal(costMicroYuanFromUsage(unknown, rate), 2_000_000)
  assert.equal(displayFen(2_000_000), 200)
})

test('tokens reported only in total_tokens are billed at the higher unit price', () => {
  const usage = parseUsage({ prompt_tokens: 1_000_000, completion_tokens: 0, total_tokens: 2_000_000 })
  assert.equal(usage.extraTokens, 1_000_000)
  assert.equal(costMicroYuanFromUsage(usage, prices()), 10_000_000)
  assert.equal(displayFen(10_000_000), 1_000)
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
    return 'data: {"choices":[],"translatehud_trial":{"costMicroYuan":10,"costFen":0}}\n\n'
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
