'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  GIFT_FEN,
  MAX_GRAPHEMES,
  MESSAGES,
  applyCharge,
  graphemeLength,
  openAccount,
  quoteSource,
  settleCharge
} = require('../src/trialPolicy')

test('graphemes match extended clusters, including combining marks and emoji', () => {
  assert.equal(graphemeLength('你好'), 2)
  assert.equal(graphemeLength('a\u0301'), 1)
  assert.equal(graphemeLength('👨‍👩‍👧‍👦'), 1)
  assert.equal(graphemeLength('字'.repeat(500)), 500)
  assert.equal(graphemeLength('字\n字'), 3)
})

test('500 graphemes are allowed and 501 are rejected with the product message', () => {
  const allowed = quoteSource('字'.repeat(MAX_GRAPHEMES))
  assert.equal(allowed.ok, true)
  assert.equal(allowed.graphemes, 500)
  assert.equal(Object.hasOwn(allowed, 'costFen'), false)
  const rejected = quoteSource('字'.repeat(MAX_GRAPHEMES + 1))
  assert.equal(rejected.ok, false)
  assert.equal(rejected.code, 'trial_length_limit')
  assert.equal(rejected.message, '超出单次翻译上限（体验额度单次最多 500 字）')
  assert.equal(rejected.message, MESSAGES.length)
  assert.equal(rejected.message.includes('字'.repeat(50)), false)
})

test('gift is applied once and never tops up an existing account', () => {
  const first = openAccount(null, 1000)
  assert.equal(first.giftedNow, true)
  assert.equal(first.record.balanceFen, GIFT_FEN)
  assert.equal(first.record.giftGranted, true)

  const spent = { balanceFen: 0, giftGranted: true, createdAt: 1000 }
  const again = openAccount(spent, 2000)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceFen, 0)
  assert.equal(again.record.createdAt, 1000)
})

test('balance gate rejects an empty wallet and a short wallet without changing them', () => {
  const empty = applyCharge({ balanceFen: 0, giftGranted: true, createdAt: 1 }, 1)
  assert.equal(empty.ok, false)
  assert.equal(empty.code, 'trial_balance_exhausted')
  assert.equal(empty.message, MESSAGES.exhausted)
  assert.match(empty.message, /API Key/)

  const short = applyCharge({ balanceFen: 5, giftGranted: true, createdAt: 1 }, 6)
  assert.equal(short.ok, false)
  assert.equal(short.code, 'trial_balance_insufficient')
  assert.equal(short.balanceFen, 5)

  const exact = applyCharge({ balanceFen: 50, giftGranted: true, createdAt: 1 }, 50)
  assert.equal(exact.ok, true)
  assert.equal(exact.balanceFen, 0)

  const missing = applyCharge(null, 1)
  assert.equal(missing.ok, false)
  assert.equal(missing.code, 'trial_balance_exhausted')
})

test('settlement spends the token cost and stops at zero', () => {
  const paid = settleCharge({ balanceFen: 200, giftGranted: true, createdAt: 1 }, 6)
  assert.equal(paid.ok, true)
  assert.equal(paid.costFen, 6)
  assert.equal(paid.chargedFen, 6)
  assert.equal(paid.balanceFen, 194)
  assert.equal(paid.clamped, false)

  const last = settleCharge({ balanceFen: 1, giftGranted: true, createdAt: 1 }, 6)
  assert.equal(last.chargedFen, 1)
  assert.equal(last.balanceFen, 0)
  assert.equal(last.costFen, 6)
  assert.equal(last.clamped, true)
  assert.equal(last.record.balanceFen, 0)

  const empty = settleCharge({ balanceFen: 0, giftGranted: true, createdAt: 1 }, 6)
  assert.equal(empty.chargedFen, 0)
  assert.equal(empty.balanceFen, 0)
  assert.equal(empty.clamped, true)
})
