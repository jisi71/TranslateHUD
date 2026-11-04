'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { makeBoldFormat, restoreBoldResult } = require('../src/structuredBold')
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
