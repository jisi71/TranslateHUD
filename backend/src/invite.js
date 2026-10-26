'use strict'

const { GIFT_MICRO_YUAN, MESSAGES, grantInviteGift } = require('./trialPolicy')

const DEFAULT_INVITE_CODE = 'translatehud-200'
const DEFAULT_MAX_REDEEMS = 200

function positiveInt(value) {
  if (value == null || String(value).trim() === '') return null
  const n = Number(value)
  if (!Number.isFinite(n)) return null
  const whole = Math.floor(n)
  if (whole <= 0 || !Number.isSafeInteger(whole)) return null
  return whole
}

function parseCodes(value) {
  if (Array.isArray(value)) {
    const codes = []
    for (const item of value) {
      for (const code of parseCodes(item)) {
        if (!codes.includes(code)) codes.push(code)
      }
    }
    return codes
  }
  const codes = []
  for (const part of String(value ?? '').split(/[,，\r\n]+/)) {
    const code = part.trim()
    if (code && !codes.includes(code)) codes.push(code)
  }
  return codes
}

function normalizeInviteCode(value) {
  return String(value ?? '').trim()
}

// The public code defaults to translatehud-200. TRIAL_INVITE_CODE replaces
// that default when it is non-empty. The trial_invite/config document can add
// more codes and can raise maxRedeems. The larger cap wins, so either the env
// var or the document can add quota without a code change.
function resolveInviteConfig(env = {}, stored = null) {
  const envMax = positiveInt(env && env.TRIAL_INVITE_MAX_REDEEMS) || DEFAULT_MAX_REDEEMS
  const storedMax = positiveInt(stored && stored.maxRedeems)
  const maxRedeems = storedMax ? Math.max(envMax, storedMax) : envMax
  const envCodes = parseCodes(env && env.TRIAL_INVITE_CODE)
  const primary = envCodes.length ? envCodes : [DEFAULT_INVITE_CODE]
  const codes = []
  for (const code of [...primary, ...parseCodes(stored && stored.codes)]) {
    if (!codes.includes(code)) codes.push(code)
  }
  return { maxRedeems, codes, publicCode: primary[0] }
}

function publicInviteStatus(counter, env) {
  const stored = counter && typeof counter === 'object' ? counter : { redeemedCount: 0 }
  const config = resolveInviteConfig(env, stored)
  const redeemedCount = Math.max(0, Math.floor(Number(stored.redeemedCount) || 0))
  const remaining = Math.max(0, config.maxRedeems - redeemedCount)
  return {
    code: config.publicCode,
    remaining,
    maxRedeems: config.maxRedeems,
    redeemedCount,
    exhausted: remaining === 0
  }
}

function keptConfig(counter) {
  const next = {}
  const maxRedeems = positiveInt(counter && counter.maxRedeems)
  if (maxRedeems) next.maxRedeems = maxRedeems
  const codes = parseCodes(counter && counter.codes)
  if (codes.length) next.codes = codes
  return next
}

function nextCounter(counter) {
  const count = Math.max(0, Math.floor(Number(counter && counter.redeemedCount) || 0))
  return { redeemedCount: count + 1, ...keptConfig(counter) }
}

function fail(status, code, message, extra) {
  return { ok: false, status, code, message, ...extra }
}

// Claimed accounts are told they already claimed, even if this code is wrong.
// A wrong code does not increment the global counter. Exhaustion does not either.
function decideRedeem({ record, counter, code, now, env }) {
  const stored = counter && typeof counter === 'object' ? counter : { redeemedCount: 0 }
  const granted = grantInviteGift(record, now)
  if (!granted.ok) {
    return fail(409, 'trial_invite_claimed', MESSAGES.inviteClaimed, { record: granted.record })
  }
  const config = resolveInviteConfig(env, stored)
  if (config.codes.length === 0) {
    return fail(503, 'trial_invite_unconfigured', MESSAGES.inviteUnconfigured)
  }
  const entered = normalizeInviteCode(code)
  if (!entered || entered.length > 64 || !config.codes.includes(entered)) {
    return fail(400, 'trial_invite_invalid', MESSAGES.inviteInvalid)
  }
  const count = Math.max(0, Math.floor(Number(stored.redeemedCount) || 0))
  if (count >= config.maxRedeems) {
    return fail(403, 'trial_invite_exhausted', MESSAGES.inviteExhausted)
  }
  return {
    ok: true,
    status: 200,
    record: granted.record,
    counter: nextCounter(stored),
    giftedNow: true,
    giftMicroYuan: GIFT_MICRO_YUAN,
    maxRedeems: config.maxRedeems
  }
}

module.exports = {
  DEFAULT_INVITE_CODE,
  DEFAULT_MAX_REDEEMS,
  parseCodes,
  normalizeInviteCode,
  resolveInviteConfig,
  publicInviteStatus,
  decideRedeem
}
