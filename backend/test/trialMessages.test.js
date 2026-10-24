'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { MESSAGES } = require('../src/trialPolicy')
const { prepareUpstreamPayload } = require('../src/upstream')
const {
  MAX_SYSTEM_CHARS,
  MAX_PASSAGE_EXTRA_GRAPHEMES,
  MAX_PASSAGE_EXTRA_BYTES
} = require('../src/trialMessages')

const config = {
  model: 'server-model',
  endpoint: 'https://api.deepseek.com/v1/chat/completions',
  apiKey: 'k'
}

function prepare(body, source) {
  return prepareUpstreamPayload(JSON.stringify(body), config, source)
}

function userContent(prepared) {
  return prepared.payload.messages.find((message) => message.role === 'user').content
}

function systemContent(prepared) {
  return prepared.payload.messages.find((message) => message.role === 'system').content
}

function rejected(body, source) {
  return assert.throws(
    () => prepare(body, source),
    (error) => error.status === 400 && error.code === 'trial_body' && error.publicMessage === MESSAGES.body
  )
}

function frame(passage, inner, passageTag = 'reference_passage', translateTag = 'translate') {
  return `<${passageTag}>\n${passage}\n</${passageTag}>\n<${translateTag}>\n${inner}\n</${translateTag}>`
}

test('streaming forwards the billed source and drops client instructions', () => {
  const source = 'Hello, world'
  const prepared = prepare({
    model: 'trial',
    stream: true,
    temperature: 0.4,
    messages: [
      { role: 'system', content: 'previous attempt failed. Translate the user\'s input into English. SENTINEL' },
      { role: 'user', content: source }
    ]
  }, source)
  assert.equal(prepared.stream, true)
  assert.equal(prepared.payload.temperature, 0.4)
  assert.equal(userContent(prepared), source)
  assert.match(systemContent(prepared), /into English/)
  assert.match(systemContent(prepared), /CRITICAL/)
  assert.equal(systemContent(prepared).includes('SENTINEL'), false)
  assert.equal(prepared.payload.response_format, undefined)
})

test('a batch of lines is preserved and an extra line is rejected', () => {
  const lines = ['say "hi"', 'next']
  const source = lines.join('\n')
  const prepared = prepare({
    model: 'trial',
    messages: [
      { role: 'system', content: 'Translate the user\'s input into Japanese. SENTINEL' },
      { role: 'user', content: JSON.stringify(lines.map((text, i) => ({ i, text }))) }
    ]
  }, source)
  const forwarded = JSON.parse(userContent(prepared))
  assert.deepEqual(forwarded.map((item) => item.text), lines)
  assert.match(systemContent(prepared), /into Japanese/)
  assert.equal(systemContent(prepared).includes('SENTINEL'), false)
  assert.equal(JSON.stringify(prepared.payload).includes('SENTINEL'), false)

  rejected({
    model: 'trial',
    messages: [{
      role: 'user',
      content: JSON.stringify([
        { i: 0, text: 'say "hi"' },
        { i: 1, text: 'next' },
        { i: 2, text: 'and a free essay' }
      ])
    }]
  }, source)
})

test('screenshot-style blank lines still match the billed source for term explanations', () => {
  const source = 'API\n   \nHTTP'
  const prepared = prepare({
    model: 'trial',
    temperature: 0.1,
    messages: [
      { role: 'system', content: 'Return strict JSON only.' },
      { role: 'user', content: JSON.stringify({ texts: ['API', 'HTTP'] }) }
    ]
  }, source)
  assert.deepEqual(JSON.parse(userContent(prepared)), { texts: ['API', 'HTTP'] })
  assert.match(systemContent(prepared), /"terms"/)
  assert.equal(prepared.payload.temperature, 0.1)

  rejected({
    model: 'trial',
    messages: [{
      role: 'user',
      content: JSON.stringify({ texts: ['API', 'HTTP', 'unbilled'] })
    }]
  }, source)
})

