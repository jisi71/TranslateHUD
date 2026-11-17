'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { defaultVerifyUser, handleAccount, handleRedeem } = require('../src/trialService')
const { MemoryAccountStore } = require('../src/accountStore')

// No live auth, mail delivery, translation, environment files or provider credentials.
for (const domain of ['qq.com', '163.com', '126.com', 'outlook.com', 'hotmail.com', 'icloud.com', 'yahoo.com', 'foxmail.com']) {
  test(`${domain}: authenticated email opens zero balance and cannot redeem via forged phone`, async () => {
    const store = new MemoryAccountStore()
    let lookups = 0
    const ctx = {
      store, now: () => 1793761200000,
      env: { gateway: 'https://auth.invalid' },
      headers: { authorization: 'Bearer mock-access' },
      rawBody: JSON.stringify({ code: 'translatehud-200', phone_number: '+86 13800138000', hasEligiblePhone: true }),
      verifyUser: args => defaultVerifyUser({ ...args, fetchImpl: async (url, options) => {
        lookups++
        assert.equal(url, 'https://auth.invalid/auth/v1/user/me')
        assert.equal(options.headers.Authorization, 'Bearer mock-access')
        return { ok: true, json: async () => ({ sub: 'mock-user', email: `mock+tag@${domain}` }) }
      } })
    }
    for (let attempt = 0; attempt < 2; attempt++) {
      const response = await handleAccount(ctx)
      assert.equal(response.status, 200)
      const account = JSON.parse(response.body)
      assert.equal(account.balanceMicroYuan, 0)
      assert.equal(account.canRedeemInvite, false)
      assert.equal(account.giftedNow, false)
      const denied = await handleRedeem(ctx)
      assert.equal(denied.status, 403)
      assert.equal(JSON.parse(denied.body).error.code, 'trial_invite_phone_required')
    }
    assert.equal(lookups, 4)
    assert.equal(store.invite.redeemedCount, 0)
    assert.equal(store.users.get('mock-user').balanceMicroYuan, 0)
    assert.equal(JSON.stringify([...store.users]).includes(`mock+tag@${domain}`), false)
  })
}

for (const scenario of ['unauthorized', 'missing uid', 'transport failure']) {
  test(`email profile ${scenario}: fails closed without creating an account`, async () => {
    const store = new MemoryAccountStore()
    const ctx = {
      store, now: () => 1793761200000, env: { gateway: 'https://auth.invalid' },
      headers: { authorization: 'Bearer mock-access' }, rawBody: '{"code":"translatehud-200"}',
      verifyUser: args => defaultVerifyUser({ ...args, fetchImpl: async () => {
        if (scenario === 'transport failure') throw new Error('offline')
        return { ok: scenario !== 'unauthorized', json: async () => ({ email: 'mock@outlook.com' }) }
      } })
    }
    assert.equal((await handleAccount(ctx)).status, 401)
    assert.equal((await handleRedeem(ctx)).status, 401)
    assert.equal(store.users.size, 0)
    assert.equal(store.invite.redeemedCount, 0)
  })
}
