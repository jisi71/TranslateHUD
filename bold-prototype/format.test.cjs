'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const root = process.env.TRIAL_CANDIDATE_ROOT
if (!root || !path.isAbsolute(root)) throw new Error('TRIAL_CANDIDATE_ROOT must be an absolute path')
const { makeBoldFormat, restoreBoldResult } = require(path.join(root, 'src/structuredBold'))
const { prepareUpstreamPayload } = require(path.join(root, 'src/upstream'))
const { handleTranslate } = require(path.join(root, 'src/trialService'))
const { MemoryAccountStore } = require(path.join(root, 'src/accountStore'))
const { countSourceTokens } = require(path.join(root, 'src/sourceTokens'))
const baseline = process.env.TRIAL_BASELINE_ROOT
const nonce = () => '0123456789abcdef01234567'
const config = { model: 'test', endpoint: 'https://api.deepseek.com/v1/chat/completions' }

function body(items, stream = false) {
  return JSON.stringify({ model: 'ignored', stream, messages: [{ role: 'user', content: JSON.stringify(items) }] })
}

function provider(results, usage = { prompt_tokens: 500, completion_tokens: 80 }) {
  return { choices: [{ message: { content: JSON.stringify({ results }) } }], usage }
}

test('UTF-8 ranges require complete graphemes, strict bounds, ordering, and finite limits', () => {
  const text = 'A👨‍👩‍👧‍👦e\u0301中B'
  const emojiEnd = Buffer.byteLength('A👨‍👩‍👧‍👦')
  const accentEnd = Buffer.byteLength('A👨‍👩‍👧‍👦e\u0301')
  assert.ok(makeBoldFormat([text], [[[1, emojiEnd], [emojiEnd, accentEnd]]], '', nonce))
  for (const ranges of [[[2, emojiEnd]], [[emojiEnd, emojiEnd + 1]], [[1, 999]], [[-1, 2]], [[1, 1]], [[1.5, 3]], [[emojiEnd, accentEnd], [1, emojiEnd]], [[1, accentEnd], [emojiEnd, accentEnd]], [[1, 3, 4]]]) {
    assert.throws(() => makeBoldFormat([text], [ranges], '', nonce))
  }
  for (const separator of ['\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029']) {
    const line = `a${separator}b`
    assert.throws(() => makeBoldFormat([line], [[[0, Buffer.byteLength(line)]]], '', nonce))
  }
  assert.throws(() => makeBoldFormat(['a'.repeat(65)], [Array.from({length:65}, (_, i) => [i, i + 1])], '', nonce))
})

test('nonce collision is avoided and bounded', () => {
  let index = 0
  const next = () => index++ === 0 ? 'aaaaaaaaaaaaaaaaaaaaaaaa' : 'bbbbbbbbbbbbbbbbbbbbbbbb'
  const format = makeBoldFormat(['a'.repeat(24)], [[[0, 1]]], '', next)
  assert.equal(format.nonce, 'bbbbbbbbbbbbbbbbbbbbbbbb')
  assert.throws(() => makeBoldFormat(['a'.repeat(24)], [[[0, 1]]], '', () => 'aaaaaaaaaaaaaaaaaaaaaaaa'))
})

test('global ratio and byte budgets bound markup amplification across many items', () => {
  const short = makeBoldFormat(['x'], [[[0, 1]]], '', nonce)
  assert.ok(short)
  const one = (text) => [text, [[0, Buffer.byteLength(text)]]]
  const items = Array.from({length: 33}, () => one('x'))
  assert.throws(() => makeBoldFormat(items.map(x => x[0]), items.map(x => x[1]), '', nonce), /too many/)
  // 32 segments on a long source fit the count cap but exceed the total marker-byte cap.
  const long = 'a'.repeat(1000)
  assert.throws(() => makeBoldFormat([long], [Array.from({length: 32}, (_, i) => [i * 2, i * 2 + 1])], '', nonce), /too many/)
  assert.throws(() => makeBoldFormat(['a'.repeat(64)], [Array.from({length: 8}, (_, i) => [i * 2, i * 2 + 1])], '', nonce), /too many/)
  assert.ok(makeBoldFormat(['e\u0301 👨‍👩‍👧‍👦'], [[[0, 3]]], '', nonce))
})

test('translated marker pairs may reorder while ranges follow UTF-8 output', () => {
  const format = makeBoldFormat(['red and blue', 'plain'], [[[0, 3], [8, 12]], []], '', nonce)
  const [red, blue] = format.expected[0]
  const output = provider([{ i: 1, t: '普通' }, { i: 0, t: `${blue.open}蓝色${blue.close}和${red.open}红色${red.close}` }])
  const decoded = JSON.parse(restoreBoldResult(output, format).choices[0].message.content)
  assert.deepEqual(decoded.results, [{ i: 0, t: '蓝色和红色', boldRanges: [[0, 6], [9, 15]] }, { i: 1, t: '普通', boldRanges: [] }])
})

