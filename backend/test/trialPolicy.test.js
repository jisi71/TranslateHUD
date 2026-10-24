'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  GIFT_FEN,
  GIFT_MICRO_YUAN,
  MAX_GRAPHEMES,
  MESSAGES,
  MICRO_YUAN_PER_FEN,
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

test('gift is applied once and a legacy fen balance migrates to micro-yuan', () => {
  const first = openAccount(null, 1000)
  assert.equal(first.giftedNow, true)
  assert.equal(first.record.balanceMicroYuan, GIFT_MICRO_YUAN)
  assert.equal(first.record.balanceFen, GIFT_FEN)
  assert.equal(first.record.giftGranted, true)

  const legacy = openAccount({ balanceFen: 150, giftGranted: true, createdAt: 1000 }, 2000)
  assert.equal(legacy.giftedNow, false)
  assert.equal(legacy.record.balanceMicroYuan, 150 * MICRO_YUAN_PER_FEN)
  assert.equal(legacy.record.balanceFen, 150)
  assert.equal(legacy.record.createdAt, 1000)

  const spent = { balanceMicroYuan: 0, balanceFen: GIFT_FEN, giftGranted: true, createdAt: 1000 }
  const again = openAccount(spent, 3000)
  assert.equal(again.giftedNow, false)
  assert.equal(again.record.balanceMicroYuan, 0)
  assert.equal(again.record.balanceFen, 0)
})

test('balance gate rejects an empty wallet and a short wallet without changing them', () => {
  const empty = applyCharge({ balanceMicroYuan: 0, giftGranted: true, createdAt: 1 }, 1)
  assert.equal(empty.ok, false)
  assert.equal(empty.code, 'trial_balance_exhausted')
  assert.equal(empty.message, MESSAGES.exhausted)
  assert.match(empty.message, /API Key/)

  const short = applyCharge({ balanceMicroYuan: 5, giftGranted: true, createdAt: 1 }, 6)
  assert.equal(short.ok, false)
  assert.equal(short.code, 'trial_balance_insufficient')
  assert.equal(short.balanceMicroYuan, 5)
  assert.equal(short.balanceFen, 0)

  const exact = applyCharge({ balanceMicroYuan: 50, giftGranted: true, createdAt: 1 }, 50)
  assert.equal(exact.ok, true)
  assert.equal(exact.balanceMicroYuan, 0)
  assert.equal(exact.balanceFen, 0)

  const missing = applyCharge(null, 1)
  assert.equal(missing.ok, false)
  assert.equal(missing.code, 'trial_balance_exhausted')
})

test('settlement spends micro-yuan, keeps a sub-fen remainder, and stops at zero', () => {
  const dust = settleCharge({ balanceMicroYuan: GIFT_MICRO_YUAN, giftGranted: true, createdAt: 1 }, 10)
  assert.equal(dust.ok, true)
  assert.equal(dust.costMicroYuan, 10)
  assert.equal(dust.chargedMicroYuan, 10)
  assert.equal(dust.balanceMicroYuan, GIFT_MICRO_YUAN - 10)
  assert.equal(dust.costFen, 0)
  assert.equal(dust.chargedFen, 0)
  assert.equal(dust.balanceFen, GIFT_FEN)
  assert.equal(dust.clamped, false)

  const last = settleCharge({ balanceMicroYuan: MICRO_YUAN_PER_FEN, giftGranted: true, createdAt: 1 }, GIFT_MICRO_YUAN)
  assert.equal(last.chargedMicroYuan, MICRO_YUAN_PER_FEN)
  assert.equal(last.balanceMicroYuan, 0)
  assert.equal(last.costFen, GIFT_FEN)
  assert.equal(last.chargedFen, 1)
  assert.equal(last.clamped, true)
  assert.equal(last.record.balanceMicroYuan, 0)

  const empty = settleCharge({ balanceMicroYuan: 0, giftGranted: true, createdAt: 1 }, 10)
  assert.equal(empty.chargedMicroYuan, 0)
  assert.equal(empty.balanceMicroYuan, 0)
  assert.equal(empty.chargedFen, 0)
  assert.equal(empty.clamped, true)
})