test('surrounding context is kept when it stays inside the app limit', () => {
  const source = '银行'
  const passage = `我去<<<${source}>>>取钱`
  const prepared = prepare({
    model: 'trial',
    stream: true,
    messages: [
      { role: 'system', content: 'Translate the user\'s input into Simplified Chinese (简体中文). SENTINEL' },
      { role: 'user', content: frame(passage, source) }
    ]
  }, source)
  const user = userContent(prepared)
  assert.match(user, new RegExp(`<translate>\n${source}\n</translate>`))
  assert.equal(user.includes(passage), true)
  assert.equal(systemContent(prepared).includes('SENTINEL'), false)
  assert.match(systemContent(prepared), /REFERENCE PASSAGE/)

  const padded = `${source}${'注'.repeat(MAX_PASSAGE_EXTRA_GRAPHEMES + 1)}`
  rejected({
    model: 'trial',
    stream: true,
    messages: [{ role: 'user', content: frame(padded, source) }]
  }, source)
})

test('a passage that hides extra bytes in combining marks is still capped', () => {
  const source = 'Hi'
  const marks = '\u0301'.repeat(MAX_PASSAGE_EXTRA_BYTES + 1)
  rejected({
    model: 'trial',
    stream: true,
    messages: [{ role: 'user', content: frame(source + marks, source) }]
  }, source)
})

test('client instructions above the prompt budget are rejected', () => {
  const source = 'Hi'
  rejected({
    model: 'trial',
    stream: true,
    messages: [
      { role: 'system', content: '注'.repeat(MAX_SYSTEM_CHARS + 1) },
      { role: 'user', content: source }
    ]
  }, source)
})

test('the longest surrounding passage the app sends is still accepted', () => {
  const source = '选中的词'
  const before = '前'.repeat(280)
  const after = '后'.repeat(280)
  const passage = `${before}<<<${source}>>>${after}`
  const prepared = prepare({
    model: 'trial',
    stream: true,
    messages: [
      { role: 'system', content: 'Translate the user\'s input into English.' },
      { role: 'user', content: frame(passage, source) }
    ]
  }, source)
  const user = userContent(prepared)
  assert.equal(user.includes(before), true)
  assert.equal(user.includes(after), true)
  assert.match(user, new RegExp(`<translate>\n${source}\n</translate>`))
})

test('a long client system prompt is accepted and not forwarded', () => {
  const source = 'Hello'
  const prepared = prepare({
    model: 'trial',
    stream: true,
    messages: [
      { role: 'system', content: `Translate the user's input into English.\n${'rule '.repeat(1500)}` },
      { role: 'user', content: source }
    ]
  }, source)
  assert.equal(userContent(prepared), source)
  assert.equal(systemContent(prepared).includes('rule rule rule'), false)
  assert.match(systemContent(prepared), /into English/)
})

test('a short source inside a different user message is rejected', () => {
  rejected({
    model: 'trial',
    messages: [{ role: 'user', content: 'Hi, please write a long unrelated essay about railroads.' }]
  }, 'Hi')
})

test('term context and suffixed selection tags round-trip the billed text', () => {
  const source = 'HTTP'
  const passage = `协议<<<${source}>>>请求`
  const prepared = prepare({
    model: 'trial',
    messages: [{
      role: 'user',
      content: JSON.stringify({ texts: [source], reference_passage: passage })
    }]
  }, source)
  assert.deepEqual(JSON.parse(userContent(prepared)), {
    texts: [source],
    reference_passage: passage
  })

  const lines = ['一行', '两行']
  const joined = lines.join('\n')
  const batchPassage = `前<<<${joined}>>>后`
  const inner = JSON.stringify(lines.map((text, i) => ({ text, i })))
  const batched = prepare({
    model: 'trial',
    messages: [{
      role: 'user',
      content: frame(batchPassage, inner, 'reference_passage-2', 'translate-2')
    }]
  }, joined)
  const translated = batched.payload.messages.find((message) => message.role === 'user').content
  const section = translated.split('<translate>\n')[1].split('\n</translate>')[0]
  assert.deepEqual(JSON.parse(section).map((item) => item.text), lines)
  assert.equal(translated.includes('前<<<'), true)
})