test('missing, duplicate, crossing, nested, forged and cross-item markers fail', () => {
  const format = makeBoldFormat(['red and blue', 'plain'], [[[0, 3], [8, 12]], []], '', nonce)
  const [a, b] = format.expected[0]
  for (const text of [
    `${a.open}红${a.close}蓝`,
    `${a.open}红${a.close}${a.open}红${a.close}${b.open}蓝${b.close}`,
    `${a.open}红${b.open}蓝${a.close}${b.close}`,
    `${a.open}红${b.open}蓝${b.close}${a.close}`,
    `${a.open}红${a.close}${b.open}蓝${b.close}⟦THB${format.nonce}:99:0:S⟧`,
    `${a.open}红${a.close}${b.open}蓝${b.close}${format.nonce}`
  ]) assert.throws(() => restoreBoldResult(provider([{i:0,t:text},{i:1,t:'普通'}]), format))
  assert.throws(() => restoreBoldResult(provider([{i:0,t:`${a.open}红${a.close}`},{i:1,t:`${b.open}蓝${b.close}`}]), format))
  assert.throws(() => restoreBoldResult(provider([{i:0,t:`${a.open}e${a.close}\u0301${b.open}蓝${b.close}`},{i:1,t:'普通'}]), format))
  for (const separator of ['\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029']) {
    assert.throws(() => restoreBoldResult(provider([{i:0,t:`${a.open}红${separator}色${a.close}${b.open}蓝${b.close}`},{i:1,t:'普通'}]), format))
  }
  const extraChoice = provider([{i:0,t:`${a.open}红${a.close}${b.open}蓝${b.close}`},{i:1,t:'普通'}])
  extraChoice.choices.push({message:{content:'unvalidated'}})
  assert.throws(() => restoreBoldResult(extraChoice, format))
})

test('batch text remains bound to billed source and legacy requests are unchanged', () => {
  assert.throws(() => prepareUpstreamPayload(body([{ i: 0, text: 'different', boldRanges: [[0, 1]] }]), config, 'source'))
  assert.throws(() => prepareUpstreamPayload(body([{ i: 0, text: 'source', boldRanges: [[0, 1]], injection: 'extra' }]), config, 'source'))
  assert.throws(() => prepareUpstreamPayload(body([{ i: 0, text: 'source', boldRanges: [[0, 1]] }], true), config, 'source'))
  const old = prepareUpstreamPayload(body([{ i: 0, text: 'source' }]), config, 'source')
  assert.equal(old.format, null)
  assert.equal(JSON.parse(old.payload.messages[1].content)[0].text, 'source')
})

test('legacy payloads and rejections match the corresponding original baseline', () => {
  if (!baseline || !path.isAbsolute(baseline)) throw new Error('TRIAL_BASELINE_ROOT must be an absolute path')
  const old = require(path.join(baseline, 'src/upstream')).prepareUpstreamPayload
  const cases = [
    [body([{i:0,text:'Hello'}, {i:1,text:'world'}]), 'Hello\nworld'],
    [JSON.stringify({stream:true,messages:[{role:'user',content:'Hello'}]}), 'Hello'],
    [JSON.stringify({stream:false,messages:[{role:'user',content:JSON.stringify({texts:['Hello']})}]}), 'Hello'],
    [body([{i:0,text:'different'}]), 'Hello'],
    [body([{i:0,text:'Hello',fake:'not allowed'}]), 'Hello']
  ]
  const capture = (fn, raw, source) => {
    try { const r = fn(raw, config, source); return { payload:r.payload, stream:r.stream } }
    catch (error) { return { status:error.status, code:error.code, message:error.publicMessage } }
  }
  for (const [raw, source] of cases) assert.deepEqual(capture(prepareUpstreamPayload,raw,source), capture(old,raw,source))
})

