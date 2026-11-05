'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { makeBoldFormat, restoreBoldResult, formatFailureReason } = require('../src/structuredBold')
const { prepareUpstreamPayload } = require('../src/upstream')
const { handleTranslate } = require('../src/trialService')
const { MemoryAccountStore } = require('../src/accountStore')

test('bold ranges are source-bound UTF-8 graphemes and translation can reorder pairs', () => {
  const config = { model: 'test', endpoint: 'https://api.deepseek.com/v1/chat/completions' }
  const item = { i: 0, text: 'red blue', boldRanges: [[0, 3], [4, 8]] }
  const request = JSON.stringify({stream:false,messages:[{role:'user',content:JSON.stringify([item])}]})
  assert.throws(() => prepareUpstreamPayload(request, config, 'other'))
  const format = makeBoldFormat([item.text], [item.boldRanges])
  const [red, blue] = format.expected[0]
  const response = { choices: [{message:{content:JSON.stringify({results:[{i:0,t:`${blue.open}蓝${blue.close}${red.open}红${red.close}`}]})}}] }
  const result = JSON.parse(restoreBoldResult(response, format).choices[0].message.content).results[0]
  assert.deepEqual(result, {i:0,t:'蓝红',boldRanges:[[0,3],[3,6]]})
  assert.throws(() => makeBoldFormat(['e\u0301'], [[[0,1]]]))
  assert.throws(() => makeBoldFormat(['a\u2028b'], [[[0,5]]]))
})

test('whole-item bold is restored across the entire translation without model markers', () => {
  const format = makeBoldFormat(['Product Status Report', 'A B'], [[[0, 21]], [[2, 3]]])
  assert.equal(format.marked[0], 'Product Status Report')
  assert.deepEqual(format.expected[0], [])
  const pair = format.expected[1][0]
  const response = { choices: [{ message: { content: JSON.stringify({ results: [
    { i: 0, t: '产品状态报告' }, { i: 1, t: `A ${pair.open}B${pair.close}` }
  ] }) }, finish_reason: 'stop' }] }
  const results = JSON.parse(restoreBoldResult(response, format).choices[0].message.content).results
  assert.deepEqual(results[0], { i: 0, t: '产品状态报告', boldRanges: [[0, 18]] })
  assert.deepEqual(results[1], { i: 1, t: 'A B', boldRanges: [[2, 3]] })
  response.choices[0].message.content = JSON.stringify({ results: [
    { i: 0, t: '⟦THB:S⟧产品状态报告⟦THB:E⟧' }, { i: 1, t: `A ${pair.open}B${pair.close}` }
  ] })
  assert.throws(() => restoreBoldResult(response, format), error => formatFailureReason(error) === 'marker_token')
  for (const text of ['', '  ', '产品\n报告']) {
    response.choices[0].message.content = JSON.stringify({ results: [
      { i: 0, t: text }, { i: 1, t: `A ${pair.open}B${pair.close}` }
    ] })
    assert.throws(() => restoreBoldResult(response, format))
  }
})

test('marker-like text from the source can remain in a full-bold translation', () => {
  const text = '保留 ⟦THB:S⟧ 示例'
  const format = makeBoldFormat([text], [[[0, Buffer.byteLength(text)]]])
  const translated = 'Keep ⟦THB:S⟧ example'
  const response = { choices: [{ message: { content: JSON.stringify({ results: [{ i: 0, t: translated }] }) } }] }
  const result = JSON.parse(restoreBoldResult(response, format).choices[0].message.content).results[0]
  assert.deepEqual(result, { i: 0, t: translated, boldRanges: [[0, Buffer.byteLength(translated)]] })
})

test('marker-like source text survives partial bold and cannot be replaced with forged markers', () => {
  const text = 'Keep ⟦THB:S⟧ example'
  const start = Buffer.byteLength('Keep ⟦T')
  const format = makeBoldFormat([text], [[[start, start + 1]]])
  const response = value => ({ choices: [{ message: { content: JSON.stringify({ results: [{ i: 0, t: value }] }) } }] })
  const result = JSON.parse(restoreBoldResult(response(format.marked[0]), format).choices[0].message.content).results[0]
  assert.deepEqual(result, { i: 0, t: text, boldRanges: [[start, start + 1]] })
  const pair = format.expected[0][0]
  for (const forged of ['⟦THB:BAD', `⟦THB:${'x'.repeat(150)}⟧`]) {
    assert.throws(() => restoreBoldResult(response(`${pair.open}H${pair.close} ${forged}`), format),
      error => formatFailureReason(error) === 'marker_token')
  }
})

