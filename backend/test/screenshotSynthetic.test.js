'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const { MemoryAccountStore } = require('../src/accountStore')
const { handleTranslate } = require('../src/trialService')

const values = [
  { text: 'Product Status Report', boldRanges: [[0, 21]] },
  { text: 'Quarterly Overview', boldRanges: [[0, 18]] },
  { text: 'Please check the highlighted details before review.', boldRanges: [[17, 36]] },
  { text: 'Empty cells must remain empty.' },
  { text: 'Name' }, { text: 'Region' }, { text: 'Notes' },
  { text: 'A B', boldRanges: [[2, 3]] },
  { text: 'New York', boldRanges: [[4, 8]] },
  { text: 'slow response', boldRanges: [[0, 4]] },
  { text: 'Beta' }, { text: 'Los Angeles' },
  { text: '人工智能系统', boldRanges: [[6, 12]] }, { text: '大模型' }, { text: '处理中' }
]
const translations = [
  '产品状态报告', '季度概览', '请在审核前检查突出显示的详细信息。', '空单元格必须保持为空。',
  '名称', '地区', '备注', 'A B', '纽约', '响应缓慢', '贝塔', '洛杉矶', '人工智能系统', '大模型', '处理中'
]

function markedOutput(value, index) {
  const text = translations[index]
  const marks = [...value.matchAll(/⟦THB[0-9a-f]{24}:\d+:\d+:[SE]⟧/gu)].map(match => match[0])
  if (!marks.length) return text
  assert.equal(marks.length, 2)
  if (index === 8) return `${marks[0]}${text}${marks[1]}`
  if (index === 2) return `请在审核前检查${marks[0]}突出显示的详细信息${marks[1]}。`
  if (index === 7) return `A ${marks[0]}B${marks[1]}`
  if (index === 9) return `响应${marks[0]}缓慢${marks[1]}`
  if (index === 12) return `人工${marks[0]}智能${marks[1]}系统`
  throw new Error('missing synthetic marker mapping')
}

test('synthetic screenshot keeps label cells and bold spans through the trial backend', async () => {
  const text = values.map(value => value.text).join('\n')
  const store = new MemoryAccountStore()
  const now = Date.parse('2026-11-04T03:00:00Z')
  await store.redeem('synthetic-user', 'translatehud-200', now, {})
  let calls = 0
  const ctx = {
    now: () => now,
    env: { gateway: 'https://test.invalid', apiKey: 'not-real', baseURL: 'https://api.deepseek.com/v1', model: 'test' },
    headers: { authorization: 'Bearer fake', 'x-translatehud-source': Buffer.from(text).toString('base64') },
    verifyUser: async () => ({ uid: 'synthetic-user' }),
    store,
    rawBody: JSON.stringify({
      stream: false,
      messages: [
        { role: 'system', content: 'Translate into Simplified Chinese (简体中文).' },
        { role: 'user', content: JSON.stringify(values.map((value, i) => ({ i, ...value }))) }
      ]
    }),
    forward: async ({ payload }) => {
      calls++
      const marked = JSON.parse(payload.messages[1].content)
      assert.equal(marked[0].text, values[0].text)
      assert.equal(marked[1].text, values[1].text)
      const results = marked.map(({ i, text }) => ({ i, t: markedOutput(text, i) }))
      return {
        status: 200,
        text: JSON.stringify({
          choices: [{ message: { content: JSON.stringify({ results }) }, finish_reason: 'stop' }],
          usage: { prompt_tokens: 500, completion_tokens: 80 }
        })
      }
    }
  }
  const result = await handleTranslate(ctx)
  assert.equal(calls, 1)
  assert.equal(result.status, 200)
  const body = JSON.parse(result.body)
  const restored = JSON.parse(body.choices[0].message.content).results
  assert.equal(restored.length, values.length)
  assert.deepEqual(restored[0], { i: 0, t: '产品状态报告', boldRanges: [[0, 18]] })
  assert.deepEqual(restored[7], { i: 7, t: 'A B', boldRanges: [[2, 3]] })
  assert.deepEqual(restored[9], { i: 9, t: '响应缓慢', boldRanges: [[6, 12]] })
  assert.deepEqual(restored[12], { i: 12, t: '人工智能系统', boldRanges: [[6, 12]] })
  assert.ok(body.translatehud_trial)
  const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, '../../TranslateHUDTests/Fixtures/ScreenshotTables/synthetic-structured-response.json'), 'utf8'))
  assert.deepEqual(body, fixture)
})
