'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const candidate = process.env.TRIAL_CANDIDATE_ROOT
if (!candidate || !path.isAbsolute(candidate)) throw new Error('TRIAL_CANDIDATE_ROOT must be the absolute candidate path')
const { defaultVerifyUser, handleAccount, handleRedeem } = require(path.join(candidate, 'src/trialService'))
const { MemoryAccountStore } = require(path.join(candidate, 'src/accountStore'))

test('email receives zero-balance daily allowance and cannot redeem an invite', async () => {
  const store = new MemoryAccountStore()
  const now = Date.parse('2026-11-04T03:00:00Z')
  const ctx = { store, now: () => now, env: { gateway: 'https://test.invalid' }, headers: { authorization: 'Bearer x' },
    verifyUser: async () => ({ uid: 'email-user', hasEligiblePhone: false }), rawBody: '{"code":"translatehud-200","phone_number":"+86 13800138000"}' }
  const account = await handleAccount(ctx)
  assert.equal(account.status, 200)
  assert.equal(JSON.parse(account.body).balanceMicroYuan, 0)
  assert.equal(JSON.parse(account.body).dailyLimit, 2000)
  assert.equal(JSON.parse(account.body).canRedeemInvite, false)
  const denied = await handleRedeem(ctx)
  assert.equal(denied.status, 403)
  assert.equal(JSON.parse(denied.body).error.code, 'trial_invite_phone_required')
  assert.equal(store.invite.redeemedCount, 0)
  const held = await store.acquireInflight('email-user', now, 10)
  assert.equal(held.ok, true)
  assert.equal(held.free, true)
  const settled = await store.settle('email-user', 531, held.slotId, now)
  assert.equal(settled.balanceMicroYuan, 0)
  assert.equal(settled.chargedMicroYuan, 0)
  assert.equal(settled.dailyTokens, 10)
})

test('phone identity can redeem and unknown identity fails closed', async () => {
  const store = new MemoryAccountStore()
  const ctx = { store, now: () => 1793761200000, env: { gateway: 'https://test.invalid' }, headers: { authorization: 'Bearer x' },
    verifyUser: async () => ({ uid: 'phone-user', hasEligiblePhone: true }), rawBody: '{"code":"translatehud-200"}' }
  const ok = await handleRedeem(ctx)
  assert.equal(ok.status, 200)
  assert.equal(JSON.parse(ok.body).balanceMicroYuan, 2000000)
  assert.equal(JSON.parse(ok.body).canRedeemInvite, true)
  const account = await handleAccount(ctx)
  assert.equal(JSON.parse(account.body).canRedeemInvite, true)
  assert.equal(JSON.parse(account.body).inviteRedeemed, true)
  ctx.verifyUser = async () => ({ uid: 'unknown-user' })
  const denied = await handleRedeem(ctx)
  assert.equal(denied.status, 403)
  assert.equal(store.invite.redeemedCount, 1)
})

test('eligibility comes from the authenticated profile, not request body', async () => {
  const fetchImpl = async () => ({ ok: true, json: async () => ({ sub: 'email-user', email: 'person@example.com' }) })
  assert.deepEqual(await defaultVerifyUser({ gateway: 'https://test.invalid', token: 'x', fetchImpl }), { uid: 'email-user', hasEligiblePhone: false })
  const linked = async () => ({ ok: true, json: async () => ({ sub: 'linked-user', email: 'person@example.com', phone_number: '+86 13800138000' }) })
  assert.deepEqual(await defaultVerifyUser({ gateway: 'https://test.invalid', token: 'x', fetchImpl: linked }), { uid: 'linked-user', hasEligiblePhone: true })
})