test('upstream requests ask for markers only where the input has them', () => {
  const config = { model: 'test', endpoint: 'https://api.deepseek.com/v1/chat/completions' }
  const prepare = items => prepareUpstreamPayload(JSON.stringify({ stream: false, messages: [
    { role: 'system', content: 'Translate into Simplified Chinese (简体中文).' },
    { role: 'user', content: JSON.stringify(items) }
  ] }), config, items.map(item => item.text).join('\n'))
  const full = prepare([{ i: 0, text: 'Title', boldRanges: [[0, 5]] }])
  assert.equal(full.payload.messages[0].content.includes('Formatting markers in text'), false)
  assert.equal(JSON.parse(full.payload.messages[1].content)[0].text, 'Title')
  const mixed = prepare([{ i: 0, text: 'Title', boldRanges: [[0, 5]] }, { i: 1, text: 'A B', boldRanges: [[2, 3]] }])
  const entries = JSON.parse(mixed.payload.messages[1].content)
  assert.equal(entries[0].text, 'Title')
  assert.match(entries[1].text, /⟦THB/)
  assert.match(mixed.payload.messages[0].content, /Do not add markers to an item that has none/)
})

test('format failures are classified without copying model text', () => {
  const format = makeBoldFormat(['A B'], [[[2, 3]]], '', () => '0123456789abcdef01234567')
  const pair = format.expected[0][0]
  const response = content => ({ choices: [{ message: { content }, finish_reason: 'stop' }] })
  const body = text => JSON.stringify({ results: [{ i: 0, t: text }] })
  const cases = [
    [response('private bad JSON'), 'json'],
    [response(JSON.stringify({ results: [] })), 'items'],
    [response(body('missing marker')), 'marker_missing'],
    [response(body(`${pair.close}B${pair.open}`)), 'marker_order'],
    [response(body(`${pair.open}B${pair.close}${pair.open}B${pair.close}`)), 'marker_token'],
    [{ choices: [{ message: { content: body('truncated') }, finish_reason: 'length' }] }, 'incomplete']
  ]
  for (const [value, expected] of cases) {
    assert.throws(() => restoreBoldResult(value, format), error => {
      assert.equal(formatFailureReason(error), expected)
      assert.equal(error.message, 'invalid formatted output')
      return true
    })
  }
  assert.equal(formatFailureReason(new Error('private provider text')), 'internal')
})

test('invalid markers return a settlement receipt after paid model use', async () => {
  const text = 'Hello World'
  const store = new MemoryAccountStore()
  const now = Date.parse('2026-11-04T03:00:00Z')
  await store.redeem('test-user', 'translatehud-200', now, {})
  const ctx = {
    now: () => now,
    env: { gateway:'https://test.invalid', apiKey:'test', baseURL:'https://api.deepseek.com/v1', model:'test' },
    headers: { authorization:'Bearer test', 'x-translatehud-source':Buffer.from(text).toString('base64') },
    verifyUser: async () => ({uid:'test-user'}), store,
    rawBody:JSON.stringify({stream:false,messages:[{role:'user',content:JSON.stringify([{i:0,text,boldRanges:[[0,5]]}])}]}),
    forward:async () => ({status:200,text:JSON.stringify({choices:[{message:{content:JSON.stringify({results:[{i:0,t:'你好世界'}]})}}],usage:{prompt_tokens:500,completion_tokens:80}})})
  }
  const response = await handleTranslate(ctx)
  assert.equal(response.status, 422)
  const result = JSON.parse(response.body)
  assert.equal(result.error.code, 'trial_format_invalid')
  assert.ok(result.translatehud_trial.chargedMicroYuan > 0)
  assert.equal(result.translatehud_trial.balanceMicroYuan, 2000000 - result.translatehud_trial.chargedMicroYuan)
  assert.equal((await store.ensure('test-user')).record.balanceMicroYuan, result.translatehud_trial.balanceMicroYuan)
})