async function run(options = {}) {
  const text = options.source || 'Hello World'
  const selectedRoot = options.baseline ? baseline : root
  const selectedStore = options.baseline ? require(path.join(selectedRoot, 'src/accountStore')).MemoryAccountStore : MemoryAccountStore
  const selectedTranslate = options.baseline ? require(path.join(selectedRoot, 'src/trialService')).handleTranslate : handleTranslate
  const store = new selectedStore()
  const now = Date.parse('2026-11-04T03:00:00Z')
  if (options.paid) await store.redeem('test-user', 'translatehud-200', now, {})
  let forwarded = 0
  const ctx = {
    now: () => now,
    env: { gateway: 'https://test.invalid', apiKey: 'test', baseURL: 'https://api.deepseek.com/v1', model: 'test' },
    headers: { authorization: 'Bearer test', 'x-translatehud-source': Buffer.from(text).toString('base64') },
    verifyUser: async () => ({ uid: 'test-user' }),
    rawBody: options.rawBody || body([options.legacy ? {i:0,text} : { i: 0, text, boldRanges: [[0, 5]] }]),
    store,
    signal: options.cancelled ? { aborted: true } : undefined,
    forward: async ({ payload }) => {
      forwarded++
      if (options.cancelled) throw new Error('cancelled')
      const items = JSON.parse(payload.messages[1].content)
      const marked = items[0].text
      const match = marked.match(/(⟦THB[0-9a-f]{24}:0:0:S⟧)Hello(⟦THB[0-9a-f]{24}:0:0:E⟧)/)
      if (!options.legacy) assert.ok(match)
      const translated = options.legacy || options.invalid ? '你好世界' : `${match[1]}你好${match[2]}世界`
      const result = provider([{i:0,t:translated}], options.noUsage ? null : undefined)
      return { status: 200, text: JSON.stringify(result) }
    }
  }
  const result = await selectedTranslate(ctx)
  return { result, store, text, forwarded }
}

test('valid formatted request bills original source and returns output ranges', async () => {
  const { result, store, text, forwarded } = await run()
  assert.equal(forwarded, 1)
  assert.equal(result.status, 200)
  const data = JSON.parse(result.body)
  assert.deepEqual(JSON.parse(data.choices[0].message.content).results, [{ i: 0, t: '你好世界', boldRanges: [[0, 6]] }])
  assert.equal(data.translatehud_trial.dailyTokens, countSourceTokens(text))
  assert.equal(data.translatehud_trial.chargedMicroYuan, 0)
  assert.equal((await store.ensure('test-user')).record.dailyTokens, countSourceTokens(text))
})

test('invalid output with usage is billed once and produces explicit error plus receipt', async () => {
  const { result, store, text, forwarded } = await run({ invalid: true })
  assert.equal(forwarded, 1)
  assert.equal(result.status, 422)
  const data = JSON.parse(result.body)
  assert.equal(data.error.code, 'trial_format_invalid')
  assert.equal(data.translatehud_trial.dailyTokens, countSourceTokens(text))
  assert.equal((await store.ensure('test-user')).record.dailyTokens, countSourceTokens(text))
})

test('paid invalid output still deducts reported usage exactly once', async () => {
  const { result, store } = await run({ invalid: true, paid: true })
  assert.equal(result.status, 422)
  const receipt = JSON.parse(result.body).translatehud_trial
  assert.ok(receipt.chargedMicroYuan > 0)
  assert.equal(receipt.balanceMicroYuan, 2000000 - receipt.chargedMicroYuan)
  assert.equal((await store.ensure('test-user')).record.balanceMicroYuan, receipt.balanceMicroYuan)
})

test('oversized or forged requests are rejected before upstream is called', async () => {
  const { result, forwarded } = await run({ rawBody: body([{i:0,text:'different',boldRanges:[[0,1]]}]) })
  assert.equal(result.status, 400)
  assert.equal(forwarded, 0)
  const tooLong = await run({ rawBody: ' '.repeat(49 * 1024) })
  assert.equal(tooLong.result.status, 413)
  assert.equal(tooLong.forwarded, 0)
  const split = Array.from({length: 33}, (_, i) => ({i, text:'x', boldRanges:[[0,1]]}))
  const splitSource = split.map(x => x.text).join('\n')
  assert.throws(() => prepareUpstreamPayload(body(split), config, splitSource), error => error.code === 'trial_format_limit')
  const rejected = await run({ source: splitSource, rawBody: body(split) })
  assert.equal(rejected.result.status, 400)
  assert.equal(JSON.parse(rejected.result.body).error.code, 'trial_format_limit')
  assert.equal(rejected.forwarded, 0)
  assert.equal(rejected.store.users.size, 0)
})

test('cancelled and missing-usage calls retain existing non-settlement behavior', async () => {
  const cancelled = await run({ cancelled: true })
  assert.equal(cancelled.result.status, 499)
  assert.equal((await cancelled.store.ensure('test-user')).record.dailyTokens || 0, 0)
  const missing = await run({ noUsage: true })
  assert.equal(missing.result.status, 502)
  assert.equal(JSON.parse(missing.result.body).error.code, 'trial_usage_missing')
  assert.equal((await missing.store.ensure('test-user')).record.dailyTokens || 0, 0)
  const baselineCancelled = await run({ cancelled: true, baseline: true, legacy: true })
  const baselineMissing = await run({ noUsage: true, baseline: true, legacy: true })
  assert.equal(cancelled.result.status, baselineCancelled.result.status)
  assert.equal(missing.result.status, baselineMissing.result.status)
  assert.equal((await baselineCancelled.store.ensure('test-user')).record.dailyTokens || 0, 0)
  assert.equal((await baselineMissing.store.ensure('test-user')).record.dailyTokens || 0, 0)
})
